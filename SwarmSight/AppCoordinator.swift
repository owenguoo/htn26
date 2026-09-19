import Foundation
import Observation
import SwarmCore
import UIKit
import simd

/// Wires the pieces together and owns nothing else.
///
/// Every decision this class could plausibly make already lives in SwarmCore:
/// state transitions in `SessionMachine`, backpressure in `Transport`, the arrow
/// in `OverlayModel`. What is left here is plumbing — which is the point, since
/// none of this file can be tested without a device.
@MainActor
@Observable
public final class AppCoordinator {
    public private(set) var overlay = OverlayState()
    public private(set) var lastError: String?
    public private(set) var isRunning = false

    private var model = OverlayModel()
    private let haptics = HapticPlayer()
    private let encoder = CoreImageFrameEncoder()
    private var pipeline: FrameEncodePipeline?
    private var session: SessionMachine?
    private var transport: Transport?
    private var provider: ARKitPoseProvider?
    private var depthSource: (any DepthSource)?
    private var tasks: [Task<Void, Never>] = []
    private var pingID: UInt64 = 0
    private var clockOffset: Double?

    private let deviceID: String
    private let venue: Venue
    private let orchestrator: URL

    public init(venue: Venue, orchestrator: URL,
                deviceID: String = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString) {
        self.venue = venue
        self.orchestrator = orchestrator
        self.deviceID = deviceID
    }

