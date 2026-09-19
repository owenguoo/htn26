import Foundation
import simd

/// `idle → permissions → calibrating → tracking → degraded → lost → recalibrating`
public enum SessionState: String, Sendable, Codable, CaseIterable {
    /// Nothing started.
    case idle
    /// Waiting on camera, motion and local-network permission.
    case permissions
    /// The session is running but no marker has been seen, so the frame is
    /// arbitrary and nothing may be sent for fusion.
    case calibrating
    /// Origin established, ARKit reports normal tracking.
    case tracking
    /// ARKit reports `.limited`. Poses still flow; confidence decays.
    case degraded
    /// `.notAvailable`, an interruption, or nothing heard for longer than the
    /// staleness limit. The last known pose keeps flowing, flagged stale.
    case lost
    /// ARKit threw its map away. The origin is invalid until a marker is seen
    /// again.
    case recalibrating

    /// Whether a venue-frame pose exists to report at all.
    public var hasVenueFramePose: Bool {
        switch self {
        case .idle, .permissions, .calibrating: false
        case .tracking, .degraded, .lost, .recalibrating: true
        }
    }
}

/// `ProcessInfo.thermalState`, restated so SwarmCore does not have to reach for
/// the process to be testable. The app maps one to the other.
public enum ThermalState: String, Sendable, Codable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (a: ThermalState, b: ThermalState) -> Bool { a.rank < b.rank }

    /// Multiplier applied to frame and depth rates. ARKit plus streaming for
    /// thirty minutes will cook a phone, and a thermally throttled phone drops
    /// ARKit tracking, not just frame rate.
    public var rateMultiplier: Double {
        switch self {
        case .nominal, .fair: 1.0
        case .serious: 0.5
        case .critical: 0.25
        }
    }
}

/// A request to capture and send one JPEG. The app fulfils it; SwarmCore never
/// touches a pixel buffer.
public struct FrameTicket: Sendable, Equatable {
    public var frameID: UInt64
    public var deviceTimestamp: Double
    public var serverTimestamp: Double
    public var pose: PoseUpdate
    /// The capture's own resolution and focal lengths, so the encoder knows what
    /// it is downscaling and by how much.
    public var intrinsics: CameraIntrinsics?
    /// Already stamped at `.capture`, on the server clock. Every later stage is
    /// added to this same trace, so a regression past budget is attributable to
    /// a stage rather than to "the network".
    public var trace: LatencyTrace

    public init(frameID: UInt64, deviceTimestamp: Double, serverTimestamp: Double, pose: PoseUpdate, intrinsics: CameraIntrinsics?, trace: LatencyTrace) {
        self.frameID = frameID
        self.deviceTimestamp = deviceTimestamp
        self.serverTimestamp = serverTimestamp
        self.pose = pose
        self.intrinsics = intrinsics
        self.trace = trace
    }
}

/// A request to send one depth chunk. Four to eight frames is VGGT-Ω's
/// throughput sweet spot; time grows super-linearly beyond that.
public struct DepthTicket: Sendable, Equatable {
    public var chunkID: UInt64
    public var frames: [DepthChunk.FrameRef]
    /// The widest camera separation inside the chunk. Below a few centimetres
    /// there is no parallax and no scale to recover.
    public var baseline: Float

    public init(chunkID: UInt64, frames: [DepthChunk.FrameRef], baseline: Float) {
        self.chunkID = chunkID
        self.frames = frames
        self.baseline = baseline
    }
}

public enum SessionEvent: Sendable, Equatable {
    case stateChanged(from: SessionState, to: SessionState)
    case pose(PoseUpdate)
    case captureFrame(FrameTicket)
    case captureDepthChunk(DepthTicket)
    case correctionApplied(markerID: String, positionError: Float, rotationDegrees: Float)
    case correctionRejected(markerID: String, reason: String)
    case failed(String)
}

