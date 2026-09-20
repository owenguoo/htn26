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
        // `recalibrating` belongs with `calibrating`: the origin is invalid, so
        // whatever ARKit reports is in a frame nobody else shares.
        case .idle, .permissions, .calibrating, .recalibrating: false
        case .tracking, .degraded, .lost: true
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
    /// A pose in ARKit's arbitrary start-up frame, emitted only when
    /// `emitsBeforeOrigin` is set. Never venue-frame; `inVenueFrame` is false.
    case rawPose(PoseUpdate)
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
    /// Corrections built from more than one marker seen at once. Averaging
    /// several is the whole argument for putting up more than one marker.
    public var averagedSightings: Int = 0
    /// Times the origin was re-established because sightings kept agreeing with
    /// each other and not with it — ARKit relocalized with a jump.
    public var relocks: Int = 0
    /// Times the origin was thrown away because ARKit's tracking broke and came
    /// back, so the map the origin was measured in no longer existed.
    public var originsDroppedForTrackingBreak: Int = 0
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
        /// Frames are scheduled on their own clock, against every incoming
        /// sample, so `frameFPS` may exceed `poseHz`. The app runs every phone
        /// at 15 — the console's whole camera wall is live video now, not a
        /// strip of stills that only moves for whichever tile is expanded — and
        /// the hub's focus command asks for the same 15, so focusing a phone
        /// changes nothing about its rate. Thermal shedding still multiplies
        /// this down on a hot phone. Depth chunks are still considered only
        /// when a pose is emitted, so `poseHz` bounds `depthHz`.
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
        ///
        /// Turning this off does not make the timestamps good — it makes the
        /// phone send `serverTimestamp` values that are really device uptime,
        /// which a fusing server would get wrong.
        ///
        /// Off by default since the htn26 hub: the hub estimates each phone's
        /// clock offset itself from `pong.tp`, never reads these timestamps, and
        /// sends no NTP-style pong for `ClockSync` to ingest.
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
        /// Emit `rawPose` events and frame tickets before any marker has been
        /// seen.
        ///
        /// The hub marks a phone stale after 3 s without a frame, and the
        /// seat-tap fallback needs a live pose to anchor to, so a phone that
        /// says nothing until it finds a marker is both invisible and unable to
        /// use the fallback. Raw poses are flagged `inVenueFrame == false`; it is
        /// the consumer's job never to report one as a room position without a
        /// seat alignment.
        public var emitsBeforeOrigin: Bool

        public init(deviceID: String, rates: Rates = Rates(), stalenessLimit: Double = 5.0,
                    degradedToLostAfter: Double = 4.0, confidenceDecayPerSecond: Double = 0.25,
                    confidenceRecoveryPerSecond: Double = 0.5, confidenceAfterCorrection: Double = 1.0,
                    depthChunkSize: Int = 6, minimumDepthBaseline: Float = 0.12,
                    requireClockSync: Bool = false, framesSuppressedAfterOriginChange: Int = 2,
                    emitsBeforeOrigin: Bool = false) {
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
            self.emitsBeforeOrigin = emitsBeforeOrigin
        }
    }

    // MARK: - State

    private var configuration: Configuration
    /// What `rate` with a null fps goes back to.
    private var defaultFrameFPS: Double
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
    /// ARKit's tracking broke, so its world map may no longer be the one the
    /// origin was measured in. Set while the break lasts, acted on the moment
    /// tracking comes back — see `resolveSuspectOrigin`.
    private var originIsSuspect = false

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
    /// Sightings seen in the same instant, held so they can be averaged into one
    /// correction rather than applied as several. ARKit delivers every anchor it
    /// updated in a single `didUpdate` callback, so they share a timestamp
    /// exactly; this batch closes as soon as anything with a different one
    /// arrives, which at 60 Hz is within 17 ms.
    private var pendingSightings: [MarkerSighting] = []
    /// Counts down after the world origin moves. See
    /// `framesSuppressedAfterOriginChange`.
    private var framesSuppressed = 0

    private var diagnostics = SessionDiagnostics()
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?

    public init(configuration: Configuration, venue: Venue, provider: any PoseProvider,
                clock: ClockSync = ClockSync()) {
        self.configuration = configuration
        self.defaultFrameFPS = configuration.rates.frameFPS
        self.provider = provider
        self.calibration = CalibrationEngine(venue: venue)
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Moves to `permissions`. The app calls `permissionsGranted()` once the
    /// camera, motion and local-network prompts have been answered.
    public func start() -> AsyncStream<SessionEvent> {
        // Bounded, because "backpressure drops, never queues" has to hold here
        // too: this stream carries poses at 10 Hz and frame tickets at 15, and
        // its consumer hops into the transport actor for every one. An
        // unbounded buffer turns any transport stall into a growing backlog of
        // back-dated poses — a phone reporting where it was thirty seconds ago.
        // 64 rather than a tighter bound because the stream also carries
        // one-off control events (`stateChanged`, `correctionApplied`,
        // `failed`) that must survive an ordinary burst; at 25 events/s that is
        // ~2.5 s of headroom, so the newest-wins drop only bites in a real
        // stall, which is exactly when shedding poses is correct.
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
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
        pendingSightings.removeAll()
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

    /// The operator's "this is wrong, start again": throws the origin away so
    /// the next marker re-establishes it from scratch, exactly as after an
    /// interruption. The manual counterpart of the calibration engine's
    /// automatic re-anchor.
    public func resetOrigin() {
        guard state != .idle, state != .permissions else { return }
        pendingSightings.removeAll()
        calibration.invalidateOrigin()
        originIsSuspect = false
        recentFrames.removeAll(keepingCapacity: true)
        transition(to: .recalibrating)
    }

    public func setThermalState(_ newValue: ThermalState) {
        thermalState = newValue
        diagnostics.thermalState = newValue
    }

    public func setRates(_ rates: Rates) {
        configuration.rates = rates
        defaultFrameFPS = rates.frameFPS
    }

    /// The hub's `rate` command. nil restores the configured default. Clamped to
    /// 1–15: the hub asks for 8 today and 15 on its streaming branch. Thermal
    /// shedding still multiplies whatever this sets, downward only.
    public func setFrameRate(fps: Double?) {
        let requested = fps ?? defaultFrameFPS
        configuration.rates.frameFPS = fps == nil ? requested : min(Self.maxHubFPS, max(1, requested))
        // Take effect now, not after the old, slower interval has run out.
        nextFrameDue = -.infinity
    }

    public static let maxHubFPS: Double = 15

    public func currentRates() -> Rates { configuration.rates }

    /// The most recent pose in whatever frame ARKit is in, venue or not.
    public func latestPose() -> (pose: Pose, inVenueFrame: Bool, intrinsics: CameraIntrinsics?)? {
        lastPose.map { ($0, calibration.hasOrigin && state.hasVenueFramePose, lastIntrinsics) }
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
        snapshot.relocks = calibration.relockCount
        snapshot.poseAge = lastPoseTime.map { max(0, now - $0) } ?? 0
        snapshot.isStale = isStale
        snapshot.motionWhileLost = motionWhileLost
        snapshot.isBlockedOnClockSync = configuration.requireClockSync && !clock.isSynchronized
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
            await flushPendingSightings()
            await handlePose(sample)
        case .marker(let sighting):
            if let open = pendingSightings.first,
               abs(open.deviceTimestamp - sighting.deviceTimestamp) > 1e-6 {
                await flushPendingSightings()
            }
            pendingSightings.append(sighting)
        case .interrupted:
            // ARKit pauses on backgrounding, a call, the camera being taken away.
            // It also stops delivering frames, so the last quality it reported —
            // usually `.normal` — would otherwise stand, and hold confidence at
            // full, for as long as the interruption lasts.
            advance(to: now)
            quality = .notAvailable
            // A real interruption delivers no frames at all, so the pose path
            // never sees `notAvailable` and cannot notice the break for itself.
            // Say it here: if ARKit comes back tracking without ever sending
            // `interruptionEnded`, the origin still does not survive.
            originIsSuspect = true
            // Nothing is lost if nothing was ever found: an interruption during
            // calibration leaves us still waiting for a first marker, and moving
            // to `.lost` would claim a venue-frame pose that does not exist.
            transition(to: calibration.hasOrigin ? .lost : .calibrating)
        case .interruptionEnded:
            // The map is gone. Nothing is trustworthy until a marker is seen,
            // including anything sighted just before the interruption.
            pendingSightings.removeAll()
            calibration.invalidateOrigin()
            // Already handled, and handled harder: the next marker sets a new
            // origin, and `resolveSuspectOrigin` must not then throw *that* one
            // away the first time a normal pose arrives.
            originIsSuspect = false
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
        noteTrackingBreak(sample.quality)
        // Before `updateStateForQuality`, which would otherwise take a `.lost`
        // session straight back to `.tracking` on the strength of a pose whose
        // frame has moved. `.recalibrating` ignores tracking quality, so the
        // call below is a no-op once this has fired.
        resolveSuspectOrigin()
        updateStateForQuality(sample.quality)
        emitIfDue()
    }

    /// ARKit reporting `.notAvailable`, or relocalizing, means it is no longer
    /// certain where it is in its own map — and when it recovers it recovers by
    /// re-matching that map, which moves every pose in one step. The origin was
    /// measured against the old map, so it does not survive the break.
    ///
    /// Not `.initializing` (there is no origin to lose yet) and not
    /// `excessiveMotion`/`insufficientFeatures`: those degrade a map ARKit is
    /// still holding on to, and poses stay continuous across them.
    private func noteTrackingBreak(_ quality: TrackingQuality) {
        switch quality {
        case .notAvailable, .limited(.relocalizing):
            originIsSuspect = true
        case .normal, .limited:
            break
        }
    }

    /// Tracking is back after a break. Throw the origin away and ask for a
    /// marker, rather than projecting through a mapping that now points
    /// somewhere else: the symptom was a phone that said "tracking lost", went
    /// quiet, and then drew itself and the marker several metres from where they
    /// are — confidently, with nothing on screen admitting calibration was off.
    private func resolveSuspectOrigin() {
        guard originIsSuspect, quality == .normal else { return }
        originIsSuspect = false
        guard calibration.hasOrigin else { return }
        pendingSightings.removeAll()
        calibration.invalidateOrigin()
        recentFrames.removeAll(keepingCapacity: true)
        diagnostics.originsDroppedForTrackingBreak += 1
        transition(to: .recalibrating)
    }

    private func flushPendingSightings() async {
        guard !pendingSightings.isEmpty else { return }
        let batch = pendingSightings
        pendingSightings.removeAll(keepingCapacity: true)
        await apply(sightings: batch)
    }

    private func apply(sightings: [MarkerSighting]) async {
        guard let latest = sightings.map(\.deviceTimestamp).max() else { return }
        advance(to: latest)
        guard let outcome = calibration.evaluate(sightings) else { return }
        if sightings.count > 1 { diagnostics.averagedSightings += 1 }
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
            // own tracking, we now know where we are. That includes clearing a
            // suspected origin — this one was measured against the map ARKit is
            // holding *now*, so a later recovery must not throw it away.
            confidence = configuration.confidenceAfterCorrection
            originIsSuspect = false
            motionWhileLost = 0
            continuation?.yield(.correctionApplied(markerID: correction.markerID,
                                                   positionError: correction.measuredPositionError,
                                                   rotationDegrees: correction.measuredRotationDegrees))
            if state == .calibrating || state == .recalibrating || state == .lost {
                transition(to: quality.isUsable ? .tracking : .degraded)
            }
        case .rejected(let rejection):
            diagnostics.rejectedCorrections += 1
            let markerID = sightings.map(\.markerID).sorted().joined(separator: "+")
            continuation?.yield(.correctionRejected(markerID: markerID,
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
                // Still inside the same unbroken stretch of limited tracking that
                // timed out: going back to `degraded` would restart the timer and
                // flap between the two every `degradedToLostAfter` seconds.
                if let since = degradedSince, now - since >= configuration.degradedToLostAfter {
                    break
                }
                degradedSince = degradedSince ?? now
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
            // ARKit stopping mid-session is the same kind of event as ARKit
            // saying it cannot track: whatever it hands back afterwards is in a
            // map it re-established without us. The origin goes with it.
            originIsSuspect = true
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
        if newState == .tracking { degradedSince = nil }
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
        // Updated before the state guard, so a session waiting for a marker does
        // not leave the pill blaming the clock.
        diagnostics.isBlockedOnClockSync = configuration.requireClockSync && !clock.isSynchronized
        guard let pose = lastPose else { return }
        guard state.hasVenueFramePose, calibration.hasOrigin else {
            emitRawIfDue(pose: pose)
            return
        }
        // The state enum is not the invariant. `.lost` and `.recalibrating` both
        // claim to have a venue-frame pose, but an interruption during
        // calibration reaches `.lost` without any marker ever having been seen,
        // and `.recalibrating` follows an interruption that threw the origin
        // away. Either way the position is in an arbitrary frame, and a server
        // fusing it gets a confident wrong answer.
        guard calibration.hasOrigin else { return }
        guard !diagnostics.isBlockedOnClockSync else { return }

        let poseInterval = 1.0 / max(0.001, configuration.rates.poseHz)
        guard now >= nextPoseDue else {
            emitFrameIfDue { self.makePoseUpdate(pose: pose) }
            return
        }
        // Keep the phase, the way `emitFrameIfDue` does. Samples arrive at
        // 60 Hz, so a deadline measured from `now` is really measured from the
        // first sample *at or after* the deadline, and that quantisation
        // compounds: 100 ms from a sample that was already 16.67 ms late makes
        // the next slot 116.67 ms away, and 10 Hz becomes 8.57 Hz.
        //
        // The `- interval` arm keeps the original protection: when we are a
        // whole interval or more behind — tracking recovered after a long gap —
        // the phase is abandoned and the slot restarts from now, so the phone
        // does not emit a burst of back-dated poses that all describe the same
        // instant.
        nextPoseDue = nextPoseDue < now - poseInterval ? now + poseInterval : nextPoseDue + poseInterval

        let update = makePoseUpdate(pose: pose)
        diagnostics.posesEmitted += 1
        continuation?.yield(.pose(update))

        emitFrameIfDue { update }
        emitDepthIfDue()
    }

    /// Before a marker: the pose is real, the frame is arbitrary.
    private func emitRawIfDue(pose: Pose) {
        guard configuration.emitsBeforeOrigin else { return }
        guard state == .calibrating || state == .recalibrating || state == .lost else { return }
        guard !diagnostics.isBlockedOnClockSync else { return }
        func raw() -> PoseUpdate {
            var update = makePoseUpdate(pose: pose)
            update.inVenueFrame = false
            update.lastCorrectionAge = nil
            update.lastCorrectionMarker = nil
            return update
        }
        var emitted: PoseUpdate?
        if now >= nextPoseDue {
            // Same phase-keeping as the venue-frame path above.
            let poseInterval = 1.0 / max(0.001, configuration.rates.poseHz)
            nextPoseDue = nextPoseDue < now - poseInterval ? now + poseInterval : nextPoseDue + poseInterval
            let update = raw()
            emitted = update
            continuation?.yield(.rawPose(update))
        }
        // Frames, so the hub does not grey the tile while the operator is still
        // looking for a marker. No depth: baselines across frames mean nothing.
        emitFrameIfDue(recordsReference: false) { emitted ?? raw() }
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

    /// `makePose` is only called if a frame is actually due, so checking at
    /// 60 Hz does not burn a pose sequence number per sample.
    private func emitFrameIfDue(recordsReference: Bool = true, _ makePose: () -> PoseUpdate) {
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
        // Keep the phase: adding the interval to the *slot* rather than to now
        // is what stops 60 Hz sample quantisation from turning 8 fps into 7.
        // Unless we are a whole interval behind — then catching up would mean a
        // burst of frames that all show the same instant.
        nextFrameDue = nextFrameDue < now - interval ? now + interval : nextFrameDue + interval

        let pose = makePose()
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
        if recordsReference { recordFrameReference(ticket) }
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
        // The hub has no depth channel. Zero means off, not "infinitely slowly".
        guard configuration.rates.depthHz > 0 else { return }
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