    /// Loads `venue.json`, preferring a copy dropped into the app's Documents
    /// directory over the one bundled at build time.
    ///
    /// This is what "changing venue must require zero code changes and no
    /// rebuild" actually means in practice: on the day, someone tape-measures
    /// the markers, edits the numbers, and AirDrops the file onto the phones.
    /// `UIFileSharingEnabled` in Info.plist is what makes that possible.
    public static func loadVenue() throws -> Venue {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let override = documents?.appendingPathComponent("venue.json"),
           FileManager.default.fileExists(atPath: override.path) {
            return try Venue.load(from: override)
        }
        guard let url = Bundle.main.url(forResource: "venue", withExtension: "json") else {
            throw CoordinatorError.missingVenueFile
        }
        return try Venue.load(from: url)
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        // ARKit plus streaming for thirty minutes will cook a phone, and a phone
        // that sleeps mid-demo stops being a camera.
        UIApplication.shared.isIdleTimerDisabled = true
        haptics.prepare()

        let provider = ARKitPoseProvider(configuration: .init(venue: venue))
        self.provider = provider
        let encoder = self.encoder
        await provider.setPixelBufferSink { buffer in encoder.stage(buffer) }

        let transport = Transport(
            configuration: .init(url: orchestrator),
            factory: URLSessionWebSocketChannelFactory())
        self.transport = transport
        await transport.setHello(makeHello(hasLiDAR: provider.providesSceneDepth))
        let inbound = await transport.inbound()
        await transport.start()

        // The one place device class is branched on.
        let lidar = LiDARDepthSource(frames: provider)
        depthSource = lidar.isAvailable ? lidar : makeServerDepthSource()

        let pipeline = FrameEncodePipeline(encoder: encoder)
        self.pipeline = pipeline

        let session = SessionMachine(configuration: .init(deviceID: deviceID),
                                     venue: venue, provider: provider)
        self.session = session
        let events = await session.start()

        tasks.append(Task { [weak self] in await self?.consume(sessionEvents: events) })
        tasks.append(Task { [weak self] in await self?.consume(inbound: inbound) })
        tasks.append(Task { [weak self] in await self?.runClockSync() })
        tasks.append(Task { [weak self] in await self?.runOverlayTicker() })
        tasks.append(Task { [weak self] in await self?.watchThermalState() })

        do {
            try await session.permissionsGranted()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await session?.stop()
        await transport?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        isRunning = false
    }

    // MARK: - Wiring

    private func makeHello(hasLiDAR: Bool) -> Hello {
        Hello(deviceID: deviceID,
              deviceName: UIDevice.current.name,
              deviceModel: UIDevice.current.model,
              appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
              venueID: venue.id,
              hasLiDAR: hasLiDAR,
              capabilities: hasLiDAR ? ["lidar", "haptics"] : ["haptics"])
    }

    /// Server depth comes back scene-normalized. The estimate is fitted against
    /// ARKit's metric baselines before anything treats it as metres.
    private func makeServerDepthSource() -> ServerDepthSource {
        ServerDepthSource { _ in
            // The orchestrator returns depth asynchronously over the socket, so
            // there is nothing to await inline. Chunks are uploaded and the
            // reply is matched by chunk id in `consume(inbound:)`.
            nil
        }
    }

    private func consume(sessionEvents: AsyncStream<SessionEvent>) async {
        guard let transport, let pipeline, let session else { return }
        for await event in sessionEvents {
            switch event {
            case .pose(let update):
                latestPose = update.venuePose
                await transport.send(.pose(update))
            case .captureFrame(let ticket):
                await handle(frameTicket: ticket, transport: transport, pipeline: pipeline)
            case .captureDepthChunk(let ticket):
                await handle(depthTicket: ticket, transport: transport)
            case .stateChanged, .correctionApplied, .correctionRejected:
                break
            case .failed(let reason):
                lastError = reason
            }
        }
        _ = session
    }

    private func handle(frameTicket: FrameTicket, transport: Transport,
                        pipeline: FrameEncodePipeline) async {
        let offset = clockOffset ?? 0
        let clock: @Sendable () -> Double = { CACurrentMediaTime() + offset }
        guard let intrinsics = frameTicket.intrinsics else { return }
        guard let encoded = await pipeline.submit(frameID: frameTicket.frameID,
                                                  captureWidth: intrinsics.imageWidth,
                                                  captureHeight: intrinsics.imageHeight,
                                                  intrinsics: intrinsics,
                                                  now: clock) else {
            // Dropped because an encode was already running. Counted in the
            // pipeline's stats and shown on the status pill; never queued.
            return
        }
        let encodedAt = clock()
        let chunk = FrameAssembly.chunk(deviceID: deviceID, ticket: frameTicket, encoded: encoded,
                                        quality: await pipeline.currentConfiguration().quality,
                                        encodedAt: encodedAt, sentAt: clock())
        await transport.send(.frame(chunk))
    }

    private func handle(depthTicket: DepthTicket, transport: Transport) async {
        let request = DepthRequest(chunkID: depthTicket.chunkID, frames: depthTicket.frames)
        let source = depthSource
        let result = try? await source?.depth(for: request)
        let kind: DepthSourceKind = (source as? LiDARDepthSource) != nil ? .lidar : .server
        let chunk = FrameAssembly.chunk(deviceID: deviceID, ticket: depthTicket, source: kind,
                                        sentAt: serverNow, depth: result)
        await transport.send(.depth(chunk))
    }

    private func consume(inbound: AsyncStream<WireMessage>) async {
        for await message in inbound {
            switch message {
            case .command(let command):
                model.apply(command, now: serverNow)
                if case .setRates(let poseHz, let frameFPS, let depthHz) = command.kind {
                    await session?.setRates(.init(poseHz: poseHz ?? 10,
                                                  frameFPS: frameFPS ?? 1.5,
                                                  depthHz: depthHz ?? 0.3))
                }
                if let haptic = model.consumeHaptic() {
                    haptics.play(haptic)
                }
                overlay = model.state
            case .pong(let pong):
                await session?.ingest(pong: pong, receivedAt: CACurrentMediaTime())
            default:
                break
            }
        }
    }

    private func runClockSync() async {
        guard let transport else { return }
        while !Task.isCancelled {
            pingID += 1
            await transport.send(.ping(Ping(id: pingID, t0: CACurrentMediaTime())))
            // Fast at first so the phone starts reporting quickly, then slow, so
            // clock sync is not itself a source of traffic for thirty minutes.
            let interval: UInt64 = pingID < 10 ? 250_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    /// The overlay redraws on its own clock, not only when a command arrives: a
    /// tracked arrow has to follow the camera as the operator turns.
    private func runOverlayTicker() async {
        while !Task.isCancelled {
            if let session, let transport {
                await session.tick(deviceTime: CACurrentMediaTime())
                let diagnostics = await session.currentDiagnostics()
                let stats = await transport.currentStats()
                let state = await transport.currentState()
                clockOffset = await session.clockOffset()
                latestPose = await session.latestVenuePose()
                model.update(pose: latestPose, diagnostics: diagnostics, transport: stats,
                             transportState: state, now: serverNow)
                overlay = model.state
            }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func watchThermalState() async {
        while !Task.isCancelled {
            let thermal: ThermalState = switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .fair
            }
            await session?.setThermalState(thermal)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private var latestPose: Pose?

    private var serverNow: Double {
        CACurrentMediaTime() + (clockOffset ?? 0)
    }

    public enum CoordinatorError: Error, LocalizedError {
        case missingVenueFile

        public var errorDescription: String? {
            switch self {
            case .missingVenueFile:
                "venue.json is not in the bundle. It is loaded at runtime, never compiled in."
            }
        }
    }
}
