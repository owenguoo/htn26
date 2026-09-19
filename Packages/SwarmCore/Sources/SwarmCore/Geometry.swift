import Foundation
import simd

/// Coordinate conventions, fixed by CLAUDE.md. Do not deviate.
///
/// **ARKit camera**: looks down −Z, +Y up, +X right. Right-handed.
/// **Venue frame**: +X east along the stage, +Y up, +Z out from the stage.
///   Origin on the floor below the centre of the primary marker.
///
/// Once `setWorldOrigin(relativeTransform:)` has been called with the transform
/// `Calibration` computes, ARKit's world frame *is* the venue frame, so poses
/// coming out of `PoseProvider` need no further conversion. Everything in this
/// file therefore operates in one frame at a time; the only cross-frame
/// operation in the system is `Calibration.worldOriginTransform`.
public enum VenueAxis {
    /// East along the stage.
    public static let x = SIMD3<Float>(1, 0, 0)
    /// Up, opposed to gravity. Fixed by `worldAlignment = .gravity`.
    public static let up = SIMD3<Float>(0, 1, 0)
    /// Out from the stage, toward the audience.
    public static let z = SIMD3<Float>(0, 0, 1)
}

/// The direction an ARKit camera faces in its own local frame: down −Z.
public enum CameraAxis {
    public static let forward = SIMD3<Float>(0, 0, -1)
    public static let up = SIMD3<Float>(0, 1, 0)
    public static let right = SIMD3<Float>(1, 0, 0)
}

/// A rigid transform: position in metres plus orientation, in a stated frame.
public struct Pose: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var orientation: simd_quatf

    public init(position: SIMD3<Float>, orientation: simd_quatf) {
        self.position = position
        self.orientation = orientation
    }

    public static let identity = Pose(position: .zero, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))

    /// Builds a pose from a column-major 4x4 transform, re-orthonormalising the
    /// rotation block. ARKit transforms accumulate enough numerical drift over a
    /// long session that `simd_quatf(matrix)` on a raw transform can produce a
    /// non-unit quaternion.
    public init(matrix: simd_float4x4) {
        self.position = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        self.orientation = Geometry.orientation(of: matrix)
    }

    public var matrix: simd_float4x4 {
        var m = simd_float4x4(orientation)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    /// The direction the camera is looking, in the pose's frame.
    public var forward: SIMD3<Float> { orientation.act(CameraAxis.forward) }

    public var up: SIMD3<Float> { orientation.act(CameraAxis.up) }

    public var right: SIMD3<Float> { orientation.act(CameraAxis.right) }

    public var inverse: Pose {
        let inverseRotation = orientation.inverse
        return Pose(position: -inverseRotation.act(position), orientation: inverseRotation)
    }

    /// Composition: `a * b` applies `b` first, then `a` — matching matrix order.
    public static func * (a: Pose, b: Pose) -> Pose {
        Pose(position: a.position + a.orientation.act(b.position),
             orientation: (a.orientation * b.orientation).normalized)
    }

    public func transform(point: SIMD3<Float>) -> SIMD3<Float> {
        position + orientation.act(point)
    }
}

public enum Geometry {
    /// Extracts a unit quaternion from a transform whose rotation block may have
    /// drifted off the orthonormal manifold, and whose scale may not be 1.
    public static func orientation(of matrix: simd_float4x4) -> simd_quatf {
        simd_quatf(orthonormalRotation(of: matrix)).normalized
    }

    /// Gram-Schmidt on the upper-left 3x3. Returns identity for a degenerate
    /// (zero-scale) block rather than producing NaNs.
    public static func orthonormalRotation(of matrix: simd_float4x4) -> simd_float3x3 {
        let c0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let c1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let c2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        guard simd_length(c0) > 1e-6, simd_length(c1) > 1e-6, simd_length(c2) > 1e-6 else {
            return matrix_identity_float3x3
        }
        let x = simd_normalize(c0)
        var y = c1 - simd_dot(c1, x) * x
        guard simd_length(y) > 1e-6 else { return matrix_identity_float3x3 }
        y = simd_normalize(y)
        // z is forced to cross(x, y) so the result is always a proper rotation
        // (determinant +1). ARKit transforms are right-handed, so this agrees
        // with c2; a mirrored input gets the nearest true rotation rather than a
        // quaternion built from a reflection, which is meaningless.
        let z = simd_cross(x, y)
        return simd_float3x3(columns: (x, y, z))
    }

    /// Absolute angle in radians between two orientations, always in [0, π].
    public static func angle(between a: simd_quatf, and b: simd_quatf) -> Float {
        let dot = abs(simd_dot(a.normalized.vector, b.normalized.vector))
        return 2 * acos(min(1, max(-1, dot)))
    }

    /// Straight-line distance in metres.
    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(a, b)
    }

    /// Rotation about venue +Y, in radians, measured from venue −Z toward +X.
    public static func yaw(of orientation: simd_quatf) -> Float {
        let f = orientation.act(CameraAxis.forward)
        let horizontal = SIMD3<Float>(f.x, 0, f.z)
        guard simd_length(horizontal) > 1e-6 else { return 0 }
        return atan2(horizontal.x, -horizontal.z)
    }

    /// Shortest-arc interpolation. `t` is clamped to [0, 1].
    public static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        simd_slerp(a.normalized, b.normalized, min(1, max(0, t))).normalized
    }

    /// Signed horizontal bearing from where the camera is looking to a venue-frame
    /// target, in radians. Positive means the target is to the camera's right, so
    /// the on-screen arrow rotates clockwise by this angle. Returns nil when the
    /// target is directly overhead or underfoot, where bearing is undefined.
    ///
    /// This drives the "look left" directive, so the sign convention matters more
    /// than almost anything else in this file: getting it backwards makes every
    /// operator turn the wrong way.
    public static func relativeBearing(from camera: Pose, to target: SIMD3<Float>) -> Float? {
        let toTarget = target - camera.position
        let flatTarget = SIMD3<Float>(toTarget.x, 0, toTarget.z)
        guard simd_length(flatTarget) > 1e-4 else { return nil }
        let f = camera.forward
        let flatForward = SIMD3<Float>(f.x, 0, f.z)
        guard simd_length(flatForward) > 1e-4 else { return nil }
        let a = simd_normalize(flatForward)
        let b = simd_normalize(flatTarget)
        // Cross product about +Y gives the sign; dot gives the magnitude.
        let cross = simd_cross(a, b).y
        return atan2(-cross, simd_dot(a, b))
    }

    /// Elevation from the camera's horizontal plane up to the target, in radians.
    public static func relativeElevation(from camera: Pose, to target: SIMD3<Float>) -> Float? {
        let toTarget = target - camera.position
        let horizontal = simd_length(SIMD3<Float>(toTarget.x, 0, toTarget.z))
        guard simd_length(toTarget) > 1e-4 else { return nil }
        return atan2(toTarget.y, horizontal)
    }
}

extension simd_quatf {
    /// `simd_normalize` on a zero quaternion yields NaN; fall back to identity.
    var normalized: simd_quatf {
        let length = simd_length(vector)
        guard length > 1e-9 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatf(vector: vector / length)
    }
}
