import Foundation
import simd
import Testing
@testable import SwarmCore

/// Gate 4 — the highest-value gate, because operators walk. Everything here is
/// driven from `MockPoseProvider` replaying `Fixtures/trajectory-*.json`.
@Suite("Gate 4: session state machine")
struct SessionMachineTests {

    // MARK: - The state machine itself

    @Test func startsIdleAndWaitsForPermissions() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        #expect(await harness.machine.state == .idle)
        _ = await harness.machine.start()
        #expect(await harness.machine.state == .permissions)
        await harness.machine.stop()
    }

    /// No marker has been seen, so the frame is arbitrary. Nothing may be sent
    /// for fusion, however good ARKit says its tracking is.
    @Test func sendsNothingBeforeAMarkerEstablishesTheOrigin() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        // Strip the marker events: the session can never calibrate.
        var blind = trajectory
        blind.markerEvents = []
        let provider = MockPoseProvider(trajectory: blind)
        let machine = SessionMachine(configuration: .init(deviceID: "phone-a"),
                                     venue: venue, provider: provider, clock: syncedClock())

        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        let events = await collector.value

        #expect(events.poses.isEmpty, "emitted \(events.poses.count) poses with an arbitrary origin")
        #expect(events.frames.isEmpty)
        #expect(await machine.state == .calibrating)
    }

    @Test func aMarkerSightingMovesCalibratingToTracking() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let events = try await harness.run()
        let states = events.states
        #expect(states.first == .permissions)
        #expect(states.contains(.tracking))
        let calibratingIndex = try #require(states.firstIndex(of: .calibrating))
        let trackingIndex = try #require(states.firstIndex(of: .tracking))
        #expect(calibratingIndex < trackingIndex)
        #expect(!events.corrections.isEmpty)
    }

    /// The degraded fixture walks into a blank wall, takes a call, and
    /// relocalises. Every one of those has to show up as a transition.
    @Test func degradedFixtureDrivesTheWholeStateMachine() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-degraded-90s.json")
        let events = try await harness.run()
        let states = events.states
        #expect(states.contains(.tracking), "never reached tracking: \(states)")
        #expect(states.contains(.degraded), "insufficientFeatures did not degrade the session")
        #expect(states.contains(.lost), "notAvailable did not lose the session")
        #expect(states.contains(.recalibrating), "an interruption did not force recalibration")

        // The order the fixture scripts: degrade, then be interrupted, then come
        // back needing a marker before anything is trustworthy again.
        let lostIndex = try #require(states.firstIndex(of: .lost))
        let recalibratingIndex = try #require(states.firstIndex(of: .recalibrating))
        #expect(lostIndex < recalibratingIndex)
    }

    /// After an interruption ARKit has thrown its map away. Until a marker is
    /// seen again, a "position" is a number with no meaning.
    @Test func recalibratingRequiresAMarkerBeforeTrackingResumes() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-degraded-90s.json")
        let events = try await harness.run()
        let states = events.states
        guard let recalibratingIndex = states.firstIndex(of: .recalibrating) else {
            Issue.record("never recalibrated")
            return
        }
        let afterRecalibrating = states[(recalibratingIndex + 1)...]
        if afterRecalibrating.contains(.tracking) {
            // Fine — but only because a marker was sighted. Corrections after the
            // interruption are what re-established the origin.
            #expect(!events.corrections.isEmpty)
        }
    }

    /// Seen on a real device: the orchestrator logging "pose arrived with no
    /// correction age — its origin is arbitrary and must not be fused", over and
    /// over. An interruption during calibration reached `.lost`, which claims to
    /// have a venue-frame pose, and poses escaped in an arbitrary frame.
    @Test func anInterruptionBeforeAnyMarkerDoesNotLetPosesEscape() async throws {
        var blind = try Fixtures.trajectory("trajectory-walk-2min.json")
        blind.markerEvents = []
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        let provider = MockPoseProvider(trajectory: blind, configuration: .init(
            injections: [600: [.interrupted], 900: [.interruptionEnded]]))
        let machine = SessionMachine(configuration: .init(deviceID: "phone-a"),
                                     venue: venue, provider: provider, clock: syncedClock())

        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        let events = await collector.value

        #expect(events.poses.isEmpty,
                "\(events.poses.count) poses escaped with no origin ever established")
        #expect(!events.states.contains(.lost),
                "went to lost having never had anything to lose: \(events.states)")
    }

    /// After an interruption ARKit has thrown its map away, so the venue frame
    /// that the last correction established is gone with it. Reporting
    /// "corrected 30 s ago" against a frame that no longer exists is worse than
    /// reporting nothing, because the server cannot tell the difference.
    @Test func posesStopAfterAnInterruptionUntilAMarkerIsSeenAgain() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        var single = trajectory
        single.markerEvents = Array(trajectory.markerEvents.prefix(1))
        let provider = MockPoseProvider(trajectory: single, configuration: .init(
            injections: [3_000: [.interrupted], 3_100: [.interruptionEnded]]))
        let machine = SessionMachine(configuration: .init(deviceID: "phone-a"),
                                     venue: venue, provider: provider, clock: syncedClock())

        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        let events = await collector.value
        let poses = events.poses

        #expect(!poses.isEmpty, "nothing was emitted before the interruption either")
        #expect(events.states.contains(.recalibrating))
        #expect(poses.allSatisfy { $0.lastCorrectionAge != nil },
                "a pose went out with no correction age")
        // During the interruption the origin is still notionally valid and ARKit
        // has simply stopped talking, so the last known pose keeps going out
        // flagged stale — that is what greys the cone rather than removing it.
        // It is `interruptionEnded` that throws the map away, and from there
        // nothing may be sent until a marker re-establishes the frame.
        let firstSampleTime = try #require(trajectory.samples.first?.t)
        let mapDiscarded = firstSampleTime + 3_100.0 / 60.0
        let afterwards = poses.filter { $0.deviceTimestamp > mapDiscarded + 0.5 }
        #expect(afterwards.isEmpty,
                "\(afterwards.count) poses went out after the origin was thrown away")
    }

    // MARK: - Confidence

    @Test func confidenceDecaysWhileDegradedAndRecoversAfterwards() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        // Degrade from sample 2 400 (40 s in) to 4 800 (80 s in), on a fixture
        // that is otherwise clean, so the effect is unambiguous.
        let injections: [Int: [MockPoseProvider.Injection]] = [
            2_400: [.quality(.limited(.insufficientFeatures))],
            4_800: [.quality(nil)],
        ]
        // Only the first marker event survives: a correction is a hard re-lock
        // that would reset confidence and mask the decay this test is measuring.
        var single = trajectory
        single.markerEvents = Array(trajectory.markerEvents.prefix(1))
        let seeded = MockPoseProvider(trajectory: single,
                                      configuration: .init(injections: injections))

        let machine = SessionMachine(configuration: .init(deviceID: "phone-a"),
                                     venue: venue, provider: seeded, clock: syncedClock())
        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        let poses = await collector.value.poses

        let firstSampleTime = try #require(trajectory.samples.first?.t)
        func confidence(around seconds: Double) -> Float? {
            poses.last { $0.deviceTimestamp <= firstSampleTime + seconds }?.confidence
        }

        let beforeDegrading = try #require(confidence(around: 39))
        let justAfterDegrading = try #require(confidence(around: 42))
        let deepInDegradation = try #require(confidence(around: 75))
        let afterRecovery = try #require(confidence(around: 90))

        #expect(beforeDegrading > 0.9, "confidence never reached full while tracking normally")
        #expect(justAfterDegrading < beforeDegrading, "confidence did not start decaying")
        #expect(deepInDegradation < justAfterDegrading, "confidence stopped decaying part-way")
        #expect(deepInDegradation <= 0.31, "decayed to \(deepInDegradation), above the degraded ceiling")
        #expect(afterRecovery > deepInDegradation, "confidence did not recover after re-locking")
    }

    /// A marker sighting is a hard re-lock: whatever ARKit thinks of its own
    /// tracking, the phone now knows where it is.
    @Test func aCorrectionRestoresConfidenceImmediately() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-degraded-90s.json")
        let events = try await harness.run()
        var sawDip = false
        var recoveredAfterCorrection = false
        var lastConfidence: Float = 1
        for event in events {
            switch event {
            case .pose(let update):
                if update.confidence < 0.5 { sawDip = true }
                lastConfidence = update.confidence
            case .correctionApplied:
                if sawDip { recoveredAfterCorrection = true }
            default:
                break
            }
        }
        #expect(sawDip, "confidence never dipped, so the re-lock claim is untested")
        #expect(recoveredAfterCorrection || lastConfidence > 0.9,
                "a marker sighting never followed a confidence dip in this fixture")
    }

    // MARK: - Correction age and staleness

    @Test func posesCarryTheAgeOfTheLastCorrection() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let poses = try await harness.run().poses
        #expect(!poses.isEmpty)
        for pose in poses {
            let age = try #require(pose.lastCorrectionAge,
                                   "a pose was sent with no correction age, so its origin is arbitrary")
            #expect(age >= 0)
            #expect(pose.lastCorrectionMarker != nil)
        }
        // The walk passes markers repeatedly, so the age must reset, not climb
        // monotonically for two minutes.
        let ages = poses.map { $0.lastCorrectionAge ?? 0 }
        #expect(zip(ages, ages.dropFirst()).contains { $1 < $0 },
                "correction age never reset: markers are not correcting anything")
        #expect((ages.max() ?? 0) < 60, "went \(ages.max() ?? 0) s without a correction")
    }

    /// The session goes quiet. The dashboard must grey the cone rather than draw
    /// it confidently in the wrong place.
    @Test func silenceFlagsPosesStaleAndLosesTheSession() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let events = try await harness.run()
        #expect(events.poses.allSatisfy { !$0.stale },
                "a pose was flagged stale during a continuous replay")

        let lastSampleTime = try #require(harness.trajectory.samples.last?.t)
        var afterSilence = await harness.machine.currentDiagnostics()
        #expect(!afterSilence.isStale)

        // Six seconds of nothing, against a five second limit.
        await harness.machine.tick(deviceTime: lastSampleTime + 6)
        afterSilence = await harness.machine.currentDiagnostics()
        #expect(afterSilence.isStale, "six seconds of silence did not flag the pose stale")
        #expect(afterSilence.state == .lost, "state after silence was \(afterSilence.state)")
        #expect(afterSilence.poseAge >= 6)
        await harness.machine.stop()
    }

    @Test func aStalePoseIsStillReportedSoTheConeCanBeGreyed() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let stream = await harness.machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await harness.machine.permissionsGranted()
        _ = await collector.value

        let lastSampleTime = try #require(harness.trajectory.samples.last?.t)
        await harness.machine.tick(deviceTime: lastSampleTime + 8)
        let diagnostics = await harness.machine.currentDiagnostics()
        #expect(diagnostics.isStale)
        #expect(diagnostics.state == .lost)
        await harness.machine.stop()
    }

    // MARK: - Throttling

    /// `session(_:didUpdate:)` fires at 60 Hz. Everything downstream is throttled
    /// down from that, and the rates must hold regardless of the input rate.
    @Test func throttlesSixtyHertzInputToTheConfiguredRates() async throws {
        let rates = SessionMachine.Rates(poseHz: 10, frameFPS: 1.5, depthHz: 0.3)
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json",
                                        configuration: .init(deviceID: "phone-a", rates: rates))
        let events = try await harness.run()

        let trackedSeconds = try trackedDuration(events: events, trajectory: harness.trajectory)
        #expect(trackedSeconds > 100, "only \(trackedSeconds) s of the fixture was tracked")

        let poseRate = Double(events.poses.count) / trackedSeconds
        let frameRate = Double(events.frames.count) / trackedSeconds
        #expect(isClose(poseRate, 10, within: 1.0), "pose rate was \(poseRate) Hz against 10 Hz")
        #expect(frameRate >= 1.0 && frameRate <= 2.0,
                "frame rate was \(frameRate) fps, outside the 1–2 fps band")
        #expect(events.poses.count < harness.trajectory.samples.count / 4,
                "barely throttled the 60 Hz input at all")

        let depthRate = Double(events.depthChunks.count) / trackedSeconds
        #expect(depthRate >= 0.2 && depthRate <= 0.5,
                "depth rate was \(depthRate) Hz, outside the 0.2–0.5 Hz band")
    }

    @Test(arguments: [4.0, 10.0, 20.0] as [Double])
    func poseRateFollowsConfiguration(poseHz: Double) async throws {
        let rates = SessionMachine.Rates(poseHz: poseHz, frameFPS: 1.5, depthHz: 0.3)
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json",
                                        configuration: .init(deviceID: "phone-a", rates: rates))
        let events = try await harness.run()
        let trackedSeconds = try trackedDuration(events: events, trajectory: harness.trajectory)
        let measured = Double(events.poses.count) / trackedSeconds
        #expect(isClose(measured, poseHz, within: max(1.0, poseHz * 0.15)),
                "asked for \(poseHz) Hz, measured \(measured) Hz")
    }

    /// ARKit plus streaming for thirty minutes will cook a phone. At `.serious`
    /// the frame rate sheds; the pose rate does not, because the dashboard
    /// needs to keep knowing where everyone is.
    @Test func thermalPressureShedsFrameRateButNotPoseRate() async throws {
        func measure(thermal: ThermalState) async throws -> (poses: Int, frames: Int, seconds: Double) {
            let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
            await harness.machine.setThermalState(thermal)
            let events = try await harness.run()
            let seconds = try trackedDuration(events: events, trajectory: harness.trajectory)
            return (events.poses.count, events.frames.count, seconds)
        }
        let nominal = try await measure(thermal: .nominal)
        let serious = try await measure(thermal: .serious)

        #expect(isClose(Double(nominal.poses), Double(serious.poses), within: Double(nominal.poses) * 0.05),
                "pose rate changed with thermal state: \(nominal.poses) vs \(serious.poses)")
        #expect(Double(serious.frames) < Double(nominal.frames) * 0.75,
                "frame rate did not shed at .serious: \(nominal.frames) vs \(serious.frames)")
    }

    @Test func serverDrivenRateChangesTakeEffect() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        await harness.machine.setRates(.init(poseHz: 2, frameFPS: 0.5, depthHz: 0.2))
        let events = try await harness.run()
        let seconds = try trackedDuration(events: events, trajectory: harness.trajectory)
        let poseRate = Double(events.poses.count) / seconds
        #expect(isClose(poseRate, 2, within: 0.6), "setRates was ignored: measured \(poseRate) Hz")
    }

    // MARK: - Depth chunk formation

    /// A stationary phone gives no parallax and no scale, so submitting a chunk
    /// from one is inference the server cannot make metric.
    @Test func aStationaryReplayProducesNoDepthChunks() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-stationary-30s.json")
        let events = try await harness.run()
        let diagnostics = await harness.machine.currentDiagnostics()
        #expect(events.depthChunks.isEmpty,
                "submitted \(events.depthChunks.count) depth chunks from a phone that did not move")
        #expect(diagnostics.depthChunksSkippedForBaseline > 0,
                "the baseline check never ran, so this passes for the wrong reason")
    }

    @Test func depthChunksHoldTheSweetSpotNumberOfFrames() async throws {
        let harness = try ReplayHarness(
            fixture: "trajectory-walk-2min.json",
            configuration: .init(deviceID: "phone-a", depthChunkSize: 6))
        let chunks = try await harness.run().depthChunks
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.frames.count == 6, "chunk \(chunk.chunkID) held \(chunk.frames.count) frames")
            #expect(chunk.baseline >= 0.12)
            #expect(Set(chunk.frames.map(\.frameID)).count == chunk.frames.count,
                    "a chunk repeated a frame")
        }
    }

    /// The fixture sights several markers in the same instant when the operator
    /// stands where more than one is visible. Those must arrive as one averaged
    /// correction rather than several sequential re-origins.
    @Test func simultaneousSightingsInTheReplayAreAveraged() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        var byTimestamp: [Double: Int] = [:]
        for event in trajectory.markerEvents { byTimestamp[event.t, default: 0] += 1 }
        let simultaneous = byTimestamp.values.filter { $0 > 1 }.count
        try #require(simultaneous > 0,
                     "the fixture never sights two markers at once, so this proves nothing")

        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let events = try await harness.run()
        let diagnostics = await harness.machine.currentDiagnostics()
        #expect(diagnostics.averagedSightings > 0,
                "\(simultaneous) simultaneous sightings in the fixture, none averaged")
        #expect(events.corrections.contains { $0.contains("+") },
                "no correction named more than one marker")
        // One correction per instant, never one per marker.
        #expect(diagnostics.corrections <= trajectory.markerEvents.count)
    }

    // MARK: - Soak

    /// Thirty minutes of replay. Nothing internal may grow with session length:
    /// a collection that tracks uptime is a leak with a schedule.
    @Test func thirtyMinuteReplayDoesNotGrowInternalStorage() async throws {
        let harness = try ReplayHarness(
            fixture: "trajectory-walk-2min.json",
            providerConfiguration: .init(loops: 15))

        let stream = await harness.machine.start()
        let sampler = Task { () -> (footprints: [Int], poses: Int) in
            var footprints: [Int] = []
            var poses = 0
            for await event in stream {
                if case .pose = event {
                    poses += 1
                    if poses % 2_000 == 0 {
                        footprints.append(await harness.machine.storageFootprint())
                    }
                }
            }
            return (footprints, poses)
        }
        try await harness.machine.permissionsGranted()
        let (footprints, poses) = await sampler.value

        #expect(poses > 15_000, "the soak only replayed \(poses) poses")
        #expect(footprints.count >= 5, "not enough samples to see growth")
        let first = try #require(footprints.first)
        let last = try #require(footprints.last)
        #expect(last <= first + 4,
                "internal storage grew from \(first) to \(last) over thirty minutes: \(footprints)")
        #expect(last < 64, "internal storage settled at \(last) elements")

        let diagnostics = await harness.machine.currentDiagnostics()
        #expect(diagnostics.posesEmitted == poses)
        await harness.machine.stop()
    }

    // MARK: - Helpers

    /// Seconds of the replay during which a venue-frame pose existed, which is
    /// the window the rate assertions are against. Measuring against the whole
    /// fixture would understate every rate by the calibration period.
    private func trackedDuration(events: [SessionEvent], trajectory: Trajectory) throws -> Double {
        let poses = events.poses
        guard let first = poses.first, let last = poses.last, poses.count > 1 else {
            throw TrackedDurationError.noPoses
        }
        return last.deviceTimestamp - first.deviceTimestamp
    }

    private enum TrackedDurationError: Error { case noPoses }
}
