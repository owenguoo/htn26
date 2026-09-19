import Foundation
import simd

/// The on-disk format of `Fixtures/trajectory-*.json`: a recording of what ARKit
/// actually produced during a walk.
///
/// Real ARKit motion has drift, dropouts and jitter that cannot be invented
/// correctly, which is why this format exists rather than tests generating
/// motion inline. `synthetic` is the honesty flag: a fixture recorded on a real
/// device sets it false, and anything standing in for one until that recording
/// happens sets it true and says so in `note`.
public struct Trajectory: Sendable, Codable, Equatable {
    public struct Sample: Sendable, Codable, Equatable {
        /// `frame.timestamp` — `CACurrentMediaTime()` domain, per-device uptime.
        public var t: Double
        /// `frame.camera.transform`, 16 floats, column-major, as simd stores it.
        public var transform: [Float]
        /// `TrackingQuality.wireValue`.
        public var trackingState: String

        public init(t: Double, transform: [Float], trackingState: String) {
            self.t = t
            self.transform = transform
            self.trackingState = trackingState
        }

        public var pose: Pose? {
            guard let matrix = Trajectory.matrix(from: transform) else { return nil }
            return Pose(matrix: matrix)
        }

        public var quality: TrackingQuality {
            TrackingQuality(wireValue: trackingState) ?? .limited(.unknown)
        }
    }

    public struct MarkerEvent: Sendable, Codable, Equatable {
        public var t: Double
        public var markerID: String
        /// The marker's transform in the recording's ARKit world frame.
        public var transform: [Float]
        /// False for `didAdd`, true for `didUpdate`.
        public var isUpdate: Bool
        public var estimatedPhysicalWidth: Float?

        public init(t: Double, markerID: String, transform: [Float], isUpdate: Bool,
                    estimatedPhysicalWidth: Float? = nil) {
            self.t = t
            self.markerID = markerID
            self.transform = transform
            self.isUpdate = isUpdate
            self.estimatedPhysicalWidth = estimatedPhysicalWidth
        }
    }

    public struct Interruption: Sendable, Codable, Equatable {
        public var startT: Double
        public var endT: Double

        public init(startT: Double, endT: Double) {
            self.startT = startT
            self.endT = endT
        }
    }

    public var name: String
    public var recordedAt: String
    public var device: String
    /// Must be "gravity". `.gravityAndHeading` pulls in the magnetometer, which
    /// is off by tens of degrees indoors.
    public var worldAlignment: String
    /// True when this file is a stand-in rather than a device recording.
    public var synthetic: Bool
    public var note: String
    public var intrinsics: CameraIntrinsics?
    public var samples: [Sample]
    public var markerEvents: [MarkerEvent]
    public var interruptions: [Interruption]
    /// Present only in a synthetic fixture, where the true venue-frame pose for
    /// every sample is known by construction. A device recording has no ground
    /// truth, so tests that need one skip rather than assert against fiction.
    public var groundTruth: [Sample]?

    public init(name: String, recordedAt: String, device: String, worldAlignment: String = "gravity",
                synthetic: Bool, note: String, intrinsics: CameraIntrinsics?,
                samples: [Sample], markerEvents: [MarkerEvent] = [], interruptions: [Interruption] = [],
                groundTruth: [Sample]? = nil) {
        self.name = name
        self.recordedAt = recordedAt
        self.device = device
        self.worldAlignment = worldAlignment
        self.synthetic = synthetic
        self.note = note
        self.intrinsics = intrinsics
        self.samples = samples
        self.markerEvents = markerEvents
        self.interruptions = interruptions
        self.groundTruth = groundTruth
    }

    /// Duration of the recording in seconds.
    public var duration: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.t - first.t
    }

    /// Mean sample rate, which should be close to 60 Hz for a real recording.
    public var sampleRate: Double {
        guard duration > 0 else { return 0 }
        return Double(samples.count - 1) / duration
    }

    /// Rebuilds a column-major `simd_float4x4` from 16 floats. Returns nil rather
    /// than trapping on a short array, because fixtures are files and files rot.
    public static func matrix(from values: [Float]) -> simd_float4x4? {
        guard values.count == 16 else { return nil }
        return simd_float4x4(columns: (
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        ))
    }

    public static func values(from matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
