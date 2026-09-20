import ARKit
import Foundation
import QuartzCore
import SceneKit
import SwarmCore
import simd
import UIKit

/// **The only file in this repo that imports ARKit.**
///
/// It adapts `ARSession` to `PoseProvider` and does nothing else. No filtering,
/// no state machine, no throttling — all of that is in SwarmCore, where it can
/// be tested against a recorded trajectory with no device in the room.
///
/// If something here starts wanting to make a decision, the decision belongs in
/// SwarmCore and this file should be widening `PoseProvider` instead.
///
// DEVICE-VERIFY: nothing in this file has ever executed — ARKit does not run in
// the iOS Simulator. A human must confirm, on hardware: that the local-network,
// camera and motion prompts appear; that a marker takes the session from
// calibrating to tracking; that an ARImageAnchor's +Y really does point out of
// the printed surface (DEVICE_CHECKLIST.md item 3, on which every other
// geometric claim depends); marker detection range and angle under show
// lighting; re-lock time after walking out of view and back; drift over a
// five-minute walk with and without markers; and that backgrounding produces
// lost then recalibrating and sends no poses until a marker is seen again.
// DEVICE_CHECKLIST.md items 1-8.
/// A finished set of `ARReferenceImage`s on its way to the main actor.
///
/// ARKit does not mark `ARReferenceImage` `Sendable`, but each one here is
/// fully constructed — including its `name` — before it is ever shared, and
/// nothing mutates it afterwards. The wrapper states that promise in one place
/// instead of scattering `nonisolated(unsafe)` across the call chain.
struct MarkerImageSet: @unchecked Sendable {
    let images: Set<ARReferenceImage>
}

