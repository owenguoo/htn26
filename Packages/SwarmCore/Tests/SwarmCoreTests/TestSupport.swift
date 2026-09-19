import Foundation
import simd
import Testing
@testable import SwarmCore

// MARK: - Fixture loading

/// Fixtures live at the repo root (`Fixtures/trajectory-*.json`), not inside the
/// test bundle, so the recorded trajectories are one artifact shared by the app,
/// the tools and the tests. Resolved from `#filePath` because `swift test` is the
/// only harness that runs them.
enum Fixtures {
    static var directory: URL {
        // …/Packages/SwarmCore/Tests/SwarmCoreTests/TestSupport.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwarmCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SwarmCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Fixtures")
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func trajectory(_ name: String) throws -> Trajectory {
        let data = try Data(contentsOf: url(name))
        return try JSONDecoder().decode(Trajectory.self, from: data)
    }

    /// Every `trajectory-*.json` in the fixtures directory, sorted.
    static func allTrajectoryNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("trajectory-") && $0.hasSuffix(".json") }
            .sorted()
    }
}

// MARK: - Transport doubles

/// Records what it was asked to send and only lets a send complete when the test
/// grants a permit. This is how "a socket that accepts 1 msg/sec while the
/// producer emits 10/sec" is expressed without spending ten seconds of wall clock.
actor GatedChannel: WebSocketChannel {
    private(set) var delivered: [Data] = []
    private var permits = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inbox: [Data] = []
    private var inboxWaiters: [CheckedContinuation<Data, any Error>] = []
    private var closed = false
    private(set) var closeCount = 0
    /// When set, every send after this many sends throws, simulating a socket
    /// that dies mid-stream.
    var failAfterSends: Int?
    private(set) var concurrentSendPeak = 0
    private var concurrentSends = 0

    init(failAfterSends: Int? = nil) {
        self.failAfterSends = failAfterSends
    }

    func send(_ data: Data) async throws {
        concurrentSends += 1
        concurrentSendPeak = max(concurrentSendPeak, concurrentSends)
        defer { concurrentSends -= 1 }
        await awaitPermit()
        if closed { throw TransportError.notConnected }
        if let limit = failAfterSends, delivered.count >= limit {
            throw TransportError.notConnected
        }
        delivered.append(data)
    }

    private func awaitPermit() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    /// Lets `count` pending or future sends through.
    func grant(_ count: Int = 1) {
        for _ in 0..<count {
            if waiting.isEmpty {
                permits += 1
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw TransportError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            inboxWaiters.append(continuation)
        }
    }

    func deliverInbound(_ data: Data) {
        if inboxWaiters.isEmpty {
            inbox.append(data)
        } else {
            inboxWaiters.removeFirst().resume(returning: data)
        }
    }

    func close() {
        closed = true
        closeCount += 1
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
        for continuation in inboxWaiters { continuation.resume(throwing: TransportError.notConnected) }
        inboxWaiters.removeAll()
    }

    /// Decoded envelopes, in the order the socket accepted them.
    func deliveredEnvelopes() -> [WireEnvelope] {
        delivered.compactMap { try? WireCoder.decode($0) }
    }

    func deliveredCount() -> Int { delivered.count }
}

/// Hands out a prepared list of channels, one per connect attempt, so a test can
/// script "this socket dies, the next one works".
actor ScriptedChannelFactory: WebSocketChannelFactory {
    private var queue: [GatedChannel]
    private(set) var connectCount = 0
    private(set) var handedOut: [GatedChannel] = []
    private var onConnect: (@Sendable (Int) -> Void)?

    init(channels: [GatedChannel]) {
        self.queue = channels
    }

    nonisolated func connect(to url: URL) async throws -> any WebSocketChannel {
        try await take()
    }

    private func take() throws -> any WebSocketChannel {
        connectCount += 1
        guard !queue.isEmpty else { throw TransportError.notConnected }
        let channel = queue.removeFirst()
        handedOut.append(channel)
        onConnect?(connectCount)
        return channel
    }

    func channel(at index: Int) -> GatedChannel? {
        index < handedOut.count ? handedOut[index] : nil
    }

    func attempts() -> Int { connectCount }
}

/// A factory that refuses every connection, for backoff tests.
struct AlwaysFailingFactory: WebSocketChannelFactory {
    func connect(to url: URL) async throws -> any WebSocketChannel {
        throw TransportError.notConnected
    }
}

/// Records requested delays and returns immediately, so a backoff test costs
/// microseconds instead of the thirty seconds it is actually asserting about.
actor RecordingSleeper: Sleeper {
    private(set) var delays: [Double] = []
    private var limit: Int?

    init(stopAfter: Int? = nil) {
        self.limit = stopAfter
    }

    nonisolated func sleep(seconds: Double) async throws {
        try await record(seconds)
    }

    private func record(_ seconds: Double) throws {
        delays.append(seconds)
        if let limit, delays.count >= limit {
            throw CancellationError()
        }
    }

    func recorded() -> [Double] { delays }
}

// MARK: - Async polling

/// Spins until `condition` holds or the deadline passes. Actor hops and detached
/// send tasks make strict ordering unavailable, so tests assert on settled state
/// rather than on scheduling.
func waitUntil(_ description: String, timeout: Double = 3.0,
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("timed out waiting for: \(description)", sourceLocation: sourceLocation)
}

/// Absolute-tolerance float comparison, spelled once so every gate reads the same.
func isClose(_ a: Float, _ b: Float, within tolerance: Float) -> Bool {
    abs(a - b) <= tolerance
}

func isClose(_ a: Double, _ b: Double, within tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Sample values

enum Sample {
    static func hello(deviceID: String = "phone-a") -> Hello {
        Hello(deviceID: deviceID, deviceName: "Dawson's iPhone", deviceModel: "iPhone16,1",
              appVersion: "1.0.0", venueID: "hth-main-hall", hasLiDAR: true,
              capabilities: ["lidar", "haptics"])
    }

    static func poseUpdate(seq: UInt64 = 1, t: Double = 1_000.5) -> PoseUpdate {
        PoseUpdate(deviceID: "phone-a", serverTimestamp: t, deviceTimestamp: t - 4_000,
                   position: [1.5, 1.6, -2.25], quaternion: [0, 0.7071, 0, 0.7071],
                   trackingState: TrackingQuality.limited(.relocalizing).wireValue,
                   confidence: 0.42, lastCorrectionAge: 12.5, lastCorrectionMarker: "marker-primary",
                   stale: false, seq: seq)
    }

    static func intrinsics() -> CameraIntrinsics {
        CameraIntrinsics(fx: 1_449.5, fy: 1_449.5, cx: 959.5, cy: 719.5,
                         imageWidth: 1_920, imageHeight: 1_440)
    }

    static func frameChunk(id: UInt64 = 7) -> FrameChunk {
        var trace = LatencyTrace(frameID: id)
        trace.stamp(.capture, at: 1_000.000)
        trace.stamp(.encoded, at: 1_000.018)
        trace.stamp(.sent, at: 1_000.027)
        return FrameChunk(deviceID: "phone-a", frameID: id, serverTimestamp: 1_000.027,
                          width: 960, height: 720, jpegQuality: 0.6, intrinsics: intrinsics(),
                          pose: poseUpdate(), jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
                          trace: trace)
    }

    static func depthChunk() -> DepthChunk {
        DepthChunk(deviceID: "phone-a", chunkID: 3, serverTimestamp: 1_000.5, source: .server,
                   frames: (0..<4).map { index in
                       DepthChunk.FrameRef(frameID: UInt64(index), serverTimestamp: 1_000 + Double(index) * 0.2,
                                           position: [Float(index) * 0.3, 1.5, 0],
                                           quaternion: [0, 0, 0, 1])
                   },
                   metricScale: 1.37, width: 4, height: 2,
                   depth: [1, 2, 3, 4, 5, 6, 7, 8], confidence: [1, 1, 1, 1, 0.5, 0.5, 0.5, 0.5])
    }

    static let commands: [Command] = [
        Command(id: "c1", serverTimestamp: 1_000, kind: .flash(r: 1, g: 0.2, b: 0, durationMs: 400), expiresInMs: 800),
        Command(id: "c2", serverTimestamp: 1_001, kind: .arrow(target: [3, 1.5, -2], bearingRadians: nil, label: "backpack")),
        Command(id: "c3", serverTimestamp: 1_002, kind: .arrow(target: nil, bearingRadians: -1.2, label: nil)),
        Command(id: "c4", serverTimestamp: 1_003, kind: .sound(name: "ping")),
        Command(id: "c5", serverTimestamp: 1_004, kind: .haptic(pattern: "sharp", intensity: 0.9)),
        Command(id: "c6", serverTimestamp: 1_005, kind: .setRates(poseHz: 10, frameFPS: 1.5, depthHz: 0.3)),
        Command(id: "c7", serverTimestamp: 1_006, kind: .clear),
    ]
}

// MARK: - Deterministic randomness

/// SplitMix64. Tests that assert on convergence need the same jitter every run,
/// or a flake at 3am is indistinguishable from a regression.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    /// Box-Muller, so jitter distributions look like the ones in the field.
    mutating func gaussian(mean: Double = 0, deviation: Double = 1) -> Double {
        let u1 = max(1e-12, Double.random(in: 0...1, using: &self))
        let u2 = Double.random(in: 0...1, using: &self)
        return mean + deviation * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A phone and a server whose clocks disagree, connected by a link with
/// configurable delay in each direction.
struct ClockPairSimulator {
    /// serverClock − deviceClock, in seconds.
    var skew: Double
    /// One-way delay, before jitter.
    var upBase: Double
    var downBase: Double
    /// Uniform jitter added to each direction, one-sided: delay is only ever
    /// added, never subtracted.
    var jitter: Double
    /// How long the server holds the message before replying.
    var serverDwell: Double
    var generator: SeededGenerator

    init(skew: Double, upBase: Double = 0.015, downBase: Double = 0.015,
         jitter: Double = 0.080, serverDwell: Double = 0.002, seed: UInt64 = 0xC10C) {
        self.skew = skew
        self.upBase = upBase
        self.downBase = downBase
        self.jitter = jitter
        self.serverDwell = serverDwell
        self.generator = SeededGenerator(seed: seed)
    }

    /// Performs one exchange starting at device time `t0`, returning the pong and
    /// the device time it arrived.
    mutating func exchange(id: UInt64, at t0: Double) -> (pong: Pong, receivedAt: Double) {
        let up = upBase + generator.uniform(0...jitter)
        let down = downBase + generator.uniform(0...jitter)
        let t1 = t0 + up + skew
        let t2 = t1 + serverDwell
        let t3 = t0 + up + serverDwell + down
        return (Pong(id: id, t0: t0, t1: t1, t2: t2), t3)
    }
}

// MARK: - Session assembly

/// A `ClockSync` already converged on a known offset, so a test can get past the
/// "poses are not sent before the clock is synchronised" rule in one line.
func syncedClock(offset: Double = 1_700_000_000.0) -> ClockSync {
    var simulator = ClockPairSimulator(skew: offset, jitter: 0.004, seed: 0xBEEF)
    var sync = ClockSync()
    for id in 0..<12 {
        let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id) * 0.1)
        sync.ingest(pong, receivedAt: receivedAt)
    }
    return sync
}

/// Everything a replay-driven session test needs, assembled.
struct ReplayHarness {
    let machine: SessionMachine
    let provider: MockPoseProvider
    let trajectory: Trajectory
    let venue: Venue

    init(fixture: String,
         configuration: SessionMachine.Configuration? = nil,
         providerConfiguration: MockPoseProvider.Configuration = .immediate,
         clockOffset: Double = 1_700_000_000.0) throws {
        trajectory = try Fixtures.trajectory(fixture)
        venue = try Venue.load(from: Fixtures.url("venue.json"))
        provider = MockPoseProvider(trajectory: trajectory, configuration: providerConfiguration)
        machine = SessionMachine(
            configuration: configuration ?? SessionMachine.Configuration(deviceID: "phone-a"),
            venue: venue,
            provider: provider,
            clock: syncedClock(offset: clockOffset))
    }

    /// Runs the whole replay and returns every event the machine emitted.
    func run() async throws -> [SessionEvent] {
        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        return await collector.value
    }
}

extension Array where Element == SessionEvent {
    var poses: [PoseUpdate] {
        compactMap { if case .pose(let update) = $0 { return update }; return nil }
    }

    var frames: [FrameTicket] {
        compactMap { if case .captureFrame(let ticket) = $0 { return ticket }; return nil }
    }

    var depthChunks: [DepthTicket] {
        compactMap { if case .captureDepthChunk(let ticket) = $0 { return ticket }; return nil }
    }

    var states: [SessionState] {
        compactMap { if case .stateChanged(_, let to) = $0 { return to }; return nil }
    }

    var corrections: [String] {
        compactMap { if case .correctionApplied(let id, _, _) = $0 { return id }; return nil }
    }
}
