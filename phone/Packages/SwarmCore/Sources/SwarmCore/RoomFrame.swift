import Foundation
import simd

/// The hub's 2D room frame, and how a 3D pose gets into it.
///
/// **Room frame** (`room.json`, `web/phone.js`): metres on the floor plan.
/// `x` runs along the stage with 0 on the stage centre line, in
/// `[-width/2, width/2]`. `y` is 0 at the stage wall and grows toward the back
/// of the room. `heading` is degrees, 0 = facing the stage, clockwise seen from
/// above, so 90 = facing +x. `pitch` is degrees, positive = camera tilted up.
///
/// **Venue frame** (CLAUDE.md): +X east along the stage, +Y up, +Z out from the
/// stage. So with the stage wall on the venue's X axis the two line up directly:
/// `room.x = venue.x`, `room.y = venue.z`, and room heading is
/// `atan2(forward.x, −forward.z)` — the same angle as `Geometry.yaw`.
public enum RoomMath {
    /// Wraps into [0, 360).
    public static func wrap360(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// `a − b` wrapped into [−180, 180). Positive means `a` is clockwise of `b`.
    /// Mirrors `signedDiff` in `phone.js`.
    public static func signedDiff(_ a: Double, _ b: Double) -> Double {
        wrap360(a - b + 180) - 180
    }

    /// Room heading from one floor point to another. Mirrors `bearing_to` in the
    /// hub: `atan2(dx, −dy)`.
    public static func bearing(fromX x: Double, y: Double, toX tx: Double, y ty: Double) -> Double {
        wrap360(atan2(tx - x, -(ty - y)) * 180 / .pi)
    }
}

/// A pose as the hub wants it.
public struct RoomPose: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// nil when the camera points straight up or down and heading is undefined.
    public var heading: Double?
    public var pitch: Double

    public init(x: Double, y: Double, heading: Double?, pitch: Double) {
        self.x = x
        self.y = y
        self.heading = heading
        self.pitch = pitch
    }
}

/// A rigid 2D transform from a gravity-aligned 3D frame's floor plane into the
/// room frame. Used both for venue → room (from `venue.json`) and for
/// raw-ARKit-world → room (from a seat tap).
public struct RoomAlignment: Sendable, Equatable, Codable {
    /// Room coordinates of the source frame's origin.
    public var originX: Double
    public var originY: Double
    /// Added to a source-frame heading to get a room heading. Zero when the
    /// source frame's −Z points at the stage.
    public var yawDegrees: Double

    public init(originX: Double = 0, originY: Double = 0, yawDegrees: Double = 0) {
        self.originX = originX
        self.originY = originY
        self.yawDegrees = yawDegrees
    }

    /// Venue frame as CLAUDE.md defines it, with the primary marker on the
    /// stage centre line at the stage wall.
    public static let identity = RoomAlignment()

    public func project(_ pose: Pose) -> RoomPose {
        let yaw = yawDegrees * .pi / 180
        let px = Double(pose.position.x), pz = Double(pose.position.z)
        let x = originX + px * cos(yaw) - pz * sin(yaw)
        let y = originY + px * sin(yaw) + pz * cos(yaw)
        let f = pose.forward
        let flat = hypot(Double(f.x), Double(f.z))
        // Same cut-off as phone.js: pointing at the floor or ceiling has no heading.
        let heading: Double? = flat < 1e-3 ? nil
            : RoomMath.wrap360(atan2(Double(f.x), Double(-f.z)) * 180 / .pi + yawDegrees)
        let pitch = asin(min(1, max(-1, Double(f.y)))) * 180 / .pi
        return RoomPose(x: x, y: y, heading: heading, pitch: pitch)
    }

    /// Room floor point → source-frame point at the given height, for projecting
    /// pings into the camera view.
    public func unproject(x: Double, y: Double, height: Float = 0) -> SIMD3<Float> {
        let yaw = yawDegrees * .pi / 180
        let dx = x - originX, dy = y - originY
        return SIMD3<Float>(Float(dx * cos(yaw) + dy * sin(yaw)), height,
                            Float(-dx * sin(yaw) + dy * cos(yaw)))
    }

