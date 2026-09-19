import Foundation
import simd
import Testing
@testable import SwarmCore

/// "Look up" / "look down" — the vertical half of a directional cue.
///
/// This exists nowhere else in the system: `swarm/` models the room as a 2D
/// floor plan and emits no elevation of any kind, and the only pitch-aware
/// string in the hub or in `web/phone.js` is "Hold your phone up". So the sign
/// convention here has no upstream to check against, which is exactly the
/// situation `RoomFrameTests` guards against for heading: a flipped sign sends
/// every operator looking at the ceiling while the candidate is at their feet,
/// and nothing on screen tells you which way is right.
@Suite("Elevation cue: look up, look down")
struct ElevationCueTests {

    /// Room heading `h`, camera tilted `pitch` degrees above horizontal.
    private func facing(_ h: Double, pitch: Double, at position: SIMD3<Float> = [0, 1.5, 5]) -> Pose {
        let yaw = simd_quatf(angle: -Float(h * .pi / 180), axis: VenueAxis.up)
        let tilt = simd_quatf(angle: Float(pitch * .pi / 180), axis: CameraAxis.right)
        return Pose(position: position, orientation: yaw * tilt)
    }

    private func diagnostics() -> SessionDiagnostics {
        var value = SessionDiagnostics()
        value.state = .tracking
        value.quality = .normal
        value.confidence = 0.95
        value.isStale = false
        value.lastCorrectionAge = 2
        return value
    }

    private func tick(_ model: inout OverlayModel, pose: Pose, now: Double) {
        model.update(pose: pose, alignment: .identity, source: .marker, intrinsics: nil,
                     diagnostics: diagnostics(), transport: .init(), transportState: .connected, now: now)
    }

    /// A `go` directive to a spot `distance` metres away at room heading 0, with
    /// the operator facing it and tilted `pitch` degrees.
    private func state(pitch: Double, distance: Double? = 9, heading: Double = 0,
                       kind: String = "go") -> OverlayState {
        var model = OverlayModel()
        model.apply(.guideHeading(kind: kind, sector: "back row", heading: 0, distance: distance,
                                  untilMs: 90_000), heading: nil, now: 0)
        tick(&model, pose: facing(heading, pitch: pitch), now: 0.1)
        return model.state
    }

    // MARK: - The sign

    /// The one that matters. The phone is pointed at the ceiling; the target is
    /// out in front on the floor. The only correct instruction is *down*.
    @Test func pointedAtTheCeilingTheCueSaysLookDown() throws {
        let cue = try #require(state(pitch: 60).elevation)
        #expect(!cue.isUp, "pointed 60° up at a target 9 m away, the cue said look up")
        #expect(cue.neededDegrees < 0)
        #expect(cue.text.hasPrefix("Look down"))
    }

    /// And the mirror image: pointed at the floor, the cue says up.
    @Test func pointedAtTheFloorTheCueSaysLookUp() throws {
        let cue = try #require(state(pitch: -60).elevation)
        #expect(cue.isUp, "pointed 60° down at a target 9 m away, the cue said look down")
        #expect(cue.neededDegrees > 0)
        #expect(cue.text.hasPrefix("Look up"))
    }

    /// Symmetry: the same tilt either side of the target's elevation asks for
    /// the same number of degrees back, in opposite directions. Catches an
    /// off-by-a-sign in the difference rather than in the rendering.
    @Test func theCueIsSymmetricAboutTheTargetsOwnElevation() throws {
        let targetDegrees = TargetGeometry.elevationRadians(horizontalDistance: 9) * 180 / .pi
        for offset in [25.0, 40.0, 55.0] {
            let up = try #require(state(pitch: targetDegrees + offset).elevation)
            let down = try #require(state(pitch: targetDegrees - offset).elevation)
            // 1e-3°: the pose round-trips through a Float quaternion, which is
            // good for about six digits, and the cue renders whole degrees.
            #expect(isClose(up.neededDegrees, -offset, within: 1e-3))
            #expect(isClose(down.neededDegrees, offset, within: 1e-3))
        }
    }

