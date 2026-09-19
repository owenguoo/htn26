import Foundation

/// The socket, abstracted so tests can drive a channel that accepts one message
/// per second while the producer emits ten.
///
/// Text and binary are distinct because the hub cares which: it reads the first
/// message with `receive_json()` and drops a socket whose hello is binary
/// (`hub.py` `ws_phone`), and it only treats binary messages as camera frames.
public protocol WebSocketChannel: Sendable {
    func send(_ frame: SocketFrame) async throws
    /// Returns the next inbound message, or throws when the channel closes.
    func receive() async throws -> SocketFrame
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
/// where it was thirty seconds ago. Perishable traffic — `slam`/`orient`,
/// frames, `debug` — sits in a shallow latest-wins buffer per lane: when a newer
/// one arrives and the buffer is full, the *stale* one is discarded and counted.
/// Control traffic — hello, pong, seat, name — is never dropped: a lost pong
/// leaves the hub without a clock offset and therefore without latency.
///
/// **Audio is the third kind.** Voice chunks may not be dropped — the hub
/// concatenates them into one WAV (`hub.py` `end_utterance`), so a missing chunk
/// is not a lost moment but a hole spliced into the middle of a sentence, and
/// the transcript comes back wrong rather than short. But they may not be sent
/// ahead of everything else either: a held microphone produces about twelve
/// messages a second, and putting those in the control queue — which is drained
/// to empty before any perishable lane gets a turn — would starve frames on a
/// slow socket, and no frames means no inference, which is the whole system.
/// So audio has a never-dropped FIFO that takes its turn in the same round-robin
/// as frames and poses. It is bounded by `VoiceGate`'s 12 s utterance cut, not
/// by dropping.
///
/// **Hello goes first, alone.** The hub registers the phone from the first
/// message on the socket. With more than one send in flight the socket does not
/// promise ordering, so after every connect the hello is sent by itself and
/// nothing else is pumped until it has completed.
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
        public var droppedByLane: [HubOutbound.Lane: Int] = [:]
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
    /// True between adopting a socket and its hello completing. Nothing else
    /// may be sent in that window.
    private var awaitingHello = false

    /// Never dropped, FIFO.
    private var controlQueue: [HubOutbound] = []
    /// Never dropped either, but rotated rather than prioritised.
    private var audioQueue: [HubOutbound] = []
    /// Latest-wins, one shallow buffer per perishable lane so a burst of frames
    /// cannot starve poses.
    private var perishable: [HubOutbound.Lane: [HubOutbound]] = [:]
    /// Where the round-robin resumes, so every perishable type gets a turn.
    private var perishableCursor = 0

    /// Evaluated afresh and sent first on every successful connect, so the hub
    /// re-registers the phone with its *current* name and seat. Everything else
    /// buffered is discarded on disconnect — stale frames are never replayed.
    private var hello: (@Sendable () async -> HubHello)?

    private var inboundContinuation: AsyncStream<HubInbound>.Continuation?
    private var runTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var pumpTasks: Set<UUID> = []
    /// Resumed when the current socket should be considered dead, from either
    /// end: a failed send or a failed receive.
    private var disconnectWaiter: CheckedContinuation<Void, Never>?
    /// Set when a disconnect is signalled before anyone is waiting, so a socket
    /// that fails on its very first send is not lost.
    private var disconnectPending = false

    public init(configuration: Configuration,
                factory: any WebSocketChannelFactory,
                sleeper: any Sleeper = TaskSleeper()) {
        self.configuration = configuration
        self.factory = factory
        self.sleeper = sleeper
    }

    /// Inbound messages, already decoded. Finishes when the transport is closed.
    public func inbound() -> AsyncStream<HubInbound> {
        if let existing = inboundStream { return existing }
        let (stream, continuation) = AsyncStream<HubInbound>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inboundContinuation = continuation
        inboundStream = stream
        return stream
    }

    private var inboundStream: AsyncStream<HubInbound>?

    /// Registers the identity sent first on every connect.
    public func setHello(_ hello: @escaping @Sendable () async -> HubHello) {
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
        signalDisconnect()
        await teardownChannel(countBufferedAsDropped: true)
        state = .closed
        inboundContinuation?.finish()
        inboundContinuation = nil
        inboundStream = nil
    }

    // MARK: - Sending

    /// Offers a message. Perishable messages may be dropped here and now; that is
    /// the design, not a failure.
    public func send(_ message: HubOutbound) {
        // Hello is the transport's to send, first and alone. See `adopt`.
        if case .hello = message { return }
        let lane = message.lane
        if lane == .audio {
            audioQueue.append(message)
        } else if lane != .control {
            var bucket = perishable[lane] ?? []
            bucket.append(message)
            while bucket.count > configuration.bufferDepth {
                // Discard the stale one, keep the newest. A pose from 400 ms ago
                // is not worth the bandwidth it would take to deliver it.
                bucket.removeFirst()
                stats.dropped += 1
                stats.droppedByLane[lane, default: 0] += 1
            }
            perishable[lane] = bucket
        } else {
            controlQueue.append(message)
        }
        stats.buffered = bufferedCount
        pump()
    }

    private var bufferedCount: Int {
        controlQueue.count + audioQueue.count + perishable.values.reduce(0) { $0 + $1.count }
    }

    /// The lanes the cursor rotates through. `.audio` is here so it takes a turn
    /// like the rest, even though its queue is never dropped.
    private static let rotatingOrder: [HubOutbound.Lane] = [.slam, .frame, .audio, .debug, .hud]

