import Foundation
import simd

/// A `PoseProvider` the operator drives with their thumbs, for the iOS
/// Simulator.
///
/// ARKit does not exist in the Simulator, so the only way to judge the HUD there
/// has been a recorded walk that does whatever it recorded. This lets you drag
/// to look and hold a stick to walk, which is what makes "does the compass turn
/// the right way" a question you can answer by looking.
///
/// **What it claims, and what it does not.** It reports `.normal` tracking,
/// because there is no honest third option: a new `TrackingQuality` case changes
/// `wireValue`, a wire surface the hub owns, and `.limited` would pin the status
/// pill at "Tracking is shaky" forever — destroying the thing you are trying to
/// judge. The disclosure rides in `build` instead, as `"-drive"`, which is the
/// mechanism the replay path already uses and the one the hub and console
/// already read. Nothing here lies to `CalibrationEngine`: the poses genuinely
/// are venue-frame by construction, and the synthetic sighting says exactly
/// that.
///
/// SIM-VERIFY: this file can never run on a device — there is no `DEVICE-VERIFY`
/// for it and it must not join `ArchitectureTests`' `deviceDependent` list. What
/// a human has to check in the Simulator is in `DriveControlsView`: that a drag
/// beginning on the mini-map or the status pill does nothing (SwiftUI will not
/// re-route a touch after a tap gesture claims it), that the joystick puck
/// clears the mini-map and the settings gear, and that the drag sensitivity
/// feels right.
public actor DrivePoseProvider: PoseProvider {
    public struct Configuration: Sendable {
        /// Matches ARKit's delegate rate and the 60 Hz fixtures, so
        /// `SessionMachine`'s 10 Hz pose and 2 fps frame throttles behave
        /// exactly as they do on the other two paths.
        public var emitHz: Double
        /// False is the `markers=0` path: no sighting is emitted, the session
        /// never gets an origin, and the operator locates themselves with a seat
        /// tap. Mirrors `replayMarkers`.
        public var emitsMarkers: Bool
        public var bounds: DriveBounds
        public var start: RoomPose?
        /// How often the synthetic sighting is re-emitted. See
        /// `markerNudgeMetres` — the two exist together.
        public var markerRefreshSeconds: Double
        /// **Why the re-sighting is not exact.** A sighting that agrees
        /// perfectly with the current estimate returns `.noChangeNeeded` and
        /// never refreshes `lastCorrectionTime` (`Calibration.swift`), so
        /// `OperatorStatus` would flip to "Position may be drifting" 30 s in and
        /// stay there — a false alarm on the one screen this whole source exists
        /// to let someone look at. Nudging alternately ±3 cm along venue +X is
        /// above `noChangePositionMeters` (2 cm) and far below `maxStepMeters`
        /// (25 cm), so every sighting is accepted, and the alternating sign
        /// means successive corrections cancel instead of walking the origin.
        public var markerNudgeMetres: Double
        /// Stops after this much simulated time. nil drives until stopped.
        public var maxDuration: Double?

        public init(emitHz: Double = 60, emitsMarkers: Bool = true,
                    bounds: DriveBounds = .roomJSON, start: RoomPose? = nil,
                    markerRefreshSeconds: Double = 5, markerNudgeMetres: Double = 0.03,
                    maxDuration: Double? = nil) {
            self.emitHz = max(1, emitHz)
            self.emitsMarkers = emitsMarkers
            self.bounds = bounds
            self.start = start
            self.markerRefreshSeconds = markerRefreshSeconds
            self.markerNudgeMetres = markerNudgeMetres
            self.maxDuration = maxDuration
        }
    }

    /// The synthetic fixtures' camera, not a measured one. Real enough for
    /// `Projection.visibleMarkers` and the ping overlay to have something sane
    /// to work with.
    public static let intrinsics = CameraIntrinsics(fx: 1_449.5, fy: 1_449.5, cx: 959.5, cy: 719.5,
                                                    imageWidth: 1_920, imageHeight: 1_440)

    private let configuration: Configuration
    private let venue: Venue
    private let alignment: RoomAlignment
    /// Injected so the emit loop is deterministic in tests. `SwarmRuntime` hands
    /// it the same `{ CACurrentMediaTime() }` it gives `SwarmClient`, which is
    /// why `anchorsClockToPoses` stays false here — unlike replay, whose fixture
    /// timestamps are somebody else's uptime.
    private let now: @Sendable () -> Double
    private let sleeper: any Sleeper

    private var model: DriveMotionModel
    /// Drag deltas since the last step: accumulated, then consumed, so a burst
    /// of touch events between two frames is one movement rather than several.
    private var pendingYaw: Double = 0
    private var pendingPitch: Double = 0
    private var pendingLevel = false
    /// The joystick, **latched** rather than consumed. A finger holding the puck
    /// still produces no further gesture events, so a stick that reset every
    /// frame would stop the operator dead the moment they stopped moving their
    /// thumb — which is the opposite of what holding a stick means. The view
    /// clears it by sending `.zero` when the drag ends.
    private var stick: SIMD2<Double> = .zero
    private var continuation: AsyncStream<PoseProviderEvent>.Continuation?
    private var task: Task<Void, Never>?
    private var nudgeSign: Double = 1

    public init(venue: Venue, configuration: Configuration = Configuration(),
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleeper: any Sleeper = TaskSleeper()) {
        self.venue = venue
        self.configuration = configuration
        self.alignment = venue.room ?? .identity
        self.now = now
        self.sleeper = sleeper
        self.model = DriveMotionModel(bounds: configuration.bounds, start: configuration.start)
    }

    // MARK: - Driving

    /// Accumulates one gesture update. Called from the SwiftUI layer.
    public func apply(_ input: DriveInput) {
        pendingYaw += input.yawPoints
        pendingPitch += input.pitchPoints
        pendingLevel = pendingLevel || input.levelPitch
        stick = input.walk
    }

    /// The room dimensions from the hub's `welcome`. Forwarded by the view model
    /// when `OverlayState.room` changes, which is how bounds arrive without
    /// `PoseProvider` growing a room-shaped parameter.
    public func setBounds(_ bounds: DriveBounds) {
        model.setBounds(bounds)
    }

    /// Where the operator currently is, for a test or a debug readout.
    public var roomPose: RoomPose { model.roomPose }

    // MARK: - PoseProvider

    public func start() async throws -> AsyncStream<PoseProviderEvent> {
        let (stream, continuation) = AsyncStream<PoseProviderEvent>
            .makeStream(bufferingPolicy: .bufferingOldest(1))
        self.continuation = continuation
        task = Task { [weak self] in
            await self?.drive()
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

    /// **A deliberate no-op.** This provider's poses are venue-frame by
    /// construction, not a SLAM estimate that can drift, so there is nothing to
    /// correct. Composing the offset the way `MockPoseProvider` does would also
    /// be defensible; the no-op is better here because it keeps the dot exactly
    /// where the operator drove it while the 5 s re-sightings come and go.
    public func setWorldOrigin(relativeTransform: simd_float4x4) async {}

    public func consumeMotionSinceLastQuery() async -> Float {
        Float(model.consumeDistance())
    }

    // MARK: - The loop

    private func drive() async {
        guard let continuation else { return }
        let dt = 1 / configuration.emitHz
        let started = now()
        var lastMarker = -Double.infinity

        while !Task.isCancelled {
            let timestamp = now()
            if let limit = configuration.maxDuration, timestamp - started >= limit { return }

            if configuration.emitsMarkers,
               timestamp - lastMarker >= configuration.markerRefreshSeconds,
               let sighting = markerSighting(at: timestamp, isUpdate: lastMarker > -.infinity) {
                lastMarker = timestamp
                continuation.yield(.marker(sighting))
            }

            model.step(dt: dt, input: DriveInput(yawPoints: pendingYaw, pitchPoints: pendingPitch,
                                                 walk: stick, levelPitch: pendingLevel))
            pendingYaw = 0
            pendingPitch = 0
            pendingLevel = false

            // A drive pose is only meaningful if it can be inverted into a 3D
            // camera. `unproject` returns nil only at a heading the model's ±85°
            // pitch clamp keeps it away from, so this skips rather than traps.
            if let pose = alignment.unproject(model.roomPose, height: Float(model.bounds.eyeHeight)) {
                // Best-effort, unlike `MockPoseProvider`'s retrying `deliver`: a
                // replay must not lose a recorded sample, but a dropped frame
                // here is one 16 ms tick of a live input that is about to send
                // another. Spinning would make the loop lurch.
                continuation.yield(.pose(PoseSample(pose: pose, deviceTimestamp: timestamp,
                                                    quality: .normal, intrinsics: Self.intrinsics)))
            }

            do { try await sleeper.sleep(seconds: dt) } catch { return }
        }
    }

    /// The primary marker, seen exactly where `venue.json` says it is, nudged.
    ///
    /// `Calibration.worldOriginTransform(observed:markerVenue:)` of an unnudged
    /// sighting is the identity, so `CalibrationEngine` records
    /// `.originEstablished` with a measured error of zero and `SessionMachine`
    /// goes `calibrating → tracking`. The nudge on every subsequent one is what
    /// keeps `lastCorrectionAge` fresh — see `Configuration.markerNudgeMetres`.
    private func markerSighting(at timestamp: Double, isUpdate: Bool) -> MarkerSighting? {
        guard let marker = venue.primaryMarker, let pose = marker.pose else { return nil }
        var observed = pose
        if isUpdate {
            observed.position += VenueAxis.x * Float(nudgeSign * configuration.markerNudgeMetres)
            nudgeSign = -nudgeSign
        }
        return MarkerSighting(markerID: marker.id, observedTransform: observed.matrix,
                              deviceTimestamp: timestamp, isUpdate: isUpdate,
                              estimatedPhysicalWidth: marker.physicalWidth)
    }
}
