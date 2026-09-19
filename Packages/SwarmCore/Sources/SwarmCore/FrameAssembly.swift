import Foundation

/// Assembles the wire message for one frame, so the app target does not have to
/// know the shape of `FrameChunk`.
public enum FrameAssembly {
    /// Builds the chunk and stamps `.sent` on its trace.
    ///
    /// The trace travels with the frame: the server appends its own stages and
    /// sends the finished trace back, which is the only way an end-to-end number
    /// exists at all. A frame sent without one cannot be held to the budget.
    public static func chunk(deviceID: String,
                             ticket: FrameTicket,
                             encoded: EncodedFrame,
                             quality: Float,
                             encodedAt: Double,
                             sentAt: Double) -> FrameChunk {
        var trace = ticket.trace
        trace.stamp(.encoded, at: encodedAt)
        trace.stamp(.sent, at: sentAt)
        return FrameChunk(deviceID: deviceID,
                          frameID: ticket.frameID,
                          serverTimestamp: sentAt,
                          width: encoded.width,
                          height: encoded.height,
                          jpegQuality: quality,
                          intrinsics: encoded.intrinsics,
                          pose: ticket.pose,
                          jpeg: encoded.jpeg,
                          trace: trace)
    }

    /// Builds the depth chunk for a ticket. Depth that has not been made metric
    /// carries `metricScale == nil`, so the server can never mistake
    /// scene-normalized units for metres.
    public static func chunk(deviceID: String, ticket: DepthTicket, source: DepthSourceKind,
                             sentAt: Double, depth: DepthResult? = nil) -> DepthChunk {
        DepthChunk(deviceID: deviceID,
                   chunkID: ticket.chunkID,
                   serverTimestamp: sentAt,
                   source: source,
                   frames: ticket.frames,
                   metricScale: depth?.appliedScale,
                   width: depth?.maps.first?.width,
                   height: depth?.maps.first?.height,
                   depth: depth?.maps.first?.values,
                   confidence: depth?.maps.first?.confidence)
    }
}
