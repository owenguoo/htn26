import Foundation
import simd
import Testing
@testable import SwarmCore

/// Gate 8 — the overlay's data model. The SwiftUI views and CoreHaptics live in
/// the app target; the arrow's sign convention lives here, because getting it
/// backwards makes every operator turn the wrong way and looking at the screen
/// does not tell you which way is right.
@Suite("Gate 8: overlay model")
struct OverlayTests {

    private func camera(at position: SIMD3<Float>, yaw: Float) -> Pose {
        Pose(position: position, orientation: simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
    }

    private func diagnostics(stale: Bool = false, state: SessionState = .tracking,
                             correctionAge: Double? = 2) -> SessionDiagnostics {
        var value = SessionDiagnostics()
        value.state = state
        value.quality = .normal
        value.confidence = 0.95
        value.isStale = stale
        value.lastCorrectionAge = correctionAge
        return value
    }

    // MARK: - The arrow's sign

    /// A camera at the origin looking down venue −Z. A target to its right is at
    /// +X, and the arrow must turn clockwise, which is a positive bearing.
    @Test func aTargetToTheRightGivesAPositiveBearing() throws {
        let pose = camera(at: .zero, yaw: 0)
        let bearing = try #require(Geometry.relativeBearing(from: pose, to: SIMD3<Float>(5, 0, 0)))
        #expect(bearing > 0, "a target to the right produced \(bearing), which turns the operator left")
        #expect(isClose(bearing, .pi / 2, within: 1e-4))
    }

    @Test func aTargetToTheLeftGivesANegativeBearing() throws {
        let pose = camera(at: .zero, yaw: 0)
        let bearing = try #require(Geometry.relativeBearing(from: pose, to: SIMD3<Float>(-5, 0, 0)))
        #expect(bearing < 0)
        #expect(isClose(bearing, -.pi / 2, within: 1e-4))
    }

    @Test func aTargetStraightAheadGivesZero() throws {
        let pose = camera(at: .zero, yaw: 0)
        let bearing = try #require(Geometry.relativeBearing(from: pose, to: SIMD3<Float>(0, 0, -5)))
        #expect(isClose(bearing, 0, within: 1e-4))
    }

    @Test func aTargetBehindGivesHalfATurn() throws {
        let pose = camera(at: .zero, yaw: 0)
        let bearing = try #require(Geometry.relativeBearing(from: pose, to: SIMD3<Float>(0, 0, 5)))
        #expect(isClose(abs(bearing), .pi, within: 1e-4))
    }

    /// Turning the camera toward the target must reduce the bearing, not grow it.
    /// This is the assertion that catches a flipped sign no matter which
    /// convention the rest of the file settled on.
    @Test func turningTowardTheTargetReducesTheBearing() throws {
        // The target sits well to the camera's right. `camera(at:yaw:)` rotates
        // about venue +Y, and a right-handed rotation about +Y swings the
        // camera's forward vector counter-clockwise seen from above, so facing
        // something on the right means a *negative* yaw.
        let target = SIMD3<Float>(4, 1.5, -1)
        var previous = Float.infinity
        // Sweep from facing straight ahead round to facing the target.
        for step in 0...10 {
            let yaw = -Float(step) * 0.1326
            let pose = camera(at: SIMD3<Float>(0, 1.5, 0), yaw: yaw)
            let bearing = try #require(Geometry.relativeBearing(from: pose, to: target))
            if step > 0 {
                #expect(abs(bearing) < previous + 1e-4,
                        "turning toward the target increased the bearing at step \(step)")
            }
            previous = abs(bearing)
        }
        #expect(previous < 0.2, "the sweep never arrived at the target: \(previous) rad out")
    }

    @Test func elevationIsPositiveForATargetAboveTheCamera() throws {
        let pose = camera(at: SIMD3<Float>(0, 1.5, 0), yaw: 0)
        let up = try #require(Geometry.relativeElevation(from: pose, to: SIMD3<Float>(0, 3.5, -2)))
        let down = try #require(Geometry.relativeElevation(from: pose, to: SIMD3<Float>(0, 0.2, -2)))
        #expect(up > 0)
        #expect(down < 0)
    }

