--[=[
	ReliableMessagingService: RLNC-based reliable messaging wrapper
	
	Simple reliable message delivery over MessagingService using Random Linear
	Network Coding (RLNC) for erasure correction.
	
	Wire format (17 bytes binary header):
		[8 bytes: JobId prefix] [4 bytes: Counter] [1 byte: Timestamp]
		[2 bytes: PieceByteLen] [1 byte: PieceCount] [1 byte: Flags]
	
	Return type: ReliableMessagingService module
	
	Example usage:
		local RMS = require(path.to.ReliableMessagingService)
		local Service = RMS.New()
		
		local Connection = Service:Subscribe("MyTopic", function(Data: buffer)
			print("Received:", buffer.tostring(Data))
		end)
		
		local Success, Error = Service:Publish("MyTopic", buffer.fromstring("Hello!"))
		
		Connection:Disconnect()
		Service:Destroy()
--]=]

--!strict

local MessagingService = game:GetService("MessagingService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local RLNC = require("@self/RLNC")
local RetryAsync = require("@self/RetryAsync")

type Encoder = RLNC.Encoder
type Decoder = RLNC.Decoder
type RLNCError = RLNC.RLNCError

local HEADER_SIZE = 17
local MESSAGE_SIZE_LIMIT = 900
local FLAG_COMPRESSED = 0x01

local DEFAULT_PIECE_COUNT = 8
local DEFAULT_REDUNDANCY = 1.5
local DEFAULT_TIMEOUT = 30
local DEFAULT_MAX_RETRIES = 3
local DEFAULT_RETRY_DELAY = 1

local MAX_PIECE_COUNT = 64
local MAX_DECOMPRESSED_SIZE = 1024 * 1024
local MAX_ACTIVE_PUBLISHES = 50
local MAX_PENDING_PER_TOPIC = 256

type MessageHeader = {
	JobId: string,
	Counter: number,
	Timestamp: number,
	PieceByteLen: number,
	PieceCount: number,
	Compressed: boolean,
}

type PendingMessage = {
	Decoder: Decoder,
	Compressed: boolean,
}

export type Config = {
	PieceCount: number?,
	RedundancyFactor: number?,
	Timeout: number?,
	MaxRetries: number?,
	RetryDelay: number?,
	EnableCompression: boolean?,
	CompressionLevel: number?,
}

type ServiceData = {
	PieceCount: number,
	Redundancy: number,
	Timeout: number,
	MaxRetries: number,
	RetryDelay: number,
	EnableCompression: boolean,
	CompressionLevel: number,
	JobId: string,
	Counter: number,
	Random: Random,
	ActivePublishes: number,
	Pending: { [string]: { [string]: PendingMessage } },
	PendingCounts: { [string]: number },
	Subscribing: { [string]: boolean },
	SubscribeWaiters: { [string]: { thread } },
	Callbacks: { [string]: { (Data: buffer) -> () } },
	Connections: { [string]: RBXScriptConnection },
	CleanupThread: thread?,
	Destroyed: boolean,
}

local ReliableMessagingService = {}
ReliableMessagingService.__index = ReliableMessagingService

export type ReliableMessagingService = typeof(setmetatable({} :: ServiceData, ReliableMessagingService))

local function GetAge(Timestamp: number): number
	local Now = os.time() % 256
	local Age = Now - Timestamp
	if Age < 0 then
		Age += 256
	end

	return Age
end

local function MessageIdToKey(JobId: string, Counter: number, Timestamp: number): string
	return string.format("%s-%d-%d", JobId, Counter, Timestamp)
end

local function PackMessage(Header: MessageHeader, CodedPiece: buffer): string
	local PieceLen = buffer.len(CodedPiece)
	local Buf = buffer.create(HEADER_SIZE + PieceLen)

	buffer.writestring(Buf, 0, string.sub(Header.JobId, 1, 8))
	buffer.writeu32(Buf, 8, Header.Counter)
	buffer.writeu8(Buf, 12, Header.Timestamp)
	buffer.writeu8(Buf, 13, bit32.rshift(Header.PieceByteLen, 8))
	buffer.writeu8(Buf, 14, bit32.band(Header.PieceByteLen, 0xFF))
	buffer.writeu8(Buf, 15, Header.PieceCount)
	buffer.writeu8(Buf, 16, Header.Compressed and FLAG_COMPRESSED or 0)
	buffer.copy(Buf, HEADER_SIZE, CodedPiece, 0, PieceLen)

	return buffer.tostring(EncodingService:Base64Encode(Buf))
end

local function UnpackMessage(Encoded: string): (MessageHeader?, buffer?)
	local Buf = EncodingService:Base64Decode(buffer.fromstring(Encoded))
	if buffer.len(Buf) < HEADER_SIZE then
		return nil, nil
	end

	local PieceCount = buffer.readu8(Buf, 15)
	local PieceByteLen = bit32.bor(bit32.lshift(buffer.readu8(Buf, 13), 8), buffer.readu8(Buf, 14))
	local ExpectedLen = HEADER_SIZE + PieceCount + PieceByteLen

	if buffer.len(Buf) ~= ExpectedLen then
		return nil, nil
	end

	if PieceCount == 0 or PieceCount > MAX_PIECE_COUNT then
		return nil, nil
	end

	local Flags = buffer.readu8(Buf, 16)

	local Header: MessageHeader = {
		JobId = buffer.readstring(Buf, 0, 8),
		Counter = buffer.readu32(Buf, 8),
		Timestamp = buffer.readu8(Buf, 12),
		PieceByteLen = PieceByteLen,
		PieceCount = PieceCount,
		Compressed = bit32.band(Flags, FLAG_COMPRESSED) ~= 0,
	}

	local CodedPiece = buffer.create(PieceCount + PieceByteLen)
	buffer.copy(CodedPiece, 0, Buf, HEADER_SIZE, PieceCount + PieceByteLen)

	return Header, CodedPiece
end

function ReliableMessagingService.New(Config: Config?): ReliableMessagingService
	local JobId = game.JobId
	if JobId == "" then
		JobId = HttpService:GenerateGUID(false)
	end

	local self: ServiceData = {
		PieceCount = Config and Config.PieceCount or DEFAULT_PIECE_COUNT,
		Redundancy = Config and Config.RedundancyFactor or DEFAULT_REDUNDANCY,
		Timeout = Config and Config.Timeout or DEFAULT_TIMEOUT,
		MaxRetries = Config and Config.MaxRetries or DEFAULT_MAX_RETRIES,
		RetryDelay = Config and Config.RetryDelay or DEFAULT_RETRY_DELAY,
		EnableCompression = if Config and Config.EnableCompression ~= nil then Config.EnableCompression else true,
		CompressionLevel = Config and Config.CompressionLevel or 3,

		JobId = JobId,
		Counter = 0,
		Random = Random.new(),
		ActivePublishes = 0,

		Pending = {},
		PendingCounts = {},
		Subscribing = {},
		SubscribeWaiters = {},
		Callbacks = {},
		Connections = {},

		CleanupThread = nil,
		Destroyed = false,
	}

	setmetatable(self, ReliableMessagingService)
	local Typed = self :: ReliableMessagingService

	self.CleanupThread = task.spawn(function()
		while not Typed.Destroyed do
			task.wait(Typed.Timeout / 2)
			if not Typed.Destroyed then
				Typed:CleanupExpired()
			end
		end
	end)

	return Typed
end

function ReliableMessagingService.CleanupExpired(self: ReliableMessagingService): ()
	local TimeoutValue = self.Timeout

	for Topic, TopicPending in self.Pending do
		local ToRemove = {}

		for MessageId, _ in TopicPending do
			local Timestamp = tonumber(string.match(MessageId, "%-(%d+)$")) or 0
			if GetAge(Timestamp) > TimeoutValue then
				table.insert(ToRemove, MessageId)
			end
		end

		for _, MessageId in ToRemove do
			if TopicPending[MessageId] then
				TopicPending[MessageId] = nil
				local Count = self.PendingCounts[Topic]
				if Count and Count > 0 then
					self.PendingCounts[Topic] = Count - 1
				end
			end
		end

		if next(TopicPending) == nil then
			self.Pending[Topic] = nil
			self.PendingCounts[Topic] = nil
		end
	end
end

function ReliableMessagingService.ProcessPiece(self: ReliableMessagingService, Topic: string, Header: MessageHeader, CodedPiece: buffer): ()
	local Callbacks = self.Callbacks[Topic]
	if not Callbacks or #Callbacks == 0 then
		return
	end

	if GetAge(Header.Timestamp) > self.Timeout then
		return
	end

	local MessageId = MessageIdToKey(Header.JobId, Header.Counter, Header.Timestamp)

	local TopicPending = self.Pending[Topic]
	if not TopicPending then
		TopicPending = {}
		self.Pending[Topic] = TopicPending
	end

	local PendingEntry = TopicPending[MessageId]
	if not PendingEntry then
		local Count = self.PendingCounts[Topic] or 0
		if Count >= MAX_PENDING_PER_TOPIC then
			return
		end

		local Dec, DecErr = RLNC.Decoder.New(Header.PieceByteLen, Header.PieceCount)
		if DecErr or not Dec then
			return
		end

		PendingEntry = {
			Decoder = Dec,
			Compressed = Header.Compressed,
		}
		TopicPending[MessageId] = PendingEntry
		self.PendingCounts[Topic] = Count + 1
	end

	local Dec = PendingEntry.Decoder
	if Dec:IsAlreadyDecoded() then
		return
	end

	local DecErr = Dec:Decode(CodedPiece)
	if DecErr and DecErr ~= RLNC.Error.PieceNotUseful then
		TopicPending[MessageId] = nil
		local Count = self.PendingCounts[Topic]
		if Count and Count > 0 then
			self.PendingCounts[Topic] = Count - 1
		end

		return
	end

	if not Dec:IsAlreadyDecoded() then
		return
	end

	local Decoded, ExtractErr = Dec:GetDecodedData()

	TopicPending[MessageId] = nil
	local Count = self.PendingCounts[Topic]
	if Count and Count > 0 then
		self.PendingCounts[Topic] = Count - 1
	end

	if ExtractErr or not Decoded then
		return
	end

	local FinalData = Decoded
	if PendingEntry.Compressed then
		local DecompressedSize = EncodingService:GetDecompressedBufferSize(Decoded, Enum.CompressionAlgorithm.Zstd)
		if not DecompressedSize or DecompressedSize > MAX_DECOMPRESSED_SIZE then
			return
		end
		FinalData = EncodingService:DecompressBuffer(Decoded, Enum.CompressionAlgorithm.Zstd)
	end

	for _, Callback in Callbacks do
		task.spawn(Callback, FinalData)
	end
end

function ReliableMessagingService.HandleMessage(self: ReliableMessagingService, Topic: string, Content: string): ()
	if self.Destroyed then
		return
	end

	local Header, CodedPiece = UnpackMessage(Content)
	if not Header or not CodedPiece then
		return
	end

	self:ProcessPiece(Topic, Header, CodedPiece)
end

function ReliableMessagingService.PublishAsync(self: ReliableMessagingService, Topic: string, Data: buffer): (boolean, string?)
	if self.Destroyed then
		return false, "Service has been destroyed"
	end

	if self.ActivePublishes >= MAX_ACTIVE_PUBLISHES then
		return false, "Too many active publishes"
	end

	local DataLen = buffer.len(Data)
	if DataLen == 0 then
		return false, "Data is empty"
	end

	self.ActivePublishes += 1

	local ToEncode = Data
	local IsCompressed = false

	if self.EnableCompression then
		local Compressed = EncodingService:CompressBuffer(Data, Enum.CompressionAlgorithm.Zstd, self.CompressionLevel)
		if buffer.len(Compressed) < DataLen then
			ToEncode = Compressed
			IsCompressed = true
		end
	end

	local PieceCountValue = self.PieceCount
	local Enc, EncErr = RLNC.Encoder.New(ToEncode, PieceCountValue)
	if EncErr or not Enc then
		self.ActivePublishes -= 1
		return false, RLNC.Error.Message(EncErr :: RLNCError)
	end

	local FullPieceLen = Enc:GetFullCodedPieceByteLen()
	local PieceByteLen = Enc:GetPieceByteLen()

	local MessageLen = math.ceil((HEADER_SIZE + FullPieceLen) * 4 / 3)
	if MessageLen > MESSAGE_SIZE_LIMIT then
		self.ActivePublishes -= 1
		return false, "Message too large"
	end

	local TotalPieces = math.ceil(PieceCountValue * self.Redundancy)

	self.Counter += 1
	if self.Counter > 0xFFFFFFFF then
		self.Counter = 1
		self.JobId = HttpService:GenerateGUID(false)
	end

	local CurrentJobId = self.JobId
	local CounterValue = self.Counter
	local Timestamp = os.time() % 256
	local CodedBuf = buffer.create(FullPieceLen)
	local SuccessCount = 0

	for _ = 1, TotalPieces do
		Enc:CodeWithBuffer(CodedBuf, self.Random)

		local Header: MessageHeader = {
			JobId = CurrentJobId,
			Counter = CounterValue,
			Timestamp = Timestamp,
			PieceByteLen = PieceByteLen,
			PieceCount = PieceCountValue,
			Compressed = IsCompressed,
		}

		local Message = PackMessage(Header, CodedBuf)

		local Ok = RetryAsync(function()
			MessagingService:PublishAsync(Topic, Message)
		end, self.MaxRetries, self.RetryDelay, 2)

		if Ok then
			SuccessCount += 1
		end
	end

	self.ActivePublishes -= 1

	if SuccessCount >= PieceCountValue then
		return true, nil
	end

	return false, string.format("Only %d/%d pieces sent", SuccessCount, TotalPieces)
end

function ReliableMessagingService.SubscribeAsync(self: ReliableMessagingService, Topic: string, ...: (Data: buffer) -> ()): boolean
	if self.Destroyed then
		return false
	end

	local NewCallbacks = {...}
	if #NewCallbacks == 0 then
		return false
	end

	local Callbacks = self.Callbacks[Topic]
	if not Callbacks then
		Callbacks = {}
		self.Callbacks[Topic] = Callbacks
	end

	for _, Callback in NewCallbacks do
		table.insert(Callbacks, Callback)
	end

	if self.Connections[Topic] then
		return true
	end

	if self.Subscribing[Topic] then
		local Waiters = self.SubscribeWaiters[Topic]
		if not Waiters then
			Waiters = {}
			self.SubscribeWaiters[Topic] = Waiters
		end

		table.insert(Waiters, coroutine.running())

		local Result = coroutine.yield()
		if self.Destroyed then
			return false
		end

		return Result ~= nil
	end

	self.Subscribing[Topic] = true

	local Success, Connection = RetryAsync(function()
		return MessagingService:SubscribeAsync(Topic, function(Message)
			if typeof(Message.Data) == "string" then
				self:HandleMessage(Topic, Message.Data)
			end
		end)
	end, self.MaxRetries, self.RetryDelay, 2)

	self.Subscribing[Topic] = nil

	if not Success or not Connection then
		self.Callbacks[Topic] = nil
	else
		self.Connections[Topic] = Connection
	end

	local Waiters = self.SubscribeWaiters[Topic]
	if Waiters then
		for _, Thread in Waiters do
			task.spawn(Thread, Connection)
		end
		self.SubscribeWaiters[Topic] = nil
	end

	return Connection ~= nil
end

function ReliableMessagingService.Unsubscribe(self: ReliableMessagingService, Topic: string, ...: (Data: buffer) -> ()): ()
	local ToRemove = {...}

	if #ToRemove == 0 then
		local Conn = self.Connections[Topic]
		if Conn then
			Conn:Disconnect()
		end

		self.Connections[Topic] = nil
		self.Callbacks[Topic] = nil
		self.Pending[Topic] = nil
		self.PendingCounts[Topic] = nil
		self.Subscribing[Topic] = nil
		return
	end

	local Callbacks = self.Callbacks[Topic]
	if not Callbacks then
		return
	end

	for _, CallbackToRemove in ToRemove do
		for i = #Callbacks, 1, -1 do
			if Callbacks[i] == CallbackToRemove then
				table.remove(Callbacks, i)
			end
		end
	end

	if #Callbacks == 0 then
		local Conn = self.Connections[Topic]
		if Conn then
			Conn:Disconnect()
		end

		self.Connections[Topic] = nil
		self.Callbacks[Topic] = nil
		self.Pending[Topic] = nil
		self.PendingCounts[Topic] = nil
		self.Subscribing[Topic] = nil
	end
end

function ReliableMessagingService.Destroy(self: ReliableMessagingService): ()
	if self.Destroyed then
		return
	end

	self.Destroyed = true

	if self.CleanupThread then
		task.cancel(self.CleanupThread)
		self.CleanupThread = nil
	end

	for _, Conn in self.Connections do
		Conn:Disconnect()
	end

	for _, Waiters in self.SubscribeWaiters do
		for _, Thread in Waiters do
			task.spawn(Thread, nil)
		end
	end

	table.clear(self.SubscribeWaiters)
	table.clear(self.Subscribing)

	table.clear(self.Connections)

	for _, Callbacks in self.Callbacks do
		table.clear(Callbacks)
	end
	table.clear(self.Callbacks)

	table.clear(self.Pending)
	table.clear(self.PendingCounts)
end

return ReliableMessagingService