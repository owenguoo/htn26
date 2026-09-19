import Foundation
import simd

/// Closes the loop on server depth.
///
/// The phone is the only thing in the system that knows metres. VGGT-Ω returns
/// each chunk in its own arbitrary origin and scale, so the server cannot make
/// its own output metric — it does not know how far the camera actually moved.
/// The exchange is therefore:
///
/// 1. The phone uploads a chunk, with the metric ARKit pose for every frame.
/// 2. The server reconstructs it and sends back its *predicted* camera poses
///    and scene-normalized depth, with `metricScale` absent.
/// 3. The phone fits its known baselines against the predicted ones and replies
///    with the factor.
///
/// Step 3 is what this does. Without it a server-depth device produces depth
/// nobody can turn into metres, which is the same as producing nothing.
///
/// Bounded by construction: it remembers the last `capacity` chunks and no more.
/// A reply that arrives after its chunk has aged out is counted, not kept.
public struct DepthScaleNegotiator: Sendable {
    private let source: ServerDepthSource
    private let capacity: Int
    /// Chunk id → the metric poses the phone sent for it.
    private var outstanding: [(chunkID: UInt64, frames: [DepthChunk.FrameRef])] = []

    public private(set) var replied = 0
    /// Replies for chunks this phone no longer remembers sending.
    public private(set) var unmatched = 0
    /// Chunks whose scale could not be recovered — no parallax, or a
    /// reconstruction that disagrees with itself.
    public private(set) var unscalable = 0

    public init(source: ServerDepthSource = ServerDepthSource(estimates: { _ in nil }),
                capacity: Int = 16) {
        self.source = source
        self.capacity = max(1, capacity)
    }

    /// Remembers the metric poses for a chunk the phone is about to upload.
    public mutating func record(_ ticket: DepthTicket) {
        outstanding.append((ticket.chunkID, ticket.frames))
        if outstanding.count > capacity {
            outstanding.removeFirst(outstanding.count - capacity)
        }
    }

    public var outstandingCount: Int { outstanding.count }

    /// Builds the reply carrying the fitted factor, or nil when there is none.
    ///
    /// Returning nil rather than a guess is the point: a scale invented from a
    /// stationary phone's non-existent parallax would be drawn by the dashboard
    /// as though it had been measured.
    public mutating func reply(to inbound: DepthChunk, deviceID: String,
                               sentAt: Double) -> DepthChunk? {
        guard inbound.metricScale == nil else {
            // Already metric — nothing to negotiate. LiDAR chunks come back this
            // way, and echoing a factor at them would be noise.
            return nil
        }
        guard let index = outstanding.firstIndex(where: { $0.chunkID == inbound.chunkID }) else {
            unmatched += 1
            return nil
        }
        let metricFrames = outstanding.remove(at: index).frames

        let predicted = inbound.frames.compactMap { frame -> SIMD3<Float>? in
            guard frame.position.count == 3 else { return nil }
            return SIMD3<Float>(frame.position[0], frame.position[1], frame.position[2])
        }
        let request = DepthRequest(chunkID: inbound.chunkID, frames: metricFrames)
        let estimate = ServerDepthEstimate(chunkID: inbound.chunkID,
                                           predictedCameras: predicted,
                                           maps: [])
        guard let result = try? source.scale(estimate, against: request) else {
            unscalable += 1
            return nil
        }

        replied += 1
        // The reply carries the factor and the metric frames, not the depth: the
        // server already has the depth, and sending it back would be the same
        // bytes twice over a link that is the reason for the whole latency budget.
        return DepthChunk(deviceID: deviceID,
                          chunkID: inbound.chunkID,
                          serverTimestamp: sentAt,
                          source: .server,
                          frames: metricFrames,
                          metricScale: result.appliedScale)
    }
}