    private func nextMessage() -> HubOutbound? {
        if !controlQueue.isEmpty { return controlQueue.removeFirst() }

        // Genuine round-robin, not priority order. Under the starvation this
        // whole design exists for — a socket accepting one message a second —
        // strict priority would send nothing but poses forever: the pose buffer
        // refills at 10 Hz, so it is never empty at a send opportunity, and
        // frames would never leave the phone. No frames means no inference,
        // which is the entire point of the system.
        let order = Self.rotatingOrder
        for step in 0..<order.count {
            let index = (perishableCursor + step) % order.count
            let lane = order[index]
            if lane == .audio {
                if !audioQueue.isEmpty {
                    perishableCursor = (index + 1) % order.count
                    return audioQueue.removeFirst()
                }
            } else if var bucket = perishable[lane], !bucket.isEmpty {
                let message = bucket.removeFirst()
                perishable[lane] = bucket
                perishableCursor = (index + 1) % order.count
                return message
            }
        }
        return nil
    }

    private func pump() {
        guard case .connected = state, let channel, !awaitingHello else { return }
        while inFlight < configuration.maxInFlight, let message = nextMessage() {
            let data: SocketFrame
            do {
                data = try message.encoded()
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
            // A send that throws means the socket is gone. Carrying on would
            // silently burn every subsequent pose against a dead connection.
            stats.sendFailures += 1
            signalDisconnect()
            return
        }
        stats.sent += 1
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
                startReceiving()
                // Blocks until either end of the socket reports it is gone.
                await waitForDisconnect()
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
        disconnectPending = false
        inFlight = 0
        stats.inFlight = 0
        channel = newChannel
        state = .connected
        stats.connects += 1
        if stats.connects > 1 { stats.reconnects += 1 }
        // Identity first and alone, so the hub has registered the phone before
        // anything else can reach the socket.
        guard let hello else {
            pump()
            return
        }
        awaitingHello = true
        inFlight = 1
        stats.inFlight = 1
        let currentGeneration = generation
        Task { [weak self] in
            do {
                try await newChannel.send(HubOutbound.hello(await hello()).encoded())
                await self?.finishHello(generation: currentGeneration, failed: false)
            } catch {
                await self?.finishHello(generation: currentGeneration, failed: true)
            }
        }
    }

    private func finishHello(generation sendGeneration: UInt64, failed: Bool) {
        guard sendGeneration == generation else { return }
        awaitingHello = false
        inFlight = max(0, inFlight - 1)
        stats.inFlight = inFlight
        if failed {
            stats.sendFailures += 1
            signalDisconnect()
            return
        }
        stats.sent += 1
        pump()
    }

    private func startReceiving() {
        receiveTask?.cancel()
        let currentGeneration = generation
        guard let channel else { return }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await channel.receive()
                    guard let self else { return }
                    let stillCurrent = await self.receive(data, generation: currentGeneration)
                    if !stillCurrent { return }
                } catch {
                    // Stamped with the generation, because a receive task whose
                    // socket has already been replaced must retire quietly — not
                    // tear down the connection that superseded it.
                    await self?.signalDisconnect(generation: currentGeneration)
                    return
                }
            }
        }
    }

    /// Returns false when this socket has been superseded, so the receive task
    /// for the old generation retires instead of feeding the new one.
    private func receive(_ data: SocketFrame, generation receiveGeneration: UInt64) -> Bool {
        guard receiveGeneration == generation else { return false }
        stats.received += 1
        // Anything that is not a typed JSON object decodes to nil and is ignored.
        if let message = HubInbound.decode(data) {
            inboundContinuation?.yield(message)
        }
        return true
    }

    private func waitForDisconnect() async {
        if disconnectPending {
            disconnectPending = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            disconnectWaiter = continuation
        }
    }

    private func signalDisconnect(generation signalGeneration: UInt64) {
        guard signalGeneration == generation else { return }
        signalDisconnect()
    }

    private func signalDisconnect() {
        if let waiter = disconnectWaiter {
            disconnectWaiter = nil
            waiter.resume()
        } else {
            disconnectPending = true
        }
    }

    private func teardownChannel(countBufferedAsDropped: Bool) async {
        receiveTask?.cancel()
        receiveTask = nil
        let old = channel
        channel = nil
        generation &+= 1
        inFlight = 0
        awaitingHello = false
        stats.inFlight = 0
        if countBufferedAsDropped {
            // Never replay stale frames across a reconnect. Whatever was waiting
            // describes a moment that has passed.
            for (lane, bucket) in perishable where !bucket.isEmpty {
                stats.dropped += bucket.count
                stats.droppedByLane[lane, default: 0] += bucket.count
            }
            // The hub's buffer for this phone died with the socket, so a
            // half-utterance waiting here has nothing to be appended to.
            if !audioQueue.isEmpty {
                stats.dropped += audioQueue.count
                stats.droppedByLane[.audio, default: 0] += audioQueue.count
                audioQueue.removeAll()
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

    /// Blocks until the server has completed the WebSocket handshake.
    ///
    /// `resume()` returns immediately, long before anything has connected, so a
    /// transport that treated that as success reported "online" while pointed at
    /// an address with nothing on it. On stage that sends somebody to debug the
    /// wrong thing — the same failure mode as a status pill blaming the clock
    /// for a missing marker.
    func waitUntilOpen() async throws {
        // A ping only completes once the handshake has, and needs no cooperation
        // from the application protocol on the far side.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func send(_ frame: SocketFrame) async throws {
        switch frame {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }

    public func receive() async throws -> SocketFrame {
        switch try await task.receive() {
        case .data(let data): return .binary(data)
        case .string(let string): return .text(string)
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
        let channel = URLSessionWebSocketChannel(task: session.webSocketTask(with: url))
        // Not connected until the handshake lands. Returning before that makes
        // every downstream connection indicator a lie.
        try await channel.waitUntilOpen()
        return channel
    }
}