    @Test func bearingIsUndefinedWhenTheTargetIsUnderfoot() {
        let pose = camera(at: SIMD3<Float>(1, 1.5, 2), yaw: 0.4)
        #expect(Geometry.relativeBearing(from: pose, to: SIMD3<Float>(1, 0, 2)) == nil)
    }

    // MARK: - Hub guides

    private func tick(_ model: inout OverlayModel, pose: Pose?, now: Double, stale: Bool = false,
                      alignment: RoomAlignment? = .identity, intrinsics: CameraIntrinsics? = nil) {
        model.update(pose: pose, alignment: alignment, source: alignment == nil ? .none : .marker,
                     intrinsics: intrinsics, diagnostics: diagnostics(stale: stale),
                     transport: .init(), transportState: .connected, now: now)
    }

    /// Room heading h means a right-handed yaw of −h about +Y.
    private func facing(_ headingDegrees: Double, at position: SIMD3<Float> = [0, 1.5, 5]) -> Pose {
        camera(at: position, yaw: -Float(headingDegrees * .pi / 180))
    }

    /// The hub says "turn right 40°" from where the phone *was* facing. As the
    /// operator turns, the arrow must shrink — that is the whole point of storing
    /// the target as a heading, and what makes the directive feel live between
    /// the hub's updates.
    @Test func aTurnGuideShrinksAsTheOperatorTurnsTowardIt() throws {
        var model = OverlayModel()
        model.apply(.guideTurn(sector: "B2", delta: 40, onTarget: false, text: "Turn right 40°",
                               kind: "search", distance: nil), heading: 10, now: 0)
        tick(&model, pose: facing(10), now: 0.1)
        let first = try #require(model.state.arrow)
        #expect(isClose(first.bearingRadians, 40 * .pi / 180, within: 1e-3))
        #expect(first.bearingRadians > 0, "turn right must be a positive, clockwise arrow")
        #expect(model.state.banner?.text == "Turn right 40° →")

        tick(&model, pose: facing(30), now: 0.2)
        #expect(isClose(try #require(model.state.arrow).bearingRadians, 20 * .pi / 180, within: 1e-3))
        tick(&model, pose: facing(50), now: 0.3)
        #expect(try #require(model.state.arrow).isOnTarget)
        tick(&model, pose: facing(70), now: 0.4)
        #expect(try #require(model.state.arrow).bearingRadians < 0, "overshot: now turn back left")
    }

    @Test func aTurnGuideWrapsThroughNorth() throws {
        var model = OverlayModel()
        model.apply(.guideTurn(sector: nil, delta: -30, onTarget: false, text: nil, kind: "search",
                               distance: nil), heading: 10, now: 0)
        tick(&model, pose: facing(10), now: 0)
        #expect(isClose(try #require(model.state.arrow).bearingRadians, -30 * .pi / 180, within: 1e-3))
    }

    @Test func aTurnGuideExpiresThreeSecondsAfterTheHubStopsRefreshingIt() {
        var model = OverlayModel()
        let guide = HubCommand.guideTurn(sector: "A1", delta: 20, onTarget: false, text: nil,
                                         kind: "search", distance: nil)
        model.apply(guide, heading: 0, now: 0)
        tick(&model, pose: facing(0), now: 2.9)
        #expect(model.state.arrow != nil)
        model.apply(guide, heading: 0, now: 2.9)
        tick(&model, pose: facing(0), now: 5.8)
        #expect(model.state.arrow != nil, "a refresh must extend the guide")
        tick(&model, pose: facing(0), now: 6.0)
        #expect(model.state.arrow == nil)
        #expect(model.state.banner == nil)
    }

    @Test func aTurnGuideWithNoHeadingIsIgnoredLikePhoneJS() {
        var model = OverlayModel()
        let applied = model.apply(.guideTurn(sector: nil, delta: 20, onTarget: false, text: nil,
                                             kind: "search", distance: nil), heading: nil, now: 0)
        #expect(!applied)
        tick(&model, pose: facing(0), now: 0)
        #expect(model.state.arrow == nil)
    }

