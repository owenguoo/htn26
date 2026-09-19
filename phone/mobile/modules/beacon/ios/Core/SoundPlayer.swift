import AVFoundation
import Foundation
import SwarmCore

/// The two beeps `phone.js` makes, generated rather than shipped: a double
/// 1175 Hz blip for a ping, one 660 Hz tone for a message.
///
/// **This no longer sets the audio session category.** It used to set
/// `.ambient` every time it prepared, which quietly killed
/// `MicrophoneCapture`'s input tap the first time the hub pinged a phone that
/// was also listening. The category is decided in exactly one place now —
/// `AudioSessionOwner` in `MicrophoneCapture.swift` — and this class declares
/// what it needs (`.playback`) rather than imposing it. See that file for what
/// the resolution is and what it costs.
///
// DEVICE-VERIFY: the Simulator plays these through the Mac. A human must confirm
// on hardware, per DEVICE_CHECKLIST.md, that a ping and a message are audible
// with the ringer on; that they are silent with it off *while voice is not
// capturing* (`.ambient`) and audible with it off while voice is capturing
// (`.playAndRecord` ignores the silent switch — a deliberate trade, not a bug);
// and that starting the audio engine does not interrupt or degrade the ARSession.
@MainActor
public final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private var isReady = false
    private var reconfigureHandler: UUID?

    public init() {}

    public func prepare() {
        guard !isReady, let format else { return }
        AudioSessionOwner.shared.begin(.playback)
        // The category can move under this engine — it does, the moment voice
        // starts — and an engine whose route changed has stopped without saying
        // so. Rebuild the graph then, or the next ping is silent.
        reconfigureHandler = AudioSessionOwner.shared.onReconfigure { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        do {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            isReady = true
        } catch {
            // A missing beep is never worth interrupting the demo for.
            isReady = false
        }
    }

    /// Gives the session claim back. Not called from `deinit`: a main-actor
    /// `deinit` cannot reach `AudioSessionOwner`, and this object lives as long
    /// as the operator view does.
    public func shutdown() {
        if let reconfigureHandler { AudioSessionOwner.shared.removeHandler(reconfigureHandler) }
        reconfigureHandler = nil
        if engine.isRunning { engine.stop() }
        isReady = false
        AudioSessionOwner.shared.end(.playback)
    }

    private func restart() {
        guard isReady else { return }
        if engine.isRunning { engine.stop() }
        try? engine.start()
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
