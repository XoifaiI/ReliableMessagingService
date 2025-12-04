--[=[
	ReliableMessagingService: RLNC-based reliable messaging wrapper
	
	Reliable message delivery over MessagingService using Random Linear Network
	Coding (RLNC) for erasure correction.
	
	Wire format (20 bytes binary header):
		[8 bytes: JobId prefix] [4 bytes: Counter] [2 bytes: PieceIndex]
		[2 bytes: TotalPieces] [2 bytes: PieceByteLen] [1 byte: PieceCount]
		[1 byte: Flags]
	
	Return type: ReliableMessagingService module
	
	Example usage:
		local RMS = require(path.to.ReliableMessagingService)
		local Service = RMS.New()
		
		local Connection = Service:SubscribeAsync("MyTopic", function(Data: buffer)
			print("Received:", buffer.tostring(Data))
		end)
		
		local Success, Error = Service:PublishAsync("MyTopic", buffer.fromstring("Hello!"))
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

local HEADER_SIZE = 20
local MESSAGE_SIZE_LIMIT = 900
local DEFAULT_PIECE_COUNT = 8
local DEFAULT_REDUNDANCY = 1.5
local DEFAULT_TIMEOUT = 30
local MAX_PIECE_COUNT = 64
local MAX_TOTAL_PIECES = 256
local COMPLETED_CACHE_SIZE = 128
local MAX_PENDING_PER_TOPIC = 256
local MAX_DECOMPRESSED_SIZE = 1024 * 1024

type MessageHeader = {
	JobId: string,
	Counter: number,
	PieceIndex: number,
	TotalPieces: number,
	PieceByteLen: number,
	PieceCount: number,
	Compressed: boolean,
}

type PendingMessage = {
	Decoder: Decoder,
	CreatedAt: number,
	Compressed: boolean,
	PieceByteLen: number,
	PieceCount: number,
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

export type ReliableMessagingService = {
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
	Completed: { [string]: { [string]: number } },
	CompletedOrder: { [string]: { string } },
	Queues: { [string]: { [string]: ThreadQueue.ThreadQueue } },
	Callbacks: { [string]: { CallbackEntry } },
	Connections: { [string]: RBXScriptConnection },
	Destroyed: boolean,
	PublishAsync: (self: ReliableMessagingService, Topic: string, Data: buffer, OptionalHandler: RetryHandler?) -> (boolean, string?),
	SubscribeAsync: (self: ReliableMessagingService, Topic: string, Callback: (Data: buffer) -> ()) -> RBXScriptConnection,
	Unsubscribe: (self: ReliableMessagingService, Topic: string) -> (),
	Destroy: (self: ReliableMessagingService) -> (),
}

local function MessageIdToKey(JobId: string, Counter: number): string
	return JobId .. "-" .. tostring(Counter)
end

local function PackMessage(Header: MessageHeader, CodedPiece: buffer): string
	local PieceLen = buffer.len(CodedPiece)
	local Buf = buffer.create(HEADER_SIZE + PieceLen)

	buffer.writestring(Buf, 0, string.sub(Header.JobId, 1, 8))
	buffer.writeu32(Buf, 8, Header.Counter)
	buffer.writeu16(Buf, 12, Header.PieceIndex)
	buffer.writeu16(Buf, 14, Header.TotalPieces)
	buffer.writeu16(Buf, 16, Header.PieceByteLen)
	buffer.writeu8(Buf, 18, Header.PieceCount)
	buffer.writeu8(Buf, 19, Header.Compressed and 1 or 0)
	buffer.copy(Buf, HEADER_SIZE, CodedPiece, 0, PieceLen)

	return buffer.tostring(EncodingService:Base64Encode(Buf))
end

local function UnpackMessage(Encoded: string): (MessageHeader?, buffer?)
	local Success, Buf = pcall(function()
		return EncodingService:Base64Decode(buffer.fromstring(Encoded))
	end)

	if not Success or buffer.len(Buf) < HEADER_SIZE then
		return nil, nil
	end

	local PieceCount = buffer.readu8(Buf, 18)
	local PieceByteLen = buffer.readu16(Buf, 16)
	local ExpectedLen = HEADER_SIZE + PieceCount + PieceByteLen

	if buffer.len(Buf) ~= ExpectedLen then
		return nil, nil
	end

	if PieceCount == 0 or PieceCount > MAX_PIECE_COUNT then
		return nil, nil
	end

	local Header: MessageHeader = {
		JobId = buffer.readstring(Buf, 0, 8),
		Counter = buffer.readu32(Buf, 8),
		PieceIndex = buffer.readu16(Buf, 12),
		TotalPieces = buffer.readu16(Buf, 14),
		PieceByteLen = PieceByteLen,
		PieceCount = PieceCount,
		Compressed = buffer.readu8(Buf, 19) == 1,
	}

	if Header.TotalPieces == 0 or Header.TotalPieces > MAX_TOTAL_PIECES then
		return nil, nil
	end

	if Header.PieceIndex == 0 or Header.PieceIndex > Header.TotalPieces then
		return nil, nil
	end

	local CodedPiece = buffer.create(PieceCount + PieceByteLen)
	buffer.copy(CodedPiece, 0, Buf, HEADER_SIZE, PieceCount + PieceByteLen)

	return Header, CodedPiece
end

local ReliableMessagingService = {}
ReliableMessagingService.__index = ReliableMessagingService

function ReliableMessagingService.New(Config: Config?): ReliableMessagingService
	local JobId = game.JobId
	if JobId == "" then
		JobId = HttpService:GenerateGUID(false)
	end

	local self = {
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
		Completed = {},
		CompletedOrder = {},
		Queues = {},
		Callbacks = {},
		Connections = {},
		Destroyed = false,
	}

	setmetatable(self, ReliableMessagingService)

	task.spawn(function()
		while not self.Destroyed do
			task.wait(self.Timeout / 2)
			self:CleanupExpired()
		end
	end)

	return (self :: any) :: ReliableMessagingService
end

function ReliableMessagingService.NextMessageId(self : ReliableMessagingService): (string, number)
	self.Counter += 1
	if self.Counter > 0xFFFFFFFF then
		self.Counter = 1
	end
	
	return self.JobId, self.Counter
end

function ReliableMessagingService:GetQueue(Topic: string, MessageId: string): ThreadQueue.ThreadQueue?
	local TopicQueues = self.Queues[Topic]
	if not TopicQueues then
		TopicQueues = {}
		self.Queues[Topic] = TopicQueues
	end

	local Queue = TopicQueues[MessageId]
	if not Queue then
		local QueueCount = 0
		for _ in TopicQueues :: { [string]: ThreadQueue.ThreadQueue } do
			QueueCount += 1
		end
		
		if QueueCount >= MAX_PENDING_PER_TOPIC then
			return nil
		end

		Queue = ThreadQueue.New()
		TopicQueues[MessageId] = Queue
	end

	return Queue
end

function ReliableMessagingService:CleanupQueue(Topic: string, MessageId: string)
	local TopicQueues = self.Queues[Topic]
	if TopicQueues then
		local Queue = TopicQueues[MessageId]
		if Queue and Queue:GetLength() == 0 then
			TopicQueues[MessageId] = nil
		end
	end
end

function ReliableMessagingService:MarkCompleted(Topic: string, MessageId: string)
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

	TopicCompleted[MessageId] = os.clock()
	table.insert(TopicOrder, MessageId)

	while #TopicOrder > COMPLETED_CACHE_SIZE do
		local Old = table.remove(TopicOrder, 1)
		if Old then
			TopicCompleted[Old] = nil
		end
	end
end

function ReliableMessagingService:IsCompleted(Topic: string, MessageId: string): boolean
	local TopicCompleted = self.Completed[Topic]
	return TopicCompleted and TopicCompleted[MessageId] ~= nil
end

function ReliableMessagingService:CleanupExpired()
	local Now = os.clock()
	local TimeoutValue = self.Timeout

	for Topic, TopicPending in self.Pending :: { [string]: { [string]: PendingMessage } } do
		for MessageId, PendingEntry in TopicPending :: { [string]: PendingMessage } do
			if Now - PendingEntry.CreatedAt > TimeoutValue then
				TopicPending[MessageId] = nil
			end
		end
	end

	for Topic, TopicQueues in self.Queues :: { [string]: { [string]: ThreadQueue.ThreadQueue } } do
		for MessageId, Queue in TopicQueues :: { [string]: ThreadQueue.ThreadQueue } do
			if Queue:GetLength() == 0 then
				TopicQueues[MessageId] = nil
			end
		end
	end
end

function ReliableMessagingService:PublishAsync(Topic: string, Data: buffer, OptionalHandler: RetryHandler?): (boolean, string?)
	local DataLen = buffer.len(Data)
	if DataLen == 0 then
		return false, "Data is empty"
	end

	local ToEncode = Data
	local IsCompressed = false

	if self.EnableCompression then
		local Success, Compressed = pcall(function()
			return EncodingService:CompressBuffer(Data, Enum.CompressionAlgorithm.Zstd, self.CompressionLevel)
		end)
		
		if Success and buffer.len(Compressed) < DataLen then
			ToEncode = Compressed
			IsCompressed = true
		end
	end

	local PieceCountValue = self.PieceCount
	local EncoderResult, EncErr = RLNC.Encoder.New(ToEncode, PieceCountValue)
	if EncErr then
		return false, RLNC.Error.Message(EncErr :: RLNCError)
	end

	local Enc = EncoderResult :: Encoder
	local FullPieceLen = Enc:GetFullCodedPieceByteLen()
	local PieceByteLen = Enc:GetPieceByteLen()

	local MessageLen = math.ceil((HEADER_SIZE + FullPieceLen) * 4 / 3)
	if MessageLen > MESSAGE_SIZE_LIMIT then
		return false, "Message too large, increase piece count or reduce data size"
	end

	local TotalPieces = math.min(math.ceil(PieceCountValue * self.Redundancy), MAX_TOTAL_PIECES)
	local JobId, CounterValue = self:NextMessageId()

	local CodedBuf = buffer.create(FullPieceLen)
	local SuccessCount = 0

	for Index = 1, TotalPieces do
		Enc:CodeWithBuffer(CodedBuf, self.Random)

		local Header: MessageHeader = {
			JobId = JobId,
			Counter = CounterValue,
			PieceIndex = Index,
			TotalPieces = TotalPieces,
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

function ReliableMessagingService:ProcessPiece(Topic: string, Header: MessageHeader, CodedPiece: buffer): buffer?
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
	if not PendingEntry then
		local PendingCount = 0
		for _ in TopicPending :: { [string]: PendingMessage } do
			PendingCount += 1
		end
		
		if PendingCount >= MAX_PENDING_PER_TOPIC then
			return nil
		end

		local Dec, DecErr = RLNC.Decoder.New(Header.PieceByteLen, Header.PieceCount)
		if DecErr then
			return nil
		end

		PendingEntry = {
			Decoder = Dec :: Decoder,
			CreatedAt = os.clock(),
			Compressed = Header.Compressed,
			PieceByteLen = Header.PieceByteLen,
			PieceCount = Header.PieceCount,
		}
		TopicPending[MessageId] = PendingEntry
	end

	if PendingEntry.PieceByteLen ~= Header.PieceByteLen or PendingEntry.PieceCount ~= Header.PieceCount then
		return nil
	end

	local Dec = PendingEntry.Decoder
	if Dec:IsAlreadyDecoded() then
		return nil
	end

	local DecErr = Dec:Decode(CodedPiece)
	if DecErr and DecErr ~= RLNC.Error.PieceNotUseful then
		return nil
	end

	if not Dec:IsAlreadyDecoded() then
		return nil
	end

	local Decoded, ExtractErr = Dec:GetDecodedData()
	if ExtractErr or not Decoded then
		TopicPending[MessageId] = nil
		return nil
	end

	TopicPending[MessageId] = nil
	self:MarkCompleted(Topic, MessageId)

	if PendingEntry.Compressed then
		local Success, Decompressed = pcall(function()
			return EncodingService:DecompressBuffer(Decoded :: buffer, Enum.CompressionAlgorithm.Zstd)
		end)
		
		if not Success then
			return nil
		end
		
		if buffer.len(Decompressed) > MAX_DECOMPRESSED_SIZE then
			return nil
		end
		
		return Decompressed
	end

	return Decoded
end

function ReliableMessagingService:HandleMessage(Topic: string, Content: string)
	local Header, CodedPiece = UnpackMessage(Content)
	if not Header or not CodedPiece then
		return
	end

	local MessageId = MessageIdToKey(Header.JobId, Header.Counter)
	local Queue = self:GetQueue(Topic, MessageId)
	if not Queue then
		return
	end

	local Success, Result = Queue:SubmitAsync(function()
		return self:ProcessPiece(Topic, Header, CodedPiece)
	end)

	self:CleanupQueue(Topic, MessageId)

	if not Success or not Result then
		return
	end

	local FinalData = Result :: buffer
	local TopicCallbacks = self.Callbacks[Topic]
	if not TopicCallbacks then
		return
	end

	for _, Entry in TopicCallbacks :: { CallbackEntry } do
		if Entry.Active then
			task.spawn(Entry.Callback, FinalData)
		end
	end
end

function ReliableMessagingService:SubscribeAsync(Topic: string, Callback: (Data: buffer) -> ()): RBXScriptConnection
	local TopicCallbacks = self.Callbacks[Topic]
	if not TopicCallbacks then
		TopicCallbacks = {}
		self.Callbacks[Topic] = TopicCallbacks
	end

	local Entry: CallbackEntry = { Callback = Callback, Active = true }
	table.insert(TopicCallbacks, Entry)

	if not self.Connections[Topic] then
		local Connection = MessagingService:SubscribeAsync(Topic, function(Message)
			if typeof(Message.Data) == "string" then
				self:HandleMessage(Topic, Message.Data)
			end
		end)
		self.Connections[Topic] = Connection
	end

	local Self = self
	return {
		Connected = true,
		Disconnect = function(Proxy: any)
			if not Proxy.Connected then
				return
			end
			Proxy.Connected = false
			Entry.Active = false

			local CurrentCallbacks = Self.Callbacks[Topic] :: { CallbackEntry }?
			if CurrentCallbacks then
				for Index = #CurrentCallbacks, 1, -1 do
					if CurrentCallbacks[Index] == Entry then
						table.remove(CurrentCallbacks, Index)
						break
					end
				end

				if #CurrentCallbacks == 0 then
					local Conn = Self.Connections[Topic]
					if Conn then
						Conn:Disconnect()
						Self.Connections[Topic] = nil
					end
					Self.Callbacks[Topic] = nil
					Self.Pending[Topic] = nil
					Self.Completed[Topic] = nil
					Self.CompletedOrder[Topic] = nil
					Self.Queues[Topic] = nil
				end
			end
		end,
	} :: any
end

function ReliableMessagingService:Unsubscribe(Topic: string)
	local Conn = self.Connections[Topic]
	if Conn then
		Conn:Disconnect()
		self.Connections[Topic] = nil
	end

	self.Callbacks[Topic] = nil
	self.Pending[Topic] = nil
	self.Completed[Topic] = nil
	self.CompletedOrder[Topic] = nil
	self.Queues[Topic] = nil
end

function ReliableMessagingService:Destroy()
	self.Destroyed = true

	for Topic, Conn in self.Connections :: { [string]: RBXScriptConnection } do
		Conn:Disconnect()
	end

	table.clear(self.Connections)
	table.clear(self.Callbacks)
	table.clear(self.Pending)
	table.clear(self.Completed)
	table.clear(self.CompletedOrder)
	table.clear(self.Queues)
end

return ReliableMessagingService