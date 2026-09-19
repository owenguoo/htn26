import Foundation
import Testing
@testable import SwarmCore

/// Gates 1 and 2, driven the same way every other gate is: `MockPoseProvider`
/// replaying `Fixtures/trajectory-*.json`.
///
/// The unit tests for those gates use synthetic inputs, because a wire message
/// and a clock exchange are not trajectory-shaped. These are the counterpart:
/// the whole chain from a recorded walk through the state machine and out of the
/// socket, so a protocol or clock regression cannot hide behind a mock.
@Suite("Gates 1 and 2 over the replayed fixture", .serialized)
struct ReplayIntegrationTests {

    // MARK: - Gate 1 over the replay

    /// Every pose the replay produces projects into the room and encodes as a
    /// `slam` the hub's `set_external_pose` will accept: finite x and y, heading
    /// in [0, 360). A test over invented values would not catch a field that
    /// only goes wrong for real motion.
    @Test func everyReplayedPoseBecomesAValidSlam() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let poses = try await harness.run().poses
        #expect(poses.count > 500)

        for (index, update) in poses.enumerated() {
            #expect(update.inVenueFrame)
            let room = RoomAlignment.identity.project(try #require(update.venuePose))
            let message = DeliveredMessage(try HubOutbound.slam(x: room.x, y: room.y, heading: room.heading,
                                                                pitch: room.pitch).encoded())
            #expect(message.type == "slam")
            let x = try #require(message.number("x")), y = try #require(message.number("y"))
            #expect(x.isFinite && y.isFinite, "pose \(index)")
            #expect(isClose(x, Double(update.position[0]), within: 1e-6))
            #expect(isClose(y, Double(update.position[2]), within: 1e-6))
            if let heading = message.number("heading") {
                #expect(heading >= 0 && heading < 360, "pose \(index) heading \(heading)")
            }
        }
    }

    /// The real shape of the backpressure claim: a recorded walk driving a socket
    /// that cannot keep up. In-flight stays bounded, drops rise, and the pose
    /// that survives is the latest one — not one from thirty seconds ago.
    @Test func aStarvedSocketUnderReplayDropsAndKeepsTheNewest() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let poses = try await harness.run().poses
        #expect(poses.count > 500)

        let channel = GatedChannel()
        let factory = ScriptedChannelFactory(channels: [channel])
        let transport = Transport(
            configuration: .init(url: URL(string: "ws://127.0.0.1:8000/ws/phone")!,
                                 maxInFlight: 1, bufferDepth: 1),
            factory: factory, sleeper: RecordingSleeper())
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        // The socket accepts roughly one message for every twenty offered, which
        // is the ratio a phone hits when the Wi-Fi in a crowded hall degrades.
        for (index, _) in poses.enumerated() {
            await transport.send(Sample.slam(index))
            if index % 20 == 0 { await channel.grant(1) }
            await Task.yield()
            let buffered = await transport.bufferedMessageCount()
            #expect(buffered <= 1, "the buffer grew to \(buffered) at pose \(index)")
        }
        await channel.grant(50)
        await waitUntil("drained and settled") {
            let buffered = await transport.bufferedMessageCount()
            let inFlight = await transport.currentStats().inFlight
            return buffered == 0 && inFlight == 0
        }

        let stats = await transport.currentStats()
        #expect(stats.dropped > poses.count / 2, "only \(stats.dropped) of \(poses.count) dropped")
        #expect(stats.sent + stats.dropped == poses.count)
        #expect(stats.inFlight == 0)

