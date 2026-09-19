import Foundation
import Testing
@testable import SwarmCore

/// Regressions found by REVIEW.md. Each of these failed against the code as it
/// stood and asserts on what the session does over time, not on whether a state
/// was ever visited — `states.contains(.lost)` is how the first one hid.
@Suite("Review: behaviour the fixtures were too clean to show")
struct FieldBehaviourTests {

    /// Runs the clean walk with only its first marker event, so nothing after
    /// calibration re-locks the session and masks what is being measured.
    private func run(injections: [Int: [MockPoseProvider.Injection]],
                     maxDuration: Double) async throws -> (machine: SessionMachine, events: [SessionEvent]) {
        var trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        trajectory.markerEvents = Array(trajectory.markerEvents.prefix(1))
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        let provider = MockPoseProvider(trajectory: trajectory,
                                        configuration: .init(maxDuration: maxDuration, injections: injections))
        let machine = SessionMachine(configuration: .init(deviceID: "phone-a"),
                                     venue: venue, provider: provider, clock: syncedClock())
        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        return (machine, await collector.value)
    }

    /// "Degraded for longer than this and the session is considered lost." Thirty
    /// seconds of unbroken `.limited` is one loss, not a new one every four
    /// seconds with `degraded` in between.
    @Test func unbrokenLimitedTrackingIsLostOnceAndStaysLost() async throws {
        let (machine, events) = try await run(
            injections: [600: [.quality(.limited(.insufficientFeatures))]], maxDuration: 40)
        let losses = events.states.filter { $0 == .lost }.count
        #expect(losses == 1, "went lost \(losses) times: \(events.states.map(\.rawValue))")
        let final = await machine.state
        #expect(final == .lost,
                "thirty seconds into unbroken limited tracking the session reports \(final)")
        await machine.stop()
    }

    /// DEVICE_CHECKLIST.md item 8: "No pose was sent while recalibrating. The
    /// origin is invalid after an interruption." The synthetic fixture keeps the
    /// same world frame across its interruption, so poses sent here look right
    /// in replay; on a phone they are in whatever frame ARKit restarted with.
    @Test func nothingIsSentWhileRecalibrating() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-degraded-90s.json")
        let events = try await harness.run()
        var state = SessionState.idle
        var poses = 0
        var frames = 0
        for event in events {
            switch event {
            case .stateChanged(_, let to): state = to
            case .pose where state == .recalibrating: poses += 1
            case .captureFrame where state == .recalibrating: frames += 1
            default: break
            }
        }
        try #require(events.states.contains(.recalibrating), "the fixture never recalibrated")
        #expect(poses == 0, "\(poses) poses were sent from an invalid origin")
        #expect(frames == 0, "\(frames) frames were requested from an invalid origin")
    }

    /// A real interruption delivers no frames at all, so the last tracking state
    /// ARKit reported before it is `.normal`. The fixture instead keeps sampling
    /// through its interruption with `notAvailable`, which is what drove
    /// confidence down in replay. Without that, a backgrounded phone reported
    /// full confidence until the staleness limit.
    @Test func anInterruptionWithNoFramesStillDropsConfidence() async throws {
        let (machine, _) = try await run(
            injections: [600: [.interrupted, .dropout(count: 1_000_000)]], maxDuration: 20)
        let interrupted = await machine.currentDiagnostics()
        #expect(interrupted.state == .lost)
        let interruptedAt = try Fixtures.trajectory("trajectory-walk-2min.json").samples[599].t

        // Three seconds in: not yet stale, so confidence is the only thing
        // telling the dashboard not to believe this cone.
        await machine.tick(deviceTime: interruptedAt + 3)
        let later = await machine.currentDiagnostics()
        #expect(!later.isStale)
        #expect(later.confidence < 0.5,
                "three seconds into an interruption confidence is still \(later.confidence)")
        await machine.stop()
    }
}
