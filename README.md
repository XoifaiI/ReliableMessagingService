# ReliableMessagingService
A wrapper around Roblox's MessagingService that guarantees message delivery using Random Linear Network Coding (RLNC) for erasure correction. Messages are automatically encoded into coded pieces that can handle packet loss, duplicates, and out-of-order delivery.

## Why ReliableMessagingService?

Roblox's MessagingService provides "best effort" delivery, messages can be dropped, especially under high load or network issues. ReliableMessagingService solves this by:
- **Erasure Correction**: Uses RLNC to handle packet loss up to 33-67% depending on configuration
- **Automatic Compression**: Zstd compression via EncodingService
- **Smart Retries**: Built in retry logic with exponential backoff for publish and subscribe methods
- **Zero Configuration**: Works out of the box with sensible defaults
- **Order Independence**: Receivers don't need pieces in any particular order

## Installation
Copy the ReliableMessagingService module and its dependencies (RLNC, RetryAsync, ThreadQueue) into your project:

```lua
local ReliableMessagingService = require(path.to.ReliableMessagingService)
```

## Quick Start

```lua
local Start = 0
local ReliableMessagingService = require(game.ReplicatedStorage.ReliableMessagingService)
local RMS = ReliableMessagingService.New()

-- Subscribe to a topic
local Connection = RMS:SubscribeAsync("GameEvents", function(Data: buffer)
	print("Received:", buffer.tostring(Data), os.clock() - Start)
end)

local Success, Error = RMS:PublishAsync("GameEvents", buffer.fromstring("Hello, World!"))
if not Success then
	warn("Failed to publish:", Error)
else
	Start = os.clock()
end

if Connection then
	-- Disconnect when done
	Connection:Disconnect()
end

-- Clean up the service
RMS:Destroy()
```

## Configuration
Customize behavior with optional configuration:

```lua
local RMS = ReliableMessagingService.New({
    PieceCount = 8,              -- Number of pieces to split data into (default: 8)
    RedundancyFactor = 1.5,      -- Send 50% extra pieces for reliability (default: 1.5)
    DecoderTimeout = 30,         -- Cleanup incomplete decoders after 30s (default: 30)
    MaxRetries = 3,              -- Retry failed publishes up to 3 times (default: 3)
    RetryDelay = 1,              -- Base retry delay in seconds (default: 1)
    EnableCompression = true,    -- Use Zstd compression (default: true)
    CompressionLevel = 3,        -- Compression level -7 to 22 (default: 3)
})
```

### Understanding Redundancy

The `RedundancyFactor` determines how many extra pieces are sent:

| RedundancyFactor | Pieces Sent (k=8) | Max Packet Loss |
|------------------|-------------------|-----------------|
| 1.0              | 8                 | 0%              |
| 1.5              | 12                | 33%             |
| 2.0              | 16                | 50%             |
| 3.0              | 24                | 67%             |

Higher redundancy = more reliability, but more bandwidth and slower receive times.

## API Reference

### Constructor

```lua
ReliableMessagingService.New(Config: Config?) -> ReliableMessagingService
```

Creates a new instance with optional configuration.

### Methods

#### PublishAsync

```lua
RMS:PublishAsync(
    Topic: string,
    Data: buffer,
    OptionalRetryHandler: RetryHandler?
) -> (boolean, string?)
```

Publishes a reliable message to a topic. Returns `(true, nil)` on success or `(false, error)` on failure.

**Parameters:**
- `Topic`: MessagingService topic name
- `Data`: Buffer containing your message data
- `OptionalRetryHandler`: Custom retry callback (optional)

**Example:**
```lua
local Message = buffer.fromstring("Important data")
local Success, Error = RMS:PublishAsync("CriticalEvents", Message)
if not Success then
    warn("Failed to publish:", Error)
end
```

#### SubscribeAsync

```lua
RMS:SubscribeAsync(
    Topic: string,
    Callback: (Data: buffer) -> ()
) -> RBXScriptConnection?
```

