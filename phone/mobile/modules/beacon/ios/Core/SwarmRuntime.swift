import Foundation
import QuartzCore
import SwarmCore
import UIKit

/// How a session gets its poses and pictures.
public enum PoseSourceKind: String, Sendable {
    /// The real thing. Does not exist in the Simulator.
    case arkit
    /// A recorded walk and a synthetic JPEG: the whole client, minus ARKit and
    /// the camera. This is what the hub e2e runs, and what `replay=1` selects.
    case replay
    /// Drag to look, hold a stick to walk. **Simulator only** — see
    /// `isAvailableOnThisPlatform`. The Simulator's default, because a HUD you
    /// cannot turn is a HUD you cannot judge.
    case drive

    /// `.drive` exists to make the Simulator judgeable and has no meaning on a
    /// phone that has ARKit. Gating here as well as at the `switch` in `join` is
    /// deliberate belt and braces: a `RuntimeOptions` written by a
    /// `configure({poseSource:'drive'})` call would otherwise survive in
    /// `UserDefaults`-shaped state onto hardware and quietly replace the camera
    /// with a joystick.
    var isAvailableOnThisPlatform: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        self != .drive
        #endif
    }
}

public struct RuntimeOptions: Sendable {
    public var poseSource: PoseSourceKind
    public var fixture: String
    public var replayRate: Double
    /// Replay only: strip marker sightings, to exercise the seat-tap fallback.
    public var replayMarkers: Bool

    public init(poseSource: PoseSourceKind = .arkit, fixture: String = "trajectory-walk-2min",
                replayRate: Double = 1, replayMarkers: Bool = true) {
        self.poseSource = poseSource
        self.fixture = fixture
        self.replayRate = replayRate
        self.replayMarkers = replayMarkers
    }

    /// ARKit where it exists, drive where it does not.
    ///
    /// The Simulator default moved from `.replay` to `.drive`: a recorded walk
    /// shows the HUD doing something, but only a HUD you can turn tells you
    /// whether the compass turns the right way. Nothing automated depends on
    /// this default — `e2e-hub.sh` drives the `swarm-replay` CLI on macOS, and
    /// `join.tsx` / `RootView.swift` still ask for `.replay` *explicitly* when
    /// they see `replay=1`.
    public static var platformDefault: RuntimeOptions {
        #if targetEnvironment(simulator)
        RuntimeOptions(poseSource: .drive)
        #else
        RuntimeOptions(poseSource: .arkit)
        #endif
    }
}

/// One joined session: the client plus the two things only the app side can
/// supply — the camera preview and the pixel-buffer plumbing.
public struct RuntimeSession: Sendable {
    public let client: SwarmClient
    public let preview: CameraPreviewSource?
    public let venue: Venue
    public let socketURL: URL
    /// Non-nil only on the `.drive` path, which is Simulator-only. The handle
    /// the gesture layer pushes `DriveInput` into and the view model pushes the
    /// hub's room dimensions into — `PoseProvider` was deliberately not widened
    /// to carry either, so this is how they reach the provider.
    public let drive: DrivePoseProvider?
    /// Live ARKit sessions only. Strongly retained here because
    /// `MicrophoneCapture`'s process registry holds it weakly — without this,
    /// the tap would deallocate as soon as `start` returned.
    public let microphone: MicrophoneCapture?

    public init(client: SwarmClient, preview: CameraPreviewSource?, venue: Venue,
                socketURL: URL, drive: DrivePoseProvider? = nil,
                microphone: MicrophoneCapture? = nil) {
        self.client = client
        self.preview = preview
        self.venue = venue
        self.socketURL = socketURL
        self.drive = drive
        self.microphone = microphone
    }
}

/// Builds and holds the running `SwarmClient`.
///
/// Sendable and lock-guarded so both the Expo module's `AsyncFunction` bodies
/// (arbitrary executors) and the main-actor view model can reach the same
/// session without either owning it.
public final class SwarmRuntime: @unchecked Sendable {
    public static let shared = SwarmRuntime()

    private let lock = NSLock()
    private var current: RuntimeSession?
    private var options = RuntimeOptions.platformDefault
    private var listeners: [UUID: @Sendable (RuntimeSession?) -> Void] = [:]

    public init() {}

    public var session: RuntimeSession? {
        lock.withLock { current }
    }

    /// Rejects a pose source this platform has no business running.
    ///
    /// Today that is exactly `.drive` off-simulator, which falls back to
    /// `.arkit` rather than throwing: `configure` is a fire-and-forget
    /// `Function` on the JS side, and a stale stored option is not a reason to
    /// leave an operator unable to join.
    public func configure(_ newOptions: RuntimeOptions) {
        var sanitised = newOptions
        if !sanitised.poseSource.isAvailableOnThisPlatform { sanitised.poseSource = .arkit }
        lock.withLock { options = sanitised }
    }

    public var currentOptions: RuntimeOptions {
        lock.withLock { options }
    }

    /// Called with the session whenever one starts or ends — how a view that was
    /// mounted before `join` finds out there is now something to draw.
    @discardableResult
    public func observe(_ listener: @escaping @Sendable (RuntimeSession?) -> Void) -> UUID {
        let id = UUID()
        let existing = lock.withLock { () -> RuntimeSession? in
            listeners[id] = listener
            return current
        }
        listener(existing)
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.withLock { _ = listeners.removeValue(forKey: id) }
    }

    private func publish(_ session: RuntimeSession?) {
        let targets = lock.withLock { () -> [@Sendable (RuntimeSession?) -> Void] in
            current = session
            return Array(listeners.values)
        }
        for target in targets { target(session) }
    }

