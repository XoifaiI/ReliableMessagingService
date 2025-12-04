--[=[
	ReliableMessagingService: RLNC-based reliable messaging wrapper
	
	Reliable message delivery over MessagingService using Random Linear Network
	Coding (RLNC) for erasure correction. Requests to the same message are queued
	to make sure pieces are processed in order, avoiding race conditions.
	
	Wire format (16 bytes binary header):
		[8 bytes: JobId prefix] [4 bytes: Counter] [1 byte: PieceByteLen high]
		[1 byte: PieceByteLen low] [1 byte: PieceCount] [1 byte: Flags]
	
	Return type: ReliableMessagingService module
	
	Example usage:
		local RMS = require(path.to.ReliableMessagingService)
		local Service = RMS.New()
		
		local Connection = Service:SubscribeAsync("MyTopic", function(Data: buffer)
			print("Received:", buffer.tostring(Data))
		end)
		
		local Success, Error = Service:PublishAsync("MyTopic", buffer.fromstring("Hello!"))
		
		Service:Destroy()
--]=]

--!strict

local MessagingService = game:GetService("MessagingService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local RLNC = require("@self/RLNC")
local RetryAsync = require("@self/RetryAsync")
local ThreadQueue = require("@self/ThreadQueue")

type Encoder = RLNC.Encoder
type Decoder = RLNC.Decoder
type RLNCError = RLNC.RLNCError
type RetryHandler = RetryAsync.Handler

local HEADER_SIZE = 16

local MESSAGE_SIZE_LIMIT = 900

local DEFAULT_PIECE_COUNT = 8
local DEFAULT_REDUNDANCY = 1.5
local DEFAULT_TIMEOUT = 30

local MAX_PIECE_COUNT = 64
local MAX_TOTAL_PIECES = 256

local MAX_PENDING_PER_TOPIC = 256
local MAX_DECOMPRESSED_SIZE = 1024 * 1024

local COMPLETED_CACHE_SIZE = 128
local FLAG_COMPRESSED = 0x01

type MessageHeader = {
	JobId: string,
	Counter: number,
	PieceByteLen: number,
	PieceCount: number,
	Compressed: boolean,
}

type PendingMessage = {
	Decoder: Decoder,
	CreatedAt: number,
	Compressed: boolean,
}

type CallbackEntry = {
	Callback: (Data: buffer) -> (),
	Active: boolean,
}

export type Config = {
	PieceCount: number?,
	RedundancyFactor: number?,
	DecoderTimeout: number?,
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
	Pending: { [string]: { [string]: PendingMessage } },
	PendingCounts: { [string]: number },
	Completed: { [string]: { [string]: boolean } },
	CompletedOrder: { [string]: { string } },
	MessageQueues: { [string]: ThreadQueue.ThreadQueue },
	MessageQueueCount: number,
	Callbacks: { [string]: { CallbackEntry } },
	Connections: { [string]: RBXScriptConnection },
	SubscribeQueue: ThreadQueue.ThreadQueue,
	CleanupThread: thread?,
	Destroyed: boolean,
}

local ReliableMessagingService = {}
ReliableMessagingService.__index = ReliableMessagingService

export type ReliableMessagingService = typeof(setmetatable({} :: ServiceData, ReliableMessagingService))

local function MessageIdToKey(JobId: string, Counter: number): string
	return string.format("%s-%d", JobId, Counter)
end

local function PackMessage(Header: MessageHeader, CodedPiece: buffer): string
	local PieceLen = buffer.len(CodedPiece)
	local Buf = buffer.create(HEADER_SIZE + PieceLen)

	buffer.writestring(Buf, 0, string.sub(Header.JobId, 1, 8))
	buffer.writeu32(Buf, 8, Header.Counter)
	buffer.writeu8(Buf, 12, bit32.rshift(Header.PieceByteLen, 8))
	buffer.writeu8(Buf, 13, bit32.band(Header.PieceByteLen, 0xFF))
	buffer.writeu8(Buf, 14, Header.PieceCount)
	buffer.writeu8(Buf, 15, Header.Compressed and FLAG_COMPRESSED or 0)
	buffer.copy(Buf, HEADER_SIZE, CodedPiece, 0, PieceLen)

	return buffer.tostring(EncodingService:Base64Encode(Buf))
end

local function UnpackMessage(Encoded: string): (MessageHeader?, buffer?)
	local Buf = EncodingService:Base64Decode(buffer.fromstring(Encoded))
	if buffer.len(Buf) < HEADER_SIZE then
		return nil, nil
	end

	local PieceCount = buffer.readu8(Buf, 14)
	local PieceByteLen = bit32.bor(bit32.lshift(buffer.readu8(Buf, 12), 8), buffer.readu8(Buf, 13))
	local ExpectedLen = HEADER_SIZE + PieceCount + PieceByteLen

	if buffer.len(Buf) ~= ExpectedLen then
		return nil, nil
	end

	if PieceCount == 0 or PieceCount > MAX_PIECE_COUNT then
		return nil, nil
	end

	local Flags = buffer.readu8(Buf, 15)

	local Header: MessageHeader = {
		JobId = buffer.readstring(Buf, 0, 8),
		Counter = buffer.readu32(Buf, 8),
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
		Timeout = Config and Config.DecoderTimeout or DEFAULT_TIMEOUT,
		MaxRetries = Config and Config.MaxRetries or 3,
		RetryDelay = Config and Config.RetryDelay or 1,
		EnableCompression = if Config and Config.EnableCompression ~= nil then Config.EnableCompression else true,
		CompressionLevel = Config and Config.CompressionLevel or 3,
		JobId = JobId,
		Counter = 0,
		Random = Random.new(),
		Pending = {},
		PendingCounts = {},
		Completed = {},
		CompletedOrder = {},
		MessageQueues = {},
		MessageQueueCount = 0,
		Callbacks = {},
		Connections = {},
		SubscribeQueue = ThreadQueue.New(),
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

function ReliableMessagingService.NextMessageId(self: ReliableMessagingService): (string, number)
	self.Counter += 1
	if self.Counter > 0xFFFFFFFF then
		self.Counter = 1
		self.JobId = HttpService:GenerateGUID(false)
	end

	return self.JobId, self.Counter
end

function ReliableMessagingService.GetOrCreateQueue(self: ReliableMessagingService, MessageId: string): ThreadQueue.ThreadQueue?
	local Queue = self.MessageQueues[MessageId]
	if Queue then
		return Queue
	end

	if self.MessageQueueCount >= MAX_PENDING_PER_TOPIC then
		return nil
	end

	Queue = ThreadQueue.New()
	self.MessageQueues[MessageId] = Queue
	self.MessageQueueCount += 1
	return Queue
end

function ReliableMessagingService.CleanupQueue(self: ReliableMessagingService, MessageId: string): ()
	local Queue = self.MessageQueues[MessageId]
	if Queue and Queue:GetLength() == 0 then
		self.MessageQueues[MessageId] = nil
		self.MessageQueueCount -= 1
	end
end

function ReliableMessagingService.MarkCompleted(self: ReliableMessagingService, Topic: string, MessageId: string): ()
	local TopicCompleted = self.Completed[Topic]
	if not TopicCompleted then
		TopicCompleted = {}
		self.Completed[Topic] = TopicCompleted
	end

	local TopicOrder = self.CompletedOrder[Topic]
	if not TopicOrder then
		TopicOrder = {}
		self.CompletedOrder[Topic] = TopicOrder
	end

	TopicCompleted[MessageId] = true
	table.insert(TopicOrder, MessageId)

	while #TopicOrder > COMPLETED_CACHE_SIZE do
		local Old = table.remove(TopicOrder, 1)
		if Old then
			TopicCompleted[Old] = nil
		end
	end
end

function ReliableMessagingService.IsCompleted(self: ReliableMessagingService, Topic: string, MessageId: string): boolean
	local TopicCompleted = self.Completed[Topic]
	return TopicCompleted ~= nil and TopicCompleted[MessageId] == true
end

function ReliableMessagingService.GetPendingCount(self: ReliableMessagingService, Topic: string): number
	return self.PendingCounts[Topic] or 0
end

function ReliableMessagingService.CleanupExpired(self: ReliableMessagingService): ()
	local Now = os.clock()
	local TimeoutValue = self.Timeout

	for Topic, TopicPending in self.Pending do
		local ToRemove = {}

		for MessageId, Entry in TopicPending do
			if Now - Entry.CreatedAt > TimeoutValue then
				table.insert(ToRemove, MessageId)
			end
		end

		for _, MessageId in ToRemove do
			TopicPending[MessageId] = nil
			local Count = self.PendingCounts[Topic]
			if Count then
				Count -= 1
				if Count <= 0 then
					self.PendingCounts[Topic] = nil
				else
					self.PendingCounts[Topic] = Count
				end
			end
		end
	end

	local QueuesToRemove = {}
	for MessageId, Queue in self.MessageQueues do
		if Queue:GetLength() == 0 then
			table.insert(QueuesToRemove, MessageId)
		end
	end

	for _, MessageId in QueuesToRemove do
		if self.MessageQueues[MessageId] then
			self.MessageQueues[MessageId] = nil
			self.MessageQueueCount -= 1
		end
	end
end

function ReliableMessagingService.ProcessPiece(self: ReliableMessagingService, Topic: string, Header: MessageHeader, CodedPiece: buffer): buffer?
	local MessageId = MessageIdToKey(Header.JobId, Header.Counter)

	if self:IsCompleted(Topic, MessageId) then
		return nil
	end

	local TopicPending = self.Pending[Topic]
	if not TopicPending then
		TopicPending = {}
		self.Pending[Topic] = TopicPending
	end

	local PendingEntry = TopicPending[MessageId]
	local CreatedNewEntry = false

	if not PendingEntry then
		if self:GetPendingCount(Topic) >= MAX_PENDING_PER_TOPIC then
			return nil
		end

		local Dec, DecErr = RLNC.Decoder.New(Header.PieceByteLen, Header.PieceCount)
		if DecErr or not Dec then
			return nil
		end

		PendingEntry = {
			Decoder = Dec,
			CreatedAt = os.clock(),
			Compressed = Header.Compressed,
		}
		TopicPending[MessageId] = PendingEntry
		self.PendingCounts[Topic] = (self.PendingCounts[Topic] or 0) + 1
		CreatedNewEntry = true
	end

	local Dec = PendingEntry.Decoder
	if Dec:IsAlreadyDecoded() then
		return nil
	end

	local DecErr = Dec:Decode(CodedPiece)
	if DecErr and DecErr ~= RLNC.Error.PieceNotUseful then
		if CreatedNewEntry then
			TopicPending[MessageId] = nil
			local Count = self.PendingCounts[Topic]
			if Count then
				Count -= 1
				if Count <= 0 then
					self.PendingCounts[Topic] = nil
				else
					self.PendingCounts[Topic] = Count
				end
			end
		end

		return nil
	end

	if not Dec:IsAlreadyDecoded() then
		return nil
	end

	local Decoded, ExtractErr = Dec:GetDecodedData()

	TopicPending[MessageId] = nil
	local Count = self.PendingCounts[Topic]
	if Count then
		Count -= 1
		if Count <= 0 then
			self.PendingCounts[Topic] = nil
		else
			self.PendingCounts[Topic] = Count
		end
	end

	if ExtractErr or not Decoded then
		return nil
	end

	self:MarkCompleted(Topic, MessageId)

	if PendingEntry.Compressed then
		local DecompressedSize = EncodingService:GetDecompressedBufferSize(Decoded, Enum.CompressionAlgorithm.Zstd)
		if not DecompressedSize or DecompressedSize > MAX_DECOMPRESSED_SIZE then
			return nil
		end

		return EncodingService:DecompressBuffer(Decoded, Enum.CompressionAlgorithm.Zstd)
	end

	return Decoded
end

function ReliableMessagingService.HandleMessage(self: ReliableMessagingService, Topic: string, Content: string): ()
	if self.Destroyed then
		return
	end

	local Header, CodedPiece = UnpackMessage(Content)
	if not Header or not CodedPiece then
		return
	end

	local MessageId = MessageIdToKey(Header.JobId, Header.Counter)

	if self:IsCompleted(Topic, MessageId) then
		return
	end

	local Queue = self:GetOrCreateQueue(MessageId)
	if not Queue then
		return
	end

	local Success, Result = Queue:SubmitAsync(function()
		return self:ProcessPiece(Topic, Header, CodedPiece)
	end)

	self:CleanupQueue(MessageId)

	if not Success or not Result then
		return
	end

	if self.Destroyed then
		return
	end

	local FinalData = Result :: buffer
	local TopicCallbacks = self.Callbacks[Topic]
	if not TopicCallbacks then
		return
	end

	for _, Entry in TopicCallbacks do
		if Entry.Active then
			task.spawn(Entry.Callback, FinalData)
		end
	end
end

function ReliableMessagingService.PublishAsync(self: ReliableMessagingService, Topic: string, Data: buffer, OptionalHandler: RetryHandler?): (boolean, string?)
	if self.Destroyed then
		return false, "Service has been destroyed"
	end

	local DataLen = buffer.len(Data)
	if DataLen == 0 then
		return false, "Data is empty"
	end

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
		return false, RLNC.Error.Message(EncErr :: RLNCError)
	end

	local FullPieceLen = Enc:GetFullCodedPieceByteLen()
	local PieceByteLen = Enc:GetPieceByteLen()

	local MessageLen = math.ceil((HEADER_SIZE + FullPieceLen) * 4 / 3)
	if MessageLen > MESSAGE_SIZE_LIMIT then
		return false, "Message too large, increase piece count or reduce data size"
	end

	local TotalPieces = math.min(math.ceil(PieceCountValue * self.Redundancy), MAX_TOTAL_PIECES)
	local CurrentJobId, CounterValue = self:NextMessageId()

	local CodedBuf = buffer.create(FullPieceLen)
	local SuccessCount = 0

	for _ = 1, TotalPieces do
		Enc:CodeWithBuffer(CodedBuf, self.Random)

		local Header: MessageHeader = {
			JobId = CurrentJobId,
			Counter = CounterValue,
			PieceByteLen = PieceByteLen,
			PieceCount = PieceCountValue,
			Compressed = IsCompressed,
		}

		local Message = PackMessage(Header, CodedBuf)

		local Ok = RetryAsync(function()
			MessagingService:PublishAsync(Topic, Message)
		end, self.MaxRetries, self.RetryDelay, 2, OptionalHandler)

		if Ok then
			SuccessCount += 1
		end
	end

	if SuccessCount >= PieceCountValue then
		return true, nil
	end

	return false, string.format("Only %d/%d pieces sent, need %d", SuccessCount, TotalPieces, PieceCountValue)
end

function ReliableMessagingService.SubscribeAsync(self: ReliableMessagingService, Topic: string, Callback: (Data: buffer) -> ()): (boolean, RBXScriptConnection?)
	local QueueSuccess, QueueResult = self.SubscribeQueue:SubmitAsync(function()
		if self.Destroyed then
			return nil
		end

		local TopicCallbacks = self.Callbacks[Topic]
		if not TopicCallbacks then
			TopicCallbacks = {}
			self.Callbacks[Topic] = TopicCallbacks
		end

		local Entry: CallbackEntry = { Callback = Callback, Active = true }
		table.insert(TopicCallbacks, Entry)

		if not self.Connections[Topic] then
			local Success, Connection = RetryAsync(function()
				return MessagingService:SubscribeAsync(Topic, function(Message)
					if typeof(Message.Data) == "string" then
						self:HandleMessage(Topic, Message.Data)
					end
				end)
			end, self.MaxRetries, self.RetryDelay, 2)

			if not Success or not Connection then
				table.remove(TopicCallbacks, #TopicCallbacks)
				if #TopicCallbacks == 0 then
					self.Callbacks[Topic] = nil
				end
				return nil
			end

			self.Connections[Topic] = Connection
		end

		return Entry
	end)

	if not QueueSuccess or not QueueResult then
		return false, nil
	end

	local Entry = QueueResult :: CallbackEntry

	local Connection: RBXScriptConnection
	Connection = {
		Connected = true,
		Disconnect = function()
			if not Connection.Connected then
				return
			end
			Connection.Connected = false
			Entry.Active = false

			if self.Destroyed then
				return
			end

			local CurrentCallbacks = self.Callbacks[Topic]
			if CurrentCallbacks then
				for Index = #CurrentCallbacks, 1, -1 do
					if CurrentCallbacks[Index] == Entry then
						table.remove(CurrentCallbacks, Index)
						break
					end
				end

				if #CurrentCallbacks == 0 then
					local Conn = self.Connections[Topic]
					if Conn then
						Conn:Disconnect()
						self.Connections[Topic] = nil
					end

					self.Callbacks[Topic] = nil
					self.Pending[Topic] = nil
					self.PendingCounts[Topic] = nil
					self.Completed[Topic] = nil
					self.CompletedOrder[Topic] = nil
				end
			end
		end,
	} :: any

	return true, Connection
end

function ReliableMessagingService.Unsubscribe(self: ReliableMessagingService, Topic: string): ()
	local Conn = self.Connections[Topic]
	if Conn then
		Conn:Disconnect()
		self.Connections[Topic] = nil
	end

	self.Callbacks[Topic] = nil
	self.Pending[Topic] = nil
	self.PendingCounts[Topic] = nil
	self.Completed[Topic] = nil
	self.CompletedOrder[Topic] = nil
end

function ReliableMessagingService.GetQueueLength(self: ReliableMessagingService, MessageId: string): number
	local Queue = self.MessageQueues[MessageId]
	return if Queue then Queue:GetLength() else 0
end

function ReliableMessagingService.AreAllQueuesEmpty(self: ReliableMessagingService): boolean
	for _, Queue in self.MessageQueues do
		if Queue:GetLength() > 0 then
			return false
		end
	end

	return true
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

	local SubscribeQueueData = self.SubscribeQueue :: any
	if SubscribeQueueData.Queue then
		for _, Entry in SubscribeQueueData.Queue do
			if Entry.Thread and coroutine.status(Entry.Thread) == "suspended" then
				task.spawn(Entry.Thread, false, "Service destroyed")
			end
		end
	end

	for _, Queue in self.MessageQueues do
		local QueueData = Queue :: any
		if QueueData.Queue then
			for _, Entry in QueueData.Queue do
				if Entry.Thread and coroutine.status(Entry.Thread) == "suspended" then
					task.spawn(Entry.Thread, false, "Service destroyed")
				end
			end
		end
	end

	table.clear(self.Connections)
	table.clear(self.Callbacks)

	table.clear(self.Pending)
	table.clear(self.PendingCounts)

	table.clear(self.Completed)
	table.clear(self.CompletedOrder)

	table.clear(self.MessageQueues)
	self.MessageQueueCount = 0
end

return ReliableMessagingService