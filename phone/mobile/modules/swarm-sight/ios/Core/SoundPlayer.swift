import AVFoundation
import Foundation
import SwarmCore

/// The two beeps `phone.js` makes, generated rather than shipped: a double
/// 1175 Hz blip for a ping, one 660 Hz tone for a message.
///
// DEVICE-VERIFY: the Simulator plays these through the Mac. A human must confirm
// on hardware that a ping and a message are audible with the ringer on, silent
// with it off (`.ambient`), and that starting the audio engine does not
// interrupt or degrade the ARSession.
@MainActor
public final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private var isReady = false

    public init() {}

    public func prepare() {
        guard !isReady, let format else { return }
        do {
            // Ambient: obeys the ringer switch and never steals audio from anything.
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            isReady = true
        } catch {
            // A missing beep is never worth interrupting the demo for.
            isReady = false
        }
    }

    public func play(_ cue: SoundCue) {
        switch cue.name {
        case "ping": beep(frequency: 1_175, duration: 0.09, repeats: 2)
        default: beep(frequency: 660, duration: 0.12, repeats: 1)
        }
    }

    private func beep(frequency: Double, duration: Double, repeats: Int) {
        guard isReady, let format else { return }
        if !engine.isRunning { try? engine.start() }
        let gap = 0.07
        let total = Double(repeats) * duration + Double(max(0, repeats - 1)) * gap
        let frames = AVAudioFrameCount(total * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let t = Double(index) / format.sampleRate
            let slot = t.truncatingRemainder(dividingBy: duration + gap)
            guard slot < duration else {
                samples[index] = 0
                continue
            }
            // A short fade at each end, or every beep starts and ends with a click.
            let envelope = min(1, min(slot, duration - slot) / 0.008)
            samples[index] = Float(sin(2 * .pi * frequency * t) * 0.35 * envelope)
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }
}
