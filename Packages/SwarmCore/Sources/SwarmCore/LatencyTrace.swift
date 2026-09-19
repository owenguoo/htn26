import Foundation

/// The stages a frame passes through, in order. Adjacent pairs are what the
/// CLAUDE.md budget is stated against.
public enum LatencyStage: String, Sendable, Codable, CaseIterable, Comparable {
    /// ARKit handed us the pixel buffer.
    case capture
    /// JPEG encode finished.
    case encoded
    /// Handed to the WebSocket.
    case sent
    /// Server read it off the socket.
    case serverReceived
    /// Server pulled it off its work queue.
    case serverDequeued
    /// Inference produced a result.
    case inferenceComplete
    /// The phone painted whatever the result asked for.
    case painted

    public var order: Int {
        switch self {
        case .capture: 0
        case .encoded: 1
        case .sent: 2
        case .serverReceived: 3
        case .serverDequeued: 4
        case .inferenceComplete: 5
        case .painted: 6
        }
    }

    public static func < (a: LatencyStage, b: LatencyStage) -> Bool { a.order < b.order }

    /// The stages the phone itself can stamp. The rest are filled in by the
    /// server and come back attached to the command.
    public static let clientStages: [LatencyStage] = [.capture, .encoded, .sent]
}

/// Hard target: end to end under 300 ms. The web prototype measures ~1000 ms
/// median, which is fatal for the "look left" directive — people turn, see
/// nothing, and read it as broken.
public struct LatencyBudget: Sendable, Equatable {
    public var captureToEncode: Double
    public var encodeToSend: Double
    public var network: Double
    public var serverQueue: Double
    public var inference: Double
    public var paint: Double
    public var endToEnd: Double

    public init(captureToEncode: Double = 0.030, encodeToSend: Double = 0.020,
                network: Double = 0.030, serverQueue: Double = 0.050,
                inference: Double = 0.100, paint: Double = 0.030,
                endToEnd: Double = 0.300) {
        self.captureToEncode = captureToEncode
        self.encodeToSend = encodeToSend
        self.network = network
        self.serverQueue = serverQueue
        self.inference = inference
        self.paint = paint
        self.endToEnd = endToEnd
    }

    public static let standard = LatencyBudget()

    /// The allowance for the interval ending at `stage`, or nil if that interval
    /// has no stated budget.
    public func limit(endingAt stage: LatencyStage) -> Double? {
        switch stage {
        case .capture: nil
        case .encoded: captureToEncode
        case .sent: encodeToSend
        case .serverReceived: network
        case .serverDequeued: serverQueue
        case .inferenceComplete: inference
        case .painted: paint
        }
    }

    /// Sum of the stage allowances. Stated separately from `endToEnd` so a
    /// regression that spreads across stages without breaching any single one
    /// still fails the gate.
    public var sumOfStages: Double {
        captureToEncode + encodeToSend + network + serverQueue + inference + paint
    }
}

/// A per-frame stage trace, carried alongside the frame so a regression past
/// budget is attributable to a stage rather than to "the network".
///
/// All times are server-clock seconds, via `ClockSync`. Stamping with raw device
/// time would make the server-side stages incomparable.
public struct LatencyTrace: Sendable, Equatable, Codable {
    public struct Stamp: Sendable, Equatable, Codable {
        public var stage: LatencyStage
        public var t: Double

        public init(stage: LatencyStage, t: Double) {
            self.stage = stage
            self.t = t
        }
    }

    public var frameID: UInt64
    public private(set) var stamps: [Stamp]

    public init(frameID: UInt64, stamps: [Stamp] = []) {
        self.frameID = frameID
        self.stamps = stamps
    }

    /// Records a stage. Re-stamping a stage overwrites it rather than appending,
    /// so a retried encode does not produce two `encoded` entries.
    public mutating func stamp(_ stage: LatencyStage, at time: Double) {
        if let index = stamps.firstIndex(where: { $0.stage == stage }) {
            stamps[index].t = time
        } else {
            stamps.append(Stamp(stage: stage, t: time))
            stamps.sort { $0.stage < $1.stage }
        }
    }

    public func time(of stage: LatencyStage) -> Double? {
        stamps.first { $0.stage == stage }?.t
    }

    public func duration(from: LatencyStage, to: LatencyStage) -> Double? {
        guard let a = time(of: from), let b = time(of: to) else { return nil }
        return b - a
    }

    /// Wall time from capture to the last stage present.
    public var total: Double? {
        guard let first = stamps.first, let last = stamps.last, stamps.count > 1 else { return nil }
        return last.t - first.t
    }

    /// True when timestamps never go backwards. A false here means the clock
    /// offset moved mid-frame, which invalidates every duration in the trace.
    public var isMonotonic: Bool {
        zip(stamps, stamps.dropFirst()).allSatisfy { $0.t <= $1.t }
    }

    /// Every stage the phone is responsible for is present.
    public var isClientComplete: Bool {
        LatencyStage.clientStages.allSatisfy { time(of: $0) != nil }
    }

    public var isComplete: Bool {
        LatencyStage.allCases.allSatisfy { time(of: $0) != nil }
    }

    public struct Violation: Sendable, Equatable, CustomStringConvertible {
        public var stage: LatencyStage
        public var measured: Double
        public var limit: Double

        public var description: String {
            let over = (measured - limit) * 1000
            return "\(stage.rawValue) took \(String(format: "%.1f", measured * 1000)) ms, "
                + "budget \(String(format: "%.1f", limit * 1000)) ms (+\(String(format: "%.1f", over)) ms)"
        }
    }

    /// Stage intervals that exceeded their allowance. Only intervals whose two
    /// endpoints are both present are checked — a missing server stage is
    /// reported by `isComplete`, not silently counted as a violation.
    public func violations(against budget: LatencyBudget = .standard) -> [Violation] {
        var result: [Violation] = []
        for (previous, current) in zip(stamps, stamps.dropFirst()) {
            guard let limit = budget.limit(endingAt: current.stage) else { continue }
            let measured = current.t - previous.t
            if measured > limit {
                result.append(Violation(stage: current.stage, measured: measured, limit: limit))
            }
        }
        return result
    }

    public func exceedsEndToEnd(_ budget: LatencyBudget = .standard) -> Bool {
        guard let total else { return false }
        return total > budget.endToEnd
    }
}

/// Rolling latency statistics, so the status pill and the gate can both read one
/// number. Bounded by construction — it keeps percentile samples in a ring, not a
/// growing array, because this runs for the whole demo.
public struct LatencyStatistics: Sendable {
    public private(set) var count: Int = 0
    public private(set) var violationCount: Int = 0
    public private(set) var incompleteCount: Int = 0
    private var ring: [Double]
    private var index = 0
    private var filled = 0

    public init(capacity: Int = 256) {
        ring = Array(repeating: 0, count: max(1, capacity))
    }

    public mutating func record(_ trace: LatencyTrace, budget: LatencyBudget = .standard) {
        count += 1
        if !trace.isClientComplete { incompleteCount += 1 }
        if !trace.violations(against: budget).isEmpty || trace.exceedsEndToEnd(budget) {
            violationCount += 1
        }
        guard let total = trace.total else { return }
        ring[index] = total
        index = (index + 1) % ring.count
        filled = min(filled + 1, ring.count)
    }

    public var median: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }

    public func percentile(_ p: Double) -> Double? {
        guard filled > 0 else { return nil }
        let sorted = ring.prefix(filled).sorted()
        let position = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[position]
    }
}
