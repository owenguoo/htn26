import Foundation
import simd

/// **VGGT-Ω depth is scene-normalized, not metres.** Each chunk comes back with
/// an arbitrary origin and an arbitrary scale, so a depth map from it is a
/// picture of relative distances until something metric is attached to it.
///
/// The only metric thing the phone has is ARKit: the camera positions for the
/// frames in the chunk are real metres. Comparing the network's predicted camera
/// baselines against those known baselines recovers the missing factor.
///
/// Both estimators take the median of pairwise ratios rather than a least-squares
/// fit. Least squares is pulled around by a single bad pair; the median survives
/// up to half the pairs being wrong, and one badly reconstructed frame in a chunk
/// of six is well inside that.
public enum DepthScaleFit {

    public enum Method: String, Sendable, Equatable {
        case cameraBaselines
        case depthCorrespondences
    }

    public struct Result: Sendable, Equatable {
        /// Multiply scene-normalized depth by this to get metres.
        public var scale: Float
        /// Fraction of ratios within tolerance of the chosen scale. A low value
        /// means the chunk disagrees with itself and the result should not be
        /// trusted even though one was produced.
        public var inlierFraction: Float
        /// Median absolute deviation of the ratios, relative to the scale.
        public var relativeSpread: Float
        public var method: Method
        public var sampleCount: Int

        public init(scale: Float, inlierFraction: Float, relativeSpread: Float,
                    method: Method, sampleCount: Int) {
            self.scale = scale
            self.inlierFraction = inlierFraction
            self.relativeSpread = relativeSpread
            self.method = method
            self.sampleCount = sampleCount
        }
    }

    /// Widest separation between any two cameras in the chunk. This is the
    /// parallax the reconstruction had to work with; below a few centimetres
    /// there is none, and no scale exists to be recovered.
    public static func widestBaseline(of positions: [SIMD3<Float>]) -> Float {
        guard positions.count > 1 else { return 0 }
        var widest: Float = 0
        for i in 0..<(positions.count - 1) {
            for j in (i + 1)..<positions.count {
                widest = max(widest, simd_distance(positions[i], positions[j]))
            }
        }
        return widest
    }

    public static func widestBaseline(of poses: [Pose]) -> Float {
        widestBaseline(of: poses.map(\.position))
    }

    public static func widestBaseline(of frames: [DepthChunk.FrameRef]) -> Float {
        widestBaseline(of: frames.compactMap { frame -> SIMD3<Float>? in
            guard frame.position.count == 3 else { return nil }
            return SIMD3<Float>(frame.position[0], frame.position[1], frame.position[2])
        })
    }

    /// Fits the factor that turns the network's own units into metres, by
    /// comparing its predicted camera baselines against ARKit's known metric
    /// ones.
    ///
    /// Returns nil — never a guess — when the phone barely moved during the
    /// chunk. A stationary phone gives no parallax, and a scale invented from
    /// noise is worse than admitting there is none, because the dashboard would
    /// draw it as if it were measured.
    public static func fit(predictedCameras: [SIMD3<Float>],
                           metricCameras: [SIMD3<Float>],
                           minimumBaseline: Float = 0.12,
                           inlierTolerance: Float = 0.10) -> Result? {
        guard predictedCameras.count == metricCameras.count, predictedCameras.count >= 2 else {
            return nil
        }
        guard widestBaseline(of: metricCameras) >= minimumBaseline else { return nil }

        var ratios: [Float] = []
        ratios.reserveCapacity(predictedCameras.count * (predictedCameras.count - 1) / 2)
        for i in 0..<(predictedCameras.count - 1) {
            for j in (i + 1)..<predictedCameras.count {
                let predicted = simd_distance(predictedCameras[i], predictedCameras[j])
                let metric = simd_distance(metricCameras[i], metricCameras[j])
                // Pairs that barely separated carry no information and turn into
                // enormous ratios; leave them out rather than let them dominate.
                guard predicted > 1e-5, metric >= minimumBaseline * 0.25 else { continue }
                ratios.append(metric / predicted)
            }
        }
        return summarise(ratios, method: .cameraBaselines, inlierTolerance: inlierTolerance)
    }

    /// Fits the same factor from paired depth readings: scene-normalized values
    /// and a metric reference for the same points, e.g. LiDAR on a Pro device or
    /// ARKit's own sparse feature depths.
    ///
    /// Survives outliers because it takes the median: a fifth of the pairs being
    /// wrong moves the median hardly at all.
    public static func fit(normalizedDepths: [Float],
                           metricDepths: [Float],
                           inlierTolerance: Float = 0.10) -> Result? {
        guard normalizedDepths.count == metricDepths.count, !normalizedDepths.isEmpty else {
            return nil
        }
        var ratios: [Float] = []
        ratios.reserveCapacity(normalizedDepths.count)
        for (normalized, metric) in zip(normalizedDepths, metricDepths) {
            guard normalized.isFinite, metric.isFinite, normalized > 1e-5, metric > 1e-5 else { continue }
            ratios.append(metric / normalized)
        }
        return summarise(ratios, method: .depthCorrespondences, inlierTolerance: inlierTolerance)
    }

    private static func summarise(_ ratios: [Float], method: Method, inlierTolerance: Float) -> Result? {
        guard !ratios.isEmpty else { return nil }
        let scale = median(ratios)
        guard scale.isFinite, scale > 0 else { return nil }
        let deviations = ratios.map { abs($0 - scale) }
        let spread = median(deviations) / scale
        let inliers = ratios.filter { abs($0 - scale) <= inlierTolerance * scale }.count
        return Result(scale: scale,
                      inlierFraction: Float(inliers) / Float(ratios.count),
                      relativeSpread: spread,
                      method: method,
                      sampleCount: ratios.count)
    }

    /// Lower median for an even count, so the result is always an observed
    /// ratio rather than an average of two that may straddle an outlier.
    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// Applies a fitted scale in place of guessing. Returns nil when there is no
    /// scale, so a caller cannot accidentally publish normalized units as metres.
    public static func toMetres(_ normalized: [Float], scale: Float?) -> [Float]? {
        guard let scale, scale.isFinite, scale > 0 else { return nil }
        return normalized.map { $0 * scale }
    }
}
