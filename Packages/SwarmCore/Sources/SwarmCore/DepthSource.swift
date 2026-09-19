import Foundation
import simd

/// Metric depth for a chunk of frames, in the venue frame.
///
/// Two implementations: `LiDARDepthSource` in the app target (ARKit
/// `frameSemantics = .sceneDepth`, Pro devices only) and `ServerDepthSource`
/// here (frames uploaded, VGGT-Ω depth returned).
///
/// **Device class is branched on here and nowhere else.** No UI and no session
/// logic may ask whether the phone has LiDAR.
public protocol DepthSource: Sendable {
    /// True when the source's depths are already metres. LiDAR is; VGGT-Ω is not.
    var isNativelyMetric: Bool { get }
    func depth(for request: DepthRequest) async throws -> DepthResult?
}

public struct DepthRequest: Sendable, Equatable {
    public var chunkID: UInt64
    /// The metric ARKit poses for the frames in the chunk. These are the only
    /// metric thing in the system, and what a scene-normalized reconstruction is
    /// fitted against.
    public var frames: [DepthChunk.FrameRef]

    public init(chunkID: UInt64, frames: [DepthChunk.FrameRef]) {
        self.chunkID = chunkID
        self.frames = frames
    }

    public var metricPositions: [SIMD3<Float>] {
        frames.compactMap { frame in
            guard frame.position.count == 3 else { return nil }
            return SIMD3<Float>(frame.position[0], frame.position[1], frame.position[2])
        }
    }
}

public struct DepthMap: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Row-major. Metres once `DepthResult.isMetric` is true.
    public var values: [Float]
    public var confidence: [Float]?

    public init(width: Int, height: Int, values: [Float], confidence: [Float]? = nil) {
        self.width = width
        self.height = height
        self.values = values
        self.confidence = confidence
    }

    public var isWellFormed: Bool {
        width > 0 && height > 0 && values.count == width * height
            && (confidence == nil || confidence?.count == values.count)
    }
}

public struct DepthResult: Sendable, Equatable {
    public var chunkID: UInt64
    public var maps: [DepthMap]
    /// The factor applied to make the maps metric: 1 for LiDAR, the fitted value
    /// for server depth.
    public var appliedScale: Float
    public var fit: DepthScaleFit.Result?

    public init(chunkID: UInt64, maps: [DepthMap], appliedScale: Float, fit: DepthScaleFit.Result?) {
        self.chunkID = chunkID
        self.maps = maps
        self.appliedScale = appliedScale
        self.fit = fit
    }
}

/// What the orchestrator sends back for a chunk: cameras and per-frame depth in
/// VGGT-Ω's own arbitrary origin and scale.
public struct ServerDepthEstimate: Sendable, Equatable {
    public var chunkID: UInt64
    /// Predicted camera positions, in the network's units.
    public var predictedCameras: [SIMD3<Float>]
    /// Scene-normalized depth, one map per frame.
    public var maps: [DepthMap]

    public init(chunkID: UInt64, predictedCameras: [SIMD3<Float>], maps: [DepthMap]) {
        self.chunkID = chunkID
        self.predictedCameras = predictedCameras
        self.maps = maps
    }
}

public enum DepthSourceError: Error, Sendable, Equatable {
    case noEstimateAvailable
    case malformedEstimate
    /// The chunk had no usable parallax, so no scale exists to recover. Not a
    /// failure to handle — a fact about the capture.
    case scaleNotRecoverable
}

/// Turns a scene-normalized server reconstruction into metric depth in the venue
/// frame, by fitting the network's camera baselines against ARKit's.
///
/// Pure: the transport hands it an estimate, it hands back metres or nothing.
public struct ServerDepthSource: DepthSource {
    public var isNativelyMetric: Bool { false }

    public var minimumBaseline: Float
    /// Below this, the chunk's pairwise ratios disagree too much to publish.
    public var minimumInlierFraction: Float
    private let estimates: @Sendable (DepthRequest) async throws -> ServerDepthEstimate?

    public init(minimumBaseline: Float = 0.12, minimumInlierFraction: Float = 0.5,
                estimates: @escaping @Sendable (DepthRequest) async throws -> ServerDepthEstimate?) {
        self.minimumBaseline = minimumBaseline
        self.minimumInlierFraction = minimumInlierFraction
        self.estimates = estimates
    }

    public func depth(for request: DepthRequest) async throws -> DepthResult? {
        guard let estimate = try await estimates(request) else {
            throw DepthSourceError.noEstimateAvailable
        }
        return try scale(estimate, against: request)
    }

    /// Separated out so the fitting can be tested without an async round trip.
    public func scale(_ estimate: ServerDepthEstimate, against request: DepthRequest) throws -> DepthResult {
        guard estimate.maps.allSatisfy(\.isWellFormed),
              estimate.predictedCameras.count == request.metricPositions.count else {
            throw DepthSourceError.malformedEstimate
        }
        guard let fit = DepthScaleFit.fit(predictedCameras: estimate.predictedCameras,
                                          metricCameras: request.metricPositions,
                                          minimumBaseline: minimumBaseline),
              fit.inlierFraction >= minimumInlierFraction else {
            throw DepthSourceError.scaleNotRecoverable
        }
        let scaled = estimate.maps.map { map in
            DepthMap(width: map.width, height: map.height,
                     values: map.values.map { $0 * fit.scale },
                     confidence: map.confidence)
        }
        return DepthResult(chunkID: estimate.chunkID, maps: scaled, appliedScale: fit.scale, fit: fit)
    }
}

/// Metric depth straight off the device, copied out of whatever frame produced
/// it.
///
/// This exists so `LiDARDepthSource` does not have to import ARKit. CLAUDE.md
/// puts ARKit in exactly one file, and the only object that holds an `ARFrame`
/// is `ARKitPoseProvider` — which conforms to this and copies the depth buffer
/// out. An `ARFrame` retained beyond its delegate callback stalls the session.
public protocol MetricDepthFrameSource: Sendable {
    /// True on devices with a LiDAR scanner and `.sceneDepth` enabled.
    var providesSceneDepth: Bool { get }
    /// The most recent depth map, already copied, in metres, with the camera
    /// pose it was captured at.
    func latestSceneDepth() async -> (map: DepthMap, pose: Pose, deviceTimestamp: Double)?
}
