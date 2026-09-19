import Foundation
import simd

/// Marker sightings are continuing pose corrections, not just initial
/// calibration. Operators walk, so ARKit drift accumulates; every re-sighting is
/// a fix.
public enum Calibration {
    /// The transform to hand `session.setWorldOrigin(relativeTransform:)` so that
    /// a marker observed at `observed` lands at its true venue pose.
    ///
    /// ARKit defines `relativeTransform` as the new origin expressed in the
    /// current world frame, so a point `p` in the old frame becomes `R⁻¹ · p`.
    /// Wanting `R⁻¹ · observed == markerVenue` gives `R = observed · markerVenue⁻¹`.
    ///
    /// The same expression serves both jobs: before the first call it re-origins
    /// an arbitrary frame onto the venue, and afterwards it measures and removes
    /// whatever drift has accumulated since.
    public static func worldOriginTransform(observed: simd_float4x4, markerVenue: simd_float4x4) -> simd_float4x4 {
        observed * markerVenue.inverse
    }

    public static func worldOriginTransform(observed: Pose, markerVenue: Pose) -> Pose {
        observed * markerVenue.inverse
    }

    /// Averages several simultaneous sightings into one origin estimate.
    ///
    /// Translations average directly. Orientations average by summing the
    /// quaternions with their signs aligned to the first — the cheap
    /// approximation to the true chordal mean, which is exact enough here
    /// because disagreeing sightings have already been rejected and what remains
    /// differs by a degree or two.
    public static func average(_ poses: [Pose]) -> Pose? {
        guard let first = poses.first else { return nil }
        guard poses.count > 1 else { return first }
        var position = SIMD3<Float>.zero
        var quaternionSum = SIMD4<Float>.zero
        let reference = first.orientation.unitOrIdentity.vector
        for pose in poses {
            position += pose.position
            let v = pose.orientation.unitOrIdentity.vector
            quaternionSum += simd_dot(v, reference) < 0 ? -v : v
        }
        position /= Float(poses.count)
        guard simd_length(quaternionSum) > 1e-6 else { return nil }
        return Pose(position: position,
                    orientation: simd_quatf(vector: simd_normalize(quaternionSum)))
    }

    public enum Rejection: Sendable, Equatable {
        /// The implied origin disagrees with the current estimate by more than
        /// the venue's threshold. A misdetection, a mirrored marker, or the wrong
        /// marker entirely.
        case disagreesBeyondThreshold(positionMeters: Float, rotationDegrees: Float)
        /// The sighting names a marker that is not in `venue.json`.
        case unknownMarker(String)
        /// `venue.json` has this marker but its pose is malformed.
        case malformedMarker(String)
    }

    public struct Correction: Sendable, Equatable {
        public var markerID: String
        /// What to hand `setWorldOrigin`, already clamped to the venue's maximum
        /// step so the cone converges instead of teleporting.
        public var relativeTransform: simd_float4x4
        /// The full, unclamped disagreement this sighting measured.
        public var measuredPositionError: Float
        public var measuredRotationDegrees: Float
        /// True when the correction was clamped, so more sightings are needed to
        /// finish converging.
        public var wasClamped: Bool
        public var deviceTimestamp: Double

        public init(markerID: String, relativeTransform: simd_float4x4, measuredPositionError: Float,
                    measuredRotationDegrees: Float, wasClamped: Bool, deviceTimestamp: Double) {
            self.markerID = markerID
            self.relativeTransform = relativeTransform
            self.measuredPositionError = measuredPositionError
            self.measuredRotationDegrees = measuredRotationDegrees
            self.wasClamped = wasClamped
            self.deviceTimestamp = deviceTimestamp
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The first sighting: the frame was arbitrary, so the full transform is
        /// applied with no clamping. There is nothing yet to disagree with.
        case originEstablished(Correction)
        case corrected(Correction)
        case rejected(Rejection)
        /// The sighting agreed with the current estimate closely enough that
        /// applying it would be noise.
        case noChangeNeeded(markerID: String)
    }

    /// Clamps a correction toward identity so no single application moves the
    /// world further than the venue allows.
    public static func clamp(_ correction: Pose, maxMeters: Float, maxRadians: Float) -> (pose: Pose, clamped: Bool) {
        var clamped = false
        var position = correction.position
        let distance = simd_length(position)
        if distance > maxMeters, distance > 1e-6 {
            position *= maxMeters / distance
            clamped = true
        }
        var orientation = correction.orientation.unitOrIdentity
        let angle = Geometry.angle(between: orientation, and: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        if angle > maxRadians, angle > 1e-6 {
            orientation = Geometry.slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), orientation, maxRadians / angle)
            clamped = true
        }
        return (Pose(position: position, orientation: orientation), clamped)
    }
}

