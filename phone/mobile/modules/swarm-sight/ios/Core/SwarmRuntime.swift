import Foundation
import QuartzCore
import SwarmCore
import UIKit

/// How a session gets its poses and pictures.
public enum PoseSourceKind: String, Sendable {
    /// The real thing. Does not exist in the Simulator.
    case arkit
    /// A recorded walk and a synthetic JPEG: the whole client, minus ARKit and
    /// the camera. This is what runs in the Simulator and in the hub e2e.
    case replay
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

    /// ARKit where it exists, replay where it does not.
    public static var platformDefault: RuntimeOptions {
        #if targetEnvironment(simulator)
        RuntimeOptions(poseSource: .replay)
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

    public func configure(_ newOptions: RuntimeOptions) {
        lock.withLock { options = newOptions }
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
        var configuration = SwarmClient.Configuration(
            socketURL: socketURL, phoneId: PhoneIdentity.phoneId, name: name,
            build: "ios-\(version)", venue: venue)

        let session: RuntimeSession
        switch options.poseSource {
        case .arkit:
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
            session = RuntimeSession(client: client, preview: preview, venue: venue, socketURL: socketURL)
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
        }

        PhoneIdentity.name = name
        PhoneIdentity.lastHubURL = scanned
        publish(session)
        await MainActor.run {
            // ARKit plus streaming for thirty minutes will cook a phone, and a
            // phone that sleeps mid-demo stops being a camera.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        do {
            try await session.client.start()
        } catch {
            await leave()
            throw error
        }
    }

    public func leave() async {
        guard let session else { return }
        publish(nil)
        await session.client.stop()
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
    }

    public enum RuntimeError: Error, LocalizedError {
        case badHubURL(String)
        case notJoined

        public var errorDescription: String? {
            switch self {
            case .badHubURL(let text): "“\(text)” is not a hub address. Scan the QR on the dashboard."
            case .notJoined: "Not joined to a hub."
            }
        }
    }
}
