--[=[
	ReliableMessagingService: RLNC-based reliable messaging wrapper
	
	Reliable message delivery over MessagingService using Random Linear
	Network Coding (RLNC) for erasure correction. Messages are encoded into
	coded pieces that can tolerate packet loss and out-of-order delivery.
	
	Features:
		- RLNC encoding for erasure correction
		- Zstd compression to get the most payload capacity (enabled by default)
		- Configurable redundancy factor for reliability
		- Per-message decoders with timeout cleanup
		- RetryAsync for publish reliability (that actually ends cough cough Kohl)
	
	Limitations (MessagingService):
		- Message size: 1kB max
		- Messages sent: 600 + 240 * players per minute per server
		- Messages received per topic: (40 + 80 * servers) per minute
		- Subscriptions: 20 + 8 * players per server
	
	Return type: ReliableMessagingService class constructor
	
	Example usage:
		local ReliableMessagingService = require(path.to.ReliableMessagingService)
		local RMS = ReliableMessagingService.New()
		
		-- Subscribe to a topic
		local Connection = RMS:SubscribeAsync("MyTopic", function(Data: buffer)
			print("Received:", buffer.tostring(Data))
		end)
		
		-- Publish a message
		local Success, Error = RMS:PublishAsync("MyTopic", buffer.fromstring("Hello!"))
--]=]

--!strict

