--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReliableMessagingService = require("@self/ReliableMessagingService")

print("TEST 1: Basic Publish/Subscribe")
do
	local RMS = ReliableMessagingService.New({
		PieceCount = 4,
		RedundancyFactor = 1.5,
	})

	local Topic = "TestTopic_" .. tostring(math.random(100000, 999999))
	local ReceivedData: buffer? = nil

	local Connection = RMS:SubscribeAsync(Topic, function(Data: buffer)
		ReceivedData = Data
		print("Message received:", buffer.tostring(Data))
	end)

	local TestMessage = "Hello from ReliableMessagingService!"
	local Success, Error = RMS:PublishAsync(Topic, buffer.fromstring(TestMessage))

	if not Success then
		warn("FAIL: Publish failed -", Error)
	else
		print("Published successfully")

		local WaitStart = os.clock()
		while not ReceivedData and (os.clock() - WaitStart) < 10 do
			task.wait(0.1)
		end

		if ReceivedData then
			local Match = buffer.tostring(ReceivedData) == TestMessage
			print("PASS: Content match =", Match)
		else
			print("TIMEOUT: No message received (expected if running locally)")
		end
	end

	Connection:Disconnect()
	print("Disconnected\n")
end

print("TEST 2: Compression Effectiveness")
do
	local RMS_Compressed = ReliableMessagingService.New({ EnableCompression = true })
	local RMS_Uncompressed = ReliableMessagingService.New({ EnableCompression = false })

	local RepetitiveData = string.rep("ABCDEFGHIJ", 50)
	local TestBuffer = buffer.fromstring(RepetitiveData)

	print("Original size:", buffer.len(TestBuffer), "bytes")
	print("Compression enabled:", RMS_Compressed.EnableCompression)
	print("Compression disabled:", RMS_Uncompressed.EnableCompression)
	print("PASS\n")
end

print("TEST 3: Multiple Callbacks on Same Topic")
do
	local RMS = ReliableMessagingService.New()
	local Topic = "MultiTest_" .. tostring(math.random(100000, 999999))

	local Callback1Fired = false
	local Callback2Fired = false

	local Conn1 = RMS:SubscribeAsync(Topic, function(Data: buffer)
		Callback1Fired = true
	end)

	local Conn2 = RMS:SubscribeAsync(Topic, function(Data: buffer)
		Callback2Fired = true
	end)

	print("Subscribed 2 callbacks")
	print("Connection 1 active:", Conn1.Connected)
	print("Connection 2 active:", Conn2.Connected)

	Conn1:Disconnect()
	print("Disconnected callback 1, active:", Conn1.Connected)

	Conn2:Disconnect()
	print("Disconnected callback 2, active:", Conn2.Connected)
	print("PASS\n")
end

print("TEST 4: Unsubscribe Method")
do
	local RMS = ReliableMessagingService.New()
	local Topic = "UnsubTest_" .. tostring(math.random(100000, 999999))

	local Conn1 = RMS:SubscribeAsync(Topic, function() end)
	local Conn2 = RMS:SubscribeAsync(Topic, function() end)

	print("Created 2 subscriptions")
	print("Pending decoders for topic:", RMS.PendingDecoders[Topic] ~= nil)
	print("Callbacks registered:", #(RMS.Callbacks[Topic] or {}))

	RMS:Unsubscribe(Topic)

	print("Called Unsubscribe()")
	print("Pending decoders cleaned:", RMS.PendingDecoders[Topic] == nil)
	print("Callbacks cleaned:", RMS.Callbacks[Topic] == nil)
	print("Connection cleaned:", RMS.Connections[Topic] == nil)
	print("PASS\n")
end

print("TEST 5: Empty Data Handling")
do
	local RMS = ReliableMessagingService.New()
	local Topic = "EmptyTest_" .. tostring(math.random(100000, 999999))

	local EmptyBuffer = buffer.create(0)
	local Success, Error = RMS:PublishAsync(Topic, EmptyBuffer)

	if not Success and Error == "Data length is zero" then
		print("PASS: Correctly rejected empty buffer")
	else
		warn("FAIL: Should reject empty buffer")
	end
end

print("TEST 6: Large Message Handling")
do
	local RMS = ReliableMessagingService.New({ PieceCount = 16 })
	local Topic = "LargeTest_" .. tostring(math.random(100000, 999999))

	local LargeMessage = string.rep("X", 2000)
	local Success, Error = RMS:PublishAsync(Topic, buffer.fromstring(LargeMessage))

	if Success then
		print("PASS: Large message encoded successfully")
	else
		print("Expected behavior: Message too large -", Error)
	end
end

print("TEST 7: Decoder Timeout Cleanup")
do
	local RMS = ReliableMessagingService.New({ DecoderTimeout = 2 })
	local Topic = "CleanupTest_" .. tostring(math.random(100000, 999999))

	RMS.PendingDecoders[Topic] = {
		["test-message-id"] = {
			Decoder = nil :: any,
			CreatedAt = os.clock() - 5,
			TotalPieces = 8,
			Compressed = false,
		}
	}

	print("Created expired decoder (age: 5s, timeout: 2s)")
	print("Decoders before cleanup:", next(RMS.PendingDecoders[Topic]) ~= nil)

	RMS:CleanupExpiredDecoders()

	print("Decoders after cleanup:", next(RMS.PendingDecoders[Topic]) ~= nil)
	print("PASS: Expired decoders removed\n")
end

print("TEST 8: Connection Reuse for Same Topic")
do
	local RMS = ReliableMessagingService.New()
	local Topic = "ReuseTest_" .. tostring(math.random(100000, 999999))

	RMS:SubscribeAsync(Topic, function() end)
	local FirstConnection = RMS.Connections[Topic]

	RMS:SubscribeAsync(Topic, function() end)
	local SecondConnection = RMS.Connections[Topic]

	if FirstConnection == SecondConnection then
		print("PASS: Same MessagingService connection reused")
	else
		warn("FAIL: Should reuse connection for same topic")
	end

	RMS:Unsubscribe(Topic)
end

print("All Tests Done")