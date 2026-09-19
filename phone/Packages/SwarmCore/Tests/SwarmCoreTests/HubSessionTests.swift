import Foundation
import Testing
@testable import SwarmCore

/// What the session machine does differently for the htn26 hub.
@Suite("Session machine on the hub path")
struct HubSessionTests {
    private func run(_ machine: SessionMachine) async throws -> [SessionEvent] {
        let stream = await machine.start()
        let collector = Task {
            var events: [SessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await machine.permissionsGranted()
        return await collector.value
    }

    private func machine(markers: Bool, configuration: SessionMachine.Configuration) throws -> SessionMachine {
        var trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        if !markers { trajectory.markerEvents = [] }
        return SessionMachine(configuration: configuration,
                              venue: try Venue.load(from: Fixtures.url("venue.json")),
                              provider: MockPoseProvider(trajectory: trajectory),
                              clock: ClockSync())
    }

    /// The hub never answers an NTP-style ping, so a session that waited for
    /// `ClockSync` would wait forever.
    @Test func posesFlowWithoutAnySynchronisedClock() async throws {
        let events = try await run(try machine(markers: true, configuration: .init(deviceID: "a")))
        #expect(events.poses.count > 500)
        #expect(events.poses.allSatisfy { $0.inVenueFrame })
        #expect(events.rawPoses.isEmpty, "raw poses are opt-in")
    }

    /// Without a marker the seat fallback still needs live poses, and the hub
    /// still needs frames or it greys the tile after 3 s.
    @Test func withNoMarkerRawPosesAndFramesFlowButNeverAsVenuePoses() async throws {
        let configuration = SessionMachine.Configuration(deviceID: "a", emitsBeforeOrigin: true)
        let events = try await run(try machine(markers: false, configuration: configuration))
        #expect(events.poses.isEmpty, "a venue-frame pose was claimed with no origin")
        #expect(events.rawPoses.count > 500)
        #expect(events.rawPoses.allSatisfy { !$0.inVenueFrame && $0.lastCorrectionAge == nil })
        #expect(events.frames.count > 50)
        #expect(events.frames.allSatisfy { !$0.pose.inVenueFrame })
        #expect(events.depthChunks.isEmpty, "baselines across an arbitrary frame mean nothing")
    }

    @Test func rawPosesStopTheMomentAMarkerEstablishesTheOrigin() async throws {
        let configuration = SessionMachine.Configuration(deviceID: "a", emitsBeforeOrigin: true)
        let events = try await run(try machine(markers: true, configuration: configuration))
        let firstVenue = try #require(events.firstIndex { if case .pose = $0 { true } else { false } })
        let lastRaw = events.lastIndex { if case .rawPose = $0 { true } else { false } }
        if let lastRaw { #expect(lastRaw < firstVenue, "raw and venue poses interleaved") }
        #expect(events.poses.count > 500)
        // Nothing the machine emits goes backwards in sequence across the hand-over.
        let sequences = events.compactMap { event -> UInt64? in
            switch event {
            case .pose(let u), .rawPose(let u): u.seq
            default: nil
            }
        }
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func theHubsRateCommandIsClampedAndNilRestoresTheDefault() async throws {
        let machine = try machine(markers: true, configuration: .init(
            deviceID: "a", rates: .init(poseHz: 10, frameFPS: 2, depthHz: 0)))
        await machine.setFrameRate(fps: 8)
        #expect(await machine.currentRates().frameFPS == 8)
        await machine.setFrameRate(fps: 60)
        #expect(await machine.currentRates().frameFPS == 15)
        await machine.setFrameRate(fps: 0.1)
        #expect(await machine.currentRates().frameFPS == 1)
        await machine.setFrameRate(fps: nil)
        #expect(await machine.currentRates().frameFPS == 2)
    }

    @Test func aBoostedRateReallyProducesMoreFrames() async throws {
        let base = SessionMachine.Configuration(deviceID: "a", rates: .init(poseHz: 10, frameFPS: 2, depthHz: 0))
        let normal = try await run(try machine(markers: true, configuration: base)).frames.count
        let boosted = try machine(markers: true, configuration: base)
        await boosted.setFrameRate(fps: 8)
        let fast = try await run(boosted).frames.count
        #expect(Double(fast) > Double(normal) * 3, "\(fast) frames at 8 fps against \(normal) at 2")
    }

    @Test func depthIsOffWhenItsRateIsZero() async throws {
        let configuration = SessionMachine.Configuration(
            deviceID: "a", rates: .init(poseHz: 10, frameFPS: 2, depthHz: 0))
        let events = try await run(try machine(markers: true, configuration: configuration))
        #expect(events.depthChunks.isEmpty)
        let byDefault = try await run(try machine(markers: true, configuration: .init(deviceID: "a")))
        #expect(!byDefault.depthChunks.isEmpty,
                "and still on by default, so the dormant depth path keeps its tests")
    }
}
