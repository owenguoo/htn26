import Foundation
import simd

/// One frame's worth of operator input, from a drag and a joystick puck.
///
/// Pure deflections and deltas — no points, no clock, no gestures. The SwiftUI
/// layer converts touches into this and nothing else, which is what keeps the
/// only untestable part of the drive source down to "did the drag reach the
/// right view".
public struct DriveInput: Sendable, Equatable {
    /// Points of horizontal drag since the last step. Right is positive.
    public var yawPoints: Double
    /// Points of vertical drag since the last step. **Up the screen is
    /// positive**, which the view has to flip out of UIKit's downward y.
    public var pitchPoints: Double
    /// Joystick deflection in −1…1. `x` strafes right, `y` walks forward.
    public var walk: SIMD2<Double>
    /// A double-tap: snap the pitch back to level.
    public var levelPitch: Bool

    public init(yawPoints: Double = 0, pitchPoints: Double = 0,
                walk: SIMD2<Double> = .zero, levelPitch: Bool = false) {
        self.yawPoints = yawPoints
        self.pitchPoints = pitchPoints
        self.walk = walk
        self.levelPitch = levelPitch
    }

    public static let idle = DriveInput()
}

/// Where the operator is allowed to walk.
///
/// **These come from the hub's `welcome`, not from `venue.json`.** `venue.json`
/// describes markers and has no room dimensions at all; `room.json` has the
/// width and depth and arrives as `OverlayState.room`. The view model forwards
/// it when it changes, which is why `PoseProvider` did not have to grow a
/// room-shaped parameter it has no business carrying.
public struct DriveBounds: Sendable, Equatable {
    public var width: Double
    public var depth: Double
    /// How far off each wall to stop. Cosmetic — the mini-map already draws
    /// outside-the-room as a different floor — but walking through a wall while
    /// judging a HUD is a distraction.
    public var inset: Double
    /// Venue +Y of the camera. Markers in `venue.json` sit at y ≈ 1.55–1.6, so
    /// 1.5 puts them at eye level rather than underfoot.
    public var eyeHeight: Double

    public init(width: Double = 20, depth: Double = 15, inset: Double = 0.25,
                eyeHeight: Double = 1.5) {
        self.width = width
        self.depth = depth
        self.inset = inset
        self.eyeHeight = eyeHeight
    }

    /// `room.json`'s numbers, for before `welcome` arrives.
    public static let roomJSON = DriveBounds()
}

/// Drag-to-look, hold-to-walk, integrated in the room frame.
///
/// A plain value with no clock: `step(dt:input:)` takes the time step, which is
/// what makes a ten-thousand-frame stability sweep cost microseconds and makes
/// two models fed the same inputs agree bit for bit. `DrivePoseProvider` owns
/// the clock; this owns the maths.
///
/// It works in the **room frame** — heading clockwise from the stage, pitch
/// positive up, metres on the floor plan — and hands the result to
/// `RoomAlignment.unproject` to become a venue-frame `Pose`. Doing the geometry
/// in room terms is the point: the numbers in this file are the numbers on the
/// mini-map, so a mirrored drive source is visible the instant you drag right
/// and the dot goes left.
public struct DriveMotionModel: Sendable, Equatable {
    public struct Tuning: Sendable, Equatable {
        /// A 390 pt swipe — one screen width — turns 117°, so a full turn is
        /// about three swipes. Enough to sweep a room without flinging past it.
        public var yawDegreesPerPoint: Double = 0.30
        /// A 400 pt drag covers the whole ±85° range in one flick.
        public var pitchDegreesPerPoint: Double = 0.25
        /// `project` returns `heading = nil` past about 89.94°, and nobody tilts
        /// a phone further than this anyway. Staying short of it keeps the
        /// compass tape defined at the clamp, which is where someone testing the
        /// HUD will park it.
        public var pitchClampDegrees: Double = 85
        /// Drag up ⇒ look up. One place to flip it if it reads wrong.
        public var invertPitch = false
        /// First-order smoothing toward the drag target, `1 − exp(−dt/τ)`.
        /// Without it the compass tape judders at 60 Hz; much more than this and
        /// the phone feels like it is on a rope.
        public var lookTau: Double = 0.06
        /// Normal walking pace.
        public var forwardSpeed: Double = 1.4
        public var strafeSpeed: Double = 1.0
        /// People back up slower than they walk.
        public var reverseSpeed: Double = 0.8
        /// Velocity ramps in and out over this, both ways, so starting and
        /// stopping read as walking rather than teleporting. Not momentum: let
        /// go and it stops.
        public var walkTau: Double = 0.25

        public init() {}
    }