public actor ARKitPoseProvider: PoseProvider {

    public struct Configuration: Sendable {
        /// The markers to look for, and their true measured widths.
        public var venue: Venue
        /// Name of the `ARReferenceImage` group in the asset catalogue, or nil to
        /// build reference images from `venue.json` at runtime.
        public var referenceImageGroup: String?
        /// How many image anchors ARKit tracks at once.
        public var maximumConcurrentImages: Int
        /// Where `Markers/<id>.png` live. Inside the Expo module that is the
        /// pod's resource bundle, not `Bundle.main`.
        public var markerBundle: Bundle

        public init(venue: Venue, referenceImageGroup: String? = "Markers",
                    maximumConcurrentImages: Int = 4, markerBundle: Bundle = .main) {
            self.markerBundle = markerBundle
            self.venue = venue
            self.referenceImageGroup = referenceImageGroup
            self.maximumConcurrentImages = maximumConcurrentImages
        }
    }

    private let configuration: Configuration
    /// Owns the `ARSession`. Main-actor only so ARKit/CoreMotion never run off
    /// the main thread, and so `ARSession` never crosses a Sendable boundary.
    private var host: ARSessionHost?
    private var continuation: AsyncStream<PoseProviderEvent>.Continuation?

    /// Everything the 60 Hz delegate touches. Lives outside the actor so the
    /// delegate never has to hop onto it — see `FrameInbox`.
    private let inbox = FrameInbox()
    public private(set) var isRunning = false

    /// Where captured pixel buffers go. Set by the runtime so the encoder gets
    /// a retained `CVPixelBuffer` to work on. Only the pixel buffer is retained;
    /// the `ARFrame` itself is never handed on.
    public func setPixelBufferSink(_ sink: @escaping @Sendable (PixelBufferHandoff) -> Void) {
        inbox.setSink(sink)
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Marker reference images

    /// Builds every marker reference image, concurrently and off the main
    /// thread.
    ///
    /// Each one is a PNG decode plus ARKit's own feature extraction, and the
    /// venue carries one per marker. Doing them serially inside
    /// `ARSessionHost.start` put all of that on the main thread in the middle
    /// of the join — competing with `ARSession`, `ARSCNView`'s Metal bring-up
    /// and SwiftUI's first frame. They are independent of each other, so a task
    /// group spreads them across cores and the finished set crosses to the main
    /// actor once.
    nonisolated static func referenceImages(
        for configuration: Configuration
    ) async throws -> MarkerImageSet {
        // URLs are resolved up front so only `Sendable` values — an id, a URL,
        // a width — cross into the concurrent tasks. The bundle lookup itself
        // is a dictionary hit; the decode is the expensive half.
        let work: [MarkerImageWork] = try configuration.venue.markers.map { marker in
            guard let url = markerImageURL(marker.id, in: configuration.markerBundle) else {
                throw ProviderError.missingMarkerImage(marker.id)
            }
            return MarkerImageWork(id: marker.id, url: url, physicalWidth: marker.physicalWidth)
        }
        let built = try await withThrowingTaskGroup(of: MarkerImageSet.self) { group in
            for item in work {
                group.addTask { MarkerImageSet(images: [try buildReferenceImage(item)]) }
            }
            var all: Set<ARReferenceImage> = []
            for try await one in group { all.formUnion(one.images) }
            return all
        }
        guard !built.isEmpty else { throw ProviderError.noMarkerImages }
        return MarkerImageSet(images: built)
    }

    /// Serial fallback, for the path that still builds inside the session host.
    nonisolated static func referenceImagesFromVenue(
        _ configuration: Configuration
    ) throws -> Set<ARReferenceImage> {
        var images: Set<ARReferenceImage> = []
        for marker in configuration.venue.markers {
            guard let url = markerImageURL(marker.id, in: configuration.markerBundle) else {
                throw ProviderError.missingMarkerImage(marker.id)
            }
            images.insert(try buildReferenceImage(
                MarkerImageWork(id: marker.id, url: url, physicalWidth: marker.physicalWidth)))
        }
        guard !images.isEmpty else { throw ProviderError.noMarkerImages }
        return images
    }

    struct MarkerImageWork: Sendable {
        var id: String
        var url: URL
        var physicalWidth: Float
    }

    private nonisolated static func markerImageURL(_ id: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: id, withExtension: "png", subdirectory: "Markers")
            ?? bundle.url(forResource: id, withExtension: "png")
    }

    /// `physicalWidth` must be the true measured width in metres or all scale is
    /// wrong — which is why it comes from the venue file rather than from the
    /// asset catalogue, where it would be compiled in and need a rebuild to fix.
    private nonisolated static func buildReferenceImage(
        _ work: MarkerImageWork
    ) throws -> ARReferenceImage {
        guard let source = CGImageSourceCreateWithURL(work.url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProviderError.missingMarkerImage(work.id)
        }
        let reference = ARReferenceImage(cgImage, orientation: .up,
                                         physicalWidth: CGFloat(work.physicalWidth))
        reference.name = work.id
        return reference
    }

    // MARK: - PoseProvider

    public func start() async throws -> AsyncStream<PoseProviderEvent> {
        let (stream, continuation) = AsyncStream<PoseProviderEvent>
            .makeStream(bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        inbox.open(continuation)

        // ARSession + CoreMotion are created and started on the main actor:
        // ARKit's types are not Sendable and its own bring-up assumes the main
        // thread. Only Sendable values cross the hop.
        // Marker images first, and deliberately *here*: this actor is not the
        // main actor, so the PNG decodes and ARKit's feature extraction happen
        // off the main thread. Building them inside `ARSessionHost.start` put
        // all five on main, in the middle of the join, on the same thread
        // ARKit, SceneKit and SwiftUI were all bringing up.
        let markerImages: MarkerImageSet?
        if configuration.referenceImageGroup == nil {
            markerImages = try await BeaconLog.step("build marker images") {
                try await Self.referenceImages(for: configuration)
            }
        } else {
            markerImages = nil
        }

        BeaconLog.log("provider start: building ARSessionHost")
        let host = await ARSessionHost()
        BeaconLog.log("→ ARSessionHost.start")
        try await host.start(configuration: configuration, markerImages: markerImages, inbox: inbox)
        BeaconLog.log("✓ ARSessionHost.start")
        self.host = host
        isRunning = true
        return stream
    }

    public func stop() async {
        BeaconLog.log("provider stop")
        await host?.stop()
        host = nil
        isRunning = false
        inbox.close()
        continuation?.finish()
        continuation = nil
    }

    public func setWorldOrigin(relativeTransform: simd_float4x4) async {
        // This is the shared-origin mechanism: after this call every ARKit pose
        // is already in the venue frame, so the phone converts and the server
        // never has to.
        await host?.setWorldOrigin(relativeTransform: relativeTransform)
    }

    /// The `ARSCNView` that shows what the camera sees. Attach it to
    /// `CameraPreviewSource` after `start()` — pixel-buffer CI preview is gone.
    public func previewView() async -> UIView? {
        await host?.previewView
    }

    /// Suspends until ARKit has delivered its first frame, or `timeout` seconds
    /// pass — whichever comes first. Returns true if a frame arrived.
    ///
    /// This exists so the audio session is not reconfigured while the camera is
    /// still coming up; see `SwarmRuntime.join`. Polling rather than a
    /// continuation because the waiter is one-shot, off the hot path, and a
    /// continuation here would have to be resumed from the 60 Hz delegate.
    public func waitForFirstFrame(timeout: Double) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !inbox.hasDeliveredFrame {
            guard CACurrentMediaTime() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Metres of device motion since the last call. A yes/no signal — "did this
    /// person move while tracking was lost" — never a position. Pedestrian dead
    /// reckoning heading error compounds: 20 degrees over 10 m is ~3.4 m lateral
    /// and never recovers.
    public func consumeMotionSinceLastQuery() async -> Float {
        inbox.consumeMotion()
    }

    // MARK: - Translation

    static func quality(of state: ARCamera.TrackingState) -> TrackingQuality {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .limited(.initializing)
            case .relocalizing: return .limited(.relocalizing)
            case .excessiveMotion: return .limited(.excessiveMotion)
            case .insufficientFeatures: return .limited(.insufficientFeatures)
            @unknown default: return .limited(.unknown)
            }
        }
    }

    static func intrinsics(of camera: ARCamera) -> CameraIntrinsics {
        let matrix = camera.intrinsics
        return CameraIntrinsics(fx: matrix.columns.0.x, fy: matrix.columns.1.y,
                                cx: matrix.columns.2.x, cy: matrix.columns.2.y,
                                imageWidth: Int(camera.imageResolution.width),
                                imageHeight: Int(camera.imageResolution.height))
    }

    public enum ProviderError: Error, LocalizedError {
        case worldTrackingUnsupported
        case missingMarkerImage(String)
        case noMarkerImages

        public var errorDescription: String? {
            switch self {
            case .worldTrackingUnsupported:
                "ARWorldTrackingConfiguration is not supported here. ARKit does not run in the Simulator."
            case .missingMarkerImage(let id):
                "No Markers/\(id).png in the bundle for marker \(id)."
            case .noMarkerImages:
                "venue.json named no markers, so nothing can establish the origin."
            }
        }
    }
}

