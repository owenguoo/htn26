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

        public init(venue: Venue, referenceImageGroup: String? = "Markers",
                    wantsSceneDepth: Bool = true, maximumConcurrentImages: Int = 4) {
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

    /// Copied out of the frame, never the frame itself.
    private var latestDepth: (map: DepthMap, pose: Pose, deviceTimestamp: Double)?
    private var lastPosition: SIMD3<Float>?
    private var motionAccumulator: Float = 0
    public private(set) var isRunning = false
    /// Where captured pixel buffers go. Set by the coordinator so the encoder
    /// gets the buffer without this file knowing anything about JPEGs, and so
    /// the `ARFrame` itself is never handed on.
    private var pixelBufferSink: (@Sendable (PixelBufferHandoff) -> Void)?

    public func setPixelBufferSink(_ sink: @escaping @Sendable (PixelBufferHandoff) -> Void) {
        pixelBufferSink = sink
    }

    fileprivate func stage(pixelBuffer: PixelBufferHandoff) {
        pixelBufferSink?(pixelBuffer)
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - PoseProvider

    public func start() async throws -> AsyncStream<PoseProviderEvent> {
        let (stream, continuation) = AsyncStream<PoseProviderEvent>
            .makeStream(bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation

        let delegate = SessionDelegate(provider: self)
        self.delegate = delegate
        session.delegate = delegate
        session.delegateQueue = DispatchQueue(label: "swarmsight.arsession", qos: .userInitiated)

        let sessionConfiguration = try makeSessionConfiguration()
        session.run(sessionConfiguration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        return stream
    }

    public func stop() async {
        session.pause()
        isRunning = false
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
        defer { motionAccumulator = 0 }
        return motionAccumulator
    }

    // MARK: - MetricDepthFrameSource

    public nonisolated var providesSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    public func latestSceneDepth() async -> (map: DepthMap, pose: Pose, deviceTimestamp: Double)? {
        latestDepth
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
            guard let url = Bundle.main.url(forResource: marker.id, withExtension: "png",
                                            subdirectory: "Markers"),
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

    // MARK: - Delegate callbacks, hopped onto the actor

    /// Takes an already-copied sample. The `ARFrame` it came from stays on the
    /// delegate queue and is released the moment the callback returns; retaining
    /// one stalls the session.
    fileprivate func ingest(sample: PoseSample) {
        if let last = lastPosition {
            motionAccumulator += simd_distance(last, sample.pose.position)
        }
        lastPosition = sample.pose.position
        continuation?.yield(.pose(sample))
    }

    fileprivate func ingest(depth: DepthMap, pose: Pose, timestamp: Double) {
        latestDepth = (depth, pose, timestamp)
    }

    fileprivate func ingest(sighting: MarkerSighting) {
        continuation?.yield(.marker(sighting))
    }

    fileprivate func sessionWasInterrupted() {
        continuation?.yield(.interrupted)
    }

    fileprivate func sessionInterruptionEnded() {
        // ARKit has thrown its map away. Everything is untrustworthy until a
        // marker is seen again; SwarmCore's state machine decides what that means.
        lastPosition = nil
        continuation?.yield(.interruptionEnded)
    }

    fileprivate func sessionFailed(_ error: any Error) {
        continuation?.yield(.failed(error.localizedDescription))
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

/// ARKit's delegate is not `Sendable` and fires on its own queue, so it is a
/// separate object that does nothing but hop onto the actor.
private final class SessionDelegate: NSObject, ARSessionDelegate {
    private let provider: ARKitPoseProvider

    init(provider: ARKitPoseProvider) {
        self.provider = provider
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Fires at 60 Hz. Everything is copied out synchronously here; the frame
        // is never captured by the Task, because retaining it stalls the session.
        let timestamp = frame.timestamp
        let camera = frame.camera
        let pose = Pose(matrix: camera.transform)
        let quality = ARKitPoseProvider.quality(of: camera.trackingState)
        let intrinsics = ARKitPoseProvider.intrinsics(of: camera)
        let depth = frame.sceneDepth.flatMap {
            ARKitPoseProvider.depthMap(from: $0.depthMap, confidence: $0.confidenceMap)
        }
        // The pixel buffer is retained; the frame is not. CoreVideo buffers are
        // reference-counted independently of the ARFrame that vended them.
        let pixelBuffer = PixelBufferHandoff(frame.capturedImage, deviceTimestamp: timestamp)

        Task { [provider] in
            await provider.stage(pixelBuffer: pixelBuffer)
            await provider.ingest(sample: PoseSample(pose: pose, deviceTimestamp: timestamp,
                                                     quality: quality, intrinsics: intrinsics))
            if let depth {
                await provider.ingest(depth: depth, pose: pose, timestamp: timestamp)
            }
        }
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
        // needed is copied into plain values before crossing to the actor.
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
        Task { [provider] in
            for sighting in sightings {
                await provider.ingest(sighting: sighting)
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { [provider] in await provider.sessionWasInterrupted() }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { [provider] in await provider.sessionInterruptionEnded() }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { [provider] in await provider.sessionFailed(error) }
    }
}
