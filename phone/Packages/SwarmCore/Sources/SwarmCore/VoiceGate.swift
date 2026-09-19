import Foundation

/// The loudness gate that decides when the phone is streaming voice.
///
/// A port of `startVoice()` in `web/phone.js` (lines 881-939), constants
/// included. It is pure: hand it decimated PCM and a clock reading and it tells
/// you what to put on the socket. The microphone itself is AVFoundation and
/// lives in the Expo module, where ARKit and CoreImage live, for the same
/// reason — `SwarmCore` must build and test with `swift test` on macOS.
///
/// Why a gate at all: the hub transcribes each utterance with a paid speech
/// model (`hub.py` `transcribe`), and a phone in a noisy room streaming 32 kB/s
/// of nothing is 12 s of silence per transcription request. The gate sends only
/// while somebody is talking, plus the moment before they started — without the
/// pre-roll every transcript loses its first syllable, because the gate opens on
/// the sound that has already happened.
public struct VoiceGate: Sendable, Equatable {
    /// 16 kHz mono. The hub does not read the `rate` header field at all
    /// (`hub.py` `on_frame`) — it assumes this and builds the WAV from it, so
    /// sending anything else produces a chipmunk transcript with no error.
    public static let rate = 16_000

    /// RMS over the decimated samples, above which somebody is talking.
    /// `VOICE_THRESHOLD` in `phone.js`.
    public static let threshold: Float = 0.02

    /// Keep sending this long after it goes quiet, then end the utterance.
    /// `VOICE_HANG_MS = 600`.
    public static let hangSeconds: Double = 0.6

    /// How many quiet chunks are held back and flushed when the gate opens.
    ///
    /// `phone.js` keeps exactly one (`.slice(-1)`). Its comment says "~0.25 s",
    /// which is wrong: a chunk is `4096 / (ctx.sampleRate / 16000)` samples, so
    /// on a 48 kHz context it is 1365 samples ≈ **85 ms**. The comment assumes a
    /// 16 kHz context, which iOS does not give you. The code is the reference,
    /// not the comment.
    public static let prerollChunks = 1

    /// The hub cuts an utterance at `VOICE_MAX_S * rate * 2` bytes
    /// (`hub.py`, 12 s) and starts a new one. Ending it here instead means the
    /// hub sees a clean boundary rather than a mid-word cut, and means an open
    /// microphone in a loud room cannot queue without bound behind a slow
    /// socket.
    public static let maxUtteranceSeconds: Double = 12

    /// Below this the hub throws the utterance away (`VOICE_MIN_S`, 0.4 s).
    /// Not enforced here — a gate that second-guessed it would swallow a real
    /// short word if the two ever drifted apart — but it is why the pre-roll
    /// matters.
    public static let minUtteranceSeconds: Double = 0.4

    public enum Output: Sendable, Equatable {
        /// PCM to put on the wire, in order.
        case send([Int16])
        /// `{"type":"audio_end"}`.
        case end
    }

    /// True exactly while the gate is open, which is what drives the green ring
    /// on the microphone control.
    public private(set) var isTalking = false
    public private(set) var isMuted = false

    /// The last time a chunk was loud. Starts infinitely long ago so the first
    /// quiet chunk does not read as the tail of an utterance that never began —
    /// `phone.js` starts it at 0, which works only because its clock is epoch
    /// milliseconds and can never be near zero.
    private var lastLoud = -Double.infinity
    private var preroll: [[Int16]] = []
    /// Samples sent in the current utterance, for the 12 s cut.
    private var utteranceSamples = 0

    public init() {}

