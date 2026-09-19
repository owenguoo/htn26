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

        public init(playbackRate: Double? = nil, loops: Int = 1, maxDuration: Double? = nil,
                    injections: [Int: [Injection]] = [:], emitRecordedMarkers: Bool = true) {
            self.playbackRate = playbackRate
            self.loops = max(1, loops)
            self.maxDuration = maxDuration
            self.injections = injections
            self.emitRecordedMarkers = emitRecordedMarkers
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
    public private(set) var emittedPoseCount = 0

    public init(trajectory: Trajectory, configuration: Configuration = .immediate) {
        self.trajectory = trajectory
        self.configuration = configuration
    }

    public func start() async throws -> AsyncStream<PoseProviderEvent> {
        // Unbounded so a replay never silently loses samples: a throttling test
        // that lost input would pass for the wrong reason. Bounded by the
        // fixture length, which is a file on disk, not by anything at runtime.
        let (stream, continuation) = AsyncStream<PoseProviderEvent>.makeStream(bufferingPolicy: .unbounded)
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
    public func setWorldOrigin(relativeTransform: simd_float4x4) async {
        originOffset = Pose(matrix: relativeTransform).inverse
    }

    public func consumeMotionSinceLastQuery() async -> Float {
        defer { motionAccumulator = 0 }
        return motionAccumulator
    }

    private func replay() async {
        guard let continuation, let firstSample = trajectory.samples.first else { return }
        var qualityOverride: TrackingQuality?
        var skipRemaining = 0
        var elapsed: Double = 0
        var loopOffset: Double = 0
        var markerIndex = 0

        for pass in 0..<configuration.loops {
            if pass > 0 {
                loopOffset += trajectory.duration + (1.0 / max(1, trajectory.sampleRate))
                markerIndex = 0
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
                        continuation.yield(.interrupted)
                    case .interruptionEnded:
                        continuation.yield(.interruptionEnded)
                    case .marker(let sighting):
                        continuation.yield(.marker(sighting))
                    case .dropout(let count):
                        skipRemaining = count
                    case .failed(let reason):
                        continuation.yield(.failed(reason))
                    }
                }

                if configuration.emitRecordedMarkers {
                    while markerIndex < trajectory.markerEvents.count,
                          trajectory.markerEvents[markerIndex].t + loopOffset <= sampleTime {
                        let event = trajectory.markerEvents[markerIndex]
                        markerIndex += 1
                        guard let matrix = Trajectory.matrix(from: event.transform) else { continue }
                        continuation.yield(.marker(MarkerSighting(
                            markerID: event.markerID,
                            observedTransform: matrix,
                            deviceTimestamp: event.t + loopOffset,
                            isUpdate: event.isUpdate,
                            estimatedPhysicalWidth: event.estimatedPhysicalWidth)))
                    }
                }

                if skipRemaining > 0 {
                    skipRemaining -= 1
                    continue
                }

                guard let recorded = sample.pose else { continue }
                let pose = originOffset * recorded
                if let last = lastPosition {
                    motionAccumulator += simd_distance(last, pose.position)
                }
                lastPosition = pose.position

                continuation.yield(.pose(PoseSample(
                    pose: pose,
                    deviceTimestamp: sampleTime,
                    quality: qualityOverride ?? sample.quality,
                    intrinsics: trajectory.intrinsics)))
                emittedPoseCount += 1

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
