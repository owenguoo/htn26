import Foundation
import simd
import Testing
@testable import SwarmCore

/// Drag-to-look, hold-to-walk: the Simulator's stand-in for ARKit.
///
/// The model takes `dt` and holds no clock, so all of this runs in simulated
/// time. The sign tests matter most and for the same reason the room-frame ones
/// do — a drive source that mirrors the room makes every *other* sign look
/// wrong, and the person debugging it goes looking in `RoomFrame.swift`.
@Suite("Drive motion: the Simulator's pose source")
struct DriveMotionTests {

    private func model(_ start: RoomPose? = nil, bounds: DriveBounds = .roomJSON) -> DriveMotionModel {
        DriveMotionModel(bounds: bounds, start: start ?? RoomPose(x: 0, y: 5, heading: 0, pitch: 0))
    }

    /// Runs `seconds` of simulated time at 60 Hz under a constant input.
    private func run(_ model: inout DriveMotionModel, seconds: Double, input: DriveInput,
                     hz: Double = 60) {
        let dt = 1 / hz
        for _ in 0..<Int((seconds * hz).rounded()) { model.step(dt: dt, input: input) }
    }

    /// Settles the look smoothing so a single drag's full effect has landed.
    ///
    /// The smoothing is first-order, so it approaches its target and never
    /// arrives. Two seconds at τ = 60 ms leaves `exp(-33)` of the step — below
    /// anything worth asserting about, and still microseconds of simulated time.
    private func settleLook(_ model: inout DriveMotionModel) {
        run(&model, seconds: 2, input: .idle)
    }

    // MARK: - Looking

    /// Dragging right turns clockwise, which is what "heading grows clockwise"
    /// means. Backwards, and the compass tape scrolls the wrong way while the
    /// banner still says turn right.
    @Test func draggingRightIncreasesHeading() {
        var m = model()
        m.step(dt: 1 / 60, input: DriveInput(yawPoints: 200))
        settleLook(&m)
        #expect(m.heading > 0 && m.heading < 180, "dragging right gave heading \(m.heading)")
        #expect(isClose(m.heading, 200 * 0.30, within: 0.5), "0.30°/pt: 200 pt should be 60°")

        var left = model()
        left.step(dt: 1 / 60, input: DriveInput(yawPoints: -200))
        settleLook(&left)
        #expect(isClose(RoomMath.signedDiff(left.heading, -60), 0, within: 0.5))
    }

