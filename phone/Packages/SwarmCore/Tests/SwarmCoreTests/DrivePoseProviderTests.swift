import Foundation
import simd
import Testing
@testable import SwarmCore

/// A clock that only moves when something sleeps on it.
///
/// The drive loop is a real `Task` with a real `await`, but none of it needs to
/// take wall-clock time: `sleep` advances the simulated clock and yields, so
/// thirty-five seconds of "operator walking around" costs milliseconds and a
/// timing assertion can never flake.
final class SimulatedClock: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double

    init(start: Double = 1_000) { self.time = start }

    var now: Double {
        lock.lock(); defer { lock.unlock() }
        return time
    }

    /// The closure form the providers and the client take.
    var reading: @Sendable () -> Double { { [self] in self.now } }

    func sleep(seconds: Double) async throws {
        advance(by: seconds)
        // Let the consumer drain before the next pose is produced. Without this
        // the loop runs to its duration limit against a one-deep buffer and most
        // of what it produced is dropped.
        await Task.yield()
    }

    /// Separate and non-async because `NSLock.lock()` is unavailable from an
    /// async context — taking a lock across a suspension point is exactly the
    /// bug that rule exists to prevent, and this never does.
    private func advance(by seconds: Double) {
        lock.lock()
        time += seconds
        lock.unlock()
    }
}

/// `DrivePoseProvider` through the real session machine, the real venue and the
/// real calibration engine — the same way `ReplayHarness` drives the replay
/// path. `ReplayHarness` is untouched.
struct DriveHarness {
    let machine: SessionMachine
    let provider: DrivePoseProvider
    let venue: Venue
    let clock: SimulatedClock

    init(configuration: DrivePoseProvider.Configuration) throws {
        venue = try Venue.load(from: Fixtures.url("venue.json"))
        clock = SimulatedClock()
        provider = DrivePoseProvider(venue: venue, configuration: configuration,
                                     now: clock.reading, sleeper: clock)
        machine = SessionMachine(
            configuration: SessionMachine.Configuration(deviceID: "phone-sim",
                                                        emitsBeforeOrigin: true),
            venue: venue, provider: provider, clock: syncedClock())
    }

    func run() async throws -> [SessionEvent] {
        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        return await collector.value
    }
}

@Suite("Drive pose provider: through the real session machine", .serialized)
struct DrivePoseProviderTests {

    /// The first thing out of the provider must be the synthetic sighting, and
    /// it must be the truth: the marker seen exactly where `venue.json` says it
    /// is, so `Calibration.worldOriginTransform` is the identity and the engine
    /// records an origin with a measured error of zero. Nothing lies to the hub
    /// at any point — the disclosure is `build += "-drive"`, not a fake pose.
    @Test func theFirstSightingIsTheMarkerExactlyWhereTheVenueSaysItIs() async throws {
        let harness = try DriveHarness(configuration: .init(maxDuration: 0.2))
        let marker = try #require(harness.venue.primaryMarker)
        let markerPose = try #require(marker.pose)

        let stream = try await harness.provider.start()
        var first: PoseProviderEvent?
        for await event in stream { first = event; break }
        await harness.provider.stop()

        guard case .marker(let sighting)? = first else {
            Issue.record("the first event was \(String(describing: first)), not a marker")
            return
        }
        #expect(sighting.markerID == marker.id)
        #expect(!sighting.isUpdate)
        let origin = Calibration.worldOriginTransform(observed: Pose(matrix: sighting.observedTransform),
                                                      markerVenue: markerPose)
        #expect(simd_length(origin.position) < 1e-5, "the first sighting moved the origin by \(origin.position)")
        #expect(Geometry.angle(between: origin.orientation, and: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) < 1e-5)
    }

