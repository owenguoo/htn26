import Foundation
import simd

/// What the native operator view draws each tick.
public struct OverlayFrame: Sendable, Equatable {
    public var overlay: OverlayState
    /// Where the venue believes each marker is, in captured-image pixels. Empty
    /// until a marker has established the venue frame.
    public var markerProjections: [Projection.MarkerProjection]
    public var captureWidth: Int
    public var captureHeight: Int
    /// The HUD, exactly as it is sent to the operator console. The phone draws
    /// its own screen from this same value, so what the operator holding the
    /// phone sees and what the console overlays on the feed cannot drift apart.
    public var hud: HubHUDMirror

    public init(overlay: OverlayState = OverlayState(), markerProjections: [Projection.MarkerProjection] = [],
                captureWidth: Int = 1_920, captureHeight: Int = 1_440, hud: HubHUDMirror? = nil) {
        self.hud = hud ?? HUDMirror.make(from: overlay, captureWidth: captureWidth,
                                         captureHeight: captureHeight, screenAspect: 393.0 / 852.0)
        self.overlay = overlay
        self.markerProjections = markerProjections
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
    }
}

/// A one-shot: play this haptic, play this sound. Delivered on their own stream
/// so a dropped overlay frame can never swallow one.
public enum OverlayCue: Sendable, Equatable {
    case haptic(HapticCue)
    case sound(SoundCue)
}

/// The low-rate summary the JS side polls. Everything in it is plain data.
public struct ClientSnapshot: Sendable, Equatable {
    public var connection: StatusPill.ConnectionState = .offline
    public var sessionState: SessionState = .idle
    public var trackingState = "notAvailable"
    public var confidence: Double = 0
    public var alignment: RoomAligner.Source = .none
    public var phoneId = ""
    public var name = ""
    public var index: Int?
    public var colorHex: String?
    public var phase: String?
    public var roomPose: RoomPose?
    public var seat: HubSeat?
    public var frameFPS: Double = 0
    public var framesSent: Int = 0
    public var dropped: Int = 0
    public var reconnects: Int = 0
    public var latencyP50Ms: Double?
    public var thermal: ThermalState = .nominal
    public var lastCommand: String?
    public var lastError: String?

    public init() {}
}

