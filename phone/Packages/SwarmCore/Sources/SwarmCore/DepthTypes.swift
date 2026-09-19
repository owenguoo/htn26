import Foundation

/// Depth has no channel on the htn26 hub, so nothing here is sent today. The
/// types and the scale-fitting maths stay, dormant, for when it does.
public enum DepthSourceKind: String, Sendable, Codable {
    case lidar
    case server
}

/// One 4–8 frame chunk: VGGT-Ω's throughput sweet spot. Either LiDAR depth being
/// uploaded, or frames being submitted for server depth.
public struct DepthChunk: Sendable, Equatable, Codable {
    public struct FrameRef: Sendable, Equatable, Codable {
        public var frameID: UInt64
        public var serverTimestamp: Double
        /// The metric ARKit pose for this frame. These baselines are what
        /// `DepthScaleFit` fits scene-normalized server depth against.
        public var position: [Float]
        public var quaternion: [Float]

        public init(frameID: UInt64, serverTimestamp: Double, position: [Float], quaternion: [Float]) {
            self.frameID = frameID
            self.serverTimestamp = serverTimestamp
            self.position = position
            self.quaternion = quaternion
        }
    }

    public var deviceID: String
    public var chunkID: UInt64
    public var serverTimestamp: Double
    public var source: DepthSourceKind
    public var frames: [FrameRef]
    /// Set only when the phone already knows the metric scale: 1.0 for LiDAR,
    /// the fitted factor for server depth that has come back and been scaled.
    /// nil means "unknown, do not treat these depths as metres".
    public var metricScale: Float?
    public var width: Int?
    public var height: Int?
    /// Row-major depth, metres when `metricScale` is set. Absent when this chunk
    /// is a request for server depth rather than an upload of LiDAR depth.
    public var depth: [Float]?
    public var confidence: [Float]?

    public init(deviceID: String, chunkID: UInt64, serverTimestamp: Double, source: DepthSourceKind,
                frames: [FrameRef], metricScale: Float?, width: Int? = nil, height: Int? = nil,
                depth: [Float]? = nil, confidence: [Float]? = nil) {
        self.deviceID = deviceID
        self.chunkID = chunkID
        self.serverTimestamp = serverTimestamp
        self.source = source
        self.frames = frames
        self.metricScale = metricScale
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
    }
}
