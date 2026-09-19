import CoreGraphics
import Foundation
import simd

/// Projects venue-frame points into the camera image, so the app can draw where
/// the venue believes something is and a human can compare that against where it
/// actually is.
///
/// This is the most direct test of calibration there is. A marker outline that
/// sits exactly on the printed marker and stays glued to it while the operator
/// walks means the origin, the scale and the tracking are all right. An outline
/// that drifts off as they walk *is* the drift, made visible — no dashboard
/// needed, and no waiting for a number to come back from the server.
public enum Projection {

    /// Where a venue-frame point lands in the captured image, in pixels.
    ///
    /// Returns nil when the point is behind the camera. ARKit's camera looks
    /// down its own −Z, so "in front" means a negative z in camera coordinates —
    /// forgetting that projects everything behind you onto the screen as though
    /// it were ahead, mirrored.
    public static func project(venuePoint: SIMD3<Float>,
                               camera: Pose,
                               intrinsics: CameraIntrinsics) -> CGPoint? {
        let inCamera = camera.inverse.transform(point: venuePoint)
        // Depth along the viewing direction. Points at or behind the plane of
        // the lens have no image position at all.
        let depth = -inCamera.z
        guard depth > 0.001 else { return nil }

        let u = intrinsics.cx + intrinsics.fx * (inCamera.x / depth)
        // Image rows count downward while the camera's +Y is up.
        let v = intrinsics.cy - intrinsics.fy * (inCamera.y / depth)
        guard u.isFinite, v.isFinite else { return nil }
        return CGPoint(x: CGFloat(u), y: CGFloat(v))
    }

    /// Metres from the camera to a venue-frame point, along the viewing
    /// direction rather than straight-line — which is what decides whether it is
    /// in front, and what a depth map would report.
    public static func depth(of venuePoint: SIMD3<Float>, from camera: Pose) -> Float {
        -camera.inverse.transform(point: venuePoint).z
    }

    /// The four corners of a marker in the venue frame, in the order
    /// top-left, top-right, bottom-right, bottom-left as the printed image is
    /// read.
    ///
    /// Uses `MarkerConvention`: the image lies in the anchor's local x–z plane,
    /// +X along the width, and the image's up direction is local −Z.
    public static func corners(of marker: VenueMarker) -> [SIMD3<Float>]? {
        guard let pose = marker.pose, marker.physicalWidth > 0 else { return nil }
        let halfWidth = marker.physicalWidth / 2
        let halfHeight = (marker.physicalHeight ?? marker.physicalWidth) / 2
        let local: [SIMD3<Float>] = [
            SIMD3(-halfWidth, 0, -halfHeight),
            SIMD3(halfWidth, 0, -halfHeight),
            SIMD3(halfWidth, 0, halfHeight),
            SIMD3(-halfWidth, 0, halfHeight),
        ]
        return local.map { pose.transform(point: $0) }
    }

    /// A marker's outline in image pixels, or nil when any corner is behind the
    /// camera.
    ///
    /// All-or-nothing on purpose: drawing three of four corners produces a
    /// convincing wrong shape, and a wrong shape drawn confidently is exactly
    /// what this whole overlay exists to catch.
    public static func outline(of marker: VenueMarker,
                               camera: Pose,
                               intrinsics: CameraIntrinsics) -> [CGPoint]? {
        guard let corners = corners(of: marker) else { return nil }
        var points: [CGPoint] = []
        for corner in corners {
            guard let point = project(venuePoint: corner, camera: camera, intrinsics: intrinsics) else {
                return nil
            }
            points.append(point)
        }
        return points
    }

    /// Where the venue predicts a marker will appear, ready to draw.
    ///
    /// Not to be confused with `MarkerSighting`, which is ARKit reporting that
    /// it actually saw one. The whole point of the overlay is comparing the two.
    public struct MarkerProjection: Sendable, Equatable {
        public var markerID: String
        /// Image-space outline, in captured-image pixels.
        public var outline: [CGPoint]
        /// Metres to the marker centre.
        public var distance: Float
        /// Angle between the camera's view direction and the marker's normal, in
        /// degrees. Near 0 is head-on. Beyond about 60 ARKit stops detecting it,
        /// which is worth showing rather than leaving the operator guessing why
        /// nothing is locking.
        public var obliquityDegrees: Float

        public init(markerID: String, outline: [CGPoint], distance: Float, obliquityDegrees: Float) {
            self.markerID = markerID
            self.outline = outline
            self.distance = distance
            self.obliquityDegrees = obliquityDegrees
        }
    }

    /// Every marker in the venue that currently falls in front of the camera.
    public static func visibleMarkers(in venue: Venue,
                                      camera: Pose,
                                      intrinsics: CameraIntrinsics) -> [MarkerProjection] {
        venue.markers.compactMap { marker in
            guard let pose = marker.pose,
                  let outline = outline(of: marker, camera: camera, intrinsics: intrinsics)
            else { return nil }

            let toCamera = simd_normalize(camera.position - pose.position)
            let normal = pose.orientation.act(MarkerConvention.normal)
            // acos of the dot gives the angle between the marker's normal and
            // the direction it is being viewed from.
            let cosine = min(1, max(-1, simd_dot(normal, toCamera)))
            return MarkerProjection(markerID: marker.id,
                                    outline: outline,
                                    distance: simd_distance(camera.position, pose.position),
                                    obliquityDegrees: acos(cosine) * 180 / .pi)
        }
    }
}
