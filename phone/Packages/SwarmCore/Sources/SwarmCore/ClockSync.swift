import Foundation

/// Converts per-device uptime into server-clock time.
///
/// `frame.timestamp` is in the `CACurrentMediaTime()` domain: seconds since that
/// phone booted. Two phones that booted a day apart are four figures of seconds
/// out. Fusing their poses on the server without this is meaningless, which is
/// why Gate 2 exists.
///
/// NTP's four-timestamp exchange, with a minimum-round-trip filter over a rolling
/// window. The minimum-RTT sample is used rather than an average because network
/// jitter is one-sided: delay can only be added, never subtracted, so the fastest
/// exchange observed is the least corrupted estimate of the true offset.
public struct ClockSync: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// How many samples the minimum filter looks across.
        public var windowSize: Int
        /// An offset jumping by more than this is treated as a possible step
        /// (device slept and woke), not as jitter.
        public var stepThreshold: Double
        /// Consecutive corroborating samples required before adopting a step.
        /// One is not enough: a single delayed packet looks exactly like a step.
        public var stepConfirmations: Int
        /// How closely the corroborating samples must agree, in seconds.
        public var stepAgreement: Double
        /// Samples older than this are evicted even if the window is not full, so
        /// a device that goes quiet does not keep quoting a stale offset.
        public var maxSampleAge: Double
        /// Samples needed before `isSynchronized` becomes true.
        public var minimumSamples: Int

        public init(windowSize: Int = 16, stepThreshold: Double = 0.5, stepConfirmations: Int = 3,
                    stepAgreement: Double = 0.25, maxSampleAge: Double = 120, minimumSamples: Int = 3) {
            self.windowSize = max(1, windowSize)
            self.stepThreshold = stepThreshold
            self.stepConfirmations = max(1, stepConfirmations)
            self.stepAgreement = stepAgreement
            self.maxSampleAge = maxSampleAge
            self.minimumSamples = max(1, minimumSamples)
        }

        public static let standard = Configuration()
    }

    public struct Sample: Sendable, Equatable {
        /// Phone monotonic clock at send.
        public var t0: Double
        /// Server clock at receive.
        public var t1: Double
        /// Server clock at send.
        public var t2: Double
        /// Phone monotonic clock at receive.
        public var t3: Double

        public init(t0: Double, t1: Double, t2: Double, t3: Double) {
            self.t0 = t0
            self.t1 = t1
            self.t2 = t2
            self.t3 = t3
        }

        /// Time on the wire, both directions, excluding the server's own dwell.
        public var roundTrip: Double { max(0, (t3 - t0) - (t2 - t1)) }

        /// serverTime − deviceTime, assuming symmetric path delay. Asymmetry of
        /// `a` seconds biases this by `a / 2`; nothing in a two-way exchange can
        /// detect that, which is why `ClockSyncQuality` reports round trip too.
        public var offset: Double { ((t1 - t0) + (t2 - t3)) / 2 }
    }

    public var configuration: Configuration
    private var window: [Sample] = []
    private var stepCandidates: [Sample] = []
    private var adopted: Sample?

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    /// Feeds a completed exchange. `receivedAt` is the phone's monotonic clock at
    /// the moment the pong arrived — stamped by the caller, never trusted from
    /// the server.
    ///
    /// Returns true if this sample changed the adopted offset.
    @discardableResult
    public mutating func ingest(_ pong: Pong, receivedAt t3: Double) -> Bool {
        ingest(Sample(t0: pong.t0, t1: pong.t1, t2: pong.t2, t3: t3))
    }

    @discardableResult
    public mutating func ingest(_ sample: Sample) -> Bool {
        // A pong that claims to have been sent before it was received, or that
        // arrives before it was sent, is corrupt. Drop it rather than letting it
        // drag the estimate.
        guard sample.t3 >= sample.t0, sample.t2 >= sample.t1 else { return false }

        if let current = offset, abs(sample.offset - current) > configuration.stepThreshold {
            stepCandidates.append(sample)
            // Only consecutive, mutually agreeing outliers count as a step.
            if stepCandidates.count >= configuration.stepConfirmations {
                let recent = stepCandidates.suffix(configuration.stepConfirmations)
                let offsets = recent.map(\.offset)
                let spread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
                if spread <= configuration.stepAgreement {
                    // Device slept and woke, or the server restarted. Everything
                    // before this moment describes a clock that no longer exists.
                    window = Array(recent)
                    stepCandidates.removeAll()
                    recomputeAdopted()
                    return true
                }
                stepCandidates.removeFirst(stepCandidates.count - configuration.stepConfirmations + 1)
            }
            return false
        }

        stepCandidates.removeAll()
        window.append(sample)
        evict(now: sample.t3)
        let previous = adopted
        recomputeAdopted()
        return previous?.offset != adopted?.offset
    }

    private mutating func evict(now: Double) {
        window.removeAll { now - $0.t3 > configuration.maxSampleAge }
        if window.count > configuration.windowSize {
            window.removeFirst(window.count - configuration.windowSize)
        }
    }

    private mutating func recomputeAdopted() {
        adopted = window.min { $0.roundTrip < $1.roundTrip }
    }

    /// serverTime − deviceTime in seconds, or nil before the first valid sample.
    public var offset: Double? { adopted?.offset }

    /// The round trip of the sample the offset came from. The offset's error is
    /// bounded by half of this in the worst asymmetric case.
    public var roundTrip: Double? { adopted?.roundTrip }

    public var sampleCount: Int { window.count }

    public var isSynchronized: Bool {
        adopted != nil && window.count >= configuration.minimumSamples
    }

    /// Converts a `CACurrentMediaTime()` value to server-clock seconds. Returns
    /// nil before sync — callers must not fall back to sending device time and
    /// hoping, because the server cannot tell the two apart.
    public func serverTime(forDeviceTime deviceTime: Double) -> Double? {
        guard let offset else { return nil }
        return deviceTime + offset
    }

    public func deviceTime(forServerTime serverTime: Double) -> Double? {
        guard let offset else { return nil }
        return serverTime - offset
    }

    /// Resets to unsynchronised. Called on reconnect to a different server.
    public mutating func reset() {
        window.removeAll()
        stepCandidates.removeAll()
        adopted = nil
    }
}

// MARK: - Exchange types

/// NTP-style four-timestamp exchange. `t0` is the phone's monotonic clock; `t1`
/// and `t2` are the server's. The phone stamps `t3` on receipt and never trusts
/// the server to have done it.
public struct Ping: Sendable, Equatable, Codable {
    public var id: UInt64
    public var t0: Double

    public init(id: UInt64, t0: Double) {
        self.id = id
        self.t0 = t0
    }
}

public struct Pong: Sendable, Equatable, Codable {
    public var id: UInt64
    public var t0: Double
    public var t1: Double
    public var t2: Double

    public init(id: UInt64, t0: Double, t1: Double, t2: Double) {
        self.id = id
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
    }
}