    /// Offers one captured chunk, already decimated to 16 kHz.
    ///
    /// - Parameters:
    ///   - rms: root-mean-square of the **decimated** samples, as
    ///     `Self.downsample` returns it. Taken as a parameter rather than
    ///     recomputed so a caller that already has it from the capture path does
    ///     not pay for it twice.
    ///   - now: seconds, monotonic.
    public mutating func offer(_ chunk: [Int16], rms: Float, now: Double) -> [Output] {
        // Muted is a hard stop before anything is recorded, exactly as the web
        // does it: no loudness tracking, no pre-roll. Unmuting therefore starts
        // from silence rather than from a stale "you were talking a second ago".
        guard !isMuted else { return [] }

        if rms > Self.threshold { lastLoud = now }
        let talking = now - lastLoud < Self.hangSeconds

        var outputs: [Output] = []
        if talking {
            if !isTalking {
                // The gate opens on a sound that has already been captured, so
                // the syllable that opened it is in the chunk before this one.
                outputs.append(contentsOf: preroll.map { Output.send($0) })
                utteranceSamples = preroll.reduce(0) { $0 + $1.count }
                preroll = []
            }
            outputs.append(.send(chunk))
            utteranceSamples += chunk.count
        } else {
            if isTalking { outputs.append(.end) }
            preroll.append(chunk)
            if preroll.count > Self.prerollChunks { preroll.removeFirst(preroll.count - Self.prerollChunks) }
        }
        isTalking = talking

        // Cut a monologue at the same length the hub would, but on a chunk
        // boundary and with an explicit end, so the hub transcribes a whole
        // utterance instead of splicing one mid-word.
        if isTalking, Double(utteranceSamples) / Double(Self.rate) >= Self.maxUtteranceSeconds {
            outputs.append(.end)
            isTalking = false
            utteranceSamples = 0
            lastLoud = -Double.infinity
        }
        return outputs
    }

    /// Returns the `audio_end` owed to the hub if the microphone is muted
    /// mid-utterance. Without it the hub waits out its own `VOICE_QUIET_MS` and
    /// transcribes a sentence the operator cut off on purpose.
    public mutating func setMuted(_ muted: Bool) -> [Output] {
        guard muted != isMuted else { return [] }
        isMuted = muted
        guard muted else { return [] }
        let outputs: [Output] = isTalking ? [.end] : []
        isTalking = false
        preroll = []
        utteranceSamples = 0
        lastLoud = -Double.infinity
        return outputs
    }

    /// Forgets everything. For a disconnect: the hub's buffer for this phone is
    /// gone with the socket, so an `audio_end` afterwards would close an
    /// utterance that no longer exists, and the pre-roll describes a moment the
    /// new socket never saw.
    public mutating func reset() {
        isTalking = false
        preroll = []
        utteranceSamples = 0
        lastLoud = -Double.infinity
    }
}

// MARK: - Resampling

extension VoiceGate {
    /// Microphone samples at `sourceRate` → 16 kHz Int16, plus the RMS the gate
    /// wants.
    ///
    /// **Nearest-neighbour decimation with no anti-alias filter**, which is what
    /// `phone.js` does (`out[i] = input[floor(i * step)]`). It aliases, and that
    /// is deliberate here: the reference client has been feeding this exact
    /// signal to the hub's transcription model all along, and matching it is
    /// worth more than a cleaner signal that behaves differently. If the
    /// transcripts ever need improving, that is a change to make on both clients
    /// at once, deliberately.
    ///
    /// The RMS is over the **decimated** samples, not the input — same as the
    /// web, and it matters, because decimation changes the value.
    public static func downsample(_ input: [Float], from sourceRate: Double) -> (pcm: [Int16], rms: Float) {
        guard sourceRate > 0, !input.isEmpty else { return ([], 0) }
        let step = sourceRate / Double(rate)
        let count = Int((Double(input.count) / step).rounded(.down))
        guard count > 0 else { return ([], 0) }

        var pcm = [Int16](repeating: 0, count: count)
        var sum: Double = 0
        for i in 0..<count {
            let index = min(input.count - 1, Int((Double(i) * step).rounded(.down)))
            let sample = input[index]
            sum += Double(sample) * Double(sample)
            // `Math.max(-1, Math.min(1, v)) * 0x7fff`. Clamped before scaling:
            // an input over 1.0 would otherwise wrap to a loud negative and put
            // a click in the middle of a word.
            let clamped = min(1, max(-1, sample))
            pcm[i] = Int16((clamped * 32_767).rounded())
        }
        return (pcm, Float((sum / Double(count)).squareRoot()))
    }

    /// Int16 little-endian, which is what a JavaScript `Int16Array` puts on the
    /// wire on every platform anyone runs this on, and what `hub.py` hands to
    /// `_wav(pcm, 16000)` unexamined.
    public static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