    /// Stated in venue terms, so a consistently mirrored pair of transforms
    /// cannot pass: from heading 0 (facing the stage, venue −Z), +90° must face
    /// venue +x.
    @Test func ninetyDegreesClockwiseFromTheStageFacesVenuePlusX() throws {
        var m = model()
        m.step(dt: 1 / 60, input: DriveInput(yawPoints: 300))   // 90°
        settleLook(&m)
        let pose = try #require(RoomAlignment.identity.unproject(m.roomPose, height: 1.5))
        #expect(isClose(pose.forward.x, 1, within: 0.01),
                "dragging right from the stage faced venue \(pose.forward)")
        #expect(isClose(pose.forward.z, 0, within: 0.01))
    }

    @Test func draggingUpLooksUpAndTheClampHolds() {
        var m = model()
        // Far more drag than the range: 10 000 pt at 0.25°/pt is 2500°.
        m.step(dt: 1 / 60, input: DriveInput(pitchPoints: 10_000))
        settleLook(&m)
        #expect(isClose(m.pitch, 85, within: 1e-3), "clamped to \(m.pitch), not 85")

        var down = model()
        down.step(dt: 1 / 60, input: DriveInput(pitchPoints: -10_000))
        settleLook(&down)
        #expect(isClose(down.pitch, -85, within: 1e-3))

        // Heading must still be defined at both clamps, or the compass tape
        // vanishes exactly where someone testing the HUD will park it.
        #expect(m.roomPose.heading != nil)
        #expect(down.roomPose.heading != nil)
        #expect(RoomAlignment.identity.unproject(m.roomPose, height: 1.5) != nil)
        #expect(RoomAlignment.identity.unproject(down.roomPose, height: 1.5) != nil)
    }

    @Test func doubleTappingLevelsThePitch() {
        var m = model()
        m.step(dt: 1 / 60, input: DriveInput(pitchPoints: 300))
        settleLook(&m)
        #expect(m.pitch > 70)
        m.step(dt: 1 / 60, input: DriveInput(levelPitch: true))
        settleLook(&m)
        #expect(isClose(m.pitch, 0, within: 1e-3))
    }

    /// Five turns each way must land exactly where the arithmetic says, in
    /// [0, 360), with nothing accumulated in the wrap.
    @Test func yawWrapsWithoutDrift() {
        for turns in [-5.0, -1.0, 1.0, 5.0] {
            var m = model()
            // 360° is 1200 pt at 0.30°/pt.
            m.step(dt: 1 / 60, input: DriveInput(yawPoints: turns * 1200 + 100))
            settleLook(&m)
            #expect(m.heading >= 0 && m.heading < 360, "heading left the range: \(m.heading)")
            #expect(isClose(RoomMath.signedDiff(m.heading, 30), 0, within: 0.01),
                    "\(turns) turns plus 30° gave \(m.heading)")
        }
    }

    // MARK: - Walking

    /// Heading 90 faces venue +x, so a second of full forward walks +1.4 m in x
    /// and nowhere in y.
    @Test func walkingIntegratesAlongTheHeading() {
        var m = model(RoomPose(x: 0, y: 5, heading: 90, pitch: 0))
        // Let the ramp settle first, then measure a clean second.
        run(&m, seconds: 3, input: DriveInput(walk: SIMD2(0, 1)))
        let x0 = m.x, y0 = m.y
        run(&m, seconds: 1, input: DriveInput(walk: SIMD2(0, 1)))
        #expect(isClose(m.x - x0, 1.4, within: 0.02), "walked \(m.x - x0) m in a second")
        #expect(isClose(m.y - y0, 0, within: 0.01))
    }

    /// Heading 0 faces the stage, and the stage is at y = 0, so walking forward
    /// must *decrease* y. Getting this backwards walks the operator out of the
    /// back wall while the HUD says they are approaching the stage.
    @Test func walkingForwardFacingTheStageDecreasesY() {
        var m = model(RoomPose(x: 0, y: 10, heading: 0, pitch: 0))
        run(&m, seconds: 2, input: DriveInput(walk: SIMD2(0, 1)))
        #expect(m.y < 10, "facing the stage and walking forward raised y to \(m.y)")
        #expect(isClose(m.x, 0, within: 0.01))
    }

    /// Facing the stage, the operator's right hand is venue +x — the same fact
    /// `RoomFrameTests.turningRightIsClockwise` states about heading.
    @Test func strafingRightFacingTheStageIncreasesX() {
        var m = model(RoomPose(x: 0, y: 5, heading: 0, pitch: 0))
        run(&m, seconds: 2, input: DriveInput(walk: SIMD2(1, 0)))
        #expect(m.x > 0.5, "strafing right moved x to \(m.x)")
        #expect(isClose(m.y, 5, within: 0.05))
    }

    @Test func backingUpIsSlowerThanWalking() {
        var forward = model(RoomPose(x: 0, y: 7, heading: 90, pitch: 0))
        var back = model(RoomPose(x: 0, y: 7, heading: 90, pitch: 0))
        run(&forward, seconds: 3, input: DriveInput(walk: SIMD2(0, 1)))
        run(&back, seconds: 3, input: DriveInput(walk: SIMD2(0, -1)))
        #expect(forward.x > 0 && back.x < 0)
        #expect(abs(back.x) < abs(forward.x), "reverse was not slower")
    }

    /// Velocity mapping, not position mapping: hold the stick and keep going.
    /// Position mapping would need about 750 pt of travel to cross a 15 m room.
    @Test func holdingTheStickKeepsWalking() {
        var m = model(RoomPose(x: 0, y: 14, heading: 0, pitch: 0))
        run(&m, seconds: 1, input: DriveInput(walk: SIMD2(0, 1)))
        let afterOne = m.y
        run(&m, seconds: 1, input: DriveInput(walk: SIMD2(0, 1)))
        #expect(m.y < afterOne - 1.0, "the second second of holding went nowhere")
    }

    /// Letting go stops within the ramp. Not momentum — a coasting operator is
    /// impossible to place on a mini-map by hand.
    @Test func lettingGoStops() {
        var m = model(RoomPose(x: 0, y: 10, heading: 90, pitch: 0))
        run(&m, seconds: 2, input: DriveInput(walk: SIMD2(0, 1)))
        run(&m, seconds: 2, input: .idle)
        let settled = m.x
        run(&m, seconds: 2, input: .idle)
        #expect(isClose(m.x, settled, within: 0.01), "still drifting: \(m.x - settled) m")
    }

    /// A stick returning through zero must not produce motion, and a dead
    /// centre must produce none at all.
    @Test func aCentredStickDoesNothing() {
        var m = model(RoomPose(x: 2, y: 6, heading: 45, pitch: 0))
        run(&m, seconds: 5, input: DriveInput(walk: .zero))
        #expect(m.x == 2 && m.y == 6)
        #expect(m.consumeDistance() == 0)
    }

    // MARK: - Bounds

    /// A minute of full forward into each wall stops at the inset and never
    /// passes it. `room.json` is 20 × 15.
    @Test func everyWallHolds() {
        let bounds = DriveBounds(width: 20, depth: 15)
        let cases: [(Double, String)] = [(0, "stage wall"), (90, "+x wall"),
                                         (180, "back wall"), (270, "−x wall")]
        for (heading, name) in cases {
            var m = model(RoomPose(x: 0, y: 7, heading: heading, pitch: 0), bounds: bounds)
            run(&m, seconds: 60, input: DriveInput(walk: SIMD2(0, 1)))
            #expect(m.x.isFinite && m.y.isFinite, "\(name): position went non-finite")
            #expect(m.x >= -9.75 - 1e-9 && m.x <= 9.75 + 1e-9, "\(name): x = \(m.x)")
            #expect(m.y >= 0.25 - 1e-9 && m.y <= 14.75 + 1e-9, "\(name): y = \(m.y)")
        }
    }

    /// Bounds arrive from the hub's `welcome`, after the operator is already
    /// walking around in the 20 × 15 default. A smaller room must pull them in.
    @Test func newBoundsFromTheHubPullTheOperatorInside() {
        var m = model(RoomPose(x: 0, y: 7, heading: 90, pitch: 0))
        run(&m, seconds: 20, input: DriveInput(walk: SIMD2(0, 1)))
        #expect(m.x > 5)
        m.setBounds(DriveBounds(width: 6, depth: 4))
        #expect(m.x <= 2.75 + 1e-9, "x stayed at \(m.x) in a 6 m room")
        #expect(m.y <= 3.75 + 1e-9)
    }

    // MARK: - Robustness

    /// Ten thousand steps of pseudo-random input. Cheap, and it catches a sign
    /// error in the `1 − exp(−dt/τ)` smoothing that a single-step test cannot.
    @Test func thousandsOfRandomStepsStayFiniteAndInside() {
        var generator = SeededGenerator(seed: 0xD21E)
        var m = model(bounds: DriveBounds(width: 20, depth: 15))
        for _ in 0..<10_000 {
            let input = DriveInput(yawPoints: Double.random(in: -60...60, using: &generator),
                                   pitchPoints: Double.random(in: -60...60, using: &generator),
                                   walk: SIMD2(Double.random(in: -1...1, using: &generator),
                                               Double.random(in: -1...1, using: &generator)),
                                   levelPitch: Int.random(in: 0..<200, using: &generator) == 0)
            m.step(dt: 1 / 60, input: input)
            #expect(m.x.isFinite && m.y.isFinite && m.heading.isFinite && m.pitch.isFinite)
        }
        #expect(m.heading >= 0 && m.heading < 360)
        #expect(abs(m.pitch) <= 85 + 1e-6)
        #expect(m.x >= -9.75 - 1e-9 && m.x <= 9.75 + 1e-9)
        #expect(m.y >= 0.25 - 1e-9 && m.y <= 14.75 + 1e-9)
    }

    /// Two models fed the same `(dt, input)` sequence agree exactly. This is
    /// what forces the model to take `dt` rather than read a clock, which is in
    /// turn what makes every test above cost microseconds.
    @Test func theModelIsDeterministic() {
        var generator = SeededGenerator(seed: 99)
        let inputs = (0..<500).map { _ in
            DriveInput(yawPoints: Double.random(in: -40...40, using: &generator),
                       pitchPoints: Double.random(in: -40...40, using: &generator),
                       walk: SIMD2(Double.random(in: -1...1, using: &generator),
                                   Double.random(in: -1...1, using: &generator)))
        }
        var a = model(), b = model()
        for input in inputs {
            a.step(dt: 1 / 60, input: input)
            b.step(dt: 1 / 60, input: input)
        }
        #expect(a == b)
    }

    /// A NaN or a zero `dt` — a dropped frame, a clock that went backwards —
    /// must not become a NaN position, a `slam` the hub cannot parse and a dot
    /// that never comes back.
    @Test func aBadTimeStepIsIgnoredNotPropagated() {
        var m = model(RoomPose(x: 1, y: 6, heading: 45, pitch: 10))
        let before = m
        m.step(dt: .nan, input: DriveInput(yawPoints: 100, walk: SIMD2(0, 1)))
        m.step(dt: 0, input: DriveInput(yawPoints: 100, walk: SIMD2(0, 1)))
        m.step(dt: -1, input: DriveInput(yawPoints: 100, walk: SIMD2(0, 1)))
        #expect(m == before)

        // And a stick reading NaN, which a gesture recogniser can produce on a
        // zero-length drag.
        m.step(dt: 1 / 60, input: DriveInput(walk: SIMD2(.nan, .nan)))
        #expect(m.x.isFinite && m.y.isFinite)
    }

    @Test func distanceIsAccumulatedAndConsumedOnce() {
        var m = model(RoomPose(x: 0, y: 10, heading: 90, pitch: 0))
        run(&m, seconds: 3, input: DriveInput(walk: SIMD2(0, 1)))
        let walked = m.consumeDistance()
        #expect(walked > 2 && walked < 5, "walked \(walked) m in three seconds")
        #expect(m.consumeDistance() == 0, "the same metres were reported twice")
    }
}