Subscribes to reliable messages on a topic. Returns `(connection)` on success or `(nil)` on failure.

**Parameters:**
- `Topic`: MessagingService topic name
- `Callback`: Function called when a complete message is decoded

**Example:**
```lua
local Connection = RMS:SubscribeAsync("PlayerUpdates", function(Data: buffer)
    local Message = buffer.tostring(Data)
    print("Received update:", Message)
end)

if not Connection then
    warn("Failed to subscribe")
    return
end

-- Later...
Connection:Disconnect()
```

#### Unsubscribe

```lua
RMS:Unsubscribe(Topic: string) -> ()
```

Unsubscribes from a topic and cleans up all associated callbacks and decoders. Note: Individual connections can also call `:Disconnect()` to remove just their callback.

#### Destroy

```lua
RMS:Destroy() -> ()
```

Cleans up all connections, threads, and tables. Call this when the service is no longer needed.

## MessagingService Limits

ReliableMessagingService is still constrained by Roblox's rate limits:

- **Message size**: 1kB max (900 bytes after overhead)
- **Send rate**: 600 + 240 × players per minute per server
- **Receive rate**: 40 + 80 × servers per minute per topic
- **Subscriptions**: 20 + 8 × players per server

Each published message sends multiple pieces (e.g., 12 pieces with default settings), so factor this into your rate limit calculations.

[Enhanced MessagingService Limits](https://devforum.roblox.com/t/enhanced-messagingservice-limits/2835576)

## How It Works
1. **Publishing**: Data is optionally compressed, then encoded into multiple coded pieces using RLNC
2. **Transmission**: Each piece is sent separately with a header containing metadata
3. **Reception**: Pieces arrive in any order, and duplicates are ignored
4. **Decoding**: Once enough linearly independent pieces arrive, the original data is reconstructed
5. **Delivery**: Your callback receives the decoded buffer

The receiver only needs to successfully receive `PieceCount` valid pieces out of the total sent, regardless of which specific pieces arrive or their order.

## Error Handling

Always check return values and handle errors:

```lua
local Success, Error = RMS:PublishAsync("MyTopic", Data)
if not Success then
    warn("Publish failed:", Error)
    -- Handle failure (retry, log, notify admin, etc.)
end
```

Common errors:
- `"Data is empty"` -> Empty buffer provided
- `"Message too large, increase piece count or reduce data size"` -> Data too large even after compression
- `"Service has been destroyed"` -> Attempted to use a destroyed service
- `"Only X/Y pieces sent, need Z"` -> Too many pieces failed to send
- MessagingService throttling errors -> Rate limits exceeded

## Performance Tips
1. **Choose appropriate PieceCount**: Larger messages need more pieces to stay under the 900-byte limit per piece
2. **Tune redundancy**: Higher redundancy = better reliability but more bandwidth and slower receive times
3. **Enable compression**: Enabled by default, can dramatically reduce message size
4. **Batch updates**: Combine multiple small updates into one message when possible
5. **Monitor decoder timeouts**: If messages frequently timeout, increase `DecoderTimeout` or `RedundancyFactor`
6. **Test under load**: Make sure your configuration handles your expected message volume within rate limits

## Advanced Usage

### Multiple Callbacks per Topic

You can have multiple callbacks subscribed to the same topic:

```lua
local Conn1 = RMS:SubscribeAsync("Events", function(Data)
    print("Handler 1:", buffer.tostring(Data))
end)

local Conn2 = RMS:SubscribeAsync("Events", function(Data)
    print("Handler 2:", buffer.tostring(Data))
end)

-- Both callbacks will receive all messages
```

### Custom Retry Handlers

Provide custom retry logic:

```lua
local function MyRetryHandler(AttemptNumber: number, MaxRetries: number)
    warn(string.format("Retry attempt %d/%d", AttemptNumber, MaxRetries))
end

RMS:PublishAsync("MyTopic", Data, MyRetryHandler)
```

## License

MIT