/// Main-thread owner of `ARSession` + the live preview `ARSCNView`.
///
/// ARKit/CoreMotion stay on the main thread, non-`Sendable` ARKit types never
/// cross the pose-provider actor, and the operator sees the camera through
/// Apple's scene view rather than a home-grown `CVPixelBuffer` → CIImage path
/// that was trapping `_dispatch_assert_queue_fail` on device.
@MainActor
private final class ARSessionHost {
    private let session = ARSession()
    private var delegate: SessionDelegate?
    private var sceneView: ARSCNView?

    /// Live camera view sharing `session`. Nil until `start`.
    var previewView: UIView? { sceneView }

    func start(configuration: ARKitPoseProvider.Configuration,
               markerImages: MarkerImageSet?, inbox: FrameInbox) throws {
        BeaconLog.log("ARSessionHost.start on this queue")
        let sessionConfiguration = try makeSessionConfiguration(configuration, markerImages: markerImages)
        BeaconLog.log("session configuration built: \(sessionConfiguration.detectionImages?.count ?? 0) markers")
        let delegate = SessionDelegate(inbox: inbox)
        self.delegate = delegate

        // Scene view first, then run — Apple's required order when sharing a
        // session with `ARSCNView` so the camera feed actually composites.
        let sceneView = ARSCNView(frame: .zero)
        sceneView.scene = SCNScene()
        sceneView.autoenablesDefaultLighting = false
        sceneView.automaticallyUpdatesLighting = false
        sceneView.backgroundColor = .black
        sceneView.session = session
        self.sceneView = sceneView

        session.delegate = delegate
        // A real serial queue, off the main thread.
        //
        // This was `nil` (main) because custom queues "still trapped on device
        // once frames started". The likely reason is now understood: if the SDK
        // imports `ARSessionDelegate`'s requirements as `@MainActor`, the
        // conformance methods inherit that isolation, and ARKit calling them
        // from a non-main queue trips `dispatch_assert_queue(main)` on the
        // first frame — the same inferred-isolation defect as the audio tap in
        // `MicrophoneCapture.install`. `SessionDelegate`'s methods are now
        // explicitly `nonisolated`, which removes the assert rather than
        // satisfying it by accident.
        //
        // Why it matters: at 60 Hz on main the delegate competed with SwiftUI's
        // full-tree redraw and with every blocking `AVAudioSession` call — and
        // ARKit does not queue missed callbacks, it simply goes quiet, which is
        // what made tracking read `notAvailable` after `microphone.start`.
        //
        // **If a queue-assertion trap comes back on the first frame, this line
        // is the first thing to revert.** The `[beacon]` queue label on the last
        // line before the trap will say so.
        session.delegateQueue = DispatchQueue(label: "beacon.arkit.delegate", qos: .userInitiated)
        BeaconLog.log("ARSession.run")
        session.run(sessionConfiguration, options: [.resetTracking, .removeExistingAnchors])
        BeaconLog.log("ARSession.run returned")
    }