    // MARK: - Join / leave

    public func join(hub scanned: String, name: String) async throws {
        guard let socketURL = HubURL.derive(scanned) else { throw RuntimeError.badHubURL(scanned) }
        await leave()

        let venue = try ModuleResources.loadVenue()
        let options = currentOptions
        let uptime: @Sendable () -> Double = { CACurrentMediaTime() }
        let thermal: @Sendable () -> ThermalState = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .fair
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        // Belt to `configure`'s braces. A source that cannot run here falls
        // through to ARKit rather than failing the join — the operator standing
        // in the room wanted a camera, not an error.
        let source = options.poseSource.isAvailableOnThisPlatform ? options.poseSource : .arkit
        var configuration = SwarmClient.Configuration(
            socketURL: socketURL, phoneId: PhoneIdentity.phoneId,
            name: source == .drive && name.isEmpty ? "sim" : name,
            build: "ios-\(version)", venue: venue)

        let session: RuntimeSession
        switch source {
        case .arkit:
            // Real operators take part in voice-directed search. Replay / drive
            // stay silent so `swarm-replay` and the hub e2e do not open a mic.
            configuration.voiceEnabled = true
            let provider = ARKitPoseProvider(configuration: .init(
                venue: venue, referenceImageGroup: nil, wantsSceneDepth: false,
                markerBundle: ModuleResources.bundle))
            let encoder = CoreImageFrameEncoder()
            let preview = await CameraPreviewSource()
            await provider.setPixelBufferSink { buffer in
                // The preview only reads; the encoder takes ownership. Sequential,
                // never concurrent, which is the invariant PixelBufferHandoff names.
                preview.offer(buffer, now: CACurrentMediaTime())
                encoder.stage(buffer)
            }
            let client = SwarmClient(configuration: configuration,
                                     dependencies: .init(provider: provider, encoder: encoder,
                                                         uptime: uptime, thermal: thermal))
            let microphone = await MainActor.run { MicrophoneCapture(client: client) }
            session = RuntimeSession(client: client, preview: preview, venue: venue,
                                     socketURL: socketURL, microphone: microphone)
        case .replay:
            guard let url = ModuleResources.fixtureURL(named: options.fixture) else {
                throw ModuleResources.ResourceError.missingFixture(options.fixture)
            }
            var trajectory = try JSONDecoder().decode(Trajectory.self, from: Data(contentsOf: url))
            if !options.replayMarkers { trajectory.markerEvents = [] }
            let provider = MockPoseProvider(
                trajectory: trajectory,
                configuration: .init(playbackRate: options.replayRate, loops: 10_000))
            configuration.anchorsClockToPoses = true
            configuration.build += "-replay"
            let client = SwarmClient(configuration: configuration,
                                     dependencies: .init(provider: provider,
                                                         encoder: SyntheticFrameEncoder(now: uptime),
                                                         uptime: uptime, thermal: thermal))
            session = RuntimeSession(client: client, preview: nil, venue: venue, socketURL: socketURL)
        case .drive:
            #if targetEnvironment(simulator)
            let provider = DrivePoseProvider(
                venue: venue,
                configuration: .init(emitsMarkers: options.replayMarkers),
                // The same clock `SwarmClient` gets, which is precisely why
                // `anchorsClockToPoses` stays false here: unlike a fixture,
                // whose timestamps are somebody else's uptime, these poses are
                // already stamped in this process's `CACurrentMediaTime`.
                now: uptime)
            configuration.build += "-drive"
            let client = SwarmClient(configuration: configuration,
                                     dependencies: .init(provider: provider,
                                                         encoder: SyntheticFrameEncoder(now: uptime),
                                                         uptime: uptime, thermal: thermal))
            // `preview: nil` is what puts `DriveBackdropView` on screen — the
            // same branch `ReplayBackdrop` used to take.
            session = RuntimeSession(client: client, preview: nil, venue: venue,
                                     socketURL: socketURL, drive: provider)
            #else
            // Unreachable: `source` was rewritten to `.arkit` above. The
            // compiler still wants a value out of this arm, and a throw is more
            // honest than a silently different session.
            throw RuntimeError.unavailablePoseSource(source.rawValue)
            #endif
        }

        PhoneIdentity.name = configuration.name
        PhoneIdentity.lastHubURL = scanned
        publish(session)
        await MainActor.run {
            // ARKit plus streaming for thirty minutes will cook a phone, and a
            // phone that sleeps mid-demo stops being a camera.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        do {
            try await session.client.start()
            // After the socket is up: a declined / missing mic is soft — frames
            // and commands keep working; Settings shows "no microphone".
            if let microphone = session.microphone {
                await microphone.start()
            }
        } catch {
            await leave()
            throw error
        }
    }

    public func leave() async {
        guard let session else { return }
        // Tear the tap down while we still hold the strong ref; the registry
        // alone is weak and would not keep it alive across `publish(nil)`.
        if let microphone = session.microphone {
            await MainActor.run { microphone.stop() }
        }
        publish(nil)
        await session.client.stop()
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
    }

    public enum RuntimeError: Error, LocalizedError {
        case badHubURL(String)
        case notJoined
        case unavailablePoseSource(String)

        public var errorDescription: String? {
            switch self {
            case .badHubURL(let text): "“\(text)” is not a hub address. Scan the QR on the dashboard."
            case .notJoined: "Not joined to a hub."
            case .unavailablePoseSource(let kind): "The “\(kind)” pose source does not run on this device."
            }
        }
    }
}
