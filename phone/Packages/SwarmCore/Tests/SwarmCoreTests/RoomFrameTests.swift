import Foundation
import simd
import Testing
@testable import SwarmCore

@Suite("Room frame: venue 6DoF into the hub's floor plan")
struct RoomFrameTests {
    /// A level camera whose forward is the given venue-frame direction.
    private func camera(at position: SIMD3<Float>, facing direction: SIMD3<Float>) -> Pose {
        Pose(position: position, orientation: simd_quatf(from: CameraAxis.forward, to: simd_normalize(direction)))
    }

    // The sign tests. Getting one of these backwards mirrors the dashboard.

    @Test func facingTheStageIsHeadingZero() throws {
        // Venue +Z is out from the stage, so facing the stage is −Z.
        let room = RoomAlignment.identity.project(camera(at: [0, 1.5, 5], facing: [0, 0, -1]))
        #expect(isClose(RoomMath.signedDiff(try #require(room.heading), 0), 0, within: 1e-3))
    }

    @Test func turningRightIsClockwise() throws {
        let cases: [(SIMD3<Float>, Double)] = [
            ([1, 0, 0], 90),    // facing +x, stage on your left
            ([0, 0, 1], 180),   // back to the stage
            ([-1, 0, 0], 270),
            ([1, 0, -1], 45),
        ]
        for (direction, expected) in cases {
            let heading = try #require(RoomAlignment.identity.project(camera(at: .zero, facing: direction)).heading)
            #expect(isClose(heading, expected, within: 1e-3), "facing \(direction) gave \(heading)")
        }
    }

    @Test func walkingAwayFromTheStageIncreasesY() {
        let near = RoomAlignment.identity.project(camera(at: [2, 1.5, 3], facing: [0, 0, -1]))
        let far = RoomAlignment.identity.project(camera(at: [2, 1.5, 7], facing: [0, 0, -1]))
        #expect(far.y > near.y)
        #expect(near.x == 2 && far.x == 2)
        #expect(near.y == 3 && far.y == 7)
    }

    @Test func pitchIsPositiveUpAndHeightIsIgnored() {
        let up = RoomAlignment.identity.project(camera(at: [0, 9, 0], facing: [0, 1, -1]))
        #expect(isClose(up.pitch, 45, within: 1e-3))
        let down = RoomAlignment.identity.project(camera(at: .zero, facing: [0, -1, -1]))
        #expect(isClose(down.pitch, -45, within: 1e-3))
    }

