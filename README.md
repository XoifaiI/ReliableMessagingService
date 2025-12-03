# ReliableMessagingService
A wrapper around Roblox's MessagingService that tries to guarantee message delivery using Random Linear Network Coding (RLNC) for erasure correction. Messages are automatically encoded into coded pieces that can deal with packet loss, duplicates, and out-of-order delivery.

## Why ReliableMessagingService?

Roblox's MessagingService provides "best effort" delivery, messages can be dropped, especially under high load or network issues. ReliableMessagingService solves this by:
- **Erasure Correction**: Uses RLNC to deal with packet loss up to 33-67% depending on configuration
- **Automatic Compression**: Zstd compression (EncodingService)
- **Smart Retries**: Built in retry logic with exponential backoff for publish operations
- **Zero Configuration**: Works out of the box with sensible defaults
- **Order Independence**: Receivers don't need pieces in any particular order

## Installation
Copy the ReliableMessagingService module and its dependencies (RLNC, RetryAsync) into your project:

```lua
local ReliableMessagingService = require(path.to.ReliableMessagingService)
```

## Quick Start

```lua
local ReliableMessagingService = require(path.to.ReliableMessagingService)
local RMS = ReliableMessagingService.New()

-- Subscribe to a topic
local Connection = RMS:SubscribeAsync("GameEvents", function(Data: buffer)
    print("Received:", buffer.tostring(Data))
end)

-- Publish a message
local Success, Error = RMS:PublishAsync("GameEvents", buffer.fromstring("Hello, World!"))
if not Success then
    warn("Failed to publish:", Error)
end

-- Unsubscribe when done
RMS:Unsubscribe("GameEvents")
```

## Configuration
Customize behavior with optional configuration:

```lua
local RMS = ReliableMessagingService.New({
    PieceCount = 8,              -- Number of pieces to split data into (default: 8)
    RedundancyFactor = 1.5,      -- Send 50% extra pieces for reliability (default: 1.5)
    DecoderTimeout = 30,         -- Cleanup incomplete decoders after 30s (default: 30)
    MaxAttempts = 3,             -- Retry failed publishes up to 3 times (default: 3)
    RetryConstant = 0.5,         -- Base retry delay in seconds (default: 0.5)
    RetryExponent = 2,           -- Exponential backoff multiplier (default: 2)
    EnableCompression = true,    -- Use Zstd compression (default: true)
    CompressionLevel = 3,        -- Compression level -7-22 (default: 3)
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

Higher redundancy = more reliability, but more bandwidth and rate limit usage.

## API Reference

### Constructor

```lua
ReliableMessagingService.New(Config: ReliableMessagingServiceConfig?) -> ReliableMessagingService
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
```

#### SubscribeAsync

```lua
RMS:SubscribeAsync(
    Topic: string,
    Callback: (Data: buffer) -> ()
) -> RBXScriptConnection
```

Subscribes to reliable messages on a topic. Returns a connection object.

**Parameters:**
- `Topic`: MessagingService topic name
- `Callback`: Function called when a complete message is decoded

**Example:**
```lua
local Connection = RMS:SubscribeAsync("PlayerUpdates", function(Data: buffer)
    local Message = buffer.tostring(Data)
    print("Received update:", Message)
end)

-- Later...
RMS:Unsubscribe("PlayerUpdates")
```

#### Unsubscribe

```lua
RMS:Unsubscribe(Topic: string) -> ()
```

Unsubscribes from a topic and cleans up all associated callbacks and decoders.

#### CleanupExpiredDecoders

```lua
RMS:CleanupExpiredDecoders() -> ()
```

Manually triggers cleanup of expired decoders (automatically called periodically).

## MessagingService Limits

ReliableMessagingService is still limited by Roblox's rate limits:

- **Message size**: 1kB max (900 bytes after overhead)
- **Send rate**: 600 + 240 x players per minute per server
- **Receive rate**: 40 + 80 x servers per minute per topic
- **Subscriptions**: 20 + 8 x players per server

Each published message sends multiple pieces (e.g., 12 pieces with default settings), so take this into account.
https://devforum.roblox.com/t/enhanced-messagingservice-limits/2835576

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
- `"Data length is zero"` - Empty buffer provided
- `"Encoded piece too large"` - Data too large even after compression; reduce size or increase PieceCount
- MessagingService throttling errors - Hitting rate limits

## Performance Tips
1. **Choose appropriate PieceCount**: Larger messages need more pieces to stay under the 900-byte limit per piece
2. **Tune redundancy**: Higher redundancy = better reliability but more bandwidth
3. **Enable compression**: Enabled by default, can dramatically reduce message size
4. **Batch updates**: Combine multiple small updates into one message when possible
5. **Monitor decoder timeouts**: If messages frequently timeout, increase `DecoderTimeout` or `RedundancyFactor`

## License

MIT