/// Everything the status pill shows, and everything a test needs to assert on.
public struct SessionDiagnostics: Sendable, Equatable {
    public var state: SessionState = .idle
    public var quality: TrackingQuality = .notAvailable
    public var confidence: Double = 0
    public var lastCorrectionAge: Double?
    public var lastCorrectionMarker: String?
    public var poseAge: Double = 0
    public var isStale: Bool = false
    public var posesEmitted: Int = 0
    public var framesRequested: Int = 0
    public var depthChunksRequested: Int = 0
    public var depthChunksSkippedForBaseline: Int = 0
    public var framesSuppressedForOriginChange: Int = 0
    public var corrections: Int = 0
    public var rejectedCorrections: Int = 0
    public var thermalState: ThermalState = .nominal
    public var isBlockedOnClockSync: Bool = true
    /// Metres of device motion accumulated while tracking was unusable. A
    /// yes/no signal — "did this person move" — never a position.
    public var motionWhileLost: Float = 0
}

/// Owns the ARKit seam, the calibration engine, the clock and the throttles.
///
/// `session(_:didUpdate:)` fires at 60 Hz. Everything this machine emits is
/// throttled down from that: poses at about 10 Hz, frames at 1–2 fps, depth
/// chunks at 0.2–0.5 Hz. Nothing here grows without bound, because it runs for
/// the length of the demo.
public actor SessionMachine {
    public struct Rates: Sendable, Equatable {
        public var poseHz: Double
        public var frameFPS: Double
        public var depthHz: Double

        public init(poseHz: Double = 10, frameFPS: Double = 1.5, depthHz: Double = 0.3) {
            self.poseHz = poseHz
            self.frameFPS = frameFPS
            self.depthHz = depthHz
        }
    }

    public struct Configuration: Sendable {
        public var deviceID: String
        public var rates: Rates
        /// A pose older than this is flagged stale, so the dashboard greys the
        /// cone rather than drawing it confidently in the wrong place.
        public var stalenessLimit: Double
        /// Degraded for longer than this and the session is considered lost.
        public var degradedToLostAfter: Double
        /// Confidence units lost per second while tracking is degraded.
        public var confidenceDecayPerSecond: Double
        /// Confidence units regained per second while tracking is normal.
        public var confidenceRecoveryPerSecond: Double
        /// A marker correction is a hard re-lock: confidence jumps to this.
        public var confidenceAfterCorrection: Double
        /// Frames per depth chunk. VGGT-Ω's sweet spot is 4–8.
        public var depthChunkSize: Int
        /// Minimum camera separation within a chunk, in metres. A stationary
        /// phone gives no parallax, so submitting one is wasted inference.
        public var minimumDepthBaseline: Float
        /// Poses are not sent before the clock is synchronised: the server
        /// cannot tell an unsynchronised timestamp from a synchronised one, and
        /// fusing on device uptime is worse than fusing on nothing.
        public var requireClockSync: Bool
        /// Frames to skip after the world origin moves.
        ///
        /// `setWorldOrigin` affects subsequent frames, but a frame captured
        /// before the call can still be in flight when it lands. A pose from one
        /// is a cone that flickers for a sixtieth of a second; a *frame* from one
        /// is geometry the server unprojects into the wrong place and then
        /// reasons about. Poses keep flowing; frames wait for the origin to
        /// settle, which at 1.5 fps costs nothing.
        public var framesSuppressedAfterOriginChange: Int

        public init(deviceID: String, rates: Rates = Rates(), stalenessLimit: Double = 5.0,
                    degradedToLostAfter: Double = 4.0, confidenceDecayPerSecond: Double = 0.25,
                    confidenceRecoveryPerSecond: Double = 0.5, confidenceAfterCorrection: Double = 1.0,
                    depthChunkSize: Int = 6, minimumDepthBaseline: Float = 0.12,
                    requireClockSync: Bool = true, framesSuppressedAfterOriginChange: Int = 2) {
            self.deviceID = deviceID
            self.rates = rates
            self.stalenessLimit = stalenessLimit
            self.degradedToLostAfter = degradedToLostAfter
            self.confidenceDecayPerSecond = confidenceDecayPerSecond
            self.confidenceRecoveryPerSecond = confidenceRecoveryPerSecond
            self.confidenceAfterCorrection = confidenceAfterCorrection
            self.depthChunkSize = max(2, depthChunkSize)
            self.minimumDepthBaseline = minimumDepthBaseline
            self.requireClockSync = requireClockSync
            self.framesSuppressedAfterOriginChange = max(0, framesSuppressedAfterOriginChange)
        }
    }

    // MARK: - State

    private var configuration: Configuration
    private let provider: any PoseProvider
    private var calibration: CalibrationEngine
    private var clock: ClockSync

    private(set) public var state: SessionState = .idle
    private var quality: TrackingQuality = .notAvailable
    private var confidence: Double = 0
    private var now: Double = 0
    private var lastPoseTime: Double?
    private var lastPose: Pose?
    private var lastIntrinsics: CameraIntrinsics?
    private var degradedSince: Double?
    private var thermalState: ThermalState = .nominal
    private var motionWhileLost: Float = 0

    private var nextPoseDue: Double = -.infinity
    private var nextFrameDue: Double = -.infinity
    private var nextDepthDue: Double = -.infinity
    private var frameID: UInt64 = 0
    private var chunkID: UInt64 = 0
    private var poseSeq: UInt64 = 0

    /// A fixed-capacity ring of recent frame references. Bounded by construction:
    /// this runs for thirty minutes and a growing array is a memory leak with a
    /// schedule.
    private var recentFrames: [DepthChunk.FrameRef] = []
    /// Counts down after the world origin moves. See
    /// `framesSuppressedAfterOriginChange`.
    private var framesSuppressed = 0

    private var diagnostics = SessionDiagnostics()
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?

    public init(configuration: Configuration, venue: Venue, provider: any PoseProvider,
                clock: ClockSync = ClockSync()) {
        self.configuration = configuration
        self.provider = provider
        self.calibration = CalibrationEngine(venue: venue)
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Moves to `permissions`. The app calls `permissionsGranted()` once the
    /// camera, motion and local-network prompts have been answered.
    public func start() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        transition(to: .permissions)
        return stream
    }

    /// Starts the underlying provider and begins consuming its events.
    public func permissionsGranted() async throws {
        guard state == .permissions else { return }
        transition(to: .calibrating)
        let events = try await provider.start()
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.finish()
        }
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        await provider.stop()
        continuation?.finish()
        continuation = nil
        transition(to: .idle)
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
    }

    // MARK: - External inputs

    public func ingest(pong: Pong, receivedAt deviceTime: Double) {
        clock.ingest(pong, receivedAt: deviceTime)
        diagnostics.isBlockedOnClockSync = configuration.requireClockSync && !clock.isSynchronized
    }

    public func setThermalState(_ newValue: ThermalState) {
        thermalState = newValue
        diagnostics.thermalState = newValue
    }

    /// Server-driven rate control, from a `setRates` command.
    public func setRates(_ rates: Rates) {
        configuration.rates = rates
    }

    /// Advances the machine's clock without a new pose, so staleness and the
    /// degraded-to-lost timeout still fire when ARKit has gone quiet. The app
    /// drives this from a timer; a replay drives it from the fixture.
    public func tick(deviceTime: Double) {
        advance(to: deviceTime)
        evaluateSilence()
        emitIfDue()
    }

    /// Converts device uptime to server time, or nil before the clock has
    /// synchronised. The app stamps its own trace entries through this so every
    /// stage is on one clock.
    public func serverTime(forDeviceTime deviceTime: Double) -> Double? {
        clock.serverTime(forDeviceTime: deviceTime)
    }

    public func clockOffset() -> Double? { clock.offset }

    /// The most recent venue-frame pose, for the overlay's tracked arrow.
    public func latestVenuePose() -> Pose? {
        state.hasVenueFramePose ? lastPose : nil
    }

    public func currentDiagnostics() -> SessionDiagnostics {
        var snapshot = diagnostics
        snapshot.state = state
        snapshot.quality = quality
        snapshot.confidence = confidence
        snapshot.lastCorrectionAge = calibration.correctionAge(at: now)
        snapshot.lastCorrectionMarker = calibration.lastCorrectionMarker
        snapshot.poseAge = lastPoseTime.map { max(0, now - $0) } ?? 0
        snapshot.isStale = isStale
        snapshot.motionWhileLost = motionWhileLost
        return snapshot
    }

    /// Total number of elements held in every internal collection. A soak test
    /// asserts this does not grow with replay length.
    public func storageFootprint() -> Int {
        recentFrames.count + clock.sampleCount
    }

    // MARK: - Event handling

    private func handle(_ event: PoseProviderEvent) async {
        switch event {
        case .pose(let sample):
            await handlePose(sample)
        case .marker(let sighting):
            await handleMarker(sighting)
        case .interrupted:
            // ARKit pauses on backgrounding, a call, the camera being taken away.
            advance(to: now)
            transition(to: .lost)
        case .interruptionEnded:
            // The map is gone. Nothing is trustworthy until a marker is seen.
            calibration.invalidateOrigin()
            transition(to: .recalibrating)
        case .failed(let reason):
            continuation?.yield(.failed(reason))
            transition(to: .lost)
        }
    }

    private func handlePose(_ sample: PoseSample) async {
        advance(to: sample.deviceTimestamp)
        quality = sample.quality
        lastPose = sample.pose
        lastPoseTime = sample.deviceTimestamp
        lastIntrinsics = sample.intrinsics ?? lastIntrinsics

        updateConfidence(for: sample.quality)
        updateStateForQuality(sample.quality)
        emitIfDue()
    }

    private func handleMarker(_ sighting: MarkerSighting) async {
        advance(to: sighting.deviceTimestamp)
        let outcome = calibration.evaluate(sighting)
        switch outcome {
        case .originEstablished(let correction), .corrected(let correction):
            await provider.setWorldOrigin(relativeTransform: correction.relativeTransform)
            // Buffered frame references were recorded in the frame that just
            // moved. Re-express them, or a depth chunk straddling a correction
            // reports a baseline made of the correction rather than of motion.
            remapBufferedFrames(by: correction.relativeTransform)
            if case .originEstablished = outcome {
                // The frame changed wholesale, not by a bounded step. Nothing
                // recorded under the old one means anything.
                recentFrames.removeAll(keepingCapacity: true)
            }
            framesSuppressed = configuration.framesSuppressedAfterOriginChange
            diagnostics.corrections += 1
            // A marker sighting is a hard re-lock: whatever ARKit thinks of its
            // own tracking, we now know where we are.
            confidence = configuration.confidenceAfterCorrection
            motionWhileLost = 0
            continuation?.yield(.correctionApplied(markerID: correction.markerID,
                                                   positionError: correction.measuredPositionError,
                                                   rotationDegrees: correction.measuredRotationDegrees))
            if state == .calibrating || state == .recalibrating || state == .lost {
                transition(to: quality.isUsable ? .tracking : .degraded)
            }
        case .rejected(let rejection):
            diagnostics.rejectedCorrections += 1
            continuation?.yield(.correctionRejected(markerID: sighting.markerID,
                                                    reason: String(describing: rejection)))
        case .noChangeNeeded:
            break
        }
    }

    private func advance(to time: Double) {
        guard time > now else { return }
        let elapsed = now == 0 ? 0 : time - now
        now = time
        decayConfidence(over: elapsed)
    }

    // MARK: - Confidence

    /// The ceiling confidence can reach in a given tracking state.
    private func ceiling(for quality: TrackingQuality) -> Double {
        switch quality {
        case .normal: 1.0
        case .notAvailable: 0.0
        case .limited(let reason):
            switch reason {
            case .initializing: 0.15
            case .relocalizing: 0.20
            case .insufficientFeatures: 0.30
            case .excessiveMotion: 0.40
            case .unknown: 0.20
            }
        }
    }

    private func decayConfidence(over elapsed: Double) {
        guard elapsed > 0 else { return }
        let target = ceiling(for: quality)
        if confidence > target {
            confidence = max(target, confidence - configuration.confidenceDecayPerSecond * elapsed)
        } else if confidence < target {
            confidence = min(target, confidence + configuration.confidenceRecoveryPerSecond * elapsed)
        }
    }

    private func updateConfidence(for quality: TrackingQuality) {
        // The decay itself happens in `advance`; this only clamps an impossible
        // value, e.g. straight after a correction into a degraded state.
        confidence = min(1, max(0, confidence))
    }

    // MARK: - State transitions

    private func updateStateForQuality(_ quality: TrackingQuality) {
        switch state {
        case .idle, .permissions:
            return
        case .calibrating, .recalibrating:
            // No origin yet: a marker, not tracking quality, is what gets us out.
            return
        case .tracking:
            switch quality {
            case .normal:
                break
            case .limited:
                degradedSince = now
                transition(to: .degraded)
            case .notAvailable:
                transition(to: .lost)
            }
        case .degraded:
            switch quality {
            case .normal:
                degradedSince = nil
                transition(to: .tracking)
            case .limited:
                if let since = degradedSince, now - since >= configuration.degradedToLostAfter {
                    transition(to: .lost)
                }
            case .notAvailable:
                transition(to: .lost)
            }
        case .lost:
            switch quality {
            case .normal:
                degradedSince = nil
                transition(to: .tracking)
            case .limited:
                degradedSince = now
                transition(to: .degraded)
            case .notAvailable:
                break
            }
        }
    }

    /// Nothing has arrived for a while: ARKit has gone quiet, which is not the
    /// same as ARKit saying it is lost, and the dashboard must be told.
    private func evaluateSilence() {
        guard let lastPoseTime else { return }
        guard now - lastPoseTime > configuration.stalenessLimit else { return }
        if state == .tracking || state == .degraded {
            transition(to: .lost)
        }
    }

    private var isStale: Bool {
        guard let lastPoseTime else { return true }
        return now - lastPoseTime > configuration.stalenessLimit
    }

    private func transition(to newState: SessionState) {
        guard newState != state else { return }
        let old = state
        state = newState
        if newState == .lost || newState == .recalibrating {
            // Whatever the phone did while it could not see is a yes/no signal
            // about movement, never a position estimate. Pedestrian dead
            // reckoning heading error compounds: 20 degrees over 10 m is ~3.4 m
            // lateral and never recovers.
            Task { [weak self] in
                guard let self else { return }
                let moved = await self.provider.consumeMotionSinceLastQuery()
                await self.recordMotionWhileLost(moved)
            }
        }
        continuation?.yield(.stateChanged(from: old, to: newState))
    }

    private func recordMotionWhileLost(_ metres: Float) {
        motionWhileLost += metres
    }

    // MARK: - Throttled emission

    private func emitIfDue() {
        guard state.hasVenueFramePose, let pose = lastPose else { return }
        if configuration.requireClockSync && !clock.isSynchronized {
            diagnostics.isBlockedOnClockSync = true
            return
        }
        diagnostics.isBlockedOnClockSync = false

        let poseInterval = 1.0 / max(0.001, configuration.rates.poseHz)
        guard now >= nextPoseDue else { return }
        // Advance from the due time, not from now, so a late sample does not
        // permanently shift the cadence.
        nextPoseDue = max(now, nextPoseDue == -.infinity ? now : nextPoseDue) + poseInterval

        let update = makePoseUpdate(pose: pose)
        diagnostics.posesEmitted += 1
        continuation?.yield(.pose(update))

        emitFrameIfDue(pose: update)
        emitDepthIfDue()
    }

    private func makePoseUpdate(pose: Pose) -> PoseUpdate {
        poseSeq += 1
        let deviceTimestamp = lastPoseTime ?? now
        let serverTimestamp = clock.serverTime(forDeviceTime: deviceTimestamp) ?? deviceTimestamp
        return PoseUpdate(deviceID: configuration.deviceID,
                          serverTimestamp: serverTimestamp,
                          deviceTimestamp: deviceTimestamp,
                          position: pose.wirePosition,
                          quaternion: pose.wireQuaternion,
                          trackingState: quality.wireValue,
                          confidence: Float(confidence),
                          lastCorrectionAge: calibration.correctionAge(at: now),
                          lastCorrectionMarker: calibration.lastCorrectionMarker,
                          stale: isStale,
                          seq: poseSeq)
    }

    private func emitFrameIfDue(pose: PoseUpdate) {
        // A stale pose means we do not know where the camera is, so a frame from
        // it cannot be unprojected. Sending it wastes inference and bandwidth.
        guard !isStale else { return }
        guard framesSuppressed == 0 else {
            framesSuppressed -= 1
            diagnostics.framesSuppressedForOriginChange += 1
            return
        }
        let interval = 1.0 / max(0.001, configuration.rates.frameFPS * thermalState.rateMultiplier)
        guard now >= nextFrameDue else { return }
        nextFrameDue = (nextFrameDue == -.infinity ? now : max(now, nextFrameDue)) + interval

        frameID += 1
        var trace = LatencyTrace(frameID: frameID)
        trace.stamp(.capture, at: pose.serverTimestamp)
        let ticket = FrameTicket(frameID: frameID,
                                 deviceTimestamp: lastPoseTime ?? now,
                                 serverTimestamp: pose.serverTimestamp,
                                 pose: pose,
                                 intrinsics: lastIntrinsics,
                                 trace: trace)
        diagnostics.framesRequested += 1
        recordFrameReference(ticket)
        continuation?.yield(.captureFrame(ticket))
    }

    /// `setWorldOrigin(R)` maps every point `p` to `R⁻¹ · p`, including points
    /// already recorded.
    private func remapBufferedFrames(by transform: simd_float4x4) {
        guard !recentFrames.isEmpty else { return }
        let inverse = Pose(matrix: transform).inverse
        recentFrames = recentFrames.map { frame in
            guard frame.position.count == 3, frame.quaternion.count == 4 else { return frame }
            let pose = Pose(position: SIMD3<Float>(frame.position[0], frame.position[1], frame.position[2]),
                            orientation: simd_quatf(ix: frame.quaternion[0], iy: frame.quaternion[1],
                                                    iz: frame.quaternion[2], r: frame.quaternion[3]))
            let moved = inverse * pose
            return DepthChunk.FrameRef(frameID: frame.frameID, serverTimestamp: frame.serverTimestamp,
                                       position: moved.wirePosition, quaternion: moved.wireQuaternion)
        }
    }

    private func recordFrameReference(_ ticket: FrameTicket) {
        recentFrames.append(DepthChunk.FrameRef(frameID: ticket.frameID,
                                                serverTimestamp: ticket.serverTimestamp,
                                                position: ticket.pose.position,
                                                quaternion: ticket.pose.quaternion))
        // Fixed capacity. Never let this track session length.
        if recentFrames.count > configuration.depthChunkSize {
            recentFrames.removeFirst(recentFrames.count - configuration.depthChunkSize)
        }
    }

    private func emitDepthIfDue() {
        let interval = 1.0 / max(0.001, configuration.rates.depthHz * thermalState.rateMultiplier)
        guard now >= nextDepthDue else { return }
        guard recentFrames.count >= configuration.depthChunkSize else { return }
        nextDepthDue = (nextDepthDue == -.infinity ? now : max(now, nextDepthDue)) + interval

        let baseline = DepthScaleFit.widestBaseline(of: recentFrames)
        guard baseline >= configuration.minimumDepthBaseline else {
            // A stationary phone gives no parallax and no scale. Skip rather than
            // send the server work whose answer cannot be made metric.
            diagnostics.depthChunksSkippedForBaseline += 1
            return
        }
        chunkID += 1
        diagnostics.depthChunksRequested += 1
        let frames = recentFrames
        // Chunks are disjoint: a frame belongs to one reconstruction, not two.
        recentFrames.removeAll(keepingCapacity: true)
        continuation?.yield(.captureDepthChunk(DepthTicket(chunkID: chunkID,
                                                           frames: frames,
                                                           baseline: baseline)))
    }
}
