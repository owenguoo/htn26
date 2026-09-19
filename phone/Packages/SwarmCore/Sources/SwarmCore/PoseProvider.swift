import Foundation
import simd

/// Why ARKit's tracking is degraded. Mirrors `ARCamera.TrackingState.Reason`
/// without importing ARKit; `ARKitPoseProvider` does the one-line translation.
public enum LimitedReason: String, Sendable, Codable, CaseIterable {
    case initializing
    case relocalizing
    case excessiveMotion
    case insufficientFeatures
    case unknown
}

/// Mirrors `ARCamera.TrackingState`.
public enum TrackingQuality: Sendable, Equatable, Codable {
    case notAvailable
    case limited(LimitedReason)
    case normal

    /// Whether a pose from this state is worth sending at full confidence.
    public var isUsable: Bool {
        switch self {
        case .normal: true
        case .limited, .notAvailable: false
        }
    }

    /// Wire form, so the dashboard can render the reason without a second field.
    public var wireValue: String {
        switch self {
        case .notAvailable: "notAvailable"
        case .normal: "normal"
        case .limited(let reason): "limited.\(reason.rawValue)"
        }
    }

    public init?(wireValue: String) {
        switch wireValue {
        case "notAvailable": self = .notAvailable
        case "normal": self = .normal
        default:
            guard wireValue.hasPrefix("limited."),
                  let reason = LimitedReason(rawValue: String(wireValue.dropFirst("limited.".count)))
            else { return nil }
            self = .limited(reason)
        }
    }
}

/// Pinhole intrinsics in pixels, for the captured image's own resolution.
public struct CameraIntrinsics: Sendable, Equatable, Codable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var imageWidth: Int
    public var imageHeight: Int

    public init(fx: Float, fy: Float, cx: Float, cy: Float, imageWidth: Int, imageHeight: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// Intrinsics for the same camera after the image is rotated 90° clockwise —
    /// sensor-landscape to portrait, which is what the encoder does so the hub's
    /// feed wall shows upright tiles. A pixel at (x, y) in a W×H image lands at
    /// (H − y, x) in the H×W result, so the axes swap and the principal point
    /// follows the same map.
    public func rotatedClockwise() -> CameraIntrinsics {
        CameraIntrinsics(fx: fy, fy: fx, cx: Float(imageHeight) - cy, cy: cx,
                         imageWidth: imageHeight, imageHeight: imageWidth)
    }

    /// Intrinsics for the same camera after the image is scaled by `factor`.
    public func scaled(by factor: Float) -> CameraIntrinsics {
        CameraIntrinsics(fx: fx * factor, fy: fy * factor,
                         cx: cx * factor, cy: cy * factor,
                         imageWidth: Int((Float(imageWidth) * factor).rounded()),
                         imageHeight: Int((Float(imageHeight) * factor).rounded()))
    }
}

/// One camera pose, in whatever frame the provider is currently producing.
///
/// `deviceTimestamp` is in the `CACurrentMediaTime()` domain — per-device uptime,
/// meaningless across phones. `ClockSync` converts it to server time; nothing
/// downstream of `SessionMachine` should ever see a raw device timestamp.
public struct PoseSample: Sendable, Equatable {
    public var pose: Pose
    public var deviceTimestamp: TimeInterval
    public var quality: TrackingQuality
    public var intrinsics: CameraIntrinsics?

    public init(pose: Pose, deviceTimestamp: TimeInterval, quality: TrackingQuality, intrinsics: CameraIntrinsics? = nil) {
        self.pose = pose
        self.deviceTimestamp = deviceTimestamp
        self.quality = quality
        self.intrinsics = intrinsics
    }
}

/// An `ARImageAnchor` observation. These are continuing corrections, not just
/// initial calibration: operators walk, ARKit drifts, and every re-sighting is a
/// fix. `didAdd` and `didUpdate` both arrive here.
public struct MarkerSighting: Sendable, Equatable {
    public var markerID: String
    /// The marker's pose as ARKit currently sees it, in ARKit's current world
    /// frame. Before the first `setWorldOrigin` that frame is arbitrary; after
    /// it, it is the venue frame and this is a drift measurement.
    public var observedTransform: simd_float4x4
    public var deviceTimestamp: TimeInterval
    /// False for `didAdd`, true for `didUpdate`.
    public var isUpdate: Bool
    /// ARKit's estimate, which is only meaningful with automatic image scale
    /// estimation on. The configured physical width in `venue.json` is the
    /// authority for scale.
    public var estimatedPhysicalWidth: Float?

    public init(markerID: String, observedTransform: simd_float4x4, deviceTimestamp: TimeInterval,
                isUpdate: Bool, estimatedPhysicalWidth: Float? = nil) {
        self.markerID = markerID
        self.observedTransform = observedTransform
        self.deviceTimestamp = deviceTimestamp
        self.isUpdate = isUpdate
        self.estimatedPhysicalWidth = estimatedPhysicalWidth
    }
}

/// Everything the ARKit seam emits. Adding a case here is the sanctioned way to
/// widen the seam; moving ARKit inside SwarmCore is not.
public enum PoseProviderEvent: Sendable {
    case pose(PoseSample)
    case marker(MarkerSighting)
    /// `sessionWasInterrupted` — a call, backgrounding, the camera taken away.
    case interrupted
    /// `sessionInterruptionEnded` — tracking restarts from scratch; the session
    /// must re-enter recalibrating and wait for a marker.
    case interruptionEnded
    case failed(String)
}

/// The one seam ARKit plugs into. `MockPoseProvider` replays a recorded fixture
/// through the identical interface, which is what makes gates 3, 4 and 7
/// testable without a device.
public protocol PoseProvider: Sendable {
    /// Starts the underlying session and returns its event stream. Calling this
    /// twice is a programmer error; implementations may trap or return a stream
    /// that finishes immediately.
    func start() async throws -> AsyncStream<PoseProviderEvent>
    func stop() async

    /// Re-origins the world so subsequent poses are venue-frame.
    /// `ARKitPoseProvider` forwards this to `session.setWorldOrigin(relativeTransform:)`.
    /// Providers that cannot re-origin (a replay of an already venue-frame
    /// fixture) apply it as an offset to what they emit.
    func setWorldOrigin(relativeTransform: simd_float4x4) async

    /// The provider's motion fallback: "did this person move while tracking was
    /// lost". Metres of accumulated device motion since the last call. It is a
    /// yes/no signal, never a position — pedestrian dead reckoning heading error
    /// compounds, and 20 degrees over 10 m is ~3.4 m lateral that never recovers.
    func consumeMotionSinceLastQuery() async -> Float
}