    func stop() {
        session.pause()
        session.delegate = nil
        sceneView?.removeFromSuperview()
        sceneView = nil
        delegate = nil
    }

    func setWorldOrigin(relativeTransform: simd_float4x4) {
        session.setWorldOrigin(relativeTransform: relativeTransform)
    }

    private func makeSessionConfiguration(
        _ configuration: ARKitPoseProvider.Configuration,
        markerImages: MarkerImageSet?
    ) throws -> ARWorldTrackingConfiguration {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ARKitPoseProvider.ProviderError.worldTrackingUnsupported
        }
        let sessionConfiguration = ARWorldTrackingConfiguration()

        // Gravity fixes pitch and roll; the marker fixes yaw. Never
        // .gravityAndHeading — that pulls in the magnetometer, which is off by
        // tens of degrees indoors.
        sessionConfiguration.worldAlignment = .gravity
        sessionConfiguration.isLightEstimationEnabled = false
        sessionConfiguration.planeDetection = []
        sessionConfiguration.environmentTexturing = .none

        if let group = configuration.referenceImageGroup,
           let images = ARReferenceImage.referenceImages(inGroupNamed: group, bundle: nil) {
            // Compiled descriptors out of the asset catalogue: a lookup, not a
            // decode, so this one is cheap enough to stay on main.
            sessionConfiguration.detectionImages = images
        } else if let markerImages {
            sessionConfiguration.detectionImages = markerImages.images
        } else {
            sessionConfiguration.detectionImages =
                try ARKitPoseProvider.referenceImagesFromVenue(configuration)
        }
        sessionConfiguration.maximumNumberOfTrackedImages = configuration.maximumConcurrentImages
        // Off: ARKit's own estimate of a marker's size is less trustworthy than a
        // tape measure, and letting it float makes every distance drift with it.
        sessionConfiguration.automaticImageScaleEstimationEnabled = false

        return sessionConfiguration
    }

}

/// The hand-off point between ARKit's delegate queue and everything else.
///
/// The delegate used to hop onto the provider actor with one unstructured
/// `Task` per callback — sixty a second. Unstructured tasks carry no ordering
/// guarantee, so frame N+1 could be delivered before frame N, and a pose could
/// slip in *between* two markers seen in the same instant. `SessionMachine`
/// closes a sighting batch the moment a pose arrives, so that interleaving
/// silently turned "average these co-visible markers" into "apply them one by
/// one" — the opposite of why more than one marker goes up.
///
/// ARKit's delegate queue is serial and `AsyncStream.Continuation.yield` is
/// thread-safe, so yielding straight from the callback gives total order for
/// free: poses in capture order, and every sighting from one callback
/// back-to-back with nothing between them. No tasks, no hops.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`.
private final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<PoseProviderEvent>.Continuation?
    private var sink: (@Sendable (PixelBufferHandoff) -> Void)?
    private var lastPosition: SIMD3<Float>?
    private var motion: Float = 0
    private var didDeliverFrame = false

    var hasDeliveredFrame: Bool { lock.withLock { didDeliverFrame } }

    func open(_ continuation: AsyncStream<PoseProviderEvent>.Continuation) {
        lock.withLock {
            self.continuation = continuation
            lastPosition = nil
            motion = 0
        }
    }

    func close() {
        lock.withLock { continuation = nil }
    }

    func setSink(_ sink: @escaping @Sendable (PixelBufferHandoff) -> Void) {
        lock.withLock { self.sink = sink }
    }

    /// One camera frame, already copied out of the `ARFrame`.
    func frame(_ sample: PoseSample, pixelBuffer: PixelBufferHandoff) {
        let (continuation, sink) = lock.withLock { () -> (AsyncStream<PoseProviderEvent>.Continuation?,
                                                          (@Sendable (PixelBufferHandoff) -> Void)?) in
            didDeliverFrame = true
            if let last = lastPosition { motion += simd_distance(last, sample.pose.position) }
            lastPosition = sample.pose.position
            return (self.continuation, self.sink)
        }
        // Outside the lock: neither of these may block the other's readers.
        sink?(pixelBuffer)
        continuation?.yield(.pose(sample))
    }

    /// Every marker from one delegate callback, contiguous in the stream.
    func markers(_ sightings: [MarkerSighting]) {
        guard let continuation = lock.withLock({ self.continuation }) else { return }
        for sighting in sightings { continuation.yield(.marker(sighting)) }
    }

    func event(_ event: PoseProviderEvent) {
        let continuation = lock.withLock { () -> AsyncStream<PoseProviderEvent>.Continuation? in
            // ARKit has thrown its map away: distance across the gap is not motion.
            if case .interruptionEnded = event { lastPosition = nil }
            return self.continuation
        }
        continuation?.yield(event)
    }

    func consumeMotion() -> Float {
        lock.withLock {
            defer { motion = 0 }
            return motion
        }
    }
}

