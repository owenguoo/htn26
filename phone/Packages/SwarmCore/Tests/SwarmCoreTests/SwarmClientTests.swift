import Foundation
import Testing
@testable import SwarmCore

/// The headless client against a scripted socket. The same thing against the
/// real hub is `Scripts/e2e-hub.sh`; this is the part that must not need one.
@Suite("Swarm client", .serialized)
struct SwarmClientTests {
    private func makeClient(markers: Bool, channel: GatedChannel) throws -> SwarmClient {
        var trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        if !markers { trajectory.markerEvents = [] }
        let provider = MockPoseProvider(trajectory: trajectory,
                                        configuration: .init(playbackRate: 20, maxDuration: 30))
        let uptime: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
        return SwarmClient(
            configuration: .init(socketURL: URL(string: "ws://127.0.0.1:8000/ws/phone")!,
                                 phoneId: "phone-a", name: "Dawson",
                                 venue: try Venue.load(from: Fixtures.url("venue.json")),
                                 anchorsClockToPoses: true),
            dependencies: .init(provider: provider, encoder: SyntheticFrameEncoder(now: uptime),
                                channels: ScriptedChannelFactory(channels: [channel]),
                                sleeper: RecordingSleeper(), uptime: uptime, epochMs: { 1_789_000_000_000 }))
    }

    @Test func speaksTheHubProtocolFromHelloToPong() async throws {
        let channel = GatedChannel()
        await channel.grant(100_000)
        let client = try makeClient(markers: true, channel: channel)
        let welcomes = await client.welcomes()
        try await client.start()

        await channel.deliverInbound(try String(contentsOf: Fixtures.url("hub-messages/welcome.json"), encoding: .utf8))
        await channel.deliverInbound(#"{"type":"ping","ts":1789834632484.4612}"#)
        await channel.deliverInbound(try String(contentsOf: Fixtures.url("hub-messages/cmd-flash.json"), encoding: .utf8))

        // `debug` is 1 Hz and frames 2 fps, so wait for ones from after the first
        // marker rather than for the first of each.
        await waitUntil("pong, slam, and a marker-aligned frame and debug", timeout: 8) {
            let delivered = await channel.deliveredMessages()
            return Set(delivered.map(\.type)).isSuperset(of: ["hello", "pong", "slam"])
                && delivered.contains { $0.type == "frame" && $0.json["calibrated"] as? Bool == true }
                && delivered.contains { $0.type == "debug" && $0.json["alignment"] as? String == "marker" }
        }
        let delivered = await channel.deliveredMessages()
        #expect(delivered.first?.type == "hello")
        #expect(delivered.first?.json["phoneId"] as? String == "phone-a")

        let pong = try #require(delivered.first { $0.type == "pong" })
        #expect(pong.number("ts") == 1789834632484.4612, "ts must be echoed exactly")
        #expect(pong.number("tp") == 1_789_000_000_000)

        let frame = try #require(delivered.last { $0.type == "frame" })
        #expect(frame.isBinary)
        #expect(frame.payload == SyntheticFrameEncoder.jpeg)
        #expect(frame.json["calibrated"] as? Bool == true)
        let tCapture = try #require(frame.number("tCapture"))
        #expect(abs(tCapture - 1_789_000_000_000) < 1_000, "tCapture must be epoch ms, got \(tCapture)")

        let debug = try #require(delivered.last { $0.type == "debug" })
        #expect(debug.json["alignment"] as? String == "marker")
        #expect((debug.json["venuePosition"] as? [Double])?.count == 3)

        var iterator = welcomes.makeAsyncIterator()
        #expect(await iterator.next()?.index == 3)
        let snapshot = await client.snapshot()
        #expect(snapshot.index == 3)
        #expect(snapshot.lastCommand == "flash")
        #expect(snapshot.alignment == .marker)
        await client.stop()
    }

    /// No marker and no seat: the hub must not be given a position, or it would
    /// draw a confident cone from ARKit's arbitrary start-up frame.
    @Test func unalignedSendsOrientWithoutHeadingThenSeatTapSendsSlam() async throws {
        let channel = GatedChannel()
        await channel.grant(100_000)
        let client = try makeClient(markers: false, channel: channel)
        try await client.start()

        await waitUntil("orient and a frame sent") {
            let types = Set(await channel.deliveredMessages().map(\.type))
            return types.isSuperset(of: ["orient", "frame"])
        }
        var delivered = await channel.deliveredMessages()
        #expect(!delivered.contains { $0.type == "slam" })
        let orient = try #require(delivered.first { $0.type == "orient" })
        #expect(orient.json["heading"] == nil)
        #expect(orient.json["calibrated"] as? Bool == false)
        #expect(orient.number("pitch") != nil)

        await client.setSeat(x: 2, y: 6)
        let calibrated = await client.calibrateFacingStage()
        #expect(calibrated)
        let before = delivered.count
        await waitUntil("slam after the seat tap") {
            await channel.deliveredMessages().dropFirst(before).contains { $0.type == "slam" }
        }
        delivered = await channel.deliveredMessages()
        #expect(delivered.contains { $0.type == "seat" })
        let slam = try #require(delivered.dropFirst(before).first { $0.type == "slam" })
        // The walk moves, but one pose interval after the tap it is still near the seat.
        #expect(abs(try #require(slam.number("x")) - 2) < 1.5)
        #expect(abs(try #require(slam.number("y")) - 6) < 1.5)
        #expect(await client.snapshot().alignment == .seat)
        await client.stop()
    }
}