/// Holds the marker state for one device: whether the origin has been
/// established, and how long ago the last accepted correction was.
public struct CalibrationEngine: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Below this, the sighting agrees and applying it would be noise.
        public var noChangePositionMeters: Float
        public var noChangeRotationDegrees: Float
        /// Sightings closer together than this are ignored, so `didUpdate`
        /// arriving at 60 Hz does not re-origin the world sixty times a second.
        public var minimumInterval: Double

        public init(noChangePositionMeters: Float = 0.02, noChangeRotationDegrees: Float = 0.5,
                    minimumInterval: Double = 0.5) {
            self.noChangePositionMeters = noChangePositionMeters
            self.noChangeRotationDegrees = noChangeRotationDegrees
            self.minimumInterval = minimumInterval
        }
    }

    public let venue: Venue
    public var configuration: Configuration
    public private(set) var hasOrigin = false
    public private(set) var lastCorrectionTime: Double?
    public private(set) var lastCorrectionMarker: String?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0

    public init(venue: Venue, configuration: Configuration = Configuration()) {
        self.venue = venue
        self.configuration = configuration
    }

    /// Seconds since the last accepted correction, or nil if never corrected.
    public func correctionAge(at now: Double) -> Double? {
        guard let lastCorrectionTime else { return nil }
        return max(0, now - lastCorrectionTime)
    }

    /// Evaluates one `ARImageAnchor` observation. `didAdd` and `didUpdate` are
    /// both first-class here; the difference is only that `didAdd` on an
    /// uncalibrated session establishes the origin.
    public mutating func evaluate(_ sighting: MarkerSighting) -> Calibration.Outcome {
        guard let marker = venue.marker(id: sighting.markerID) else {
            rejectedCount += 1
            return .rejected(.unknownMarker(sighting.markerID))
        }
        guard let markerPose = marker.pose else {
            rejectedCount += 1
            return .rejected(.malformedMarker(sighting.markerID))
        }

        let observed = Pose(matrix: sighting.observedTransform)
        let full = Calibration.worldOriginTransform(observed: observed, markerVenue: markerPose)
        let positionError = simd_length(full.position)
        let rotationRadians = Geometry.angle(between: full.orientation, and: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        let rotationDegrees = rotationRadians * 180 / .pi

        guard hasOrigin else {
            // Nothing to disagree with yet: the frame was arbitrary until now.
            hasOrigin = true
            acceptedCount += 1
            lastCorrectionTime = sighting.deviceTimestamp
            lastCorrectionMarker = sighting.markerID
            return .originEstablished(Calibration.Correction(
                markerID: sighting.markerID, relativeTransform: full.matrix,
                measuredPositionError: positionError, measuredRotationDegrees: rotationDegrees,
                wasClamped: false, deviceTimestamp: sighting.deviceTimestamp))
        }

        if positionError > venue.thresholds.rejectPositionMeters
            || rotationDegrees > venue.thresholds.rejectRotationDegrees {
            rejectedCount += 1
            return .rejected(.disagreesBeyondThreshold(positionMeters: positionError,
                                                       rotationDegrees: rotationDegrees))
        }

        if positionError < configuration.noChangePositionMeters
            && rotationDegrees < configuration.noChangeRotationDegrees {
            return .noChangeNeeded(markerID: sighting.markerID)
        }

        if let last = lastCorrectionTime, sighting.deviceTimestamp - last < configuration.minimumInterval {
            return .noChangeNeeded(markerID: sighting.markerID)
        }

        let (clampedPose, wasClamped) = Calibration.clamp(
            full,
            maxMeters: venue.thresholds.maxStepMeters,
            maxRadians: venue.thresholds.maxStepDegrees * .pi / 180)
        acceptedCount += 1
        lastCorrectionTime = sighting.deviceTimestamp
        lastCorrectionMarker = sighting.markerID
        return .corrected(Calibration.Correction(
            markerID: sighting.markerID, relativeTransform: clampedPose.matrix,
            measuredPositionError: positionError, measuredRotationDegrees: rotationDegrees,
            wasClamped: wasClamped, deviceTimestamp: sighting.deviceTimestamp))
    }

    /// Clears the origin, e.g. after `sessionInterruptionEnded`, when ARKit has
    /// thrown away its map and the next marker must re-establish everything.
    public mutating func invalidateOrigin() {
        hasOrigin = false
    }
}