        let sequences = await channel.deliveredMessages().filter { $0.type == "slam" }
            .compactMap { $0.number("x").map(Int.init) }
        #expect(!sequences.isEmpty)
        // Delivered poses must be in order and must reach the end of the walk.
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 },
                "delivered poses were out of order")
        #expect(sequences.last == poses.count - 1,
                "the final pose of the walk was dropped in favour of an older one")
        await transport.stop()
    }

    /// Frames are perishable too, and a burst of them must not starve the pose
    /// stream — the dashboard can survive missing pictures but not missing cones.
    @Test func framesDoNotStarvePosesUnderReplay() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let events = try await harness.run()

        let channel = GatedChannel()
        let factory = ScriptedChannelFactory(channels: [channel])
        let transport = Transport(
            configuration: .init(url: URL(string: "ws://127.0.0.1:8000/ws/phone")!,
                                 maxInFlight: 1, bufferDepth: 1),
            factory: factory, sleeper: RecordingSleeper())
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for event in events {
            switch event {
            case .pose(let update):
                await transport.send(Sample.slam(Int(update.seq)))
            case .captureFrame(let ticket):
                let encoded = EncodedFrame(frameID: ticket.frameID, jpeg: Data(repeating: 0, count: 512),
                                           width: 720, height: 960, intrinsics: ticket.intrinsics)
                await transport.send(FrameAssembly.frame(
                    ticket: ticket, encoded: encoded, room: nil, calibrated: true, tCaptureMs: 0,
                    encodedAt: ticket.serverTimestamp + 0.018,
                    sentAt: ticket.serverTimestamp + 0.027).message)
            default:
                break
            }
            await channel.grant(1)
            await Task.yield()
        }
        await channel.grant(100)
        await waitUntil("drained and settled") {
            let buffered = await transport.bufferedMessageCount()
            let inFlight = await transport.currentStats().inFlight
            return buffered == 0 && inFlight == 0
        }

        let delivered = await channel.deliveredMessages()
        let poseCount = delivered.filter { $0.type == "slam" }.count
        let frameCount = delivered.filter { $0.type == "frame" }.count
        #expect(poseCount > 0)
        #expect(frameCount > 0, "frames were starved out entirely")
        #expect(poseCount > frameCount,
                "poses (\(poseCount)) did not outnumber frames (\(frameCount)) — the round-robin is favouring the wrong traffic")

        // The socket is granted a permit per message here, so it keeps up and
        // there is nothing to drop. What matters is that nothing was lost
        // silently: every offered message is either sent or counted.
        let stats = await transport.currentStats()
        let offered = events.poses.count + events.frames.count
        #expect(stats.sent + stats.dropped + stats.sendFailures == offered)
        #expect(stats.sendFailures == 0)
        await transport.stop()
    }

    // MARK: - Gate 2 over the replay

    /// With `requireClockSync` on — for a server that fuses on these timestamps,
    /// which the htn26 hub does not — the phone sends nothing until the clock
    /// has converged. Fusing on device uptime is worse than fusing on nothing.
    @Test func noPoseLeavesTheDeviceBeforeTheClockHasSynchronised() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        let provider = MockPoseProvider(trajectory: trajectory)
        // A brand new, unsynchronised clock.
        let machine = SessionMachine(configuration: .init(deviceID: "phone-a", requireClockSync: true),
                                     venue: venue, provider: provider, clock: ClockSync())

        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        let events = await collector.value

        #expect(events.poses.isEmpty, "\(events.poses.count) poses were sent on an unsynchronised clock")
        #expect(events.frames.isEmpty)
        #expect(events.states.contains(.tracking), "the session did track; it just could not report")
        let diagnostics = await machine.currentDiagnostics()
        #expect(diagnostics.isBlockedOnClockSync, "the status pill would not say why nothing is flowing")
        await machine.stop()
    }

    /// A session stuck in calibrating with a perfectly good clock must not blame
    /// the clock. The status pill is the only thing an operator has to tell
    /// "point at a marker" apart from "the clock has not converged", and getting
    /// that backwards sends them to debug the wrong thing.
    @Test func calibratingWithAGoodClockDoesNotBlameTheClock() async throws {
        var blind = try Fixtures.trajectory("trajectory-walk-2min.json")
        blind.markerEvents = []
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
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

        #expect(events.poses.isEmpty, "nothing should be sent from an arbitrary frame")
        let diagnostics = await machine.currentDiagnostics()
        #expect(diagnostics.state == .calibrating)
        #expect(!diagnostics.isBlockedOnClockSync,
                "the pill blamed the clock for what is a missing marker")
        await machine.stop()
    }

    /// The same replay with a converged clock: every pose carries a server
    /// timestamp that is the device timestamp plus one constant offset, and the
    /// two orderings agree.
    @Test func replayedPosesCarryConsistentServerTimestamps() async throws {
        let offset = 1_700_000_000.0
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json", clockOffset: offset)
        let poses = try await harness.run().poses
        #expect(poses.count > 500)

        let offsets = poses.map { $0.serverTimestamp - $0.deviceTimestamp }
        let spread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        #expect(spread < 1e-6, "the offset drifted by \(spread) s across the replay")
        #expect(isClose(offsets[0], offset, within: 0.020),
                "offset was \(offsets[0]), expected about \(offset)")

        let deviceTimes = poses.map(\.deviceTimestamp)
        let serverTimes = poses.map(\.serverTimestamp)
        #expect(zip(deviceTimes, deviceTimes.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(zip(serverTimes, serverTimes.dropFirst()).allSatisfy { $0 <= $1 })
        // A server timestamp near the epoch means the conversion silently fell
        // back to device uptime, which is exactly the failure Gate 2 exists for.
        #expect(serverTimes.allSatisfy { $0 > 1_600_000_000 },
                "a pose went out on device uptime dressed as server time")
    }

    /// Two phones replaying the same walk with different uptimes must land on the
    /// same server timeline. This is the thing that makes cross-phone fusion
    /// mean anything at all.
    @Test func twoDevicesWithDifferentUptimesAgreeOnServerTime() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        let serverEpoch = 1_700_000_000.0

        /// Replays the same recording as if the phone had booted `uptimeShift`
        /// seconds earlier or later, which is what actually differs between two
        /// phones in a room.
        func replay(uptimeShift: Double) async throws -> [PoseUpdate] {
            var shifted = trajectory
            shifted.samples = trajectory.samples.map {
                Trajectory.Sample(t: $0.t + uptimeShift, transform: $0.transform,
                                  trackingState: $0.trackingState)
            }
            shifted.markerEvents = trajectory.markerEvents.map {
                Trajectory.MarkerEvent(t: $0.t + uptimeShift, markerID: $0.markerID,
                                       transform: $0.transform, isUpdate: $0.isUpdate,
                                       estimatedPhysicalWidth: $0.estimatedPhysicalWidth)
            }
            let provider = MockPoseProvider(trajectory: shifted)
            // Each phone's own offset is whatever makes its uptime line up with
            // the shared server clock.
            let firstSample = try #require(shifted.samples.first?.t)
            let machine = SessionMachine(
                configuration: .init(deviceID: "phone-\(Int(uptimeShift))"),
                venue: venue, provider: provider,
                clock: syncedClock(offset: serverEpoch - firstSample))
            let stream = await machine.start()
            let collector = Task {
                var events: [SessionEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            try await machine.permissionsGranted()
            return await collector.value.poses
        }

        // One phone booted four hours before the other.
        let a = try await replay(uptimeShift: 0)
        let b = try await replay(uptimeShift: 14_400)
        #expect(!a.isEmpty && !b.isEmpty)

        let startA = try #require(a.first?.serverTimestamp)
        let startB = try #require(b.first?.serverTimestamp)
        #expect(isClose(startA, startB, within: 0.15),
                "two phones replaying the same walk started \(abs(startA - startB)) s apart on the server clock")

        // Their raw uptimes, by contrast, are four hours apart — which is exactly
        // why the server must never see them.
        let uptimeA = try #require(a.first?.deviceTimestamp)
        let uptimeB = try #require(b.first?.deviceTimestamp)
        #expect(abs(uptimeA - uptimeB) > 14_000,
                "the fixture shift did not take, so this test proves nothing")
    }
}
