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

    /// **Voice is off by default.** Not because the feature is unwanted, but
    /// because the device bring-up trap lives in the audio path and a camera
    /// that works beats a microphone that halts the process.
    ///
    /// The evidence, in order: `microphone.start` blocked the main thread for
    /// 3.9 s (fixed — `.allowBluetooth` forcing HFP negotiation, plus five
    /// preferred-route mutations on the session ARKit's camera shares); ARKit's
    /// tracking dropped to `notAvailable` the instant it returned; and CoreAudio
    /// then tripped `_dispatch_assert_queue_fail` on its own `RootQueue`, after
    /// `engine.start` returned but before the tap delivered a single buffer,
    /// with no frame of ours anywhere on the stack.
    ///
    /// `MicrophoneCapture` is untouched and still wired up — this gates only
    /// whether `join` starts it. Turn it back on for a run with `-BeaconVoice
    /// YES` in the scheme's launch arguments, or flip the default here once the
    /// audio path is fixed. The two things to fix first: `MicrophoneCapture` is
    /// `@MainActor`, and `ARSessionHost` leaves `delegateQueue` nil, so every
    /// `AVAudioSession` call it makes contends with ARKit's 60 Hz delegate on
    /// the one thread.
    static var isVoiceEnabled: Bool {
        // `object(forKey:) as? Bool` is wrong here: the argument domain parses
        // `-BeaconVoice YES` into the *string* "YES" and the cast fails.
        // `bool(forKey:)` applies `NSString.boolValue`, so YES/1/true all read
        // as true.
        UserDefaults.standard.bool(forKey: "BeaconVoice")
    }

    // MARK: - Join / leave

    public func join(hub scanned: String, name: String) async throws {
        BeaconLog.log("join(\(scanned))")
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
        var arkitProvider: ARKitPoseProvider?
        switch source {
        case .arkit:
            // Real operators take part in voice-directed search. Replay / drive
            // stay silent so `swarm-replay` and the hub e2e do not open a mic.
            configuration.voiceEnabled = true
            BeaconLog.log("building ARKit session")
            let provider = ARKitPoseProvider(configuration: .init(
                venue: venue, referenceImageGroup: nil,
                markerBundle: ModuleResources.bundle))
            let encoder = await MainActor.run { CoreImageFrameEncoder() }
            let preview = await CameraPreviewSource()
            // Preview is an `ARSCNView` sharing the session — do not also feed
            // pixel buffers into a CI preview (that path retained capture-pool
            // buffers and froze the camera LED-on / "waiting…" state).
            await provider.setPixelBufferSink { buffer in
                encoder.stage(buffer)
            }
            let client = SwarmClient(configuration: configuration,
                                     dependencies: .init(provider: provider, encoder: encoder,
                                                         uptime: uptime, thermal: thermal))
            let microphone = await MainActor.run { MicrophoneCapture(client: client) }
            arkitProvider = provider
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
        BeaconLog.log("publishing session (source=\(source.rawValue))")
        publish(session)
        await MainActor.run {
            // ARKit plus streaming for thirty minutes will cook a phone, and a
            // phone that sleeps mid-demo stops being a camera.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        do {
            try await BeaconLog.step("client.start") { try await session.client.start() }
            // ARSession is running now — hand its scene view to the operator
            // preview. Until this lands the UI shows "waiting for the camera…".
            if let arkitProvider, let preview = session.preview {
                let view = await BeaconLog.step("provider.previewView") {
                    await arkitProvider.previewView()
                }
                if let view {
                    await BeaconLog.step("preview.attach") { await preview.attach(view) }
                } else {
                    BeaconLog.log("no preview view — camera stays on \"waiting…\"")
                }
            }
            // After the socket is up: a declined / missing mic is soft — frames
            // and commands keep working; Settings shows "no microphone".
            //
            // **Not until the camera is actually delivering.** The device trace
            // showed `microphone.start` completing and ARKit's first frame
            // landing 15 ms apart, with CoreAudio then tripping
            // `_dispatch_assert_queue_fail` on its own `RootQueue` — no frame of
            // ours anywhere on that stack. `MicrophoneCapture.start` takes the
            // process-wide `AVAudioSession` to `.playAndRecord`, then sets a
            // preferred input, data source, polar pattern, orientation and
            // channel count; doing all that while `ARSession` is bringing its
            // capture session up is asking two subsystems to reconfigure the
            // same session at once. Waiting for the first frame costs a beat of
            // voice at join and serialises the two.
            if let microphone = session.microphone, Self.isVoiceEnabled {
                if let arkitProvider {
                    let arrived = await BeaconLog.step("wait for first ARKit frame") {
                        await arkitProvider.waitForFirstFrame(timeout: 5)
                    }
                    // A phone that never gets a frame has a bigger problem than
                    // voice; start the mic anyway rather than silently dropping it.
                    if !arrived { BeaconLog.log("no ARKit frame within 5s — starting mic regardless") }
                }
                await BeaconLog.step("microphone.start") { await microphone.start() }
            } else if session.microphone != nil {
                BeaconLog.log("microphone start skipped — voice off (-BeaconVoice YES to enable)")
            }
            BeaconLog.log("join complete")
        } catch {
            BeaconLog.log("join failed: \(error)")
            await leave()
            throw error
        }
    }

    public func leave() async {
        guard let session else { return }
        BeaconLog.log("leave")
        // Tear the tap down while we still hold the strong ref; the registry
        // alone is weak and would not keep it alive across `publish(nil)`.
        if let microphone = session.microphone {
            await MainActor.run { microphone.stop() }
        }
        if let preview = session.preview {
            await preview.clear()
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
