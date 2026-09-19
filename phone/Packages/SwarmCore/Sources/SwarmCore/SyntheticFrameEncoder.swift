import Foundation

/// A `FrameEncoding` with no camera behind it: every frame is the same small
/// portrait JPEG. For replay — the `swarm-replay` CLI and the simulator — where
/// the point is to prove the protocol against a real hub, not to show a picture.
///
/// The image is 180×240 with an arrow pointing up, so a feed wall showing it
/// sideways is visibly wrong.
public struct SyntheticFrameEncoder: FrameEncoding {
    public static let width = 180
    public static let height = 240

    private let now: @Sendable () -> Double

    /// - Parameter now: the device clock, so the frame can claim to have been
    ///   captured "now" and the latency the hub reports is the real pipeline.
    public init(now: @escaping @Sendable () -> Double) {
        self.now = now
    }

    public func encode(_ request: FrameEncodeRequest) async throws -> EncodedFrame {
        EncodedFrame(frameID: request.frameID, jpeg: Self.jpeg, width: Self.width, height: Self.height,
                     intrinsics: nil, captureTimestamp: now())
    }

    public static let jpeg: Data = Data(base64Encoded: base64.joined()) ?? Data()

    private static let base64: [String] = [
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA4KCw0LCQ4NDA0QDw4RFiQXFhQUFiwgIRokNC43NjMuMjI6QVNGOj1OPjIySGJJTlZY",
        "XV5dOEVmbWVabFNbXVn/2wBDAQ8QEBYTFioXFypZOzI7WVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZ",
        "WVlZWVlZWVn/wAARCADwALQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF",
        "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW",
        "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi",
        "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC",
        "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm",
        "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq",
        "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDiqKWunRdI0/w7pd1d6T9tnu/N3N9pePG18DgcdCPyrvbsZo5ilrf/ALV0D/oW/wDyek/w",
        "o/tTQP8AoW//ACek/wAKXM+xSMGit/8AtTQf+hb/APJ6T/Cj+1NB/wChb/8AJ6T/AApcz7FIwaWt7+1NB/6Fz/yek/wo/tTQf+hc",
        "/wDJ6T/ClzPsNGDS1vf2poP/AELn/k9J/hS/2poP/Quf+T0n+FF32KTMGit7+1NC/wChc/8AJ6T/AApf7U0L/oXf/J6T/Cld9ikz",
        "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",
    ]
}
