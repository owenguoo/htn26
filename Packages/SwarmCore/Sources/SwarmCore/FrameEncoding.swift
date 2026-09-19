import Foundation

/// How big and how compressed the JPEGs are.
///
/// Three to five phones means you can afford better than 640 px. Both values are
/// configuration, not constants, so the resolution/latency trade can be measured
/// on the day rather than argued about.
public struct FrameEncodingConfiguration: Sendable, Equatable {
    /// The long edge of the encoded image, in pixels. The short edge follows the
    /// capture's aspect ratio.
    public var targetLongEdge: Int
    /// 0…1, passed to the JPEG encoder.
    public var quality: Float
    /// How many encodes may be in flight. One means strictly serial, which is
    /// what a single reused `CIContext` wants.
    public var maxConcurrent: Int

    public init(targetLongEdge: Int = 960, quality: Float = 0.6, maxConcurrent: Int = 1) {
        self.targetLongEdge = max(64, targetLongEdge)
        self.quality = min(1, max(0.05, quality))
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public static let standard = FrameEncodingConfiguration()

    /// Output size for a capture of the given dimensions, never upscaling.
    public func outputSize(forCaptureWidth width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longEdge = max(width, height)
        guard longEdge > targetLongEdge else { return (width, height) }
        let factor = Double(targetLongEdge) / Double(longEdge)
        return (max(1, Int((Double(width) * factor).rounded())),
                max(1, Int((Double(height) * factor).rounded())))
    }

    public func scaleFactor(forCaptureWidth width: Int, height: Int) -> Float {
        guard width > 0, height > 0 else { return 1 }
        let longEdge = max(width, height)
        guard longEdge > targetLongEdge else { return 1 }
        return Float(targetLongEdge) / Float(longEdge)
    }
}

/// One frame to encode. The pixel buffer itself never reaches SwarmCore: an
/// `ARFrame` retained beyond its delegate callback stalls the session, so the
/// app copies out what it needs and hands over a token.
public struct FrameEncodeRequest: Sendable, Equatable {
    public var frameID: UInt64
    public var captureWidth: Int
    public var captureHeight: Int
    public var configuration: FrameEncodingConfiguration
    public var intrinsics: CameraIntrinsics?

    public init(frameID: UInt64, captureWidth: Int, captureHeight: Int,
                configuration: FrameEncodingConfiguration, intrinsics: CameraIntrinsics?) {
        self.frameID = frameID
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.configuration = configuration
        self.intrinsics = intrinsics
    }

    /// Intrinsics for the downscaled image, which is what the server will
    /// unproject against. Sending capture-resolution intrinsics with a scaled
    /// JPEG is a silent factor-of-two error in every depth estimate.
    public var scaledIntrinsics: CameraIntrinsics? {
        guard let intrinsics else { return nil }
        return intrinsics.scaled(by: configuration.scaleFactor(forCaptureWidth: captureWidth,
                                                               height: captureHeight))
    }
}

public struct EncodedFrame: Sendable, Equatable {
    public var frameID: UInt64
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var intrinsics: CameraIntrinsics?

    public init(frameID: UInt64, jpeg: Data, width: Int, height: Int, intrinsics: CameraIntrinsics?) {
        self.frameID = frameID
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.intrinsics = intrinsics
    }
}

/// The pixel work, behind a protocol. `FrameEncoder.swift` in the app target is
/// the only implementation that touches CoreImage, and it reuses one `CIContext`
/// — allocating one per frame drops you to about 3 fps.
public protocol FrameEncoding: Sendable {
    func encode(_ request: FrameEncodeRequest) async throws -> EncodedFrame
}

/// Serialises encoding and drops rather than queues.
///
/// **Backpressure drops, never queues.** If an encode is already running the
/// next frame is discarded and counted. A queue that grows here is a phone
/// sending pictures of where it was thirty seconds ago, which is worse than
/// sending nothing.
public actor FrameEncodePipeline {
    public struct Stats: Sendable, Equatable {
        public var submitted: Int = 0
        public var encoded: Int = 0
        public var droppedBusy: Int = 0
        public var failed: Int = 0
        public var inFlight: Int = 0
        /// Rolling mean encode time in seconds, for the latency budget.
        public var meanEncodeSeconds: Double = 0
    }

    public private(set) var stats = Stats()
    private let encoder: any FrameEncoding
    private var configuration: FrameEncodingConfiguration
    private var inFlight = 0
    private var encodeTimeTotal: Double = 0

    public init(encoder: any FrameEncoding, configuration: FrameEncodingConfiguration = .standard) {
        self.encoder = encoder
        self.configuration = configuration
    }

    public func setConfiguration(_ newValue: FrameEncodingConfiguration) {
        configuration = newValue
    }

    public func currentConfiguration() -> FrameEncodingConfiguration { configuration }
    public func currentStats() -> Stats { stats }

    /// Encodes the frame, or returns nil if an encode is already in flight.
    ///
    /// `now` is supplied by the caller so the encode duration is measured on the
    /// same clock as the rest of the latency trace rather than on a second one.
    public func submit(frameID: UInt64, captureWidth: Int, captureHeight: Int,
                       intrinsics: CameraIntrinsics?,
                       now: @Sendable () -> Double) async -> EncodedFrame? {
        stats.submitted += 1
        guard inFlight < configuration.maxConcurrent else {
            stats.droppedBusy += 1
            return nil
        }
        inFlight += 1
        stats.inFlight = inFlight
        defer {
            inFlight -= 1
            stats.inFlight = inFlight
        }

        let request = FrameEncodeRequest(frameID: frameID, captureWidth: captureWidth,
                                         captureHeight: captureHeight,
                                         configuration: configuration, intrinsics: intrinsics)
        let started = now()
        do {
            let encoded = try await encoder.encode(request)
            stats.encoded += 1
            encodeTimeTotal += max(0, now() - started)
            stats.meanEncodeSeconds = encodeTimeTotal / Double(stats.encoded)
            return encoded
        } catch {
            stats.failed += 1
            return nil
        }
    }
}
