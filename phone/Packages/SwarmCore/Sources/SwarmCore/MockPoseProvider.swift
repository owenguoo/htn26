import Foundation
import simd

/// Replays a recorded trajectory through the same seam ARKit plugs into.
///
/// This is the whole reason gates 3, 4 and 7 are testable with no device: the
/// state machine cannot tell this apart from a real `ARSession`, so everything
/// downstream of the seam is exercised by `swift test`.
public actor MockPoseProvider: PoseProvider {
    /// Events a test injects on top of the recording, to exercise paths the
    /// recording itself may not contain.
    public enum Injection: Sendable {
        /// Overrides the recorded tracking state from this sample onward. nil
        /// restores whatever the recording says.
        case quality(TrackingQuality?)
        case interrupted
        case interruptionEnded
        case marker(MarkerSighting)
        /// Emits nothing for the next `count` samples — the session goes quiet,
        /// which is what staleness detection exists for.
        case dropout(count: Int)
        case failed(String)
    }

    public struct Configuration: Sendable {
        /// nil replays as fast as the consumer drains. A value scales wall-clock
        /// pacing: 1.0 is real time, 10.0 is ten times faster.
        public var playbackRate: Double?
        /// Replays the recording end-to-end repeatedly, with timestamps advancing
        /// continuously. A 30-minute soak over a 2-minute fixture needs this.
        public var loops: Int
        /// Stops after this many seconds of replayed time, whatever `loops` says.
        public var maxDuration: Double?
        /// Keyed by sample index within a single pass.
        public var injections: [Int: [Injection]]
        /// Emits the recording's own marker events.
        public var emitRecordedMarkers: Bool
        /// Emits one event and then waits for `advance()`. Without this the
        /// producer runs ahead of the consumer, so a correction applied on
        /// sighting N would not reach samples N+1 onward — which is exactly the
        /// behaviour a drift-correction test is trying to measure.
        public var lockstep: Bool
        /// How many events the replay may get ahead of its consumer.
        ///
        /// A real `ARSession` delivers a frame and then the next one 16 ms later;
        /// it cannot buffer thousands while the consumer catches up. That matters
        /// because `setWorldOrigin` only affects *subsequent* frames: a replay
        /// running far ahead would hand the consumer poses computed under the old
        /// origin long after the correction, which no real session ever does.
        public var deliveryDepth: Int

        public init(playbackRate: Double? = nil, loops: Int = 1, maxDuration: Double? = nil,
                    injections: [Int: [Injection]] = [:], emitRecordedMarkers: Bool = true,
                    lockstep: Bool = false, deliveryDepth: Int = 1) {
            self.playbackRate = playbackRate
            self.loops = max(1, loops)
            self.maxDuration = maxDuration
            self.injections = injections
            self.emitRecordedMarkers = emitRecordedMarkers
            self.lockstep = lockstep
            self.deliveryDepth = max(1, deliveryDepth)
        }

        public static let immediate = Configuration()
    }

    private let trajectory: Trajectory
    private let configuration: Configuration
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<PoseProviderEvent>.Continuation?
    private var originOffset: Pose = .identity
    private var motionAccumulator: Float = 0
    private var lastPosition: SIMD3<Float>?
    private var advanceWaiter: CheckedContinuation<Void, Never>?
    private var advancePending = false
    public private(set) var emittedPoseCount = 0

    public init(trajectory: Trajectory, configuration: Configuration = .immediate) {
        self.trajectory = trajectory
        self.configuration = configuration
    }

    public func start() async throws -> AsyncStream<PoseProviderEvent> {
        // Shallow and lossless: the producer retries rather than dropping, so a
        // throttling test never passes because input went missing, and the replay
        // cannot outrun the consumer the way an unbounded buffer would let it.
        let (stream, continuation) = AsyncStream<PoseProviderEvent>
            .makeStream(bufferingPolicy: .bufferingOldest(configuration.deliveryDepth))
        self.continuation = continuation
        task = Task { [weak self] in
            await self?.replay()
            continuation.finish()
        }
        return stream
    }

    public func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// Applied as an offset to what this provider emits, standing in for
    /// `session.setWorldOrigin(relativeTransform:)`. A replay cannot re-origin a
    /// live session, so it re-origins its own output instead — which is exactly
    /// the observable effect ARKit produces.
    ///
    /// Composes rather than replaces, because ARKit expresses each
    /// `relativeTransform` in the frame that is current at the time of the call,
    /// not in the recording's original frame.
    public func setWorldOrigin(relativeTransform: simd_float4x4) async {
        originOffset = Pose(matrix: relativeTransform).inverse * originOffset
    }

    /// Releases the next event in lockstep mode. Harmless when lockstep is off.
    public func advance() {
        if let waiter = advanceWaiter {
            advanceWaiter = nil
            waiter.resume()
        } else {
            advancePending = true
        }
    }

    private func waitForAdvance() async {
        guard configuration.lockstep else { return }
        if advancePending {
            advancePending = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            advanceWaiter = continuation
        }
    }

    public func consumeMotionSinceLastQuery() async -> Float {
        defer { motionAccumulator = 0 }
        return motionAccumulator
    }

    /// Enqueues an event, waiting rather than dropping when the buffer is full.
    /// `AsyncStream` has no backpressure of its own, so this supplies it.
    ///
    /// `make` is re-invoked on every attempt rather than the event being built
    /// once up front. That is what makes `setWorldOrigin` behave the way ARKit's
    /// does: a frame is expressed in whatever origin is current when the session
    /// hands it over, not in the one that was current when it was captured. Build
    /// the event once and a correction would appear to be ignored for exactly as
    /// long as the consumer took to read the marker that caused it.
    private func deliver(_ continuation: AsyncStream<PoseProviderEvent>.Continuation,
                         _ make: () -> PoseProviderEvent) async {
        var spins = 0
        while !Task.isCancelled {
            switch continuation.yield(make()) {
            case .enqueued, .terminated:
                return
            case .dropped:
                spins += 1
                if spins < 8 {
                    await Task.yield()
                } else {
                    // The consumer is genuinely busy; stop spinning at it.
                    try? await Task.sleep(nanoseconds: 100_000)
                    spins = 0
                }
            @unknown default:
                return
            }
        }
    }

    private func replay() async {
        guard let continuation, let firstSample = trajectory.samples.first else { return }
        var qualityOverride: TrackingQuality?
        var skipRemaining = 0
        var elapsed: Double = 0
        var loopOffset: Double = 0
        var markerIndex = 0
        var interruptionIndex = 0
        var interruptionOpen = false

        for pass in 0..<configuration.loops {
            if pass > 0 {
                loopOffset += trajectory.duration + (1.0 / max(1, trajectory.sampleRate))
                markerIndex = 0
                interruptionIndex = 0
            }
            for (index, sample) in trajectory.samples.enumerated() {
                if Task.isCancelled { return }
                let sampleTime = sample.t + loopOffset
                elapsed = sampleTime - firstSample.t
                if let maxDuration = configuration.maxDuration, elapsed > maxDuration { return }

                for injection in configuration.injections[index] ?? [] {
                    switch injection {
                    case .quality(let quality):
                        qualityOverride = quality
                    case .interrupted:
                        await deliver(continuation) { .interrupted }
                    case .interruptionEnded:
                        await deliver(continuation) { .interruptionEnded }
                    case .marker(let sighting):
                        await deliver(continuation) { .marker(sighting) }
                    case .dropout(let count):
                        skipRemaining = count
                    case .failed(let reason):
                        await deliver(continuation) { .failed(reason) }
                    }
                }

                // Interruptions the recording captured: a call, backgrounding,
                // the camera being taken away. ARKit throws its map away across
                // one of these, so they are events, not just a quality change.
                while interruptionIndex < trajectory.interruptions.count {
                    let window = trajectory.interruptions[interruptionIndex]
                    if !interruptionOpen, window.startT + loopOffset <= sampleTime {
                        interruptionOpen = true
                        await deliver(continuation) { .interrupted }
                        await waitForAdvance()
                    }
                    if interruptionOpen, window.endT + loopOffset <= sampleTime {
                        interruptionOpen = false
                        interruptionIndex += 1
                        await deliver(continuation) { .interruptionEnded }
                        await waitForAdvance()
                        continue
                    }
                    break
                }

                if configuration.emitRecordedMarkers {
                    while markerIndex < trajectory.markerEvents.count,
                          trajectory.markerEvents[markerIndex].t + loopOffset <= sampleTime {
                        let event = trajectory.markerEvents[markerIndex]
                        markerIndex += 1
                        guard let matrix = Trajectory.matrix(from: event.transform) else { continue }
                        // A marker is reported in whatever frame is current, so
                        // the origin offset applies to sightings exactly as it
                        // applies to poses.
                        await deliver(continuation) {
                            let observed = self.originOffset * Pose(matrix: matrix)
                            return .marker(MarkerSighting(
                                markerID: event.markerID,
                                observedTransform: observed.matrix,
                                deviceTimestamp: event.t + loopOffset,
                                isUpdate: event.isUpdate,
                                estimatedPhysicalWidth: event.estimatedPhysicalWidth))
                        }
                        await waitForAdvance()
                    }
                }

                if skipRemaining > 0 {
                    skipRemaining -= 1
                    continue
                }

                guard let recorded = sample.pose else { continue }
                let quality = qualityOverride ?? sample.quality
                await deliver(continuation) {
                    let pose = self.originOffset * recorded
                    if let last = self.lastPosition {
                        self.motionAccumulator += simd_distance(last, pose.position)
                    }
                    self.lastPosition = pose.position
                    return .pose(PoseSample(pose: pose,
                                            deviceTimestamp: sampleTime,
                                            quality: quality,
                                            intrinsics: self.trajectory.intrinsics))
                }
                emittedPoseCount += 1
                await waitForAdvance()

                if let rate = configuration.playbackRate, rate > 0, index + 1 < trajectory.samples.count {
                    let step = trajectory.samples[index + 1].t - sample.t
                    try? await Task.sleep(nanoseconds: UInt64(max(0, step / rate) * 1_000_000_000))
                } else {
                    // Let the consumer run, so a replay of 7 200 samples does not
                    // become one enormous synchronous burst.
                    await Task.yield()
                }
            }
        }
    }
}