    public var tuning: Tuning
    public private(set) var bounds: DriveBounds

    /// Room metres.
    public private(set) var x: Double
    public private(set) var y: Double
    /// Where the drag has asked to be, before smoothing.
    private var targetHeading: Double
    private var targetPitch: Double
    /// Where the camera actually is.
    public private(set) var heading: Double
    public private(set) var pitch: Double
    /// Room metres per second, smoothed.
    private var velocity: SIMD2<Double> = .zero
    /// Metres walked, for `consumeMotionSinceLastQuery`.
    public private(set) var distanceTravelled: Double = 0

    public init(bounds: DriveBounds = .roomJSON, tuning: Tuning = Tuning(),
                start: RoomPose? = nil) {
        self.tuning = tuning
        self.bounds = bounds
        // Middle of the room, a third of the way back, facing the stage — which
        // puts the stage marker and the stage band in shot on the first frame.
        let pose = start ?? RoomPose(x: 0, y: max(bounds.inset, bounds.depth / 3),
                                     heading: 0, pitch: 0)
        self.x = pose.x
        self.y = pose.y
        self.heading = pose.heading ?? 0
        self.pitch = pose.pitch
        self.targetHeading = self.heading
        self.targetPitch = self.pitch
        clampPosition()
    }

    public mutating func setBounds(_ newBounds: DriveBounds) {
        bounds = newBounds
        clampPosition()
    }

    public var roomPose: RoomPose {
        RoomPose(x: x, y: y, heading: RoomMath.wrap360(heading), pitch: pitch)
    }

    /// Advances by `dt` seconds under `input`.
    ///
    /// Non-finite or non-positive `dt` is ignored rather than propagated: one
    /// NaN here becomes a NaN position, which becomes a `slam` message the hub
    /// cannot parse and a dot that never comes back.
    public mutating func step(dt: Double, input: DriveInput) {
        guard dt.isFinite, dt > 0 else { return }

        if input.levelPitch {
            targetPitch = 0
        } else {
            let sign: Double = tuning.invertPitch ? -1 : 1
            targetPitch += sign * input.pitchPoints * tuning.pitchDegreesPerPoint
        }
        targetHeading += input.yawPoints * tuning.yawDegreesPerPoint
        targetPitch = min(tuning.pitchClampDegrees, max(-tuning.pitchClampDegrees, targetPitch))

        // Smooth toward the drag, on the shortest arc so a wrap through 360 does
        // not spin the compass the long way round.
        let lookAlpha = 1 - exp(-dt / max(tuning.lookTau, 1e-6))
        heading = RoomMath.wrap360(heading + RoomMath.signedDiff(targetHeading, heading) * lookAlpha)
        targetHeading = RoomMath.wrap360(targetHeading)
        pitch += (targetPitch - pitch) * lookAlpha

        // Velocity-mapped walking: hold the stick and keep going. Position
        // mapping would need ~750 pt of travel to cross a 15 m room.
        let forward = clampUnit(input.walk.y)
        let strafe = clampUnit(input.walk.x)
        let wanted = SIMD2<Double>(strafe * tuning.strafeSpeed,
                                   forward >= 0 ? forward * tuning.forwardSpeed
                                                : forward * tuning.reverseSpeed)
        let walkAlpha = 1 - exp(-dt / max(tuning.walkTau, 1e-6))
        velocity += (wanted - velocity) * walkAlpha

        // Body-relative to room-relative. Heading 0 faces the stage, which is
        // −y in the room frame (y grows away from the stage), and +90 faces +x.
        let radians = heading * .pi / 180
        let dx = (velocity.y * sin(radians) + velocity.x * cos(radians)) * dt
        let dy = (-velocity.y * cos(radians) + velocity.x * sin(radians)) * dt
        let before = SIMD2<Double>(x, y)
        x += dx
        y += dy
        clampPosition()
        distanceTravelled += simd_distance(before, SIMD2<Double>(x, y))
    }

    /// Metres walked since the last call. Same contract as
    /// `PoseProvider.consumeMotionSinceLastQuery`: a yes/no signal about whether
    /// this person moved, never a position.
    public mutating func consumeDistance() -> Double {
        defer { distanceTravelled = 0 }
        return distanceTravelled
    }

    private func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }

    private mutating func clampPosition() {
        let halfWidth = max(0, bounds.width / 2 - bounds.inset)
        let minY = min(bounds.inset, max(0, bounds.depth / 2))
        let maxY = max(minY, bounds.depth - bounds.inset)
        x = x.isFinite ? min(halfWidth, max(-halfWidth, x)) : 0
        y = y.isFinite ? min(maxY, max(minY, y)) : minY
    }
}