/// The whole phone, headless.
///
/// Owns the session machine, the transport, the encode pipeline, the overlay
/// model and the room aligner, and wires them to the htn26 hub protocol. It has
/// no UI and no ARKit: hand it a `MockPoseProvider` and a
/// `SyntheticFrameEncoder` and it is a complete phone on macOS, which is how
/// `swarm-replay` proves the protocol against the real hub before any app
/// exists.
///
/// What it sends, and why:
/// - `slam` at the pose rate whenever the phone is aligned to the room (marker
///   or seat tap). The hub treats it as an external pose, `source == "slam"`.
/// - `orient {calibrated: false}` with pitch only when it is not. No heading:
///   an unaligned heading is relative to wherever ARKit started, and the hub
///   would draw a cone from it.
/// - binary frames, always — the hub greys a tile after 3 s without one.
/// - one consolidated `debug` at 1 Hz. The hub *replaces* `debug` wholesale, so
///   everything (6DoF, tracking, transport, latency, last command) is in each.
/// - `pong` for every hub `ping`, stamped with this phone's epoch clock.
public actor SwarmClient {
    public struct Configuration: Sendable {
        /// The socket, e.g. `ws://10.0.0.5:8000/ws/phone`. See `HubURL.derive`.
        public var socketURL: URL
        public var phoneId: String
        public var name: String
        public var build: String
        public var venue: Venue
        public var rates: SessionMachine.Rates
        public var encoding: FrameEncodingConfiguration
        /// Replay only: pose timestamps come from a recording, not from this
        /// machine's uptime, so the device clock is anchored to the first one.
        public var anchorsClockToPoses: Bool

        public init(socketURL: URL, phoneId: String, name: String, build: String = "swarmsight-ios",
                    venue: Venue,
                    rates: SessionMachine.Rates = .init(poseHz: 10, frameFPS: 2, depthHz: 0),
                    encoding: FrameEncodingConfiguration = .standard,
                    anchorsClockToPoses: Bool = false) {
            self.socketURL = socketURL
            self.phoneId = phoneId
            self.name = name
            self.build = build
            self.venue = venue
            self.rates = rates
            self.encoding = encoding
            self.anchorsClockToPoses = anchorsClockToPoses
        }
    }

    public struct Dependencies: Sendable {
        public var provider: any PoseProvider
        public var encoder: any FrameEncoding
        public var channels: any WebSocketChannelFactory
        public var sleeper: any Sleeper
        /// Seconds, monotonic, in the same domain as `PoseSample.deviceTimestamp`
        /// — `CACurrentMediaTime()` on a phone, which is system uptime.
        public var uptime: @Sendable () -> Double
        public var epochMs: @Sendable () -> Double
        public var thermal: @Sendable () -> ThermalState

        public init(provider: any PoseProvider, encoder: any FrameEncoding,
                    channels: any WebSocketChannelFactory = URLSessionWebSocketChannelFactory(),
                    sleeper: any Sleeper = TaskSleeper(),
                    uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                    epochMs: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                    thermal: @escaping @Sendable () -> ThermalState = { .nominal }) {
            self.provider = provider
            self.encoder = encoder
            self.channels = channels
            self.sleeper = sleeper
            self.uptime = uptime
            self.epochMs = epochMs
            self.thermal = thermal
        }
    }

    private let configuration: Configuration
    private let dependencies: Dependencies
    private let session: SessionMachine
    private let transport: Transport
    private let pipeline: FrameEncodePipeline

    private var model = OverlayModel()
    private var aligner: RoomAligner
    private var latency = LatencyStatistics()
    private var name: String
    private var tasks: [Task<Void, Never>] = []
    private var isRunning = false

    /// `uptime − poseTimestamp`, when anchoring. Zero on a real phone.
    private var clockAnchor: Double?
    private var latestPose: Pose?
    private var latestPoseInVenueFrame = false
    private var latestUpdate: PoseUpdate?
    private var latestIntrinsics: CameraIntrinsics?
    private var lastCommand: (name: String, at: Double)?
    private var lastError: String?
    private var framesSent = 0
    private var frameSendTimes: [Double] = []
    /// Set by the hub's `hud` command while a console has this phone expanded.
    private var hudRequested = false
    /// Display width ÷ height, so the mirror can say which part of the frame
    /// the operator actually sees. An iPhone's, until the view reports its own.
    private var screenAspect = 393.0 / 852.0
    private var latestFrame = OverlayFrame()

    private var frameContinuation: AsyncStream<OverlayFrame>.Continuation?
    private var cueContinuation: AsyncStream<OverlayCue>.Continuation?
    private var welcomeContinuation: AsyncStream<HubWelcome>.Continuation?

    public init(configuration: Configuration, dependencies: Dependencies) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.name = configuration.name
        self.aligner = RoomAligner(venueAlignment: configuration.venue.room ?? .identity)
        self.session = SessionMachine(
            configuration: .init(deviceID: configuration.phoneId, rates: configuration.rates,
                                 requireClockSync: false, emitsBeforeOrigin: true),
            venue: configuration.venue, provider: dependencies.provider)
        self.transport = Transport(configuration: .init(url: configuration.socketURL),
                                   factory: dependencies.channels, sleeper: dependencies.sleeper)
        self.pipeline = FrameEncodePipeline(encoder: dependencies.encoder,
                                            configuration: configuration.encoding)
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        await transport.setHello { [weak self] in
            await self?.makeHello() ?? HubHello(phoneId: "", name: "")
        }
        let inbound = await transport.inbound()
        await transport.start()
        let events = await session.start()

        tasks.append(Task { [weak self] in await self?.consume(events) })
        tasks.append(Task { [weak self] in await self?.consume(inbound) })
        tasks.append(Task { [weak self] in await self?.runTicker() })
        tasks.append(Task { [weak self] in await self?.runDebug() })
        tasks.append(Task { [weak self] in await self?.runHUDMirror() })
        tasks.append(Task { [weak self] in await self?.watchThermal() })

        do {
            try await session.permissionsGranted()
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await session.stop()
        await transport.stop()
        frameContinuation?.finish()
        cueContinuation?.finish()
        welcomeContinuation?.finish()
        frameContinuation = nil
        cueContinuation = nil
        welcomeContinuation = nil
    }

    // MARK: - Operator inputs

    public func setName(_ newName: String) async {
        name = String(newName.prefix(24))
        await transport.send(.name(name))
    }

    /// Where the operator tapped on the floor plan, room metres.
    public func setSeat(x: Double, y: Double) async {
        let seat = HubSeat(x: x, y: y)
        aligner.setSeat(seat)
        await transport.send(.seat(seat))
    }

    /// The operator's "this is wrong, start again" for a marker lock that has
    /// gone bad: forgets the origin so the next marker re-establishes it.
    public func resetOrigin() async {
        aligner.invalidate()
        await session.resetOrigin()
    }

    /// The operator view reports its size so the HUD mirror can tell the console
    /// which part of the frame the screen shows.
    public func setScreenSize(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        screenAspect = width / height
    }

    /// "I am standing on my spot, facing the stage." Returns false if there is
    /// no seat, no pose yet, the phone is pointed at the floor, or a marker
    /// already owns the alignment.
    @discardableResult
    public func calibrateFacingStage() -> Bool {
        guard let pose = latestPose, !latestPoseInVenueFrame else { return false }
        return aligner.calibrateFacingStage(rawPose: pose)
    }

    // MARK: - Outputs

    /// Latest-wins: a view that falls behind skips frames rather than lagging.
    public func overlayFrames() -> AsyncStream<OverlayFrame> {
        let (stream, continuation) = AsyncStream<OverlayFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frameContinuation?.finish()
        frameContinuation = continuation
        return stream
    }

    public func cues() -> AsyncStream<OverlayCue> {
        let (stream, continuation) = AsyncStream<OverlayCue>.makeStream(bufferingPolicy: .bufferingNewest(16))
        cueContinuation?.finish()
        cueContinuation = continuation
        return stream
    }

    public func welcomes() -> AsyncStream<HubWelcome> {
        let (stream, continuation) = AsyncStream<HubWelcome>.makeStream(bufferingPolicy: .bufferingNewest(4))
        welcomeContinuation?.finish()
        welcomeContinuation = continuation
        return stream
    }

    public func snapshot() async -> ClientSnapshot {
        let diagnostics = await session.currentDiagnostics()
        let stats = await transport.currentStats()
        var snapshot = ClientSnapshot()
        snapshot.connection = StatusPill.ConnectionState(await transport.currentState())
        snapshot.sessionState = diagnostics.state
        snapshot.trackingState = diagnostics.quality.wireValue
        snapshot.confidence = diagnostics.confidence
        snapshot.alignment = aligner.source
        snapshot.phoneId = configuration.phoneId
        snapshot.name = name
        snapshot.index = model.state.index
        snapshot.colorHex = model.state.colorHex
        snapshot.phase = model.state.phase
        snapshot.roomPose = model.state.roomPose
        snapshot.seat = aligner.seat
        snapshot.frameFPS = measuredFPS(at: dependencies.uptime())
        snapshot.framesSent = framesSent
        snapshot.dropped = stats.dropped
        snapshot.reconnects = stats.reconnects
        snapshot.latencyP50Ms = latency.median.map { $0 * 1000 }
        snapshot.thermal = diagnostics.thermalState
        snapshot.lastCommand = lastCommand?.name
        snapshot.lastError = lastError
        return snapshot
    }

    // MARK: - Clock

    /// Now, in the pose timestamps' own domain.
    private func deviceNow() -> Double? {
        guard configuration.anchorsClockToPoses else { return dependencies.uptime() }
        return clockAnchor.map { dependencies.uptime() - $0 }
    }

    /// Re-anchored on every pose, not just the first. A replay paces itself with
    /// sleeps, and sleeps only ever overshoot, so a recording played for minutes
    /// falls steadily behind the wall clock. Anchored once, that lag eventually
    /// passes the 5 s staleness limit and a perfectly healthy replay reads LOST.
    private func anchorClock(to poseTimestamp: Double) {
        guard configuration.anchorsClockToPoses else { return }
        clockAnchor = dependencies.uptime() - poseTimestamp
    }

    /// Epoch milliseconds for a moment on the device clock.
    private func epochMs(forDeviceTime time: Double) -> Double {
        let age = max(0, (deviceNow() ?? time) - time)
        return dependencies.epochMs() - age * 1000
    }

    // MARK: - Session events

    private func makeHello() -> HubHello {
        HubHello(phoneId: configuration.phoneId, name: name, seat: aligner.seat,
                 build: configuration.build)
    }

    private func consume(_ events: AsyncStream<SessionEvent>) async {
        for await event in events {
            switch event {
            case .pose(let update):
                anchorClock(to: update.deviceTimestamp)
                // A venue-frame pose exists only once a marker has set the origin.
                if aligner.source != .marker { aligner.markerAcquired() }
                remember(update)
                await sendPose(update)
            case .rawPose(let update):
                anchorClock(to: update.deviceTimestamp)
                // Back to an arbitrary frame: the origin was invalidated.
                if aligner.source == .marker { aligner.invalidate() }
                remember(update)
                await sendPose(update)
            case .captureFrame(let ticket):
                latestIntrinsics = ticket.intrinsics ?? latestIntrinsics
                // Off the event loop: an encode must never hold up poses. The
                // pipeline drops if one is already running, so this cannot pile up.
                Task { [weak self] in await self?.handle(ticket) }
            case .correctionApplied:
                aligner.markerAcquired()
            case .stateChanged(_, let to):
                if to == .recalibrating { aligner.invalidate() }
            case .captureDepthChunk, .correctionRejected:
                break
            case .failed(let reason):
                lastError = reason
            }
        }
    }

    private func remember(_ update: PoseUpdate) {
        latestUpdate = update
        latestPose = update.venuePose
        latestPoseInVenueFrame = update.inVenueFrame
    }

    /// The alignment that applies to a pose in the given kind of frame, if any.
    private func alignment(forVenueFrame inVenueFrame: Bool) -> RoomAlignment? {
        switch aligner.source {
        case .marker: inVenueFrame ? aligner.alignment : nil
        case .seat: inVenueFrame ? nil : aligner.alignment
        case .none: nil
        }
    }

    private func sendPose(_ update: PoseUpdate) async {
        guard let pose = update.venuePose else { return }
        if let alignment = alignment(forVenueFrame: update.inVenueFrame), !update.stale {
            let room = alignment.project(pose)
            await transport.send(.slam(x: room.x, y: room.y, heading: room.heading, pitch: room.pitch))
        } else {
            // Pitch is gravity-referenced, so it is true in any frame. Heading is not.
            let pitch = RoomAlignment.identity.project(pose).pitch
            await transport.send(.orient(heading: nil, pitch: pitch, calibrated: false,
                                         tCapture: epochMs(forDeviceTime: update.deviceTimestamp)))
        }
    }

    private func handle(_ ticket: FrameTicket) async {
        guard isRunning else { return }
        let clock: @Sendable () -> Double = dependencies.uptime
        guard let encoded = await pipeline.submit(
            frameID: ticket.frameID,
            captureWidth: ticket.intrinsics?.imageWidth ?? 1_920,
            captureHeight: ticket.intrinsics?.imageHeight ?? 1_440,
            intrinsics: ticket.intrinsics, now: clock) else {
            // Dropped because an encode was already running, or it failed.
            // Counted in the pipeline's stats; never queued.
            return
        }
        guard let now = deviceNow() else { return }
        // Latency is measured from the buffer that was actually encoded.
        let capturedAt: Double
        if configuration.anchorsClockToPoses {
            capturedAt = encoded.captureTimestamp.map { $0 - (clockAnchor ?? 0) } ?? ticket.deviceTimestamp
        } else {
            capturedAt = encoded.captureTimestamp ?? ticket.deviceTimestamp
        }
        var stamped = ticket
        stamped.trace = LatencyTrace(frameID: ticket.frameID)
        stamped.trace.stamp(.capture, at: min(capturedAt, now))

        let room = ticket.pose.venuePose.flatMap { pose in
            alignment(forVenueFrame: ticket.pose.inVenueFrame)?.project(pose)
        }
        let (message, trace) = FrameAssembly.frame(
            ticket: stamped, encoded: encoded, room: room, calibrated: aligner.source != .none,
            tCaptureMs: epochMs(forDeviceTime: capturedAt), encodedAt: now, sentAt: deviceNow() ?? now)
        latency.record(trace)
        framesSent += 1
        let sentAt = dependencies.uptime()
        frameSendTimes.append(sentAt)
        frameSendTimes.removeAll { sentAt - $0 > 2 }
        await transport.send(message)
    }

    private func measuredFPS(at now: Double) -> Double {
        Double(frameSendTimes.filter { now - $0 <= 2 }.count) / 2
    }

    // MARK: - Hub messages

    private func consume(_ inbound: AsyncStream<HubInbound>) async {
        for await message in inbound {
            let now = dependencies.uptime()
            switch message {
            case .ping(let ts):
                await transport.send(.pong(ts: ts, tp: dependencies.epochMs()))
            case .welcome(let welcome):
                // A fresh connection starts un-viewed, as in phone.js; the hub
                // re-sends `hud on` after the welcome if a console is watching.
                hudRequested = false
                model.apply(welcome)
                welcomeContinuation?.yield(welcome)
            case .phase(let phase):
                model.apply(phase: phase)
            case .world(let world):
                model.apply(world, now: now)
            case .command(let command):
                lastCommand = (command.name, now)
                switch command {
                case .rate(let fps):
                    await session.setFrameRate(fps: fps)
                case .hud(let on):
                    hudRequested = on
                default:
                    model.apply(command, heading: model.state.roomPose?.heading, now: now)
                    flushCues()
                }
            case .unknown:
                break
            }
        }
    }

    private func flushCues() {
        if let haptic = model.consumeHaptic() { cueContinuation?.yield(.haptic(haptic)) }
        if let sound = model.consumeSound() { cueContinuation?.yield(.sound(sound)) }
    }

    // MARK: - Periodic work

    /// The overlay redraws on its own clock, not only when a command arrives:
    /// the arrow has to follow the camera as the operator turns.
    private func runTicker() async {
        while !Task.isCancelled {
            if let now = deviceNow() { await session.tick(deviceTime: now) }
            let diagnostics = await session.currentDiagnostics()
            let stats = await transport.currentStats()
            let state = await transport.currentState()
            if let latest = await session.latestPose() {
                latestPose = latest.pose
                latestPoseInVenueFrame = latest.inVenueFrame
                latestIntrinsics = latest.intrinsics ?? latestIntrinsics
            }
            model.update(pose: latestPose, alignment: alignment(forVenueFrame: latestPoseInVenueFrame),
                         source: aligner.source, intrinsics: latestIntrinsics, diagnostics: diagnostics,
                         transport: stats, transportState: state, now: dependencies.uptime())
            flushCues()

            var projections: [Projection.MarkerProjection] = []
            if latestPoseInVenueFrame, let pose = latestPose, let intrinsics = latestIntrinsics {
                projections = Projection.visibleMarkers(in: configuration.venue, camera: pose,
                                                        intrinsics: intrinsics)
            }
            let width = latestIntrinsics?.imageWidth ?? 1_920, height = latestIntrinsics?.imageHeight ?? 1_440
            latestFrame = OverlayFrame(overlay: model.state, markerProjections: projections,
                                       captureWidth: width, captureHeight: height,
                                       hud: HUDMirror.make(from: model.state, captureWidth: width,
                                                           captureHeight: height, screenAspect: screenAspect))
            frameContinuation?.yield(latestFrame)
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    /// 5 Hz, only while a console is watching — the same cadence as phone.js.
    private func runHUDMirror() async {
        while !Task.isCancelled {
            if hudRequested {
                // The very value the phone's own screen was drawn from this tick.
                await transport.send(.hud(latestFrame.hud))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func runDebug() async {
        while !Task.isCancelled {
            await transport.send(.debug(await makeDebug()))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func makeDebug() async -> HubDebug {
        let diagnostics = await session.currentDiagnostics()
        let stats = await transport.currentStats()
        let state = StatusPill.ConnectionState(await transport.currentState())
        let now = dependencies.uptime()
        // 6DoF only when it is venue-frame. A raw pose's numbers look identical
        // and mean nothing to anyone but this phone.
        let venue = latestPoseInVenueFrame ? latestUpdate : nil
        return HubDebug(
            session: diagnostics.state.rawValue,
            venuePosition: venue?.position, venueQuaternion: venue?.quaternion,
            trackingState: diagnostics.quality.wireValue, confidence: Float(diagnostics.confidence),
            correctionAgeS: diagnostics.lastCorrectionAge, correctionMarker: diagnostics.lastCorrectionMarker,
            stale: diagnostics.isStale, alignment: aligner.source.rawValue,
            thermal: diagnostics.thermalState.rawValue, frameFPS: measuredFPS(at: now),
            transport: .init(state: state.rawValue, sent: stats.sent, dropped: stats.dropped,
                             reconnects: stats.reconnects),
            latency: .init(p50Ms: latency.median.map { $0 * 1000 }, p95Ms: latency.p95.map { $0 * 1000 },
                           overBudget: latency.violationCount),
            lastCommand: lastCommand.map { .init(cmd: $0.name, ageMs: Int((now - $0.at) * 1000)) })
    }

    private func watchThermal() async {
        while !Task.isCancelled {
            await session.setThermalState(dependencies.thermal())
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
