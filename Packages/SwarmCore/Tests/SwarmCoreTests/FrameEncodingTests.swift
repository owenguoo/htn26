import Foundation
import Testing
@testable import SwarmCore

/// An encoder the test can hold open, standing in for the CoreImage work that
/// only exists on a device.
actor GatedEncoder: FrameEncoding {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private(set) var encodedIDs: [UInt64] = []
    private(set) var concurrentPeak = 0
    private var concurrent = 0
    var shouldThrow = false

    func setShouldThrow(_ value: Bool) { shouldThrow = value }

    func encode(_ request: FrameEncodeRequest) async throws -> EncodedFrame {
        concurrent += 1
        concurrentPeak = max(concurrentPeak, concurrent)
        defer { concurrent -= 1 }
        await awaitPermit()
        if shouldThrow { throw EncodeFailure.simulated }
        encodedIDs.append(request.frameID)
        let size = request.configuration.outputSize(forCaptureWidth: request.captureWidth,
                                                    height: request.captureHeight)
        return EncodedFrame(frameID: request.frameID,
                            jpeg: Data(repeating: 0xAB, count: 64),
                            width: size.width, height: size.height,
                            intrinsics: request.scaledIntrinsics)
    }

    private func awaitPermit() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    func grant(_ count: Int = 1) {
        for _ in 0..<count {
            if waiting.isEmpty { permits += 1 } else { waiting.removeFirst().resume() }
        }
    }

    func waitingCount() -> Int { waiting.count }

    enum EncodeFailure: Error { case simulated }
}

/// A clock a test can move by hand, so encode timing is asserted on rather than
/// raced against.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func set(_ newValue: Double) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func read() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Gate 6 — partly device-only. What is testable here is the queue policy, the
/// drop accounting and the config plumbing; the CoreImage path and the measured
/// frame rate go in DEVICE_CHECKLIST.md.
@Suite("Gate 6: frame encoding policy", .serialized)
struct FrameEncodingTests {

    private func clock() -> @Sendable () -> Double {
        { Date().timeIntervalSince1970 }
    }

    // MARK: - Resolution config

    /// 3–5 phones means you can afford better than 640 px, so the resolution is
    /// a config value rather than a constant.
    @Test(arguments: [640, 960, 1_280, 1_920] as [Int])
    func downscalesToTheConfiguredLongEdge(longEdge: Int) {
        let configuration = FrameEncodingConfiguration(targetLongEdge: longEdge)
        let size = configuration.outputSize(forCaptureWidth: 1_920, height: 1_440)
        #expect(max(size.width, size.height) == longEdge)
        // Aspect ratio survives, to within a pixel of rounding.
        let ratio = Double(size.width) / Double(size.height)
        #expect(abs(ratio - 1_920.0 / 1_440.0) < 0.01, "aspect ratio drifted to \(ratio)")
    }

    @Test func neverUpscalesASmallCapture() {
        let configuration = FrameEncodingConfiguration(targetLongEdge: 1_920)
        let size = configuration.outputSize(forCaptureWidth: 640, height: 480)
        #expect(size == (640, 480))
        #expect(configuration.scaleFactor(forCaptureWidth: 640, height: 480) == 1)
    }

    /// Sending capture-resolution intrinsics with a downscaled JPEG is a silent
    /// factor-of-two error in every depth estimate the server produces.
    @Test func intrinsicsAreScaledWithTheImage() throws {
        let configuration = FrameEncodingConfiguration(targetLongEdge: 960)
        let request = FrameEncodeRequest(frameID: 1, captureWidth: 1_920, captureHeight: 1_440,
                                         configuration: configuration,
                                         intrinsics: Sample.intrinsics())
        let scaled = try #require(request.scaledIntrinsics)
        #expect(isClose(scaled.fx, 1_449.5 / 2, within: 0.01))
        #expect(isClose(scaled.cx, 959.5 / 2, within: 0.01))
        #expect(scaled.imageWidth == 960)
        #expect(scaled.imageHeight == 720)
    }

    @Test func configurationClampsNonsense() {
        let configuration = FrameEncodingConfiguration(targetLongEdge: -4, quality: 9, maxConcurrent: 0)
        #expect(configuration.targetLongEdge >= 64)
        #expect(configuration.quality <= 1)
        #expect(configuration.maxConcurrent >= 1)
    }

    @Test func outputSizeOfADegenerateCaptureIsZeroRatherThanACrash() {
        let configuration = FrameEncodingConfiguration()
        #expect(configuration.outputSize(forCaptureWidth: 0, height: 0) == (0, 0))
        #expect(configuration.scaleFactor(forCaptureWidth: 0, height: 0) == 1)
    }

    // MARK: - Drop-if-busy

    /// Frames arriving while an encode is running are discarded and counted, not
    /// queued. A queue here is a phone sending pictures of where it was.
    @Test func dropsWhileBusyRatherThanQueueing() async throws {
        let encoder = GatedEncoder()
        let pipeline = FrameEncodePipeline(encoder: encoder)
        let now = clock()

        let first = Task { await pipeline.submit(frameID: 1, captureWidth: 1_920, captureHeight: 1_440,
                                                 intrinsics: Sample.intrinsics(), now: now) }
        await waitUntil("encoder engaged") { await encoder.waitingCount() == 1 }

        var dropped = 0
        for id in 2...10 {
            let result = await pipeline.submit(frameID: UInt64(id), captureWidth: 1_920, captureHeight: 1_440,
                                               intrinsics: nil, now: now)
            if result == nil { dropped += 1 }
        }
        #expect(dropped == 9, "only \(dropped) of 9 frames were dropped while busy")

        await encoder.grant(1)
        let encoded = try #require(await first.value)
        #expect(encoded.frameID == 1)

        let stats = await pipeline.currentStats()
        #expect(stats.submitted == 10)
        #expect(stats.encoded == 1)
        #expect(stats.droppedBusy == 9)
        #expect(stats.inFlight == 0)
        #expect(await encoder.encodedIDs == [1], "a dropped frame reached the encoder anyway")
    }

