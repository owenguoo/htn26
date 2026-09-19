import Foundation
import simd
import Testing
@testable import SwarmCore

/// `venue.json` is loaded at runtime, never compiled in. Changing venue must
/// require zero code changes and no rebuild: measure the markers on the day,
/// punch the numbers in, relaunch.
@Suite("Venue configuration")
struct VenueTests {

    private func json(primaryY: Float, eastX: Float, rejectMetres: Float = 1.5) -> Data {
        Data("""
        {
          "id": "test-venue",
          "name": "Test",
          "markers": [
            {"id": "primary", "physicalWidth": 0.2965,
             "position": [0, \(primaryY), 0], "quaternion": [0, 0, 0, 1], "isPrimary": true},
            {"id": "east", "physicalWidth": 0.21,
             "position": [\(eastX), 1.55, 3.02], "quaternion": [0, 0.7071068, 0, 0.7071068],
             "isPrimary": false}
          ],
          "thresholds": {
            "rejectPositionMeters": \(rejectMetres), "rejectRotationDegrees": 25,
            "maxStepMeters": 0.25, "maxStepDegrees": 5
          }
        }
        """.utf8)
    }

    @Test func loadsFromData() throws {
        let venue = try Venue.load(from: json(primaryY: 1.6, eastX: 4.98))
        #expect(venue.id == "test-venue")
        #expect(venue.markers.count == 2)
        #expect(venue.primaryMarker?.id == "primary")
        #expect(venue.marker(id: "east") != nil)
        #expect(venue.marker(id: "nonexistent") == nil)
    }

    /// The whole point of the file: two venues, no rebuild, different geometry.
    @Test func twoVenueFilesProduceDifferentVenueFrameTransforms() throws {
        let hallA = try Venue.load(from: json(primaryY: 1.60, eastX: 4.98))
        let hallB = try Venue.load(from: json(primaryY: 2.35, eastX: 7.40))

        // The same physical observation, interpreted under each venue.
        let observed = Pose(position: SIMD3<Float>(1, 1, 1),
                            orientation: simd_quatf(angle: 0.3, axis: SIMD3<Float>(0, 1, 0)))

        let a = try #require(hallA.marker(id: "primary")?.pose)
        let b = try #require(hallB.marker(id: "primary")?.pose)
        let originA = Calibration.worldOriginTransform(observed: observed, markerVenue: a)
        let originB = Calibration.worldOriginTransform(observed: observed, markerVenue: b)

        // The primary markers differ by 0.75 m of height, so the origins must too.
        let delta = originA.position - originB.position
        #expect(isClose(simd_length(delta), 0.75, within: 1e-4),
                "origins differ by \(simd_length(delta)) m, expected 0.75 m")

