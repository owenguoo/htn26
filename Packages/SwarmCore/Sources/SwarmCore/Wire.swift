import Foundation
import simd

/// The wire protocol between a phone and the orchestrator.
///
/// The orchestrator and dashboard already exist and are running. **If anything
/// here disagrees with the server, the server wins.** `WireEnvelope` is the one
/// place framing is decided, so adapting to the real server should be an edit to
/// this file and nothing else.
///
/// Framing: one JSON object per WebSocket text message.
/// `{"v":1,"type":"pose","seq":41,"data":{…}}`
public enum WireProtocol {
    public static let version = 1
}

public enum WireMessageType: String, Sendable, Codable, CaseIterable {
    case hello
    case pose
    case frame
    case depth
    case command
    case ping
    case pong
}

/// Every message on the socket, in both directions.
public enum WireMessage: Sendable, Equatable {
    case hello(Hello)
    case pose(PoseUpdate)
    case frame(FrameChunk)
    case depth(DepthChunk)
    case command(Command)
    case ping(Ping)
    case pong(Pong)

    public var type: WireMessageType {
        switch self {
        case .hello: .hello
        case .pose: .pose
        case .frame: .frame
        case .depth: .depth
        case .command: .command
        case .ping: .ping
        case .pong: .pong
        }
    }

    /// Whether dropping this message under backpressure is acceptable.
    ///
    /// Poses, frames and depth chunks are perishable — a stale one is worse than
    /// none. Hello, commands and the clock-sync pair are control traffic and must
    /// never be dropped, or the device silently stops existing to the server.
    public var isDroppable: Bool {
        switch self {
        case .pose, .frame, .depth: true
        case .hello, .command, .ping, .pong: false
        }
    }
}

// MARK: - Payloads

public struct Hello: Sendable, Equatable, Codable {
    public var deviceID: String
    public var deviceName: String
    public var deviceModel: String
    public var appVersion: String
    public var protocolVersion: Int
    public var venueID: String
    /// Drives `DepthSource` selection on the server side only. UI and session
    /// logic never branch on device class.
    public var hasLiDAR: Bool
    public var capabilities: [String]

    public init(deviceID: String, deviceName: String, deviceModel: String, appVersion: String,
                protocolVersion: Int = WireProtocol.version, venueID: String,
                hasLiDAR: Bool, capabilities: [String] = []) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.venueID = venueID
        self.hasLiDAR = hasLiDAR
        self.capabilities = capabilities
    }
}

/// A camera pose already in the venue frame. The phone converts; the server never
/// should.
public struct PoseUpdate: Sendable, Equatable, Codable {
    public var deviceID: String
    /// Server-clock seconds, via `ClockSync`. Authoritative for fusion.
    public var serverTimestamp: Double
    /// The raw `CACurrentMediaTime()` value, carried for debugging only. It is
    /// per-device uptime and comparing it across phones is meaningless.
    public var deviceTimestamp: Double
    /// Metres, venue frame: +X east along the stage, +Y up, +Z out from the stage.
    public var position: [Float]
    /// Venue frame, ordered x, y, z, w.
    public var quaternion: [Float]
    /// `TrackingQuality.wireValue`, e.g. "normal" or "limited.relocalizing".
    public var trackingState: String
    /// 0…1. Decays while tracking is degraded.
    public var confidence: Float
    /// Seconds since the last accepted marker correction; nil if never corrected,
    /// which means this pose's origin is arbitrary and the server must not fuse it.
    public var lastCorrectionAge: Double?
    /// Which marker last corrected this device.
    public var lastCorrectionMarker: String?
    /// Set when the pose is older than the staleness limit, so the dashboard
    /// greys the cone rather than drawing it confidently in the wrong place.
    public var stale: Bool
    public var seq: UInt64

    public init(deviceID: String, serverTimestamp: Double, deviceTimestamp: Double,
                position: [Float], quaternion: [Float], trackingState: String, confidence: Float,
                lastCorrectionAge: Double?, lastCorrectionMarker: String?, stale: Bool, seq: UInt64) {
        self.deviceID = deviceID
        self.serverTimestamp = serverTimestamp
        self.deviceTimestamp = deviceTimestamp
        self.position = position
        self.quaternion = quaternion
        self.trackingState = trackingState
        self.confidence = confidence
        self.lastCorrectionAge = lastCorrectionAge
        self.lastCorrectionMarker = lastCorrectionMarker
        self.stale = stale
        self.seq = seq
    }
}

public struct FrameChunk: Sendable, Equatable, Codable {
    public var deviceID: String
    public var frameID: UInt64
    public var serverTimestamp: Double
    public var width: Int
    public var height: Int
    public var jpegQuality: Float
    public var intrinsics: CameraIntrinsics?
    /// The pose the frame was captured at, so the server does not have to
    /// interpolate between pose updates to unproject it.
    public var pose: PoseUpdate?
    /// JSONEncoder writes `Data` as base64. Binary WebSocket frames would be
    /// cheaper; switch `Transport.send` to `.data` if the server accepts them.
    public var jpeg: Data
    public var trace: LatencyTrace?