    @Test func aLookHeadingIsAbsoluteAndHonoursUntilMs() throws {
        var model = OverlayModel()
        model.apply(.guideHeading(kind: "go", sector: "door", heading: 135, distance: 6.1,
                                  untilMs: 10_000), heading: nil, now: 0)
        tick(&model, pose: facing(90), now: 1)
        let arrow = try #require(model.state.arrow)
        #expect(isClose(arrow.bearingRadians, 45 * .pi / 180, within: 1e-3))
        #expect(arrow.distance == 6.1)
        #expect(model.state.banner?.text == "Turn right 45° → · walk to door · 6.1 m")
        tick(&model, pose: facing(90), now: 10.1)
        #expect(model.state.arrow == nil)
    }

    /// `.gravity` alignment has no true north. Showing an arrow for a compass
    /// bearing would be a guess dressed as an instruction.
    @Test func aCompassGuideShowsTextOnly() {
        var model = OverlayModel()
        model.apply(.guideCompass(kind: "look", sector: "north", compass: 10, untilMs: 20_000),
                    heading: 0, now: 0)
        tick(&model, pose: facing(0), now: 1)
        #expect(model.state.arrow == nil)
        #expect(model.state.banner?.text == "Face north (no compass on this phone)")
    }

    @Test func theArrowDisappearsWhenThePoseGoesStaleButTheBannerStays() {
        var model = OverlayModel()
        model.apply(.guideHeading(kind: "look", sector: "stage", heading: 0, distance: nil,
                                  untilMs: 20_000), heading: nil, now: 0)
        tick(&model, pose: facing(90), now: 1)
        #expect(model.state.arrow != nil)
        tick(&model, pose: facing(90), now: 2, stale: true)
        #expect(model.state.arrow == nil, "an arrow from a pose we do not trust points at nothing")
        // The directive is still live, so it still says what was asked for —
        // just nothing about which way to turn.
        #expect(model.state.banner?.text == "Face stage")
        tick(&model, pose: facing(90), now: 3, alignment: nil)
        #expect(model.state.arrow == nil, "unaligned: no room heading, no arrow")
    }

    @Test func guideClearRemovesArrowAndBanner() {
        var model = OverlayModel()
        model.apply(.guideHeading(kind: "look", sector: nil, heading: 0, distance: nil, untilMs: 20_000),
                    heading: nil, now: 0)
        tick(&model, pose: facing(90), now: 1)
        model.apply(.guideClear, heading: 90, now: 1)
        #expect(model.state.arrow == nil && model.state.banner == nil)
        tick(&model, pose: facing(90), now: 1.1)
        #expect(model.state.arrow == nil)
    }

