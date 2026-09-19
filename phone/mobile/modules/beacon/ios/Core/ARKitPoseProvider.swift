import ARKit
import Foundation
import SwarmCore
import simd

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
public actor ARKitPoseProvider: PoseProvider, MetricDepthFrameSource {

    public struct Configuration: Sendable {
        /// The markers to look for, and their true measured widths.
        public var venue: Venue
        /// Name of the `ARReferenceImage` group in the asset catalogue, or nil to
        /// build reference images from `venue.json` at runtime.
        public var referenceImageGroup: String?
        /// LiDAR depth, on the devices that have it. Branching on device class
        /// happens here and nowhere else.
        public var wantsSceneDepth: Bool
        /// How many image anchors ARKit tracks at once.
        public var maximumConcurrentImages: Int
        /// Where `Markers/<id>.png` live. Inside the Expo module that is the
        /// pod's resource bundle, not `Bundle.main`.
        public var markerBundle: Bundle

        public init(venue: Venue, referenceImageGroup: String? = "Markers",
                    wantsSceneDepth: Bool = true, maximumConcurrentImages: Int = 4,
                    markerBundle: Bundle = .main) {
            self.markerBundle = markerBundle
            self.venue = venue
            self.referenceImageGroup = referenceImageGroup
            self.wantsSceneDepth = wantsSceneDepth
            self.maximumConcurrentImages = maximumConcurrentImages
        }
    }

    private let configuration: Configuration
    private let session = ARSession()
    private var continuation: AsyncStream<PoseProviderEvent>.Continuation?
    private var delegate: SessionDelegate?

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

    // MARK: - PoseProvider

    public func start() async throws -> AsyncStream<PoseProviderEvent> {
        let (stream, continuation) = AsyncStream<PoseProviderEvent>
            .makeStream(bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        inbox.open(continuation)

        let delegate = SessionDelegate(inbox: inbox)
        self.delegate = delegate
        session.delegate = delegate
        session.delegateQueue = DispatchQueue(label: "beacon.arsession", qos: .userInitiated)

        let sessionConfiguration = try makeSessionConfiguration()
        session.run(sessionConfiguration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        return stream
    }

    public func stop() async {
        session.pause()
        isRunning = false
        inbox.close()
        continuation?.finish()
        continuation = nil
        delegate = nil
    }

    public func setWorldOrigin(relativeTransform: simd_float4x4) async {
        // This is the shared-origin mechanism: after this call every ARKit pose
        // is already in the venue frame, so the phone converts and the server
        // never has to.
        session.setWorldOrigin(relativeTransform: relativeTransform)
    }

    /// Metres of device motion since the last call. A yes/no signal — "did this
    /// person move while tracking was lost" — never a position. Pedestrian dead
    /// reckoning heading error compounds: 20 degrees over 10 m is ~3.4 m lateral
    /// and never recovers.
    public func consumeMotionSinceLastQuery() async -> Float {
        inbox.consumeMotion()
    }

    // MARK: - MetricDepthFrameSource

    public nonisolated var providesSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    public func latestSceneDepth() async -> (map: DepthMap, pose: Pose, deviceTimestamp: Double)? {
        inbox.latestDepth()
    }

    // MARK: - Session configuration

    private func makeSessionConfiguration() throws -> ARWorldTrackingConfiguration {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ProviderError.worldTrackingUnsupported
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
            sessionConfiguration.detectionImages = images
        } else {
            sessionConfiguration.detectionImages = try referenceImagesFromVenue()
        }
        sessionConfiguration.maximumNumberOfTrackedImages = configuration.maximumConcurrentImages
        // Off: ARKit's own estimate of a marker's size is less trustworthy than a
        // tape measure, and letting it float makes every distance drift with it.
        sessionConfiguration.automaticImageScaleEstimationEnabled = false

        if configuration.wantsSceneDepth,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            sessionConfiguration.frameSemantics.insert(.sceneDepth)
        }
        return sessionConfiguration
    }

    /// Builds reference images from `Markers/<id>.png` in the bundle, using the
    /// measured widths in `venue.json`.
    ///
    /// `physicalWidth` must be the true measured width in metres or all scale is
    /// wrong — which is why it comes from the venue file rather than from the
    /// asset catalogue, where it would be compiled in and need a rebuild to fix.
    private func referenceImagesFromVenue() throws -> Set<ARReferenceImage> {
        var images: Set<ARReferenceImage> = []
        for marker in configuration.venue.markers {
            guard let url = configuration.markerBundle.url(forResource: marker.id, withExtension: "png",
                                                           subdirectory: "Markers")
                    ?? configuration.markerBundle.url(forResource: marker.id, withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProviderError.missingMarkerImage(marker.id)
            }
            let reference = ARReferenceImage(cgImage, orientation: .up,
                                             physicalWidth: CGFloat(marker.physicalWidth))
            reference.name = marker.id
            images.insert(reference)
        }
        guard !images.isEmpty else { throw ProviderError.noMarkerImages }
        return images
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

    /// Copies a `CVPixelBuffer` of `Float32` depth into a plain array. The buffer
    /// belongs to the frame and must not outlive the callback.
    static func depthMap(from pixelBuffer: CVPixelBuffer, confidence: CVPixelBuffer?) -> DepthMap? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var values = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let rowBase = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float.self)
            for column in 0..<width {
                values[row * width + column] = rowBase[column]
            }
        }

        var confidences: [Float]?
        if let confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            if let confidenceBase = CVPixelBufferGetBaseAddress(confidence) {
                let confidenceRow = CVPixelBufferGetBytesPerRow(confidence)
                var out = [Float](repeating: 0, count: width * height)
                for row in 0..<height {
                    let rowBase = confidenceBase.advanced(by: row * confidenceRow)
                        .assumingMemoryBound(to: UInt8.self)
                    for column in 0..<width {
                        // ARConfidenceLevel is 0…2; normalise so the server does
                        // not have to know Apple's enum.
                        out[row * width + column] = Float(rowBase[column]) / 2
                    }
                }
                confidences = out
            }
        }
        return DepthMap(width: width, height: height, values: values, confidence: confidences)
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
    private var depth: (map: DepthMap, pose: Pose, deviceTimestamp: Double)?
    private var lastPosition: SIMD3<Float>?
    private var motion: Float = 0

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
    func frame(_ sample: PoseSample, pixelBuffer: PixelBufferHandoff,
               depth newDepth: DepthMap?) {
        let (continuation, sink) = lock.withLock { () -> (AsyncStream<PoseProviderEvent>.Continuation?,
                                                          (@Sendable (PixelBufferHandoff) -> Void)?) in
            if let last = lastPosition { motion += simd_distance(last, sample.pose.position) }
            lastPosition = sample.pose.position
            if let newDepth { depth = (newDepth, sample.pose, sample.deviceTimestamp) }
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

    func latestDepth() -> (map: DepthMap, pose: Pose, deviceTimestamp: Double)? {
        lock.withLock { depth }
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Fires at 60 Hz. Everything is copied out synchronously here; the frame
        // is never retained, because retaining it stalls the session.
        let timestamp = frame.timestamp
        let camera = frame.camera
        let pose = Pose(matrix: camera.transform)
        let depth = frame.sceneDepth.flatMap {
            ARKitPoseProvider.depthMap(from: $0.depthMap, confidence: $0.confidenceMap)
        }
        // The pixel buffer is retained; the frame is not. CoreVideo buffers are
        // reference-counted independently of the ARFrame that vended them.
        inbox.frame(PoseSample(pose: pose, deviceTimestamp: timestamp,
                               quality: ARKitPoseProvider.quality(of: camera.trackingState),
                               intrinsics: ARKitPoseProvider.intrinsics(of: camera)),
                    pixelBuffer: PixelBufferHandoff(frame.capturedImage, deviceTimestamp: timestamp),
                    depth: depth)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        forward(anchors, isUpdate: false)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // didUpdate is as important as didAdd: operators walk, ARKit drifts, and
        // every re-sighting is a correction rather than a repeat of calibration.
        forward(anchors, isUpdate: true)
    }

    private func forward(_ anchors: [ARAnchor], isUpdate: Bool) {
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

    func sessionWasInterrupted(_ session: ARSession) {
        inbox.event(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // ARKit has thrown its map away. Everything is untrustworthy until a
        // marker is seen again; SwarmCore's state machine decides what that means.
        inbox.event(.interruptionEnded)
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        inbox.event(.failed(error.localizedDescription))
    }
}