/// ARKit's delegate is not `Sendable` and fires on its own serial queue. It
/// copies what it needs out of ARKit's reference types and hands plain values to
/// the inbox, synchronously — see `FrameInbox` for why not a `Task`.
private final class SessionDelegate: NSObject, ARSessionDelegate {
    private let inbox: FrameInbox

    init(inbox: FrameInbox) {
        self.inbox = inbox
    }

    private var hasLoggedFirstFrame = false

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Fires at 60 Hz. Everything is copied out synchronously here; the frame
        // is never retained, because retaining it stalls the session.
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            BeaconLog.log("first ARKit frame")
        }
        let timestamp = frame.timestamp
        let camera = frame.camera
        let pose = Pose(matrix: camera.transform)
        // The pixel buffer is retained; the frame is not. CoreVideo buffers are
        // reference-counted independently of the ARFrame that vended them.
        inbox.frame(PoseSample(pose: pose, deviceTimestamp: timestamp,
                               quality: ARKitPoseProvider.quality(of: camera.trackingState),
                               intrinsics: ARKitPoseProvider.intrinsics(of: camera)),
                    pixelBuffer: PixelBufferHandoff(frame.capturedImage, deviceTimestamp: timestamp))
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        forward(anchors, isUpdate: false)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // didUpdate is as important as didAdd: operators walk, ARKit drifts, and
        // every re-sighting is a correction rather than a repeat of calibration.
        forward(anchors, isUpdate: true)
    }

    private nonisolated func forward(_ anchors: [ARAnchor], isUpdate: Bool) {
        // ARImageAnchor is a reference type and is not Sendable, so everything
        // needed is copied into plain values first. One timestamp for the whole
        // callback: sharing it is what tells `SessionMachine` these were seen
        // together and should be averaged into a single correction.
        let timestamp = CACurrentMediaTime()
        let sightings: [MarkerSighting] = anchors.compactMap { anchor in
            guard let image = anchor as? ARImageAnchor,
                  let name = image.referenceImage.name else { return nil }
            return MarkerSighting(markerID: name,
                                  observedTransform: image.transform,
                                  deviceTimestamp: timestamp,
                                  isUpdate: isUpdate,
                                  estimatedPhysicalWidth: Float(image.referenceImage.physicalSize.width))
        }
        guard !sightings.isEmpty else { return }
        inbox.markers(sightings)
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        BeaconLog.log("ARSession interrupted")
        inbox.event(.interrupted)
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        // ARKit has thrown its map away. Everything is untrustworthy until a
        // marker is seen again; SwarmCore's state machine decides what that means.
        inbox.event(.interruptionEnded)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        BeaconLog.log("ARSession failed: \(error.localizedDescription)")
        inbox.event(.failed(error.localizedDescription))
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        BeaconLog.log("tracking state → \(ARKitPoseProvider.quality(of: camera.trackingState).wireValue)")
    }
}
