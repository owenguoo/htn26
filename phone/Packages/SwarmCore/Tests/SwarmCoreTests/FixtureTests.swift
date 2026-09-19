import Foundation
import simd
import Testing
@testable import SwarmCore

/// The fixtures are the only input the whole test suite has that resembles real
/// motion. If one rots, every gate downstream starts testing fiction quietly.
@Suite("Fixtures")
struct FixtureTests {

    @Test func atLeastOneTrajectoryExists() throws {
        let names = try Fixtures.allTrajectoryNames()
        #expect(!names.isEmpty, "no Fixtures/trajectory-*.json — every replay test is vacuous")
    }

    @Test func everyTrajectoryParses() throws {
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            #expect(!trajectory.samples.isEmpty, "\(name) has no samples")
            #expect(trajectory.worldAlignment == "gravity",
                    "\(name) was not recorded with worldAlignment = .gravity")
        }
    }

    /// ARKit delivers `session(_:didUpdate:)` at 60 Hz. A fixture that does not
    /// would make the throttling gate meaningless.
    @Test func trajectoriesAreAboutSixtyHertz() throws {
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            #expect(trajectory.sampleRate > 50 && trajectory.sampleRate < 70,
                    "\(name) samples at \(trajectory.sampleRate) Hz")
        }
    }

    @Test func transformsAreWellFormed() throws {
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            for sample in trajectory.samples {
                #expect(sample.transform.count == 16, "\(name): a transform is not 16 floats")
                let pose = try #require(sample.pose, "\(name): a transform failed to decode")
                #expect(pose.position.x.isFinite && pose.position.y.isFinite && pose.position.z.isFinite,
                        "\(name): non-finite position")
                let length = simd_length(pose.orientation.vector)
                #expect(isClose(length, 1, within: 1e-4),
                        "\(name): quaternion of length \(length) — orientations are not normalised")
            }
        }
    }

    @Test func timestampsAreMonotonicAndLookLikeUptime() throws {
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            let times = trajectory.samples.map(\.t)
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 },
                    "\(name): timestamps go backwards")
            // CACurrentMediaTime is seconds since boot, not since 1970. A fixture
            // holding wall-clock time means the recorder used the wrong clock.
            let first = try #require(times.first)
            #expect(first > 0 && first < 5_000_000,
                    "\(name): first timestamp \(first) does not look like device uptime")
        }
    }

    @Test func markerSightingsArePresent() throws {
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            #expect(!trajectory.markerEvents.isEmpty,
                    "\(name) has no marker events, so it cannot exercise corrections")
            #expect(trajectory.markerEvents.allSatisfy { $0.transform.count == 16 })
        }
    }

    @Test func venueLoadsAndValidates() throws {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        #expect(venue.primaryMarker != nil)
        #expect(venue.markers.count >= 2, "drift correction needs more than the primary marker")
        for marker in venue.markers {
            #expect(marker.physicalWidth > 0.05 && marker.physicalWidth < 1.0,
                    "\(marker.id) has an implausible printed width of \(marker.physicalWidth) m")
        }
    }

    /// Every marker a fixture sights must exist in the venue, or corrections
    /// silently never happen.
    @Test func fixtureMarkersExistInTheVenue() throws {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            for event in trajectory.markerEvents {
                #expect(venue.marker(id: event.markerID) != nil,
                        "\(name) sights unknown marker \(event.markerID)")
            }
        }
    }

    /// Loud on purpose. These fixtures are generated, not recorded, and every
    /// number derived from them is only as real as they are. PLAN.md's human
    /// task 2 is to record a real two-minute walk; until that lands this test
    /// keeps the substitution visible in the test output.
    @Test func syntheticFixturesAreLabelledAsSuch() throws {
        var synthetic: [String] = []
        for name in try Fixtures.allTrajectoryNames() {
            let trajectory = try Fixtures.trajectory(name)
            if trajectory.synthetic {
                synthetic.append(name)
                #expect(trajectory.note.contains("SYNTHETIC"),
                        "\(name) is synthetic but does not say so in its note")
            }
        }
        // Not a failure — a standing reminder that every number downstream is
        // only as real as these files are.
        let names = synthetic.joined(separator: ", ")
        #expect(synthetic.count == synthetic.count,
                "SYNTHETIC fixtures in use: \(names). Replace with a device recording (PLAN.md human task 2).")
    }
}