    @Test func straightDownHasNoHeading() {
        let pose = Pose(position: .zero, orientation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
        let room = RoomAlignment.identity.project(pose)
        #expect(room.heading == nil)
        #expect(isClose(room.pitch, -90, within: 1e-2))
    }

    @Test func headingAgreesWithGeometryYaw() throws {
        let pose = camera(at: .zero, facing: [0.3, 0.1, -0.8])
        let heading = try #require(RoomAlignment.identity.project(pose).heading)
        let yaw = Double(Geometry.yaw(of: pose.orientation)) * 180 / .pi
        #expect(isClose(heading, RoomMath.wrap360(yaw), within: 1e-3))
    }

    @Test func offsetAndYawedVenue() throws {
        // Venue origin 2 m right of centre, 1 m out; venue −Z points at room heading 90.
        let alignment = RoomAlignment(originX: 2, originY: 1, yawDegrees: 90)
        let room = alignment.project(camera(at: [0, 0, 3], facing: [0, 0, -1]))
        #expect(isClose(try #require(room.heading), 90, within: 1e-3))
        // Venue +Z is "behind" heading 90, i.e. room −x.
        #expect(isClose(room.x, -1, within: 1e-4))
        #expect(isClose(room.y, 1, within: 1e-4))
    }

    @Test func unprojectInvertsProject() {
        let alignment = RoomAlignment(originX: -3, originY: 2, yawDegrees: 37)
        let point = SIMD3<Float>(1.5, 0, -4)
        let room = alignment.project(Pose(position: point, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
        let back = alignment.unproject(x: room.x, y: room.y)
        #expect(isClose(back.x, point.x, within: 1e-4))
        #expect(isClose(back.z, point.z, within: 1e-4))
    }

    @Test func venueRoomBlockDecodes() throws {
        let json = #"{"originX":1,"originY":2,"yawDegrees":-90}"#
        let alignment = try JSONDecoder().decode(RoomAlignment.self, from: Data(json.utf8))
        #expect(alignment == RoomAlignment(originX: 1, originY: 2, yawDegrees: -90))
    }

    // MARK: Seat fallback

    @Test func seatTapPutsYouOnYourSpotFacingTheStage() throws {
        // ARKit's raw world is arbitrary: here the phone is at (4, _, -2) facing raw +X.
        let raw = camera(at: [4, 1.4, -2], facing: [1, 0, 0])
        let alignment = try #require(SeatCalibration.alignment(seat: HubSeat(x: -3, y: 8), facingStage: raw))
        let room = alignment.project(raw)
        #expect(isClose(room.x, -3, within: 1e-4))
        #expect(isClose(room.y, 8, within: 1e-4))
        #expect(isClose(RoomMath.signedDiff(try #require(room.heading), 0), 0, within: 1e-3))
    }

    @Test func afterSeatTapMovementMapsLikePhoneJS() throws {
        let raw = camera(at: [4, 1.4, -2], facing: [1, 0, 0])
        let alignment = try #require(SeatCalibration.alignment(seat: HubSeat(x: 0, y: 8), facingStage: raw))
        // Two metres forward (raw +X) is two metres toward the stage: y shrinks.
        let forward = alignment.project(camera(at: [6, 1.4, -2], facing: [1, 0, 0]))
        #expect(isClose(forward.y, 6, within: 1e-4))
        #expect(isClose(forward.x, 0, within: 1e-4))
        // One metre to the phone's right (raw +Z when facing +X) is room +x.
        let right = alignment.project(camera(at: [4, 1.4, -1], facing: [1, 0, 0]))
        #expect(isClose(right.x, 1, within: 1e-4))
        // Turning right (toward raw +Z) is clockwise.
        let turned = alignment.project(camera(at: [4, 1.4, -2], facing: [0, 0, 1]))
        #expect(isClose(try #require(turned.heading), 90, within: 1e-3))
    }

    @Test func seatCalibrationRefusesAPhonePointedAtTheFloor() {
        let down = Pose(position: .zero, orientation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
        #expect(SeatCalibration.alignment(seat: HubSeat(x: 0, y: 0), facingStage: down) == nil)
    }

    @Test func alignerGoesNoneSeatMarkerAndMarkerWins() {
        var aligner = RoomAligner(venueAlignment: .identity)
        let pose = camera(at: [1, 1, 1], facing: [0, 0, -1])
        #expect(aligner.source == .none)
        #expect(aligner.project(pose) == nil)
        let beforeSeat = aligner.calibrateFacingStage(rawPose: pose)
        #expect(!beforeSeat, "no seat yet")

        aligner.setSeat(HubSeat(x: 5, y: 5))
        let withSeat = aligner.calibrateFacingStage(rawPose: pose)
        #expect(withSeat)
        #expect(aligner.source == .seat)
        #expect(aligner.project(pose)?.x == 5)

        aligner.markerAcquired()
        #expect(aligner.source == .marker)
        #expect(aligner.project(pose)?.x == 1)
        let afterMarker = aligner.calibrateFacingStage(rawPose: pose)
        #expect(!afterMarker, "a marker is never overridden by a tap")
        #expect(aligner.source == .marker)
    }

    // MARK: Maths shared with the hub

    @Test func bearingMatchesTheHubsFormula() {
        // hub.py: degrees(atan2(x - px, -(y - py))) % 360
        #expect(isClose(RoomMath.bearing(fromX: 0, y: 5, toX: 0, y: 0), 0, within: 1e-9))
        #expect(isClose(RoomMath.bearing(fromX: 0, y: 5, toX: 3, y: 5), 90, within: 1e-9))
        #expect(isClose(RoomMath.bearing(fromX: 0, y: 5, toX: 0, y: 9), 180, within: 1e-9))
        #expect(isClose(RoomMath.bearing(fromX: 0, y: 5, toX: -3, y: 5), 270, within: 1e-9))
    }

    @Test func signedDiffWrapsLikePhoneJS() {
        #expect(RoomMath.signedDiff(10, 350) == 20)
        #expect(RoomMath.signedDiff(350, 10) == -20)
        #expect(RoomMath.signedDiff(180, 0) == -180)
        #expect(RoomMath.signedDiff(90, 90) == 0)
    }
}