    public init(deviceID: String, frameID: UInt64, serverTimestamp: Double, width: Int, height: Int,
                jpegQuality: Float, intrinsics: CameraIntrinsics?, pose: PoseUpdate?, jpeg: Data,
                trace: LatencyTrace?) {
        self.deviceID = deviceID
        self.frameID = frameID
        self.serverTimestamp = serverTimestamp
        self.width = width
        self.height = height
        self.jpegQuality = jpegQuality
        self.intrinsics = intrinsics
        self.pose = pose
        self.jpeg = jpeg
        self.trace = trace
    }
}

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

/// Server → phone. The things the web client could never do.
public struct Command: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        /// Full-screen colour flash. RGB each 0…1.
        case flash(r: Float, g: Float, b: Float, durationMs: Int)
        /// Directional arrow. Either a venue-frame point to aim at, or a
        /// precomputed bearing in radians when the server already knows where the
        /// phone is looking.
        case arrow(target: [Float]?, bearingRadians: Float?, label: String?)
        case sound(name: String)
        case haptic(pattern: String, intensity: Float)
        /// Server-driven rate control, e.g. when it is falling behind.
        case setRates(poseHz: Double?, frameFPS: Double?, depthHz: Double?)
        case clear
    }

    public var id: String
    public var serverTimestamp: Double
    public var kind: Kind
    /// Milliseconds after which an unrendered command should be discarded rather
    /// than shown late. A "look left" that paints two seconds late reads as broken.
    public var expiresInMs: Int?

    public init(id: String, serverTimestamp: Double, kind: Kind, expiresInMs: Int? = nil) {
        self.id = id
        self.serverTimestamp = serverTimestamp
        self.kind = kind
        self.expiresInMs = expiresInMs
    }
}

/// NTP-style four-timestamp exchange. `t0` is the phone's monotonic clock; `t1`
/// and `t2` are the server's. The phone stamps `t3` on receipt and never trusts
/// the server to have done it.
public struct Ping: Sendable, Equatable, Codable {
    public var id: UInt64
    public var t0: Double

    public init(id: UInt64, t0: Double) {
        self.id = id
        self.t0 = t0
    }
}

public struct Pong: Sendable, Equatable, Codable {
    public var id: UInt64
    public var t0: Double
    public var t1: Double
    public var t2: Double

    public init(id: UInt64, t0: Double, t1: Double, t2: Double) {
        self.id = id
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
    }
}

// MARK: - Envelope

/// `{"v":1,"type":"pose","seq":41,"data":{…}}`
///
/// The only framing decision in the system. Change it here if the server
/// disagrees; nothing else parses the socket.
public struct WireEnvelope: Sendable, Equatable {
    public var version: Int
    public var seq: UInt64
    public var message: WireMessage

    public init(version: Int = WireProtocol.version, seq: UInt64, message: WireMessage) {
        self.version = version
        self.seq = seq
        self.message = message
    }
}

extension WireEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case seq
        case data
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(message.type, forKey: .type)
        try container.encode(seq, forKey: .seq)
        switch message {
        case .hello(let p): try container.encode(p, forKey: .data)
        case .pose(let p): try container.encode(p, forKey: .data)
        case .frame(let p): try container.encode(p, forKey: .data)
        case .depth(let p): try container.encode(p, forKey: .data)
        case .command(let p): try container.encode(p, forKey: .data)
        case .ping(let p): try container.encode(p, forKey: .data)
        case .pong(let p): try container.encode(p, forKey: .data)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? WireProtocol.version
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        let type = try container.decode(WireMessageType.self, forKey: .type)
        message = switch type {
        case .hello: .hello(try container.decode(Hello.self, forKey: .data))
        case .pose: .pose(try container.decode(PoseUpdate.self, forKey: .data))
        case .frame: .frame(try container.decode(FrameChunk.self, forKey: .data))
        case .depth: .depth(try container.decode(DepthChunk.self, forKey: .data))
        case .command: .command(try container.decode(Command.self, forKey: .data))
        case .ping: .ping(try container.decode(Ping.self, forKey: .data))
        case .pong: .pong(try container.decode(Pong.self, forKey: .data))
        }
    }
}

public enum WireCoder {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encode(_ envelope: WireEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> WireEnvelope {
        try makeDecoder().decode(WireEnvelope.self, from: data)
    }
}

// MARK: - Conversion

extension PoseUpdate {
    /// The venue-frame pose this update carries, or nil if the arrays are
    /// malformed. Never force-unwraps a short array off the wire.
    public var venuePose: Pose? {
        guard position.count == 3, quaternion.count == 4 else { return nil }
        return Pose(position: SIMD3<Float>(position[0], position[1], position[2]),
                    orientation: simd_quatf(ix: quaternion[0], iy: quaternion[1],
                                            iz: quaternion[2], r: quaternion[3]))
    }
}

extension Pose {
    public var wirePosition: [Float] { [position.x, position.y, position.z] }
    /// Ordered x, y, z, w to match the server.
    public var wireQuaternion: [Float] {
        let q = orientation.unitOrIdentity
        return [q.imag.x, q.imag.y, q.imag.z, q.real]
    }
}
