import Foundation

/// The socket, abstracted so tests can drive a channel that accepts one message
/// per second while the producer emits ten.
public protocol WebSocketChannel: Sendable {
    func send(_ data: Data) async throws
    /// Returns the next inbound message, or throws when the channel closes.
    func receive() async throws -> Data
    func close() async
}

public protocol WebSocketChannelFactory: Sendable {
    func connect(to url: URL) async throws -> any WebSocketChannel
}

/// Injected so backoff tests do not take thirty seconds of wall clock.
public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum TransportState: Sendable, Equatable {
    case idle
    case connecting(attempt: Int)
    case connected
    case waitingToReconnect(attempt: Int, delay: Double)
    case closed
}

/// WebSocket transport with exponential-backoff reconnect and bounded in-flight
/// accounting.
///
/// **Backpressure drops, never queues.** A queue that grows is a phone reporting
/// where it was thirty seconds ago. Perishable traffic — poses, frames, depth —
/// sits in a shallow latest-wins buffer: when a newer one arrives and the buffer
/// is full, the *stale* one is discarded and counted. Control traffic — hello,
/// commands, the clock-sync pair — is never dropped, because losing it makes the
/// device silently stop existing to the server.
public actor Transport {
    public struct Configuration: Sendable {
        public var url: URL
        /// Messages handed to the socket and not yet completed.
        public var maxInFlight: Int
        /// How many perishable messages of a given type may wait behind the
        /// socket. 1 means strictly latest-wins.
        public var bufferDepth: Int
        public var initialBackoff: Double
        public var maxBackoff: Double
        public var backoffMultiplier: Double
        /// Fraction of the delay randomised, so five phones reconnecting after a
        /// Wi-Fi blip do not synchronise into a thundering herd.
        public var jitterFraction: Double
        /// Attempts before giving up. nil retries forever, which is what a demo
        /// wants.
        public var maxAttempts: Int?

        public init(url: URL, maxInFlight: Int = 2, bufferDepth: Int = 1,
                    initialBackoff: Double = 0.25, maxBackoff: Double = 8,
                    backoffMultiplier: Double = 2, jitterFraction: Double = 0.2,
                    maxAttempts: Int? = nil) {
            self.url = url
            self.maxInFlight = max(1, maxInFlight)
            self.bufferDepth = max(1, bufferDepth)
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.backoffMultiplier = backoffMultiplier
            self.jitterFraction = jitterFraction
            self.maxAttempts = maxAttempts
        }
    }

    public struct Stats: Sendable, Equatable {
        public var sent: Int = 0
        public var dropped: Int = 0
        public var received: Int = 0
        public var sendFailures: Int = 0
        public var connects: Int = 0
        public var reconnects: Int = 0
        public var inFlight: Int = 0
        public var buffered: Int = 0
        public var droppedByType: [WireMessageType: Int] = [:]
    }

    public private(set) var state: TransportState = .idle
    public private(set) var stats = Stats()

    private let configuration: Configuration
    private let factory: any WebSocketChannelFactory
    private let sleeper: any Sleeper

    private var channel: (any WebSocketChannel)?
    /// Incremented on every new socket. Completions stamped with an old
    /// generation are ignored, so a send that finishes after a reconnect cannot
    /// corrupt the in-flight count of the new socket.
    private var generation: UInt64 = 0
    private var inFlight = 0
    private var seq: UInt64 = 0

    /// Never dropped, FIFO.
    private var controlQueue: [WireMessage] = []
    /// Latest-wins, one shallow buffer per perishable type so a burst of frames
    /// cannot starve poses.
    private var perishable: [WireMessageType: [WireMessage]] = [:]

    /// Re-sent on every successful connect so the server can re-register the
    /// device after a drop. Everything else perishable is discarded on
    /// disconnect — stale frames are never replayed.
    private var hello: Hello?

    private var inboundContinuation: AsyncStream<WireMessage>.Continuation?
    private var runTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var pumpTasks: Set<UUID> = []

    public init(configuration: Configuration,
                factory: any WebSocketChannelFactory,
                sleeper: any Sleeper = TaskSleeper()) {
        self.configuration = configuration
        self.factory = factory
        self.sleeper = sleeper
    }

    /// Inbound messages, already decoded. Finishes when the transport is closed.
    public func inbound() -> AsyncStream<WireMessage> {
        if let existing = inboundStream { return existing }
        let (stream, continuation) = AsyncStream<WireMessage>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inboundContinuation = continuation
        inboundStream = stream
        return stream
    }

    private var inboundStream: AsyncStream<WireMessage>?

    /// Registers the identity re-sent on every connect.
    public func setHello(_ hello: Hello) {
        self.hello = hello
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await teardownChannel(countBufferedAsDropped: true)
        state = .closed
        inboundContinuation?.finish()
        inboundContinuation = nil
        inboundStream = nil
    }

    // MARK: - Sending

    /// Offers a message. Perishable messages may be dropped here and now; that is
    /// the design, not a failure.
    public func send(_ message: WireMessage) {
        if message.isDroppable {
            var bucket = perishable[message.type] ?? []
            bucket.append(message)
            while bucket.count > configuration.bufferDepth {
                // Discard the stale one, keep the newest. A pose from 400 ms ago
                // is not worth the bandwidth it would take to deliver it.
                bucket.removeFirst()
                stats.dropped += 1
                stats.droppedByType[message.type, default: 0] += 1
            }
            perishable[message.type] = bucket
        } else {
            controlQueue.append(message)
        }
        stats.buffered = bufferedCount
        pump()
    }

    private var bufferedCount: Int {
        controlQueue.count + perishable.values.reduce(0) { $0 + $1.count }
    }

    private func nextMessage() -> WireMessage? {
        if !controlQueue.isEmpty { return controlQueue.removeFirst() }
        // Round-robin across perishable types, oldest-first within a type, so a
        // full frame buffer cannot starve pose updates.
        for type in WireMessageType.allCases {
            if var bucket = perishable[type], !bucket.isEmpty {
                let message = bucket.removeFirst()
                perishable[type] = bucket
                return message
            }
        }
        return nil
    }

    private func pump() {
        guard case .connected = state, let channel else { return }
        while inFlight < configuration.maxInFlight, let message = nextMessage() {
            seq += 1
            let envelope = WireEnvelope(seq: seq, message: message)
            let data: Data
            do {
                data = try WireCoder.encode(envelope)
            } catch {
                // An unencodable message is a programmer error, not a network
                // one. Count it and move on rather than wedging the pump.
                stats.sendFailures += 1
                continue
            }
            inFlight += 1
            stats.inFlight = inFlight
            let currentGeneration = generation
            let token = UUID()
            pumpTasks.insert(token)
            Task { [weak self] in
                do {
                    try await channel.send(data)
                    await self?.finishSend(token: token, generation: currentGeneration, failed: false)
                } catch {
                    await self?.finishSend(token: token, generation: currentGeneration, failed: true)
                }
            }
        }
        stats.buffered = bufferedCount
    }

    private func finishSend(token: UUID, generation sendGeneration: UInt64, failed: Bool) {
        pumpTasks.remove(token)
        guard sendGeneration == generation else { return }
        inFlight = max(0, inFlight - 1)
        stats.inFlight = inFlight
        if failed {
            stats.sendFailures += 1
        } else {
            stats.sent += 1
        }
        pump()
    }

    // MARK: - Connection lifecycle

    private func runConnectionLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            if let maxAttempts = configuration.maxAttempts, attempt >= maxAttempts {
                state = .closed
                return
            }
            state = .connecting(attempt: attempt)
            do {
                let newChannel = try await factory.connect(to: configuration.url)
                guard !Task.isCancelled else {
                    await newChannel.close()
                    return
                }
                adopt(newChannel)
                attempt = 0
                // Blocks until the socket fails or is closed.
                await receiveLoop()
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
            }
            await teardownChannel(countBufferedAsDropped: true)
            attempt += 1
            let delay = backoffDelay(attempt: attempt)
            state = .waitingToReconnect(attempt: attempt, delay: delay)
            do {
                try await sleeper.sleep(seconds: delay)
            } catch {
                return
            }
        }
    }

    private func adopt(_ newChannel: any WebSocketChannel) {
        generation &+= 1
        inFlight = 0
        stats.inFlight = 0
        channel = newChannel
        state = .connected
        stats.connects += 1
        if stats.connects > 1 { stats.reconnects += 1 }
        // Identity first, so the server has registered the device before any
        // pose arrives.
        if let hello {
            controlQueue.insert(.hello(hello), at: 0)
        }
        pump()
    }

    private func receiveLoop() async {
        let currentGeneration = generation
        guard let channel else { return }
        while !Task.isCancelled {
            do {
                let data = try await channel.receive()
                guard currentGeneration == generation else { return }
                stats.received += 1
                if let envelope = try? WireCoder.decode(data) {
                    inboundContinuation?.yield(envelope.message)
                }
            } catch {
                return
            }
        }
    }

    private func teardownChannel(countBufferedAsDropped: Bool) async {
        let old = channel
        channel = nil
        generation &+= 1
        inFlight = 0
        stats.inFlight = 0
        if countBufferedAsDropped {
            // Never replay stale frames across a reconnect. Whatever was waiting
            // describes a moment that has passed.
            for (type, bucket) in perishable where !bucket.isEmpty {
                stats.dropped += bucket.count
                stats.droppedByType[type, default: 0] += bucket.count
            }
            perishable.removeAll()
            controlQueue.removeAll()
            stats.buffered = 0
        }
        await old?.close()
    }

    private func backoffDelay(attempt: Int) -> Double {
        let exponent = max(0, attempt - 1)
        let base = configuration.initialBackoff * pow(configuration.backoffMultiplier, Double(exponent))
        let capped = min(base, configuration.maxBackoff)
        guard configuration.jitterFraction > 0 else { return capped }
        let jitter = capped * configuration.jitterFraction
        return max(0, capped - jitter + Double.random(in: 0...(2 * jitter)))
    }

    // MARK: - Introspection for tests and the status pill

    public func currentStats() -> Stats { stats }
    public func currentState() -> TransportState { state }
    public func bufferedMessageCount() -> Int { bufferedCount }
}

// MARK: - URLSession implementation

/// The real socket. Foundation only — no ARKit, no UIKit, so it builds and runs
/// under `swift test` on macOS.
public final class URLSessionWebSocketChannel: WebSocketChannel {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw TransportError.unsupportedMessage
        }
    }

    public func close() async {
        task.cancel(with: .goingAway, reason: nil)
    }
}

public enum TransportError: Error, Sendable {
    case unsupportedMessage
    case notConnected
}

public struct URLSessionWebSocketChannelFactory: WebSocketChannelFactory {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func connect(to url: URL) async throws -> any WebSocketChannel {
        let session = URLSession(configuration: configuration)
        return URLSessionWebSocketChannel(task: session.webSocketTask(with: url))
    }
}
