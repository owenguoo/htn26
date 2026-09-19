import Foundation
import simd

/// A marker as measured in the room: its true printed width, and where it is.
///
/// `physicalWidth` must be the width measured with a tape *after* printing.
/// Printers scale, and a marker declared 2 cm wider than it is makes every
/// distance in the venue wrong by that ratio.
public struct VenueMarker: Sendable, Codable, Equatable {
    public var id: String
    /// Metres. Measured, not nominal.
    public var physicalWidth: Float
    public var physicalHeight: Float?
    /// The image centre in venue coordinates.
    public var position: [Float]
    /// The anchor's orientation in venue coordinates, x, y, z, w.
    /// See `MarkerConvention` for which way the axes point.
    public var quaternion: [Float]
    /// The marker the venue origin is defined by. Exactly one should be primary.
    public var isPrimary: Bool
    public var note: String?

    public init(id: String, physicalWidth: Float, physicalHeight: Float? = nil,
                position: [Float], quaternion: [Float], isPrimary: Bool, note: String? = nil) {
        self.id = id
        self.physicalWidth = physicalWidth
        self.physicalHeight = physicalHeight
        self.position = position
        self.quaternion = quaternion
        self.isPrimary = isPrimary
        self.note = note
    }

    public var pose: Pose? {
        guard position.count == 3, quaternion.count == 4 else { return nil }
        return Pose(position: SIMD3<Float>(position[0], position[1], position[2]),
                    orientation: simd_quatf(ix: quaternion[0], iy: quaternion[1],
                                            iz: quaternion[2], r: quaternion[3]).normalized)
    }
}

/// Which way an `ARImageAnchor`'s axes point relative to the printed image.
///
/// ARKit puts the image in the anchor's local x–z plane: +Y is the normal out of
/// the printed surface, +X runs along the image's width, and the image's "up"
/// direction is local −Z. `venue.json` states every marker pose in this same
/// convention, so calibration is a pure composition with no axis swizzle
/// anywhere — which is the point, because a swizzle buried in the maths is the
/// classic way to get a demo that is silently mirrored.
///
/// DEVICE-VERIFY: confirm on hardware that a marker mounted flat on a wall
/// produces an anchor whose +Y points away from the wall. If ARKit disagrees,
/// this is the one constant to change.
public enum MarkerConvention {
    public static let normal = SIMD3<Float>(0, 1, 0)
    public static let width = SIMD3<Float>(1, 0, 0)
    public static let up = SIMD3<Float>(0, 0, -1)
}

/// Loaded at runtime from `venue.json`, never compiled in. Changing venue must
/// require zero code changes and no rebuild: measure the markers on the day,
/// punch the numbers in, relaunch.
public struct Venue: Sendable, Codable, Equatable {
    public struct Thresholds: Sendable, Codable, Equatable {
        /// A sighting implying a world origin this far from the current estimate
        /// is a misdetection, not a correction. Rejected outright.
        public var rejectPositionMeters: Float
        public var rejectRotationDegrees: Float
        /// The most a single accepted correction may move the world. Larger
        /// corrections are applied in steps of this size over successive
        /// sightings, so the cone converges instead of teleporting.
        public var maxStepMeters: Float
        public var maxStepDegrees: Float

        public init(rejectPositionMeters: Float = 1.5, rejectRotationDegrees: Float = 25,
                    maxStepMeters: Float = 0.25, maxStepDegrees: Float = 5) {
            self.rejectPositionMeters = rejectPositionMeters
            self.rejectRotationDegrees = rejectRotationDegrees
            self.maxStepMeters = maxStepMeters
            self.maxStepDegrees = maxStepDegrees
        }
    }

    public var id: String
    public var name: String
    public var note: String?
    public var markers: [VenueMarker]
    public var thresholds: Thresholds

    public init(id: String, name: String, note: String? = nil, markers: [VenueMarker],
                thresholds: Thresholds = Thresholds()) {
        self.id = id
        self.name = name
        self.note = note
        self.markers = markers
        self.thresholds = thresholds
    }

    public func marker(id: String) -> VenueMarker? {
        markers.first { $0.id == id }
    }

    public var primaryMarker: VenueMarker? {
        markers.first { $0.isPrimary }
    }

    public enum LoadError: Error, Sendable, Equatable {
        case noPrimaryMarker
        case multiplePrimaryMarkers([String])
        case malformedMarker(String)
        case duplicateMarkerID(String)
    }

    /// Validates on load. A venue file with two primaries or a mistyped
    /// quaternion should fail at launch in the lobby, not silently at showtime.
    public func validated() throws -> Venue {
        let primaries = markers.filter(\.isPrimary).map(\.id)
        guard !primaries.isEmpty else { throw LoadError.noPrimaryMarker }
        guard primaries.count == 1 else { throw LoadError.multiplePrimaryMarkers(primaries) }
        var seen = Set<String>()
        for marker in markers {
            guard seen.insert(marker.id).inserted else { throw LoadError.duplicateMarkerID(marker.id) }
            guard marker.pose != nil, marker.physicalWidth > 0 else {
                throw LoadError.malformedMarker(marker.id)
            }
        }
        return self
    }

    public static func load(from url: URL) throws -> Venue {
        try JSONDecoder().decode(Venue.self, from: Data(contentsOf: url)).validated()
    }

    public static func load(from data: Data) throws -> Venue {
        try JSONDecoder().decode(Venue.self, from: data).validated()
    }
}
