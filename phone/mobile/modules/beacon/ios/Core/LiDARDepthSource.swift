import Foundation
import SwarmCore

/// Depth from the LiDAR scanner, already in metres.
///
/// Note what is *not* imported here: ARKit. CLAUDE.md puts ARKit in exactly one
/// file, and the only object that holds an `ARFrame` is `ARKitPoseProvider`,
/// which copies the depth buffer out and vends it through
/// `MetricDepthFrameSource`.
///
/// This is also the only place device class is branched on. No UI and no session
/// logic asks whether the phone has a LiDAR scanner.
///
// DEVICE-VERIFY: a human must confirm, on hardware, that hasLiDAR is true on a
// Pro device and false otherwise; that depth chunks arrive with source: lidar
// and metricScale 1; that a measured wall distance matches a tape within ~5 cm;
// and that a non-Pro device behaves identically except for the chunk source,
// with nothing in the UI or session logic differing.
// DEVICE_CHECKLIST.md item 16.
public struct LiDARDepthSource: DepthSource {
    public var isNativelyMetric: Bool { true }

    private let frames: any MetricDepthFrameSource

    public init(frames: any MetricDepthFrameSource) {
        self.frames = frames
    }

    /// True when this device can actually supply depth. The caller picks a
    /// source once, at launch, and nothing downstream asks again.
    public var isAvailable: Bool { frames.providesSceneDepth }

    public func depth(for request: DepthRequest) async throws -> DepthResult? {
        guard let latest = await frames.latestSceneDepth() else {
            throw DepthSourceError.noEstimateAvailable
        }
        guard latest.map.isWellFormed else { throw DepthSourceError.malformedEstimate }
        // Already metres: scale 1, and no fit, because there is nothing to fit.
        return DepthResult(chunkID: request.chunkID, maps: [latest.map], appliedScale: 1, fit: nil)
    }
}