    /// The haptic follows the *live* offset, not the hub's stale `onTarget`, so
    /// it fires the moment the banner goes green rather than up to 200 ms later.
    @Test func comingOnTargetFiresOneHapticNotOnePerFrame() {
        var model = OverlayModel()
        // Target at room heading 50; the operator starts facing 0, 50° off.
        model.apply(.guideTurn(sector: "A1", delta: 50, onTarget: false, text: nil, kind: "search",
                               distance: nil), heading: 0, now: 0)
        tick(&model, pose: facing(0), now: 0.1)
        do { let cue = model.consumeHaptic(); #expect(cue == nil, "50° off is not on target") }

        tick(&model, pose: facing(40), now: 0.2)
        do { let cue = model.consumeHaptic(); #expect(cue?.pattern == "onTarget") }
        // Still on target, a frame later. One arrival, one buzz.
        tick(&model, pose: facing(45), now: 0.233)
        do { let cue = model.consumeHaptic(); #expect(cue == nil) }

        // Drifting back out by less than the release band must not re-arm it:
        // a 90 s `go` would otherwise buzz on every wobble across 16°.
        tick(&model, pose: facing(31), now: 0.3)
        tick(&model, pose: facing(40), now: 0.4)
        do { let cue = model.consumeHaptic(); #expect(cue == nil, "wobbling over the line re-armed it") }

        // Properly turning away and back is a new arrival.
        tick(&model, pose: facing(10), now: 0.5)
        tick(&model, pose: facing(50), now: 0.6)
        do { let cue = model.consumeHaptic(); #expect(cue?.pattern == "onTarget") }
    }

    // MARK: - The other commands

    @Test func flashUsesItsColourThenTheWelcomeColourThenWhite() throws {
        var model = OverlayModel()
        model.apply(.flash(color: nil, text: nil, ttlMs: 1500), heading: nil, now: 0)
        #expect(model.state.flash?.red == 1 && model.state.flash?.blue == 1)

        let welcome = try #require(HubInbound.decode(Data(
            ##"{"type":"welcome","phoneId":"a","index":3,"color":"#ff0000","phase":"lobby"}"##.utf8)))
        guard case .welcome(let w) = welcome else { return }
        model.apply(w)
        #expect(model.state.index == 3)
        #expect(model.state.phase == "lobby")
        model.apply(.flash(color: nil, text: "", ttlMs: 1500), heading: nil, now: 0)
        #expect(model.state.flash?.red == 1 && model.state.flash?.green == 0)
        #expect(model.state.flash?.text == nil)

        model.apply(.flash(color: "#7ae582", text: "You're there ✓", ttlMs: 1500), heading: nil, now: 10)
        let flash = try #require(model.state.flash)
        #expect(isClose(flash.green, Float(0xe5) / 255, within: 1e-6))
        #expect(flash.text == "You're there ✓")
        tick(&model, pose: nil, now: 11.4)
        #expect(model.state.flash != nil)
        tick(&model, pose: nil, now: 11.6)
        #expect(model.state.flash == nil)
    }

    @Test func aMessageToastsBeepsAndExpires() {
        var model = OverlayModel()
        model.apply(.message(text: "Spread out", ttlMs: 8000), heading: nil, now: 0)
        #expect(model.state.toast?.text == "Spread out")
        do { let cue = model.consumeSound(); #expect(cue?.name == "message") }
        do { let cue = model.consumeSound(); #expect(cue == nil, "a sound fires once") }
        do { let cue = model.consumeHaptic(); #expect(cue?.pattern == "message") }
        tick(&model, pose: nil, now: 8.1)
        #expect(model.state.toast == nil)
    }

    @Test func detectionsReplaceEachOtherAndExpire() {
        var model = OverlayModel()
        model.apply(.detections(HubDetections(boxes: [HubDetectionBox(x: 0, y: 0, w: 1, h: 1)],
                                              ttlMs: 1500)), heading: nil, now: 0)
        model.apply(.detections(HubDetections(boxes: [], ttlMs: 1500)), heading: nil, now: 1)
        #expect(model.state.detections?.boxes.isEmpty == true)
        tick(&model, pose: nil, now: 2.6)
        #expect(model.state.detections == nil)
    }

    @Test func aPingBeepsOnceIsProjectedAndExpires() throws {
        var model = OverlayModel()
        let ping = HubCommand.ping(id: 5, x: 3, y: 5, label: "Check here", ttlMs: 12_000)
        model.apply(ping, heading: nil, now: 0)
        do { let cue = model.consumeSound(); #expect(cue?.name == "ping") }
        model.apply(ping, heading: nil, now: 1)
        do { let cue = model.consumeSound(); #expect(cue == nil, "the same ping re-sent must not beep again") }
        #expect(model.state.pings.count == 1)

        // Standing at room (0, 5) facing the stage: the ping at (3, 5) is dead right.
        tick(&model, pose: facing(0), now: 2, intrinsics: Sample.intrinsics())
        var cue = try #require(model.state.pings.first)
        #expect(isClose(try #require(cue.bearingRadians), .pi / 2, within: 1e-3))
        #expect(isClose(try #require(cue.distance), 3, within: 1e-3))
        #expect(cue.imagePoint == nil, "it is beside the camera, not in front of it")

        // Turn to face it and it lands in the image, below centre (it is on the floor).
        tick(&model, pose: facing(90), now: 3, intrinsics: Sample.intrinsics())
        cue = try #require(model.state.pings.first)
        let point = try #require(cue.imagePoint)
        #expect(isClose(Float(point.x), Sample.intrinsics().cx, within: 1))
        #expect(Float(point.y) > Sample.intrinsics().cy)

        tick(&model, pose: facing(90), now: 13.1)
        #expect(model.state.pings.isEmpty)
    }

    @Test func worldPingsFillInOnesWhoseCommandWasLostWithoutBeeping() throws {
        var model = OverlayModel()
        guard case .world(let world)? = HubInbound.decode(
            try Data(contentsOf: Fixtures.url("hub-messages/world.json"))) else {
            Issue.record("world fixture did not decode")
            return
        }
        model.apply(world, now: 100)
        #expect(model.state.pings.map(\.id) == [1])
        do { let cue = model.consumeSound(); #expect(cue == nil) }
        #expect(isClose(try #require(model.state.pings.first).until, 111.7, within: 1e-6))
        model.apply(world, now: 100.5)
        #expect(model.state.pings.count == 1)
        #expect(model.state.world?.stats?.rank == 1)
    }

    @Test func rateHudAndUnknownAreNotTheOverlaysBusiness() {
        var model = OverlayModel()
        let before = model.state
        do { let applied = model.apply(.rate(fps: 8), heading: nil, now: 0); #expect(!applied) }
        do { let applied = model.apply(.hud(on: true), heading: nil, now: 0); #expect(!applied) }
        do { let applied = model.apply(.unknown(cmd: "teleport"), heading: nil, now: 0); #expect(!applied) }
        #expect(model.state == before)
    }

    @Test func theRoomPoseIsPublishedForTheMiniMap() throws {
        var model = OverlayModel()
        tick(&model, pose: facing(90, at: [2, 1.5, 7]), now: 0)
        let room = try #require(model.state.roomPose)
        #expect(isClose(room.x, 2, within: 1e-4) && isClose(room.y, 7, within: 1e-4))
        #expect(isClose(try #require(room.heading), 90, within: 1e-3))
        #expect(model.state.alignment == .marker)
        tick(&model, pose: facing(90), now: 1, alignment: nil)
        #expect(model.state.roomPose == nil)
    }

    @Test func hexColours() {
        #expect(HexColor.parse("#ffffff")?.0 == 1)
        #expect(HexColor.parse("000") ?? (1, 1, 1) == (0, 0, 0))
        #expect(HexColor.parse("#xyzxyz") == nil)
        #expect(HexColor.parse(nil) == nil)
    }

    // MARK: - The status pill

    @Test func thePillCarriesEverythingTheOperatorNeeds() {
        var model = OverlayModel()
        var stats = Transport.Stats()
        stats.inFlight = 2
        stats.dropped = 47
        var value = diagnostics()
        value.thermalState = .serious

        model.update(pose: camera(at: .zero, yaw: 0), alignment: .identity, source: .marker,
                     intrinsics: nil, diagnostics: value, transport: stats,
                     transportState: .connected, now: 5)
        let pill = model.state.pill
        #expect(pill.sessionState == .tracking)
        #expect(pill.trackingState == "normal")
        #expect(pill.inFlight == 2)
        #expect(pill.dropped == 47)
        #expect(pill.thermalState == .serious)
        #expect(pill.secondsSinceCorrection == 2)
        #expect(pill.connection == .online)
        #expect(pill.needsAttention, "a phone at .serious thermal state should be flagged")
    }

    @Test(arguments: [
        (TransportState.idle, StatusPill.ConnectionState.offline),
        (.connecting(attempt: 0), .connecting),
        (.connecting(attempt: 3), .reconnecting),
        (.connected, .online),
        (.waitingToReconnect(attempt: 2, delay: 0.4), .reconnecting),
        (.closed, .offline),
    ])
    func connectionStateMapsFromTheTransport(transport: TransportState, expected: StatusPill.ConnectionState) {
        #expect(StatusPill.ConnectionState(transport) == expected)
    }

    /// A phone that has never been corrected is reporting positions in a frame
    /// nobody else shares. That has to be visible.
    @Test func neverHavingBeenCorrectedNeedsAttention() {
        var pill = StatusPill(sessionState: .tracking, confidence: 1, isStale: false,
                              connection: .online, secondsSinceCorrection: nil)
        #expect(pill.needsAttention)
        pill.secondsSinceCorrection = 3
        #expect(!pill.needsAttention)
        pill.secondsSinceCorrection = 45
        #expect(pill.needsAttention, "45 s without a marker should be flagged")
    }

    /// Seat calibration has no marker corrections by definition. The pill used
    /// to stay orange for the whole session on a phone with nothing wrong.
    @Test func aSeatLocatedPhoneIsNotFlaggedForNeverSeeingAMarker() {
        var pill = StatusPill(sessionState: .tracking, confidence: 1, isStale: false,
                              connection: .online, secondsSinceCorrection: nil, alignment: .seat)
        #expect(!pill.needsAttention)
        pill.alignment = .none
        #expect(pill.needsAttention, "located by nothing at all is worth flagging")
        pill.alignment = .marker
        #expect(pill.needsAttention, "claims a marker lock it has never had")
        pill.secondsSinceCorrection = 45
        #expect(pill.needsAttention)
        pill.alignment = .seat
        pill.isStale = true
        #expect(pill.needsAttention, "seat alignment excuses the marker check, nothing else")
    }

    @Test func thePillLearnsTheAlignmentFromTheOverlayUpdate() {
        var model = OverlayModel()
        var value = diagnostics(correctionAge: nil)
        value.state = .calibrating
        model.update(pose: camera(at: .zero, yaw: 0), alignment: .identity, source: .seat, intrinsics: nil,
                     diagnostics: value, transport: .init(), transportState: .connected, now: 1)
        #expect(model.state.pill.alignment == .seat)
        #expect(!model.state.pill.needsAttention)
    }

    // MARK: - Driven from the replay

    /// An operator walks the room while the hub holds a "look at heading" order.
    /// The arrow must swing through a real range as they sweep, and point behind
    /// them when they face away.
    @Test func theArrowTracksAFixedRoomHeadingAcrossTheReplayedWalk() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let truth = try #require(trajectory.groundTruth)

        var model = OverlayModel()
        model.apply(.guideHeading(kind: "look", sector: "stage", heading: 0, distance: nil,
                                  untilMs: 10_000_000), heading: nil, now: 0)

        var bearings: [Float] = []
        var onTargetCount = 0
        // Every tenth ground-truth sample: six per second, which is what the
        // overlay actually redraws at.
        for sample in stride(from: 0, to: truth.count, by: 10).compactMap({ truth[$0].pose }) {
            tick(&model, pose: sample, now: 0)
            guard let arrow = model.state.arrow else { continue } // looking straight down
            // The arrow must agree with the independent 3D bearing to a point far
            // away in the heading-0 direction: two derivations, one answer.
            let far = sample.position + SIMD3<Float>(0, 0, -1_000)
            let expected = try #require(Geometry.relativeBearing(from: sample, to: far))
            #expect(abs(RoomMath.signedDiff(Double(arrow.bearingRadians) * 180 / .pi,
                                            Double(expected) * 180 / .pi)) < 0.1)
            bearings.append(arrow.bearingRadians)
            if arrow.isOnTarget { onTargetCount += 1 }
        }

        #expect(bearings.count > 500)
        #expect(bearings.allSatisfy { $0 >= -Float.pi - 1e-4 && $0 <= Float.pi + 1e-4 },
                "a bearing escaped the range a compass can express")
        let span = (bearings.max() ?? 0) - (bearings.min() ?? 0)
        // The recorded walk sweeps about 165° of heading; it never turns its back
        // fully on the stage.
        #expect(span > 2.5, "the arrow only swung \(span) rad over a two-minute walk with a sweep")
        #expect(onTargetCount > 20, "the operator never once faced the stage: \(onTargetCount) samples")

        // Ordered to look at the back of the room instead, the same walk must at
        // some point have the arrow pointing behind the operator rather than
        // silently clamping.
        model.apply(.guideHeading(kind: "look", sector: "rear", heading: 180, distance: nil,
                                  untilMs: 10_000_000), heading: nil, now: 0)
        var behind = 0
        for sample in stride(from: 0, to: truth.count, by: 10).compactMap({ truth[$0].pose }) {
            tick(&model, pose: sample, now: 0)
            if let arrow = model.state.arrow, abs(arrow.bearingRadians) > 2.0 { behind += 1 }
        }
        #expect(behind > 0, "the arrow never pointed behind the operator")
    }
}
