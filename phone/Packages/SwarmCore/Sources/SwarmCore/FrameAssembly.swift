import Foundation

/// Assembles the hub message for one frame, so the app target does not have to
/// know the shape of the wire.
public enum FrameAssembly {
    /// Builds the binary frame message and the finished phone-side trace.
    ///
    /// The hub does not carry a trace — it measures latency itself from
    /// `tCapture` — so the trace stays on the phone, feeds `LatencyStatistics`,
    /// and is summarised into the 1 Hz `debug` blob.
    ///
    /// - Parameters:
    ///   - room: the capture pose projected into the room, if the phone is
    ///     aligned. The hub reads `heading`/`pitch` off frame headers exactly as
    ///     it does off `orient`.
    ///   - tCaptureMs: phone epoch milliseconds at capture.
    public static func frame(ticket: FrameTicket, encoded: EncodedFrame, room: RoomPose?,
                             calibrated: Bool, tCaptureMs: Double,
                             encodedAt: Double, sentAt: Double) -> (message: HubOutbound, trace: LatencyTrace) {
        var trace = ticket.trace
        trace.stamp(.encoded, at: encodedAt)
        trace.stamp(.sent, at: sentAt)
        let header = HubFrameHeader(seq: ticket.frameID, tCapture: tCaptureMs,
                                    heading: room?.heading, pitch: room?.pitch,
                                    calibrated: calibrated,
                                    width: encoded.width, height: encoded.height)
        return (.frame(header, jpeg: encoded.jpeg), trace)
    }

    /// Builds the depth chunk for a ticket. Depth that has not been made metric
    /// carries `metricScale == nil`, so nothing downstream can mistake
    /// scene-normalized units for metres. Dormant: the hub has no depth channel.
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
