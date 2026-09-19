import Testing
@testable import SwarmCore

@Suite("Directional loud-sound detection")
struct DirectionalSoundTests {
    private func constant(_ value: Float, count: Int = 480) -> [Float] {
        Array(repeating: value, count: count)
    }

    @Test func aShortLeftBurstProducesALeftCueAfterItDecays() throws {
        var detector = DirectionalSoundDetector()

        #expect(detector.offerStereo(left: constant(0.01), right: constant(0.01), at: 0) == nil)
        #expect(detector.offerStereo(left: constant(0.65), right: constant(0.12), at: 0.01) == nil)
        #expect(detector.offerStereo(left: constant(0.60), right: constant(0.11), at: 0.02) == nil)
        let cue = detector.offerStereo(left: constant(0.01), right: constant(0.01), at: 0.08)

        #expect(try #require(cue).relativeBearingDegrees < -35)
        #expect(cue?.confidence ?? 0 > 0.5)
    }

    @Test func sustainedSpeechLikeAudioIsRejected() {
        var detector = DirectionalSoundDetector()
        _ = detector.offerStereo(left: constant(0.4), right: constant(0.2), at: 0)
        for index in 1...12 {
            #expect(detector.offerStereo(left: constant(0.4), right: constant(0.2),
                                         at: Double(index) * 0.05) == nil)
        }
        #expect(detector.offerStereo(left: constant(0.01), right: constant(0.01), at: 0.7) == nil)
    }

    @Test func quietImbalanceAndMonoNeverProduceACue() {
        var detector = DirectionalSoundDetector()
        #expect(detector.offerStereo(left: constant(0.03), right: constant(0.005), at: 0) == nil)
        #expect(detector.offerStereo(left: constant(0.005), right: constant(0.005), at: 0.1) == nil)
        #expect(detector.offerMono(constant(0.9), at: 0.2) == nil)
    }

    @Test func suppressionDropsThePhonesOwnBeep() {
        var detector = DirectionalSoundDetector()
        detector.suppress(until: 1)
        #expect(detector.offerStereo(left: constant(0.8), right: constant(0.1), at: 0.2) == nil)
        #expect(detector.offerStereo(left: constant(0.01), right: constant(0.01), at: 0.3) == nil)
    }

    @Test func cooldownPreventsEchoesFromBecomingASecondEvent() {
        var detector = DirectionalSoundDetector()
        _ = detector.offerStereo(left: constant(0.1), right: constant(0.7), at: 0)
        let first = detector.offerStereo(left: constant(0.01), right: constant(0.01), at: 0.08)
        #expect(first?.relativeBearingDegrees ?? 0 > 35)

        _ = detector.offerStereo(left: constant(0.1), right: constant(0.7), at: 0.2)
        #expect(detector.offerStereo(left: constant(0.01), right: constant(0.01), at: 0.28) == nil)
    }
}