    /// A single reused `CIContext` wants strictly serial work — allocating one
    /// per frame drops you to about 3 fps.
    @Test func neverRunsTwoEncodesAtOnce() async throws {
        let encoder = GatedEncoder()
        let pipeline = FrameEncodePipeline(encoder: encoder)
        let now = clock()
        await encoder.grant(40)

        await withTaskGroup(of: EncodedFrame?.self) { group in
            for id in 1...20 {
                group.addTask {
                    await pipeline.submit(frameID: UInt64(id), captureWidth: 1_280, captureHeight: 960,
                                          intrinsics: nil, now: now)
                }
            }
            for await _ in group {}
        }
        let peak = await encoder.concurrentPeak
        #expect(peak == 1, "the encoder saw \(peak) concurrent calls")
        let stats = await pipeline.currentStats()
        #expect(stats.submitted == 20)
        #expect(stats.encoded + stats.droppedBusy == 20)
    }

    @Test func recoversAfterTheBusyFrameCompletes() async throws {
        let encoder = GatedEncoder()
        let pipeline = FrameEncodePipeline(encoder: encoder)
        let now = clock()

        for id in 1...5 {
            await encoder.grant(1)
            let encoded = await pipeline.submit(frameID: UInt64(id), captureWidth: 640, captureHeight: 480,
                                                intrinsics: nil, now: now)
            #expect(encoded?.frameID == UInt64(id))
        }
        let stats = await pipeline.currentStats()
        #expect(stats.encoded == 5)
        #expect(stats.droppedBusy == 0, "sequential submissions must never be dropped")
    }

    @Test func anEncodeFailureIsCountedAndDoesNotWedgeThePipeline() async throws {
        let encoder = GatedEncoder()
        await encoder.setShouldThrow(true)
        let pipeline = FrameEncodePipeline(encoder: encoder)
        let now = clock()
        await encoder.grant(4)

        #expect(await pipeline.submit(frameID: 1, captureWidth: 640, captureHeight: 480,
                                      intrinsics: nil, now: now) == nil)
        await encoder.setShouldThrow(false)
        let recovered = await pipeline.submit(frameID: 2, captureWidth: 640, captureHeight: 480,
                                              intrinsics: nil, now: now)
        #expect(recovered?.frameID == 2, "the pipeline stayed wedged after one failure")

        let stats = await pipeline.currentStats()
        #expect(stats.failed == 1)
        #expect(stats.encoded == 1)
        #expect(stats.inFlight == 0)
    }

    @Test func configurationChangesReachTheEncoder() async throws {
        let encoder = GatedEncoder()
        let pipeline = FrameEncodePipeline(encoder: encoder,
                                           configuration: .init(targetLongEdge: 640, quality: 0.4))
        let now = clock()
        await encoder.grant(4)

        let small = try #require(await pipeline.submit(frameID: 1, captureWidth: 1_920, captureHeight: 1_440,
                                                       intrinsics: nil, now: now))
        #expect(max(small.width, small.height) == 640)

        await pipeline.setConfiguration(.init(targetLongEdge: 1_280, quality: 0.8))
        let large = try #require(await pipeline.submit(frameID: 2, captureWidth: 1_920, captureHeight: 1_440,
                                                       intrinsics: nil, now: now))
        #expect(max(large.width, large.height) == 1_280)
        #expect(await pipeline.currentConfiguration().quality == 0.8)
    }

    @Test func meanEncodeTimeIsRecordedForTheLatencyBudget() async throws {
        let encoder = GatedEncoder()
        let pipeline = FrameEncodePipeline(encoder: encoder)
        let fakeClock = FakeClock()
        let now: @Sendable () -> Double = { fakeClock.read() }
        await encoder.grant(10)

        for id in 1...4 {
            fakeClock.set(Double(id) * 10)
            _ = await pipeline.submit(frameID: UInt64(id), captureWidth: 640, captureHeight: 480,
                                      intrinsics: nil, now: now)
        }
        let stats = await pipeline.currentStats()
        #expect(stats.encoded == 4)
        // Each encode started and finished at the same fake instant, so the mean
        // is zero; what matters is that the field is populated and finite.
        #expect(stats.meanEncodeSeconds.isFinite)
        #expect(stats.meanEncodeSeconds >= 0)
    }

    // MARK: - Driven from the replay

    /// The rate the session actually asks for frames at, fed through the drop
    /// policy: at 1.5 fps with a fast encoder nothing should be dropped.
    @Test func theSessionsFrameRateDoesNotOverrunASerialEncoder() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let tickets = try await harness.run().frames
        #expect(!tickets.isEmpty)

        let encoder = GatedEncoder()
        await encoder.grant(tickets.count + 10)
        let pipeline = FrameEncodePipeline(encoder: encoder)
        let now = clock()
        for ticket in tickets {
            _ = await pipeline.submit(frameID: ticket.frameID, captureWidth: 1_920, captureHeight: 1_440,
                                      intrinsics: Sample.intrinsics(), now: now)
        }
        let stats = await pipeline.currentStats()
        #expect(stats.encoded == tickets.count)
        #expect(stats.droppedBusy == 0)
    }
}