local MessagingService = game:GetService("MessagingService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RLNC = require("@self/RLNC")
local RetryAsync = require("@self/RetryAsync")

type Encoder = RLNC.Encoder
type Decoder = RLNC.Decoder
type RLNCError = RLNC.RLNCError
type RetryHandler = RetryAsync.Handler

local MESSAGE_SIZE_LIMIT = 900
local HEADER_SIZE = 49
local DEFAULT_PIECE_COUNT = 8
local DEFAULT_REDUNDANCY_FACTOR = 1.5
local DEFAULT_DECODER_TIMEOUT = 30
local DEFAULT_MAX_ATTEMPTS = 3
local DEFAULT_RETRY_CONSTANT = 0.5
local DEFAULT_RETRY_EXPONENT = 2
local DEFAULT_COMPRESSION_LEVEL = 3

type MessageHeader = {
	MessageId: string,
	PieceIndex: number,
	TotalPieces: number,
	PieceByteLen: number,
	PieceCount: number,
	Compressed: boolean,
}

type CallbackRef = {
	Callback: (Data: buffer) -> (),
	Active: boolean,
}

type PendingDecoder = {
	Decoder: Decoder,
	CreatedAt: number,
	TotalPieces: number,
	Compressed: boolean,
}

export type ReliableMessagingServiceConfig = {
	PieceCount: number?,
	RedundancyFactor: number?,
	DecoderTimeout: number?,
	MaxAttempts: number?,
	RetryConstant: number?,
	RetryExponent: number?,
	EnableCompression: boolean?,
	CompressionLevel: number?,
}

export type ReliableMessagingService = {
	PieceCount: number,
	RedundancyFactor: number,
	DecoderTimeout: number,
	MaxAttempts: number,
	RetryConstant: number,
	RetryExponent: number,
	EnableCompression: boolean,
	CompressionLevel: number,
	PendingDecoders: { [string]: { [string]: PendingDecoder } },
	Callbacks: { [string]: { CallbackRef } },
	Connections: { [string]: RBXScriptConnection },
	Random: Random,
	PublishAsync: (self: ReliableMessagingService, Topic: string, Data: buffer, OptionalRetryHandler: RetryHandler?) -> (boolean, string?),
	SubscribeAsync: (self: ReliableMessagingService, Topic: string, Callback: (Data: buffer) -> ()) -> RBXScriptConnection,
	Unsubscribe: (self: ReliableMessagingService, Topic: string) -> (),
	CleanupExpiredDecoders: (self: ReliableMessagingService) -> (),
}

local function SerializeHeader(Header: MessageHeader): string
	return string.format(
		"%s|%d|%d|%d|%d|%d",
		Header.MessageId,
		Header.PieceIndex,
		Header.TotalPieces,
		Header.PieceByteLen,
		Header.PieceCount,
		Header.Compressed and 1 or 0
	)
end

local function DeserializeHeader(HeaderString: string): MessageHeader?
	local Parts = string.split(HeaderString, "|")
	if #Parts ~= 6 then
		return nil
	end

	local PieceIndex = tonumber(Parts[2])
	local TotalPieces = tonumber(Parts[3])
	local PieceByteLen = tonumber(Parts[4])
	local PieceCount = tonumber(Parts[5])
	local CompressedFlag = tonumber(Parts[6])

	if not PieceIndex or not TotalPieces or not PieceByteLen or not PieceCount or not CompressedFlag then
		return nil
	end

	return {
		MessageId = Parts[1],
		PieceIndex = PieceIndex,
		TotalPieces = TotalPieces,
		PieceByteLen = PieceByteLen,
		PieceCount = PieceCount,
		Compressed = CompressedFlag == 1,
	}
end

local function EncodePayload(Payload: buffer): string
	local Encoded = EncodingService:Base64Encode(Payload)
	return buffer.tostring(Encoded)
end

local function DecodePayload(Encoded: string): buffer
	return EncodingService:Base64Decode(buffer.fromstring(Encoded))
end

local function GenerateMessageId(): string
	return HttpService:GenerateGUID(false)
end

local ReliableMessagingService = {}
ReliableMessagingService.__index = ReliableMessagingService

function ReliableMessagingService.New(Config: ReliableMessagingServiceConfig?): ReliableMessagingService
	local self = {
		PieceCount = if Config and Config.PieceCount then Config.PieceCount else DEFAULT_PIECE_COUNT,
		RedundancyFactor = if Config and Config.RedundancyFactor then Config.RedundancyFactor else DEFAULT_REDUNDANCY_FACTOR,
		DecoderTimeout = if Config and Config.DecoderTimeout then Config.DecoderTimeout else DEFAULT_DECODER_TIMEOUT,
		MaxAttempts = if Config and Config.MaxAttempts then Config.MaxAttempts else DEFAULT_MAX_ATTEMPTS,
		RetryConstant = if Config and Config.RetryConstant then Config.RetryConstant else DEFAULT_RETRY_CONSTANT,
		RetryExponent = if Config and Config.RetryExponent then Config.RetryExponent else DEFAULT_RETRY_EXPONENT,
		EnableCompression = if Config and Config.EnableCompression ~= nil then Config.EnableCompression else true,
		CompressionLevel = if Config and Config.CompressionLevel then Config.CompressionLevel else DEFAULT_COMPRESSION_LEVEL,
		PendingDecoders = {},
		Callbacks = {},
		Connections = {},
		Random = Random.new(),
	}

	setmetatable(self, ReliableMessagingService)

	task.spawn(function()
		while true do
			task.wait(self.DecoderTimeout / 2)
			self:CleanupExpiredDecoders()
		end
	end)

	return (self :: any) :: ReliableMessagingService
end

function ReliableMessagingService:PublishAsync(Topic: string, Data: buffer, OptionalRetryHandler: RetryHandler?): (boolean, string?)
	local DataLen = buffer.len(Data)
	if DataLen == 0 then
		return false, "Data length is zero"
	end

	local DataToEncode = Data
	local IsCompressed = false

	if self.EnableCompression then
		local Compressed = EncodingService:CompressBuffer(Data, Enum.CompressionAlgorithm.Zstd, self.CompressionLevel)
		if buffer.len(Compressed) < DataLen then
			DataToEncode = Compressed
			IsCompressed = true
		end
	end

	local Encoder, EncoderError = RLNC.Encoder.New(DataToEncode, self.PieceCount)
	if EncoderError then
		return false, RLNC.Error.Message(EncoderError :: RLNCError)
	end

	local EncoderTyped = Encoder :: Encoder
	local FullCodedPieceByteLen = EncoderTyped:GetFullCodedPieceByteLen()
	local PieceByteLen = EncoderTyped:GetPieceByteLen()

	local Base64PieceLen = math.ceil(FullCodedPieceByteLen * 4 / 3)
	if Base64PieceLen + HEADER_SIZE > MESSAGE_SIZE_LIMIT then
		return false, string.format("Encoded piece too large (%d bytes), reduce data size or increase piece count", Base64PieceLen + HEADER_SIZE)
	end

	local TotalPiecesToSend = math.ceil(self.PieceCount * self.RedundancyFactor)
	local MessageId = GenerateMessageId()

	local AllSuccess = true
	local LastError: string? = nil

	for PieceIndex = 1, TotalPiecesToSend do
		local CodedPiece = EncoderTyped:Code(self.Random)
		local EncodedPayload = EncodePayload(CodedPiece)

		local Header: MessageHeader = {
			MessageId = MessageId,
			PieceIndex = PieceIndex,
			TotalPieces = TotalPiecesToSend,
			PieceByteLen = PieceByteLen,
			PieceCount = self.PieceCount,
			Compressed = IsCompressed,
		}

		local MessageContent = SerializeHeader(Header) .. ":" .. EncodedPayload

		local Success, Error = RetryAsync(function()
			MessagingService:PublishAsync(Topic, MessageContent)
		end, self.MaxAttempts, self.RetryConstant, self.RetryExponent, OptionalRetryHandler)

		if not Success then
			AllSuccess = false
			LastError = tostring(Error)
		end
	end

	if AllSuccess then
		return true, nil
	else
		return false, LastError
	end
end

function ReliableMessagingService:HandleIncomingMessage(Topic: string, MessageContent: string): ()
	local SeparatorIndex = string.find(MessageContent, ":")
	if not SeparatorIndex then
		return
	end

	local HeaderString = string.sub(MessageContent, 1, SeparatorIndex - 1)
	local PayloadString = string.sub(MessageContent, SeparatorIndex + 1)

	local Header = DeserializeHeader(HeaderString)
	if not Header then
		return
	end

	local CodedPiece = DecodePayload(PayloadString)
	local ExpectedLen = Header.PieceCount + Header.PieceByteLen
	if buffer.len(CodedPiece) ~= ExpectedLen then
		return
	end

	local TopicDecoders = self.PendingDecoders[Topic]
	if not TopicDecoders then
		TopicDecoders = {}
		self.PendingDecoders[Topic] = TopicDecoders
	end

	local PendingDecoderEntry = TopicDecoders[Header.MessageId]
	if not PendingDecoderEntry then
		local DecoderInstance, DecoderError = RLNC.Decoder.New(Header.PieceByteLen, Header.PieceCount)
		if DecoderError then
			return
		end

		PendingDecoderEntry = {
			Decoder = DecoderInstance :: Decoder,
			CreatedAt = os.clock(),
			TotalPieces = Header.TotalPieces,
			Compressed = Header.Compressed,
		}
		TopicDecoders[Header.MessageId] = PendingDecoderEntry
	end

	local DecoderInstance = PendingDecoderEntry.Decoder
	if DecoderInstance:IsAlreadyDecoded() then
		return
	end

	local DecodeError = DecoderInstance:Decode(CodedPiece)
	if DecodeError and DecodeError ~= RLNC.Error.PieceNotUseful then
		return
	end

	if DecoderInstance:IsAlreadyDecoded() then
		local DecodedData, ExtractError = DecoderInstance:GetDecodedData()
		if ExtractError or not DecodedData then
			TopicDecoders[Header.MessageId] = nil
			return
		end

		TopicDecoders[Header.MessageId] = nil

		local FinalData = DecodedData
		if PendingDecoderEntry.Compressed then
			local Success, Decompressed = pcall(function()
				return EncodingService:DecompressBuffer(DecodedData, Enum.CompressionAlgorithm.Zstd)
			end)

			if not Success then
				return warn("DecompressBuffer failed")
			end

			FinalData = Decompressed
		end

		local TopicCallbacks = self.Callbacks[Topic]
		if TopicCallbacks then
			for _, CallbackRef in TopicCallbacks do
				if CallbackRef.Active then
					task.spawn(CallbackRef.Callback, FinalData)
				end
			end
		end
	end
end

function ReliableMessagingService:SubscribeAsync(Topic: string, Callback: (Data: buffer) -> ()): RBXScriptConnection
	local TopicCallbacks = self.Callbacks[Topic]
	if not TopicCallbacks then
		TopicCallbacks = {}
		self.Callbacks[Topic] = TopicCallbacks
	end

	local CallbackRef = { Callback = Callback, Active = true }
	table.insert(TopicCallbacks, CallbackRef)

	local ExistingConnection = self.Connections[Topic]
	if not ExistingConnection then
		local Connection = MessagingService:SubscribeAsync(Topic, function(Message: { Data: any, Sent: number })
			local MessageData = Message.Data
			if typeof(MessageData) ~= "string" then
				return
			end

			self:HandleIncomingMessage(Topic, MessageData)
		end)

		self.Connections[Topic] = Connection
	end

	local ProxyConnection = {
		Connected = true,
		Disconnect = function(ProxySelf: any)
			if not ProxySelf.Connected then
				return
			end

			ProxySelf.Connected = false
			CallbackRef.Active = false

			local CurrentCallbacks = self.Callbacks[Topic]
			if CurrentCallbacks then
				for Index = #CurrentCallbacks, 1, -1 do
					if CurrentCallbacks[Index] == CallbackRef then
						table.remove(CurrentCallbacks, Index)
						break
					end
				end

				if #CurrentCallbacks == 0 then
					local TopicConnection = self.Connections[Topic]
					if TopicConnection then
						TopicConnection:Disconnect()
						self.Connections[Topic] = nil
					end
					self.Callbacks[Topic] = nil
					self.PendingDecoders[Topic] = nil
				end
			end
		end,
	}

	return ProxyConnection :: any
end

function ReliableMessagingService:Unsubscribe(Topic: string): ()
	local Connection = self.Connections[Topic]
	if Connection then
		Connection:Disconnect()
		self.Connections[Topic] = nil
	end

	self.Callbacks[Topic] = nil
	self.PendingDecoders[Topic] = nil
end

function ReliableMessagingService:CleanupExpiredDecoders(): ()
	local CurrentTime = os.clock()
	local Decoders: { [string]: { [string]: PendingDecoder } } = self.PendingDecoders

	for _, TopicDecoders in Decoders do
		local ToRemove: { string } = {}

		for MessageId, PendingDecoderEntry in TopicDecoders do
			local Age = CurrentTime - PendingDecoderEntry.CreatedAt
			if Age > self.DecoderTimeout then
				table.insert(ToRemove, MessageId)
			end
		end

		for _, MessageId in ToRemove do
			TopicDecoders[MessageId] = nil
		end
	end
end

return ReliableMessagingService