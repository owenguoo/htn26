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

    // MARK: - Tracked arrows

    /// A venue-frame target stays put while the operator turns, which is the
    /// whole point of doing this on the phone rather than on the server.
    @Test func aTrackedArrowFollowsTheCameraRatherThanTheScreen() {
        var model = OverlayModel()
        model.apply(Command(id: "a", serverTimestamp: 0,
                            kind: .arrow(target: [4, 1.5, 0], bearingRadians: nil, label: "backpack")),
                    now: 0)

        var bearings: [Float] = []
        for step in 0...8 {
            let yaw = -1.2 + Float(step) * 0.15
            model.update(pose: camera(at: SIMD3<Float>(0, 1.5, 0), yaw: yaw),
                         diagnostics: diagnostics(), transport: .init(),
                         transportState: .connected, now: Double(step))
            if let arrow = model.state.arrow { bearings.append(arrow.bearingRadians) }
        }
        #expect(bearings.count == 9)
        #expect(Set(bearings).count == 9, "the bearing did not change as the camera turned")
        #expect(model.state.arrow?.label == "backpack")
        let distance = model.state.arrow?.distance ?? 0
        #expect(isClose(distance, 4, within: 0.01))
    }

    /// If we do not know where the camera is looking, we cannot say which way to
    /// turn. An arrow drawn from a stale pose points at nothing.
    @Test func aTrackedArrowDisappearsWhenThePoseGoesStale() {
        var model = OverlayModel()
        model.apply(Command(id: "a", serverTimestamp: 0,
                            kind: .arrow(target: [4, 1.5, 0], bearingRadians: nil, label: nil)),
                    now: 0)
        model.update(pose: camera(at: .zero, yaw: 0), diagnostics: diagnostics(),
                     transport: .init(), transportState: .connected, now: 1)
        #expect(model.state.arrow != nil)

        model.update(pose: camera(at: .zero, yaw: 0), diagnostics: diagnostics(stale: true),
                     transport: .init(), transportState: .connected, now: 2)
        #expect(model.state.arrow == nil, "an arrow was drawn from a pose we do not trust")
    }

    @Test func aBareBearingIsShownWithoutBeingTracked() {
        var model = OverlayModel()
        model.apply(Command(id: "a", serverTimestamp: 0,
                            kind: .arrow(target: nil, bearingRadians: -1.2, label: "left")),
                    now: 0)
        #expect(model.state.arrow?.bearingRadians == -1.2)
        #expect(model.trackedTarget == nil)
        #expect(model.state.arrow?.distance == nil)
    }

    @Test func onTargetIsReportedOnceTheOperatorIsFacingIt() {
        var model = OverlayModel()
        model.apply(Command(id: "a", serverTimestamp: 0,
                            kind: .arrow(target: [0, 1.5, -4], bearingRadians: nil, label: nil)),
                    now: 0)
        model.update(pose: camera(at: SIMD3<Float>(0, 1.5, 0), yaw: 0), diagnostics: diagnostics(),
                     transport: .init(), transportState: .connected, now: 1)
        #expect(model.state.arrow?.isOnTarget == true)

        model.update(pose: camera(at: SIMD3<Float>(0, 1.5, 0), yaw: 1.2), diagnostics: diagnostics(),
                     transport: .init(), transportState: .connected, now: 2)
        #expect(model.state.arrow?.isOnTarget == false)
    }

    // MARK: - Commands

    /// A "look left" that arrives two seconds after the moment has passed reads
    /// as broken. Discarding it is better than painting it late.
    @Test func anExpiredCommandIsDiscardedRatherThanPaintedLate() {
        var model = OverlayModel()
        let inTime = Command(id: "a", serverTimestamp: 100,
                             kind: .flash(r: 1, g: 0, b: 0, durationMs: 400), expiresInMs: 800)
        let applied = model.apply(inTime, now: 100.5)
        #expect(applied)
        #expect(model.state.flash != nil)

        // Two seconds late against an 800 ms expiry.
        var stale = OverlayModel()
        let tooLate = stale.apply(Command(id: "b", serverTimestamp: 100,
                                          kind: .flash(r: 1, g: 0, b: 0, durationMs: 400),
                                          expiresInMs: 800),
                                  now: 102)
        #expect(!tooLate)
        #expect(stale.state.flash == nil)
    }

    @Test func aCommandIsAppliedOnlyOnce() {
        var model = OverlayModel()
        let command = Command(id: "buzz", serverTimestamp: 0, kind: .haptic(pattern: "sharp", intensity: 1))
        let first = model.apply(command, now: 0)
        #expect(first)
        #expect(model.consumeHaptic()?.pattern == "sharp")
        let second = model.apply(command, now: 0.1)
        #expect(!second, "a redelivered command fired twice")
        #expect(model.consumeHaptic() == nil)
    }

    @Test func theFlashClearsItselfWhenItsDurationElapses() {
        var model = OverlayModel()
        model.apply(Command(id: "a", serverTimestamp: 0,
                            kind: .flash(r: 1, g: 0.2, b: 0, durationMs: 400)), now: 10)
        #expect(model.state.flash != nil)
        model.update(pose: nil, diagnostics: diagnostics(), transport: .init(),
                     transportState: .connected, now: 10.2)
        #expect(model.state.flash != nil)
        model.update(pose: nil, diagnostics: diagnostics(), transport: .init(),
                     transportState: .connected, now: 10.5)
        #expect(model.state.flash == nil)
    }

    @Test func clearRemovesEverythingIncludingTheTrackedTarget() {
        var model = OverlayModel()
        model.apply(Command(id: "a", serverTimestamp: 0,
                            kind: .arrow(target: [1, 1, 1], bearingRadians: nil, label: nil)), now: 0)
        model.apply(Command(id: "b", serverTimestamp: 0,
                            kind: .flash(r: 1, g: 1, b: 1, durationMs: 5_000)), now: 0)
        model.apply(Command(id: "c", serverTimestamp: 0, kind: .clear), now: 0)
        #expect(model.state.flash == nil)
        #expect(model.state.arrow == nil)
        #expect(model.trackedTarget == nil)
    }

    /// A haptic is an event, not a state: the thing the web client could never
    /// do, and it must fire exactly once.
    @Test func hapticsAndSoundsAreConsumedOnce() {
        var model = OverlayModel()
        model.apply(Command(id: "h", serverTimestamp: 0, kind: .haptic(pattern: "sharp", intensity: 0.9)),
                    now: 0)
        model.apply(Command(id: "s", serverTimestamp: 0, kind: .sound(name: "ping")), now: 0)
        #expect(model.consumeHaptic()?.intensity == 0.9)
        #expect(model.consumeHaptic() == nil)
        #expect(model.consumeSound()?.name == "ping")
        #expect(model.consumeSound() == nil)
    }

    @Test func setRatesIsNotTheOverlaysBusiness() {
        var model = OverlayModel()
        model.apply(Command(id: "r", serverTimestamp: 0,
                            kind: .setRates(poseHz: 5, frameFPS: 1, depthHz: 0.2)), now: 0)
        #expect(model.state.flash == nil)
        #expect(model.state.arrow == nil)
        #expect(model.state.pendingHaptic == nil)
    }

    /// The de-duplication set runs for the length of the demo, so it is bounded.
    @Test func theSeenCommandSetDoesNotGrowWithoutBound() {
        var model = OverlayModel()
        for index in 0..<5_000 {
            model.apply(Command(id: "c\(index)", serverTimestamp: 0, kind: .clear), now: 0)
        }
        // The oldest ids have been evicted, so re-applying one succeeds again;
        // what matters is that memory is flat, not that de-duplication is
        // eternal. A command from 5 000 ago is not going to be redelivered.
        let evictedIsAcceptedAgain = model.apply(Command(id: "c0", serverTimestamp: 0, kind: .clear), now: 0)
        #expect(evictedIsAcceptedAgain)
    }

    // MARK: - The status pill

    @Test func thePillCarriesEverythingTheOperatorNeeds() {
        var model = OverlayModel()
        var stats = Transport.Stats()
        stats.inFlight = 2
        stats.dropped = 47
        var value = diagnostics()
        value.thermalState = .serious

        model.update(pose: camera(at: .zero, yaw: 0), diagnostics: value, transport: stats,
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

    // MARK: - Driven from the replay

    /// An operator walks the room with a fixed target pinned in the venue frame.
    /// The arrow must swing through a real range as they sweep, and point behind
    /// them when they walk past it.
    @Test func theArrowTracksAFixedVenueTargetAcrossTheReplayedWalk() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let truth = try #require(trajectory.groundTruth)
        let target = SIMD3<Float>(0, 1.4, 5.5)

        var model = OverlayModel()
        model.apply(Command(id: "search", serverTimestamp: 0,
                            kind: .arrow(target: [target.x, target.y, target.z],
                                         bearingRadians: nil, label: "backpack")),
                    now: 0)

        var bearings: [Float] = []
        var distances: [Float] = []
        var onTargetCount = 0
        // Every tenth ground-truth sample: six per second, which is what the
        // overlay actually redraws at.
        for sample in stride(from: 0, to: truth.count, by: 10).compactMap({ truth[$0].pose }) {
            model.update(pose: sample, diagnostics: diagnostics(), transport: .init(),
                         transportState: .connected, now: 0)
            guard let arrow = model.state.arrow else {
                Issue.record("the arrow vanished during a clean replay")
                return
            }
            bearings.append(arrow.bearingRadians)
            distances.append(arrow.distance ?? 0)
            if arrow.isOnTarget { onTargetCount += 1 }
        }

        #expect(bearings.count > 500)
        #expect(bearings.allSatisfy { $0 >= -Float.pi - 1e-4 && $0 <= Float.pi + 1e-4 },
                "a bearing escaped the range a compass can express")
        let span = (bearings.max() ?? 0) - (bearings.min() ?? 0)
        #expect(span > 3.0, "the arrow only swung \(span) rad over a two-minute walk with a sweep")
        #expect(onTargetCount > 20, "the operator never once faced the target: \(onTargetCount) samples")
        #expect((distances.max() ?? 0) > (distances.min() ?? 0) + 1,
                "the distance to the target never changed while walking a room")

        // A target ahead, seen from a camera that has walked past it, must point
        // backwards rather than silently clamp.
        #expect(bearings.contains { abs($0) > 2.0 },
                "the arrow never pointed behind the operator")
    }
}