    /// Tilting toward the target must shrink the correction monotonically. The
    /// assertion that catches a flipped sign whatever convention the rest of the
    /// file settled on — the vertical twin of
    /// `OverlayTests.turningTowardTheTargetReducesTheBearing`.
    @Test func tiltingTowardTheTargetShrinksTheCorrection() throws {
        var previous = Double.infinity
        for step in 0...8 {
            let pitch = 70 - Double(step) * 8
            guard let cue = state(pitch: pitch).elevation else {
                // Inside the dead zone, so the correction got small enough to
                // stop asking. That is the sweep arriving, not a failure.
                #expect(previous <= GuideThresholds.elevationDeadZoneDegrees + 8)
                return
            }
            #expect(!cue.isUp, "lowering the phone toward the target flipped the instruction to up")
            #expect(abs(cue.neededDegrees) < previous + 1e-6,
                    "lowering the phone grew the correction at pitch \(pitch)")
            previous = abs(cue.neededDegrees)
        }
        Issue.record("the sweep never reached the dead zone: \(previous)° still out")
    }

    /// The target elevation on the arrow is where the target *is*, not the
    /// correction: slightly below the horizon, because the assumed target
    /// (1.0 m) sits below the assumed camera (1.3 m), and more so up close.
    @Test func theArrowsElevationIsTheTargetsOwnAngleNotTheCorrection() throws {
        let far = try #require(state(pitch: 0, distance: 12).arrow?.elevationRadians)
        let near = try #require(state(pitch: 0, distance: 1).arrow?.elevationRadians)
        #expect(far < 0 && near < 0, "a target below the camera must sit below the horizon")
        #expect(near < far, "closer to the same target means looking further down")
        #expect(isClose(Double(far), atan2(-0.3, 12), within: 1e-6))
        // The web's 0.3 m floor on the distance: without it a target underfoot
        // gives ±90° and the cue swings wildly over the last stride.
        let underfoot = try #require(state(pitch: 0, distance: 0.01).arrow?.elevationRadians)
        #expect(isClose(Double(underfoot), atan2(-0.3, 0.3), within: 1e-6))
    }

    @Test func theGeometryConstantsAreTheWebClients() {
        #expect(TargetGeometry.cameraHeightMetres == 1.3)
        #expect(TargetGeometry.targetHeightMetres == 1.0)
    }

    // MARK: - When it may speak

    /// Turning and tilting at once is two instructions. The horizontal error is
    /// the bigger one, so it goes first and the cue stays quiet.
    @Test func theCueIsSuppressedUntilTheOperatorHasTurned() {
        // 50° off the target's bearing, and pointed at the ceiling.
        #expect(state(pitch: 60, heading: 50).elevation == nil)
        #expect(state(pitch: 60, heading: 50).banner?.text.contains("Look") == false)
        // Turned onto it: now the vertical error is the only one left.
        #expect(state(pitch: 60, heading: 0).elevation != nil)
    }

    /// No distance, no geometry. A `search` sweep and a bare `look` at a sector
    /// carry none, so they get no vertical cue — and must not get a made-up one.
    @Test func withoutADistanceThereIsNoCue() {
        #expect(state(pitch: 70, distance: nil).elevation == nil)
        var search = OverlayModel()
        search.apply(.guideTurn(sector: "B2", delta: 0, onTarget: false, text: nil, kind: "search",
                                distance: nil), heading: 0, now: 0)
        tick(&search, pose: facing(0, pitch: 45), now: 0.1)
        #expect(search.state.elevation == nil)
    }

    /// Nobody holds a phone to better than a few degrees while walking. A cue
    /// that appears and vanishes as someone breathes is noise.
    @Test func smallErrorsSayNothing() {
        let targetDegrees = TargetGeometry.elevationRadians(horizontalDistance: 9) * 180 / .pi
        #expect(state(pitch: targetDegrees).elevation == nil, "level with the target")
        #expect(state(pitch: targetDegrees + 19).elevation == nil, "just inside the dead zone")
        #expect(state(pitch: targetDegrees + 21).elevation != nil, "just outside it")
    }

    /// Holding steady at the edge of the dead zone must not strobe the cue on
    /// and off. Once it is up it stays up until the error is properly gone.
    @Test func holdingSteadyAtTheEdgeDoesNotFlicker() {
        let targetDegrees = TargetGeometry.elevationRadians(horizontalDistance: 9) * 180 / .pi
        var model = OverlayModel()
        model.apply(.guideHeading(kind: "go", sector: "back row", heading: 0, distance: 9,
                                  untilMs: 90_000), heading: nil, now: 0)

        // Rising past the dead zone turns it on.
        tick(&model, pose: facing(0, pitch: targetDegrees + 25), now: 0.1)
        #expect(model.state.elevation != nil)

        // A hand wobbling either side of 20° must not blink it.
        var seenNil = false
        for (index, wobble) in [19.0, 21.0, 18.5, 20.5, 17.0, 19.5].enumerated() {
            tick(&model, pose: facing(0, pitch: targetDegrees + wobble), now: 0.2 + Double(index) * 0.033)
            if model.state.elevation == nil { seenNil = true }
        }
        #expect(!seenNil, "the cue strobed while the operator held the phone still")

        // Actually correcting it clears the cue.
        tick(&model, pose: facing(0, pitch: targetDegrees + 5), now: 0.6)
        #expect(model.state.elevation == nil)
    }

    // MARK: - No regression on "Hold your phone up"

    /// The one pitch string the hub and the web client do have, at
    /// `|pitch| > 65` on a `search` guide, is unchanged and is not joined by a
    /// second vertical instruction.
    @Test func holdYourPhoneUpStillOwnsTheSearchBannerAbove65() {
        var model = OverlayModel()
        model.apply(.guideTurn(sector: "B2", delta: 0, onTarget: false, text: nil, kind: "search",
                               distance: 9), heading: 0, now: 0)
        tick(&model, pose: facing(0, pitch: 70), now: 0.1)
        #expect(model.state.banner?.text == "Hold your phone up")
        #expect(model.state.elevation == nil, "two vertical instructions at once is one too many")
        #expect(model.state.banner?.tone == "warn")

        // Below 65 the new cue takes over for a search that does have a distance.
        tick(&model, pose: facing(0, pitch: 55), now: 0.2)
        #expect(model.state.banner?.text == "Look down 57°")
    }

    // MARK: - Wording

    /// The cue takes the slot the turn instruction would have had: one
    /// correction at a time, in the same place on the line.
    @Test func theCueTakesTheTurnInstructionsPlaceOnTheLine() {
        #expect(state(pitch: 50, kind: "go").banner?.text == "Look down 52° · walk to back row · 9 m")
        #expect(state(pitch: -50, kind: "go").banner?.text == "Look up 48° · walk to back row · 9 m")
        // `look` puts its correction after the target, so the cue does too.
        #expect(state(pitch: 50, kind: "look").banner?.text == "Face back row · look down 52°")
        #expect(state(pitch: 50, kind: "respond").banner?.text == "Look down 52° · 9 m")
    }

    /// Everything the cue drives is cleared together, or a stale "look down"
    /// outlives the directive that asked for it.
    @Test func clearingTheGuideClearsTheCue() {
        var model = OverlayModel()
        model.apply(.guideHeading(kind: "go", sector: "back row", heading: 0, distance: 9,
                                  untilMs: 90_000), heading: nil, now: 0)
        tick(&model, pose: facing(0, pitch: 60), now: 0.1)
        #expect(model.state.elevation != nil)
        model.apply(.guideClear, heading: 0, now: 0.2)
        #expect(model.state.elevation == nil)

        // And on expiry rather than an explicit clear.
        model.apply(.guideHeading(kind: "go", sector: "back row", heading: 0, distance: 9,
                                  untilMs: 1000), heading: nil, now: 1)
        tick(&model, pose: facing(0, pitch: 60), now: 1.1)
        #expect(model.state.elevation != nil)
        tick(&model, pose: facing(0, pitch: 60), now: 2.5)
        #expect(model.state.elevation == nil)
        #expect(model.state.banner == nil)
    }
}