        let eastA = try #require(hallA.marker(id: "east")?.pose)
        let eastB = try #require(hallB.marker(id: "east")?.pose)
        #expect(isClose(eastA.position.x, 4.98, within: 1e-4))
        #expect(isClose(eastB.position.x, 7.40, within: 1e-4))
        #expect(hallA.thresholds == hallB.thresholds)
    }

    @Test func rejectsAVenueWithNoPrimaryMarker() {
        let data = Data("""
        {"id": "x", "name": "x", "markers": [
          {"id": "a", "physicalWidth": 0.2, "position": [0,0,0], "quaternion": [0,0,0,1], "isPrimary": false}
        ], "thresholds": {"rejectPositionMeters": 1, "rejectRotationDegrees": 1,
                          "maxStepMeters": 1, "maxStepDegrees": 1}}
        """.utf8)
        #expect(throws: Venue.LoadError.noPrimaryMarker) {
            try Venue.load(from: data)
        }
    }

    @Test func rejectsAVenueWithTwoPrimaryMarkers() {
        let data = Data("""
        {"id": "x", "name": "x", "markers": [
          {"id": "a", "physicalWidth": 0.2, "position": [0,0,0], "quaternion": [0,0,0,1], "isPrimary": true},
          {"id": "b", "physicalWidth": 0.2, "position": [1,0,0], "quaternion": [0,0,0,1], "isPrimary": true}
        ], "thresholds": {"rejectPositionMeters": 1, "rejectRotationDegrees": 1,
                          "maxStepMeters": 1, "maxStepDegrees": 1}}
        """.utf8)
        #expect(throws: Venue.LoadError.multiplePrimaryMarkers(["a", "b"])) {
            try Venue.load(from: data)
        }
    }

    @Test func rejectsDuplicateMarkerIDs() {
        let data = Data("""
        {"id": "x", "name": "x", "markers": [
          {"id": "a", "physicalWidth": 0.2, "position": [0,0,0], "quaternion": [0,0,0,1], "isPrimary": true},
          {"id": "a", "physicalWidth": 0.2, "position": [1,0,0], "quaternion": [0,0,0,1], "isPrimary": false}
        ], "thresholds": {"rejectPositionMeters": 1, "rejectRotationDegrees": 1,
                          "maxStepMeters": 1, "maxStepDegrees": 1}}
        """.utf8)
        #expect(throws: Venue.LoadError.duplicateMarkerID("a")) {
            try Venue.load(from: data)
        }
    }

    /// `physicalWidth` must be the true measured width in metres or all scale is
    /// wrong. A zero or negative one is a typo that would otherwise surface as
    /// "positioning is broken".
    @Test func rejectsAMarkerWithNoPhysicalWidth() {
        let data = Data("""
        {"id": "x", "name": "x", "markers": [
          {"id": "a", "physicalWidth": 0, "position": [0,0,0], "quaternion": [0,0,0,1], "isPrimary": true}
        ], "thresholds": {"rejectPositionMeters": 1, "rejectRotationDegrees": 1,
                          "maxStepMeters": 1, "maxStepDegrees": 1}}
        """.utf8)
        #expect(throws: Venue.LoadError.malformedMarker("a")) {
            try Venue.load(from: data)
        }
    }

    @Test func rejectsAMarkerWithAShortPositionArray() {
        let data = Data("""
        {"id": "x", "name": "x", "markers": [
          {"id": "a", "physicalWidth": 0.2, "position": [0,0], "quaternion": [0,0,0,1], "isPrimary": true}
        ], "thresholds": {"rejectPositionMeters": 1, "rejectRotationDegrees": 1,
                          "maxStepMeters": 1, "maxStepDegrees": 1}}
        """.utf8)
        #expect(throws: Venue.LoadError.malformedMarker("a")) {
            try Venue.load(from: data)
        }
    }

    /// The shipped file must itself survive validation, or the app launches into
    /// a crash in the lobby.
    @Test func theShippedVenueFileValidates() throws {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        #expect(venue.thresholds.maxStepMeters < venue.thresholds.rejectPositionMeters,
                "a correction can never be applied: the step limit exceeds the rejection threshold")
        #expect(venue.thresholds.maxStepDegrees < venue.thresholds.rejectRotationDegrees)
    }

    @Test func hubURLAcceptsTheLegacyKeyAndRoomIsOptional() throws {
        let legacy = Data("""
        {"id":"v","name":"V","orchestratorURL":"http://10.0.0.5:8000/",
         "markers":[{"id":"p","physicalWidth":0.2,"position":[0,1,0],"quaternion":[0,0,0,1],"isPrimary":true}]}
        """.utf8)
        let venue = try Venue.load(from: legacy)
        #expect(venue.hubURL == "http://10.0.0.5:8000/")
        #expect(venue.room == nil)

        let shipped = try Venue.load(from: Fixtures.url("venue.json"))
        #expect(shipped.room == RoomAlignment.identity)
        #expect(HubURL.derive(try #require(shipped.hubURL))?.path == "/ws/phone")
    }
}
