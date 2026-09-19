import Foundation
import simd

/// A camera pose as the session emits it: full 6DoF, with everything needed to
/// decide whether to trust it.
///
/// The hub's `slam` message only has room for x, y, heading and pitch, so this
/// is no longer what goes on the wire — `RoomAlignment` projects it down, and the
/// whole of it rides in the 1 Hz `debug` blob for anything that wants 6DoF.
public struct PoseUpdate: Sendable, Equatable, Codable {
    public var deviceID: String
    /// Seconds on whatever clock the session was given. On the hub path the
    /// clock is unsynchronised, so this equals `deviceTimestamp`; the hub does
    /// its own offset estimate from `pong.tp`.
    public var serverTimestamp: Double
    /// The raw `CACurrentMediaTime()` value, carried for debugging only. It is
    /// per-device uptime and comparing it across phones is meaningless.
    public var deviceTimestamp: Double
    /// Metres, venue frame: +X east along the stage, +Y up, +Z out from the stage.
    public var position: [Float]
    /// Venue frame, ordered x, y, z, w.
    public var quaternion: [Float]
    /// `TrackingQuality.wireValue`, e.g. "normal" or "limited.relocalizing".
    public var trackingState: String
    /// 0…1. Decays while tracking is degraded.
    public var confidence: Float
    /// Seconds since the last accepted marker correction; nil if never corrected,
    /// which means this pose's origin is arbitrary and the server must not fuse it.
    public var lastCorrectionAge: Double?
    /// Which marker last corrected this device.
    public var lastCorrectionMarker: String?
    /// Set when the pose is older than the staleness limit, so the dashboard
    /// greys the cone rather than drawing it confidently in the wrong place.
    public var stale: Bool
    public var seq: UInt64
    /// False before any marker has been seen (or after ARKit threw its map
    /// away): the pose is in ARKit's arbitrary start-up frame. Only a seat-tap
    /// alignment can place such a pose in the room.
    public var inVenueFrame: Bool

    public init(deviceID: String, serverTimestamp: Double, deviceTimestamp: Double,
                position: [Float], quaternion: [Float], trackingState: String, confidence: Float,
                lastCorrectionAge: Double?, lastCorrectionMarker: String?, stale: Bool, seq: UInt64,
                inVenueFrame: Bool = true) {
        self.deviceID = deviceID
        self.serverTimestamp = serverTimestamp
        self.deviceTimestamp = deviceTimestamp
        self.position = position
        self.quaternion = quaternion
        self.trackingState = trackingState
        self.confidence = confidence
        self.lastCorrectionAge = lastCorrectionAge
        self.lastCorrectionMarker = lastCorrectionMarker
        self.stale = stale
        self.seq = seq
        self.inVenueFrame = inVenueFrame
    }
}

// MARK: - Conversion

extension PoseUpdate {
    /// The pose this update carries, or nil if the arrays are
    /// malformed. Never force-unwraps a short array off the wire.
    public var venuePose: Pose? {
        guard position.count == 3, quaternion.count == 4 else { return nil }
        return Pose(position: SIMD3<Float>(position[0], position[1], position[2]),
                    orientation: simd_quatf(ix: quaternion[0], iy: quaternion[1],
                                            iz: quaternion[2], r: quaternion[3]))
    }
}

extension Pose {
    public var wirePosition: [Float] { [position.x, position.y, position.z] }
    /// Ordered x, y, z, w.
    public var wireQuaternion: [Float] {
        let q = orientation.unitOrIdentity
        return [q.imag.x, q.imag.y, q.imag.z, q.real]
    }
}