    /// Driven through the machine, the session reaches `.tracking` and every
    /// emitted pose is venue-frame — which is what makes `SwarmClient` send
    /// `slam` rather than pitch-only `orient`.
    @Test func theSessionTracksAndEveryPoseIsVenueFrame() async throws {
        let harness = try DriveHarness(configuration: .init(maxDuration: 3))
        let events = try await harness.run()
        let poses = events.poses
        #expect(poses.count > 10, "only \(poses.count) poses in three seconds")
        #expect(poses.allSatisfy { $0.inVenueFrame })
        #expect(poses.allSatisfy { $0.trackingState == "normal" },
                "the drive source must claim normal tracking, not a new quality case")
        #expect(events.rawPoses.isEmpty, "a marker-aligned drive must not emit raw poses")
        let diagnostics = await harness.machine.currentDiagnostics()
        #expect(diagnostics.state == .tracking)
    }

    /// The end-to-end "the mini-map shows where you drove" assertion: project
    /// what the session emitted and it must equal what the model believes.
    ///
    /// Standing still, deliberately. The stick is latched, so a walking operator
    /// keeps moving between the last throttled pose and the read below, and the
    /// comparison would be measuring the 10 Hz throttle rather than the
    /// transform. Walking is covered by `DriveMotionTests` and by
    /// `aHeldStickKeepsWalkingWithoutFurtherGestureEvents`; what is under test
    /// here is that an off-centre, rotated, pitched pose survives the trip into
    /// the venue frame and back.
    @Test func whatTheSessionEmitsProjectsBackToWhereTheOperatorDrove() async throws {
        let harness = try DriveHarness(configuration: .init(
            start: RoomPose(x: -3, y: 9, heading: 210, pitch: -12), maxDuration: 2))
        let events = try await harness.run()

        let last = try #require(events.poses.last)
        let pose = try #require(last.venuePose)
        let projected = RoomAlignment.identity.project(pose)
        let model = await harness.provider.roomPose

        #expect(isClose(projected.x, model.x, within: 1e-4),
                "the hub would draw the dot at \(projected.x), the operator drove to \(model.x)")
        #expect(isClose(projected.y, model.y, within: 1e-4))
        #expect(isClose(projected.pitch, model.pitch, within: 1e-3))
        // And against the values the model was started with, so a pair of
        // transforms that are consistently wrong cannot agree with each other.
        #expect(isClose(projected.x, -3, within: 1e-4))
        #expect(isClose(projected.y, 9, within: 1e-4))
        #expect(isClose(projected.pitch, -12, within: 1e-3))
        let projectedHeading = try #require(projected.heading)
        let modelHeading = try #require(model.heading)
        #expect(isClose(RoomMath.signedDiff(projectedHeading, modelHeading), 0, within: 1e-3))
        #expect(isClose(RoomMath.signedDiff(projectedHeading, 210), 0, within: 1e-3))
    }

    /// `SessionMachine` throttles 60 Hz input to 10 Hz poses, exactly as it does
    /// for ARKit and for the 60 Hz fixtures. Emitting at 60 is what makes that
    /// true without special-casing anything downstream.
    @Test func sixtyHertzInputIsThrottledToTenHertzPoses() async throws {
        let harness = try DriveHarness(configuration: .init(maxDuration: 10))
        let poses = try await harness.run().poses
        // The one-deep buffer and the cooperative clock cost some, so this
        // asserts the order of magnitude rather than exactly 100.
        #expect(poses.count > 40 && poses.count < 130,
                "ten seconds at a 10 Hz throttle gave \(poses.count) poses")
    }

    /// **The test that pins the ±3 cm every 5 s.** A sighting that agrees
    /// perfectly returns `.noChangeNeeded` and never refreshes
    /// `lastCorrectionTime`, so a drive session would show "Position may be
    /// drifting" after 30 s — a false alarm on the one screen this source exists
    /// to let someone look at.
    @Test func theStatusPillNeverFalselyClaimsDrift() async throws {
        let harness = try DriveHarness(configuration: .init(maxDuration: 35))
        let events = try await harness.run()

        let ages = events.poses.compactMap(\.lastCorrectionAge)
        #expect(!ages.isEmpty)
        let worst = try #require(ages.max())
        #expect(worst <= 30, "correction age reached \(worst) s; the pill would claim drift")

        // And prove the pill agrees, through the real status derivation.
        let diagnostics = await harness.machine.currentDiagnostics()
        var pill = StatusPill(sessionState: diagnostics.state,
                              trackingState: diagnostics.quality.wireValue,
                              confidence: diagnostics.confidence, isStale: diagnostics.isStale,
                              connection: .online, secondsSinceCorrection: diagnostics.lastCorrectionAge,
                              alignment: .marker)
        pill.thermalState = .nominal
        #expect(OperatorStatus(pill).title != "Position may be drifting")
    }

    /// The nudge alternates, so successive corrections cancel instead of walking
    /// the origin off across a long session.
    @Test func theResightingNudgeAlternatesAndCancels() async throws {
        let harness = try DriveHarness(configuration: .init(markerRefreshSeconds: 0.05,
                                                            maxDuration: 1))
        let markerPose = try #require(harness.venue.primaryMarker?.pose)
        let stream = try await harness.provider.start()
        var offsets: [Float] = []
        for await event in stream {
            if case .marker(let sighting) = event {
                offsets.append(Pose(matrix: sighting.observedTransform).position.x - markerPose.position.x)
            }
            if offsets.count >= 6 { break }
        }
        await harness.provider.stop()

        #expect(offsets.count >= 6)
        #expect(offsets[0] == 0, "the first sighting must be exact, so the origin lands right")
        for offset in offsets.dropFirst() {
            #expect(isClose(abs(offset), 0.03, within: 1e-5), "nudged \(offset) m")
        }
        // Above `CalibrationEngine`'s `noChangePositionMeters` (0.02) so the
        // correction is accepted at all, and far below the venue's
        // `maxStepMeters` so it is never clamped into a multi-sighting ramp.
        #expect(0.03 > 0.02)
        #expect(0.03 < Double(harness.venue.thresholds.maxStepMeters))
        let signs = offsets.dropFirst().map { $0 > 0 }
        #expect(zip(signs, signs.dropFirst()).allSatisfy { $0 != $1 }, "the nudge did not alternate")
    }

    /// `markers=0`: nothing is claimed at all. No sighting, so the session never
    /// gets an origin, `SwarmClient` sends pitch-only `orient`, and the operator
    /// locates themselves with a seat tap — which is exactly what the replay
    /// path does with `replayMarkers` off.
    @Test func withoutMarkersNothingIsClaimedUntilASeatTap() async throws {
        let harness = try DriveHarness(configuration: .init(emitsMarkers: false, maxDuration: 2))
        let events = try await harness.run()
        // `SessionEvent` has no marker case: a sighting shows up as a
        // correction, and without one the session never establishes an origin.
        #expect(!events.contains { if case .correctionApplied = $0 { return true } else { return false } })
        #expect(events.poses.isEmpty, "an unaligned drive must not emit venue-frame poses")
        let raw = events.rawPoses
        #expect(!raw.isEmpty)
        #expect(raw.allSatisfy { !$0.inVenueFrame })

        // A seat tap then places the drive frame in the room. The drive frame is
        // already the venue frame, so the alignment it produces is the identity
        // up to the seat.
        var aligner = RoomAligner()
        aligner.setSeat(HubSeat(x: 2, y: 6))
        let pose = try #require(raw.last?.venuePose)
        let calibrated = aligner.calibrateFacingStage(rawPose: pose)
        #expect(calibrated)
        let room = try #require(aligner.project(pose))
        #expect(isClose(room.x, 2, within: 1e-3))
        #expect(isClose(room.y, 6, within: 1e-3))
        let roomHeading = try #require(room.heading)
        #expect(isClose(RoomMath.signedDiff(roomHeading, 0), 0, within: 1e-3))
    }

    /// Bounds come from the hub's `welcome`, not from `venue.json`, which has no
    /// room dimensions at all. The view model forwards them; `PoseProvider` never
    /// learns what a room is.
    @Test func boundsArriveFromTheHubAndTakeEffect() async throws {
        let harness = try DriveHarness(configuration: .init(
            start: RoomPose(x: 0, y: 7, heading: 90, pitch: 0), maxDuration: 0.1))
        // A `welcome` describing a small room.
        let room = HubRoom(width: 6, depth: 4)
        await harness.provider.setBounds(DriveBounds(width: room.width, depth: room.depth))
        await harness.provider.apply(DriveInput(walk: SIMD2(0, 1)))
        _ = try await harness.run()
        let pose = await harness.provider.roomPose
        #expect(pose.x <= 6 / 2 - 0.25 + 1e-9, "walked to x = \(pose.x) in a 6 m room")
        #expect(pose.y <= 4 - 0.25 + 1e-9)
    }

    /// The default before `welcome` arrives is `room.json`'s 20 × 15.
    @Test func theDefaultBoundsAreRoomJSONs() {
        #expect(DriveBounds.roomJSON.width == 20)
        #expect(DriveBounds.roomJSON.depth == 15)
    }

    /// The disclosure mechanism, stated where it can regress: `.normal` on the
    /// wire, honesty in `build`. A new `TrackingQuality` case would change
    /// `wireValue`, which the hub and console own.
    @Test func theDriveSourceReportsNormalAndDisclosesItselfInBuild() async throws {
        let harness = try DriveHarness(configuration: .init(maxDuration: 1))
        let poses = try await harness.run().poses
        #expect(poses.allSatisfy { TrackingQuality(wireValue: $0.trackingState) == .normal })
        // How `SwarmRuntime` must announce it, the same way the replay path does.
        let hello = HubHello(phoneId: "p", name: "sim", build: "ios-1.0" + "-drive")
        #expect(hello.build == "ios-1.0-drive")
    }

    /// `setWorldOrigin` is a no-op by design: these poses are venue-frame by
    /// construction, not a SLAM estimate that drifts. The operator's dot must
    /// not jump when a 5 s re-sighting lands.
    @Test func setWorldOriginDoesNotMoveTheOperator() async throws {
        let harness = try DriveHarness(configuration: .init(
            start: RoomPose(x: 1, y: 8, heading: 45, pitch: 0), maxDuration: 0.1))
        let before = await harness.provider.roomPose
        var shove = matrix_identity_float4x4
        shove.columns.3 = SIMD4<Float>(5, 0, 5, 1)
        await harness.provider.setWorldOrigin(relativeTransform: shove)
        let after = await harness.provider.roomPose
        #expect(before == after)
    }

    /// Driven without the session machine, because the machine consumes this
    /// itself — that is the whole point of the accessor.
    @Test func motionIsAccumulatedForTheLostTrackingFallback() async throws {
        let harness = try DriveHarness(configuration: .init(emitsMarkers: false, maxDuration: 3))
        await harness.provider.apply(DriveInput(walk: SIMD2(0, 1)))
        let stream = try await harness.provider.start()
        for await _ in stream {}
        let moved = await harness.provider.consumeMotionSinceLastQuery()
        #expect(moved > 0.5, "three seconds of walking reported \(moved) m")
        let again = await harness.provider.consumeMotionSinceLastQuery()
        #expect(again == 0, "the same metres were reported twice")
    }

    /// A finger resting on the joystick produces no further gesture events, so a
    /// stick that reset every frame would stop the operator dead the moment they
    /// stopped moving their thumb. It is latched until the view sends `.zero`.
    @Test func aHeldStickKeepsWalkingWithoutFurtherGestureEvents() async throws {
        let harness = try DriveHarness(configuration: .init(
            emitsMarkers: false, start: RoomPose(x: 0, y: 12, heading: 90, pitch: 0),
            maxDuration: 3))
        await harness.provider.apply(DriveInput(walk: SIMD2(0, 1)))   // one event, then nothing
        let stream = try await harness.provider.start()
        for await _ in stream {}
        let walked = await harness.provider.roomPose
        #expect(walked.x > 2, "one touch-down walked only \(walked.x) m in three seconds")

        // Letting go stops it.
        await harness.provider.apply(DriveInput(walk: .zero))
        let before = await harness.provider.roomPose
        let second = try await harness.provider.start()
        for await _ in second {}
        let after = await harness.provider.roomPose
        #expect(isClose(after.x, before.x, within: 0.5), "still walking after letting go")
    }

    /// The fixtures' intrinsics, not a measured camera — so the marker overlay
    /// and `Projection` have something sane, and so the numbers are traceable to
    /// something rather than invented.
    @Test func theIntrinsicsAreTheSyntheticFixturesOwn() {
        #expect(DrivePoseProvider.intrinsics == Sample.intrinsics())
    }
}