    /// The exact inverse of `project`: a room pose back to a full 3D camera pose
    /// at the given height. `project(unproject(p)) == p`.
    ///
    /// This lives here, next to the forward transform and next to its sign
    /// tests, rather than in whatever wants it, because **the yaw sign is not
    /// obvious and getting it wrong mirrors the room.** Room heading is measured
    /// clockwise seen from above; a simd rotation about venue +Y is right-handed
    /// and therefore counter-clockwise seen from above. So a room heading of `h`
    /// is a rotation of `−h`. `project` states the same fact the other way round
    /// as `atan2(f.x, −f.z)`.
    ///
    /// Pitch is applied about the camera's own right axis, after the yaw, so it
    /// tilts the camera rather than orbiting it — the same order
    /// `Geometry.yaw`'s decomposition assumes. A heading of nil means the pose
    /// is pointed straight up or down and there is nothing to invert.
    public func unproject(_ pose: RoomPose, height: Float) -> Pose? {
        guard let heading = pose.heading else { return nil }
        let yaw = Float((heading - yawDegrees) * .pi / 180)
        let pitch = Float(pose.pitch * .pi / 180)
        let orientation = simd_quatf(angle: -yaw, axis: VenueAxis.up)
            * simd_quatf(angle: pitch, axis: CameraAxis.right)
        return Pose(position: unproject(x: pose.x, y: pose.y, height: height),
                    orientation: orientation.unitOrIdentity)
    }
}

/// The fallback for when no marker is in sight: the operator taps where they are
/// standing on the floor plan, faces the stage, and confirms. Mirrors
/// `calibrateSlam()` in `phone.js`.
public enum SeatCalibration {
    /// The alignment that puts `rawPose` at `seat`, heading 0. Returns nil when
    /// the camera is pointing at the floor or ceiling, where "facing the stage"
    /// means nothing.
    public static func alignment(seat: HubSeat, facingStage rawPose: Pose) -> RoomAlignment? {
        let f = rawPose.forward
        guard hypot(Double(f.x), Double(f.z)) >= 1e-3 else { return nil }
        let rawHeading = atan2(Double(f.x), Double(-f.z)) * 180 / .pi
        var alignment = RoomAlignment(originX: 0, originY: 0, yawDegrees: -rawHeading)
        let at = alignment.project(rawPose)
        alignment.originX = seat.x - at.x
        alignment.originY = seat.y - at.y
        return alignment
    }
}

/// Decides which alignment is in force. `none → seat → marker`; a marker always
/// supersedes a seat tap, because after the first marker sighting ARKit's world
/// *is* the venue frame and the seat alignment describes a frame that no longer
/// exists.
public struct RoomAligner: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case none, seat, marker
    }

    public private(set) var source: Source = .none
    public private(set) var seat: HubSeat?
    private var seatAlignment: RoomAlignment?
    private let venueAlignment: RoomAlignment

    public init(venueAlignment: RoomAlignment = .identity) {
        self.venueAlignment = venueAlignment
    }

    public var alignment: RoomAlignment? {
        switch source {
        case .none: nil
        case .seat: seatAlignment
        case .marker: venueAlignment
        }
    }

    public mutating func setSeat(_ seat: HubSeat) {
        self.seat = seat
    }

    /// Returns false when there is no seat yet, the pose is unusable, or a
    /// marker already owns the alignment.
    @discardableResult
    public mutating func calibrateFacingStage(rawPose: Pose) -> Bool {
        guard source != .marker, let seat,
              let alignment = SeatCalibration.alignment(seat: seat, facingStage: rawPose) else {
            return false
        }
        seatAlignment = alignment
        source = .seat
        return true
    }

    public mutating func markerAcquired() {
        source = .marker
        seatAlignment = nil
    }

    /// ARKit threw its map away. Neither the venue frame nor the frame a seat
    /// tap was made in exists any more. The tapped spot itself is kept, so the
    /// operator only has to face the stage and confirm again.
    public mutating func invalidate() {
        source = .none
        seatAlignment = nil
    }

    public func project(_ pose: Pose) -> RoomPose? {
        alignment?.project(pose)
    }
}
