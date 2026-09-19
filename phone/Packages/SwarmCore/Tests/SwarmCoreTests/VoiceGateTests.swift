import Foundation
import Testing
@testable import SwarmCore

/// The voice path, everything except the microphone.
///
/// The microphone itself is AVFoundation and belongs in the Expo module, next to
/// ARKit; what is testable is the part that decides *when* to send, *what* the
/// bytes are, and *how* they get on the socket — which is also the part that
/// silently ruins a transcript when it is wrong. A dropped chunk is not a lost
/// moment: the hub concatenates the stream into one WAV, so it is a hole spliced
/// into the middle of a sentence.
@Suite("Voice: the web client's gate, framing and lane")
struct VoiceGateTests {

    // MARK: - Synthetic capture

    /// One `ScriptProcessor`-sized buffer of a 1 kHz tone at `amplitude`, as a
    /// 48 kHz microphone would hand it over.
    private func tone(amplitude: Float, sampleRate: Double = 48_000, frames: Int = 4096) -> [Float] {
        (0..<frames).map { amplitude * sin(Float($0) * 2 * .pi * 1000 / Float(sampleRate)) }
    }

    private func silence(frames: Int = 4096) -> [Float] { [Float](repeating: 0, count: frames) }

    // MARK: - Downsampling

    /// `step = sourceRate / 16000`, `floor(input.length / step)` output samples.
    /// On a 48 kHz context that is 1365 samples ≈ 85 ms — **not** the "~0.25 s"
    /// the web client's own comment claims, which assumes a 16 kHz context iOS
    /// does not provide. The code is the reference, not the comment.
    @Test func aChunkIsAboutEightyFiveMillisecondsAtFortyEightKilohertz() {
        let (pcm, _) = VoiceGate.downsample(tone(amplitude: 0.5), from: 48_000)
        #expect(pcm.count == 1365)
        let seconds = Double(pcm.count) / Double(VoiceGate.rate)
        #expect(seconds > 0.08 && seconds < 0.09, "a chunk is \(seconds) s")

        // 44.1 kHz gives a non-integer step; the count still floors.
        let (odd, _) = VoiceGate.downsample(tone(amplitude: 0.5, sampleRate: 44_100), from: 44_100)
        #expect(odd.count == Int(4096 / (44_100.0 / 16_000)))
    }

    @Test func samplesAreScaledAndClampedBeforeScaling() {
        // A microphone that overshoots 1.0 must saturate, not wrap: an Int16
        // wrap puts a full-scale click in the middle of a word.
        let (pcm, _) = VoiceGate.downsample([2.0, -2.0, 1.0, -1.0, 0], from: 16_000)
        #expect(pcm == [32_767, -32_767, 32_767, -32_767, 0])
    }

    /// The RMS is over the decimated samples, as in the web client. A full-scale
    /// sine is 1/√2 ≈ 0.707.
    @Test func loudnessIsRmsOfTheDecimatedSamples() {
        let (_, loud) = VoiceGate.downsample(tone(amplitude: 1.0), from: 48_000)
        #expect(loud > 0.69 && loud < 0.72, "a full-scale sine gave \(loud)")
        let (_, quiet) = VoiceGate.downsample(silence(), from: 48_000)
        #expect(quiet == 0)
        // Right at the threshold: a sine of amplitude 0.02 has RMS 0.0141, below
        // 0.02, so room tone at that level is correctly not "talking".
        let (_, roomTone) = VoiceGate.downsample(tone(amplitude: 0.02), from: 48_000)
        #expect(roomTone < VoiceGate.threshold)
    }

    @Test func pcmIsLittleEndianInt16() {
        let data = VoiceGate.pcmData([1, -1, 256])
        #expect(Array(data) == [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x01])
        #expect(data.count == 6)
    }

    @Test func theConstantsAreTheWebClients() {
        #expect(VoiceGate.rate == 16_000)
        #expect(VoiceGate.threshold == 0.02)
        #expect(VoiceGate.hangSeconds == 0.6)
        #expect(VoiceGate.prerollChunks == 1)
    }

    // MARK: - The gate

    /// The shape the whole thing exists for: silence, a word, silence. One burst
    /// of sends beginning one chunk *before* the word, one `end` 600 ms after it
    /// stops, and nothing at all either side.
    @Test func silenceThenSpeechThenSilenceGivesOneUtteranceWithPreRoll() {
        var gate = VoiceGate()
        let chunk = 0.085
        var now = 0.0
        var outputs: [VoiceGate.Output] = []

        func offer(_ samples: [Float]) {
            let (pcm, rms) = VoiceGate.downsample(samples, from: 48_000)
            outputs += gate.offer(pcm, rms: rms, now: now)
            now += chunk
        }

        // Quiet: held as pre-roll, never sent.
        for _ in 0..<5 { offer(silence()) }
        #expect(outputs.isEmpty, "the gate leaked while nobody was talking")
        #expect(!gate.isTalking)

        // Talking: ten chunks ≈ 0.85 s.
        for _ in 0..<10 { offer(tone(amplitude: 0.5)) }
        #expect(gate.isTalking)
        let sends = outputs.filter { if case .send = $0 { return true } else { return false } }
        #expect(sends.count == 11, "ten spoken chunks plus exactly one of pre-roll, got \(sends.count)")
        #expect(!outputs.contains(.end))

        // Quiet again. The hang keeps the gate open for 600 ms — about seven
        // chunks — then ends the utterance exactly once.
        for _ in 0..<12 { offer(silence()) }
        #expect(!gate.isTalking)
        #expect(outputs.filter { $0 == .end }.count == 1, "one utterance must end exactly once")

        // The tail sent during the hang is part of the utterance, so the total
        // is more than the eleven above but bounded.
        let total = outputs.filter { if case .send = $0 { return true } else { return false } }.count
        #expect(total > 11 && total < 20, "sent \(total) chunks for one word")
    }

    /// The pre-roll is exactly one chunk, not "everything since the last word".
    @Test func onlyOneChunkOfPreRollIsKept() {
        var gate = VoiceGate()
        let (quiet, quietRms) = VoiceGate.downsample(silence(), from: 48_000)
        let (loud, loudRms) = VoiceGate.downsample(tone(amplitude: 0.5), from: 48_000)
        for step in 0..<20 { _ = gate.offer(quiet, rms: quietRms, now: Double(step) * 0.085) }
        let opening = gate.offer(loud, rms: loudRms, now: 20 * 0.085)
        #expect(opening.count == 2, "one pre-roll chunk plus the chunk that opened the gate")
        #expect(opening.allSatisfy { if case .send = $0 { return true } else { return false } })
    }

    /// 600 ms of hang, not 600 ms of silence-detection. A pause inside a
    /// sentence must not cut it in two.
    @Test func aShortPauseDoesNotEndTheUtterance() {
        var gate = VoiceGate()
        let (quiet, quietRms) = VoiceGate.downsample(silence(), from: 48_000)
        let (loud, loudRms) = VoiceGate.downsample(tone(amplitude: 0.5), from: 48_000)
        _ = gate.offer(loud, rms: loudRms, now: 0)
        // 0.5 s of quiet — inside the hang.
        var outputs: [VoiceGate.Output] = []
        for step in 1...5 { outputs += gate.offer(quiet, rms: quietRms, now: Double(step) * 0.1) }
        #expect(!outputs.contains(.end), "a half-second pause split the sentence")
        #expect(gate.isTalking)
        // Past it.
        outputs += gate.offer(quiet, rms: quietRms, now: 0.65)
        #expect(outputs.contains(.end))
    }

    /// Muting is a hard stop: nothing is captured, nothing is remembered, and
    /// the hub is told the utterance is over rather than left to time it out.
    @Test func mutingEndsTheUtteranceAndStopsEverything() {
        var gate = VoiceGate()
        let (loud, loudRms) = VoiceGate.downsample(tone(amplitude: 0.5), from: 48_000)
        _ = gate.offer(loud, rms: loudRms, now: 0)
        #expect(gate.isTalking)

        #expect(gate.setMuted(true) == [.end])
        #expect(gate.isMuted)
        #expect(!gate.isTalking)
        #expect(gate.offer(loud, rms: loudRms, now: 0.1).isEmpty, "a muted gate sent audio")

        // Muting again is not a second `audio_end`.
        #expect(gate.setMuted(true).isEmpty)
        // Muting while already quiet owes the hub nothing.
        var quietGate = VoiceGate()
        #expect(quietGate.setMuted(true).isEmpty)

        // Unmuting starts from silence, not from "you were talking a second ago".
        #expect(gate.setMuted(false).isEmpty)
        #expect(!gate.isTalking)
    }

    /// The hub cuts at 12 s and starts a new buffer mid-word. Ending it here
    /// instead gives it a clean boundary, and bounds what can queue behind a
    /// slow socket.
    @Test func aMonologueIsCutAtTheHubsOwnTwelveSeconds() {
        var gate = VoiceGate()
        let (loud, loudRms) = VoiceGate.downsample(tone(amplitude: 0.5), from: 48_000)
        var outputs: [VoiceGate.Output] = []
        // 20 s of continuous speech.
        for step in 0..<236 { outputs += gate.offer(loud, rms: loudRms, now: Double(step) * 0.085) }
        let ends = outputs.filter { $0 == .end }.count
        #expect(ends >= 1, "a twenty-second monologue was never cut")
        #expect(ends <= 2, "cut \(ends) times in twenty seconds")
    }

    /// The first chunk ever offered is quiet, and `lastLoud` must not read as
    /// "a moment ago". The web starts it at 0 and only gets away with it
    /// because its clock is epoch milliseconds.
    @Test func aGateThatHasNeverHeardAnythingIsNotMidUtterance() {
        var gate = VoiceGate()
        let (quiet, quietRms) = VoiceGate.downsample(silence(), from: 48_000)
        // A monotonic clock starts near zero, which is the trap.
        let outputs = gate.offer(quiet, rms: quietRms, now: 0.001)
        #expect(outputs.isEmpty)
        #expect(!gate.isTalking)
    }

    @Test func resetForgetsEverythingWithoutOwingAnAudioEnd() {
        var gate = VoiceGate()
        let (loud, loudRms) = VoiceGate.downsample(tone(amplitude: 0.5), from: 48_000)
        _ = gate.offer(loud, rms: loudRms, now: 0)
        #expect(gate.isTalking)
        gate.reset()
        #expect(!gate.isTalking)
        // The next quiet chunk must not produce an `end` for an utterance the
        // new socket never saw.
        let (quiet, quietRms) = VoiceGate.downsample(silence(), from: 48_000)
        #expect(gate.offer(quiet, rms: quietRms, now: 0.1).isEmpty)
    }

    // MARK: - The wire

    private func object(_ frame: SocketFrame) throws -> [String: Any] {
        guard case .text(let text) = frame else {
            Issue.record("expected a text frame")
            return [:]
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// `{type:"audio", seq, rate:16000, tCapture}` then the raw PCM, in the same
    /// `[u32 big-endian header length][JSON][payload]` framing as a camera frame
    /// (`swarm/protocol.py`).
    @Test func anAudioMessageIsAPackedBinaryFrameWithTheWebsHeader() throws {
        let pcm: [Int16] = [0, 1000, -1000, 32_767]
        let header = HubAudioHeader(seq: 7, tCapture: 1_789_834_632_484.5)
        guard case .binary(let data) = try HubOutbound.audio(header, pcm: VoiceGate.pcmData(pcm)).encoded() else {
            Issue.record("audio must be binary")
            return
        }
        let (headerJSON, payload) = try HubFrame.unpack(data)
        let object = try #require(JSONSerialization.jsonObject(with: headerJSON) as? [String: Any])
        #expect(object["type"] as? String == "audio")
        #expect(object["seq"] as? Int == 7)
        #expect(object["rate"] as? Int == 16_000)
        #expect(object["tCapture"] as? Double == 1_789_834_632_484.5)
        // No width/height: those are a camera frame's, and `hub.py on_frame`
        // branches on the header type, not on the fields.
        #expect(object["width"] == nil)
        #expect(payload == VoiceGate.pcmData(pcm))
        #expect(payload.count == pcm.count * 2)
    }

    @Test func audioEndIsTheWebsExactTextMessage() throws {
        let object = try object(HubOutbound.audioEnd.encoded())
        #expect(object.count == 1)
        #expect(object["type"] as? String == "audio_end")
    }

    @Test func theCommandNamesMatchTheWire() {
        #expect(HubOutbound.audio(HubAudioHeader(seq: 0, tCapture: 0), pcm: Data()).typeName == "audio")
        #expect(HubOutbound.audioEnd.typeName == "audio_end")
    }
}

/// Audio's place in the transport, which is neither of the two kinds that
/// existed before it.
@Suite("Voice: the audio lane", .serialized)
struct VoiceLaneTests {
    private func makeTransport(_ channel: GatedChannel, maxInFlight: Int = 1)
    -> (Transport, ScriptedChannelFactory) {
        let factory = ScriptedChannelFactory(channels: [channel])
        let configuration = Transport.Configuration(
            url: URL(fileURLWithPath: "/ws/phone"),
            maxInFlight: maxInFlight, bufferDepth: 1,
            initialBackoff: 0.01, maxBackoff: 0.04, jitterFraction: 0)
        return (Transport(configuration: configuration, factory: factory, sleeper: RecordingSleeper()),
                factory)
    }

    private func chunk(_ seq: Int) -> HubOutbound {
        .audio(HubAudioHeader(seq: UInt64(seq), tCapture: Double(seq)),
               pcm: VoiceGate.pcmData([Int16(seq)]))
    }

    @Test func audioAndAudioEndShareOneLane() {
        #expect(HubOutbound.audio(HubAudioHeader(seq: 0, tCapture: 0), pcm: Data()).lane == .audio)
        // Load-bearing: the control queue is drained to empty before any other
        // lane gets a turn, so an `audio_end` sent as control would overtake the
        // chunks still queued behind it and cut the utterance short at the hub.
        #expect(HubOutbound.audioEnd.lane == .audio)
        #expect(HubOutbound.audioEnd.lane != .control)
    }

    /// The rule that makes audio different from frames: a dropped frame is a
    /// lost moment, a dropped chunk is a hole spliced into the middle of a
    /// sentence and a transcript that comes back wrong rather than short.
    ///
    /// Forty chunks into a socket that accepts one at a time — the same
    /// starvation `TransportTests` uses to prove poses *are* dropped.
    @Test func aBurstOfChunksArrivesWholeAndInOrder() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channel)
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }
        await channel.grant(1)   // the hello

        for seq in 0..<40 {
            await transport.send(chunk(seq))
            await Task.yield()
        }
        await transport.send(.audioEnd)

        for _ in 0..<60 {
            await channel.grant(1)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await waitUntil("drained") { await transport.bufferedMessageCount() == 0 }

        let delivered = await channel.deliveredMessages()
        let audio = delivered.filter { $0.type == "audio" }
        #expect(audio.count == 40, "the audio lane dropped \(40 - audio.count) chunks")
        #expect(audio.compactMap { $0.json["seq"] as? Int } == Array(0..<40),
                "chunks arrived out of order, which splices the WAV")
        #expect(audio.allSatisfy { $0.isBinary })
        #expect(audio.allSatisfy { $0.payload.count == 2 })

        // The end must come behind every chunk it belongs to.
        let endIndex = delivered.lastIndex { $0.type == "audio_end" }
        let lastAudio = delivered.lastIndex { $0.type == "audio" }
        #expect(endIndex != nil && lastAudio != nil && endIndex! > lastAudio!,
                "audio_end overtook the chunks it closes")

        let stats = await transport.currentStats()
        #expect(stats.droppedByLane[.audio, default: 0] == 0)
        await transport.stop()
    }

    /// Audio may not be dropped, but it may not be prioritised either: a held
    /// microphone is about twelve messages a second, and starving the frame lane
    /// means no inference, which is the entire point of the system.
    @Test func audioTakesItsTurnRatherThanStarvingFramesAndPoses() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channel)
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }
        await channel.grant(1)   // the hello

        // Thirty chunks queued, then a frame and a pose behind them.
        for seq in 0..<30 {
            await transport.send(chunk(seq))
            await Task.yield()
        }
        await transport.send(Sample.frame(1))
        await transport.send(Sample.slam(7))

        // Six sends is nowhere near enough to clear the voice backlog, so if
        // the pose and the frame are in there, the round-robin is working.
        for _ in 0..<6 {
            await channel.grant(1)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let firstSix = await channel.deliveredMessages().prefix(7).map(\.type)
        #expect(firstSix.contains("slam"), "a voice backlog starved the pose lane: \(firstSix)")
        #expect(firstSix.contains("frame"), "a voice backlog starved the frame lane: \(firstSix)")
        await transport.stop()
    }

    /// A reconnect means the hub's buffer for this phone is gone. A
    /// half-utterance waiting here has nothing left to be appended to, so it is
    /// dropped and counted rather than spliced onto the front of the next one.
    @Test func aDisconnectDiscardsTheHalfUtteranceAndSaysSo() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channel)
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }
        // No grants at all: the hello is still in flight and nothing drains.
        for seq in 0..<8 {
            await transport.send(chunk(seq))
            await Task.yield()
        }
        #expect(await transport.bufferedMessageCount() > 0, "nothing was queued to lose")

        await transport.stop()
        let stats = await transport.currentStats()
        #expect(stats.droppedByLane[.audio, default: 0] > 0,
                "a discarded utterance must be counted, not lost quietly")
    }
}

/// The voice path through the whole headless client, with a scripted socket.
@Suite("Voice: through the client", .serialized)
struct VoiceClientTests {
    private func makeClient(channel: GatedChannel, voiceEnabled: Bool) throws -> SwarmClient {
        var trajectory = try Fixtures.trajectory("trajectory-stationary-30s.json")
        trajectory.markerEvents = []
        let provider = MockPoseProvider(trajectory: trajectory,
                                        configuration: .init(playbackRate: 20, maxDuration: 2))
        let uptime: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
        return SwarmClient(
            configuration: .init(socketURL: URL(fileURLWithPath: "/ws/phone"),
                                 phoneId: "phone-a", name: "Dawson",
                                 venue: try Venue.load(from: Fixtures.url("venue.json")),
                                 anchorsClockToPoses: true, voiceEnabled: voiceEnabled),
            dependencies: .init(provider: provider, encoder: SyntheticFrameEncoder(now: uptime),
                                channels: ScriptedChannelFactory(channels: [channel]),
                                sleeper: RecordingSleeper(), uptime: uptime,
                                epochMs: { 1_789_000_000_000 }))
    }

    private func tone(_ amplitude: Float, frames: Int = 4096) -> [Float] {
        (0..<frames).map { amplitude * sin(Float($0) * 2 * .pi * 1000 / 48_000) }
    }

    /// `seq` is the voice counter, not the frame counter, and it counts every
    /// chunk including the pre-roll. The hub does not read it today, but a gap
    /// in it is the only way a future one could notice a lost chunk.
    @Test func speakingPutsSequencedAudioFramesAndAnEndOnTheWire() async throws {
        let channel = GatedChannel()
        await channel.grant(100_000)
        let client = try makeClient(channel: channel, voiceEnabled: true)
        try await client.start()
        #expect(await client.microphoneState == .idle)

        var now = 100.0
        for _ in 0..<6 {
            await client.offerAudio(samples: tone(0.5), sourceRate: 48_000, capturedAt: now)
            now += 0.085
        }
        #expect(await client.microphoneState == .speaking)
        // Quiet for well over the 600 ms hang.
        for _ in 0..<10 {
            await client.offerAudio(samples: tone(0), sourceRate: 48_000, capturedAt: now)
            now += 0.085
        }
        #expect(await client.microphoneState == .idle)

        await waitUntil("the utterance reached the socket") {
            await channel.deliveredMessages().contains { $0.type == "audio_end" }
        }
        let delivered = await channel.deliveredMessages()
        let audio = delivered.filter { $0.type == "audio" }
        #expect(audio.count >= 7, "six spoken chunks plus pre-roll, got \(audio.count)")
        #expect(audio.compactMap { $0.json["seq"] as? Int } == Array(0..<audio.count),
                "the voice sequence must be its own counter with no gaps")
        #expect(audio.allSatisfy { $0.json["rate"] as? Int == 16_000 })
        #expect(audio.allSatisfy { $0.isBinary && $0.payload.count == 1365 * 2 })
        // tCapture is epoch milliseconds, like a frame's.
        let capture = try #require(audio.first?.number("tCapture"))
        #expect(abs(capture - 1_789_000_000_000) < 60_000, "tCapture must be epoch ms, got \(capture)")
        #expect(delivered.filter { $0.type == "audio_end" }.count == 1)
        await client.stop()
    }

    /// Off by default, so `swarm-replay` and the hub e2e stay silent and a
    /// caller has to opt a microphone in rather than discover one.
    @Test func voiceIsSilentUntilItIsEnabled() async throws {
        let channel = GatedChannel()
        await channel.grant(100_000)
        let client = try makeClient(channel: channel, voiceEnabled: false)
        try await client.start()
        #expect(await client.microphoneState == .unavailable)
        for step in 0..<10 {
            await client.offerAudio(samples: tone(0.9), sourceRate: 48_000,
                                    capturedAt: 100 + Double(step) * 0.085)
        }
        #expect(await client.setMicrophoneMuted(false) == .unavailable)
        let delivered = await channel.deliveredMessages()
        #expect(!delivered.contains { $0.type == "audio" || $0.type == "audio_end" })
        await client.stop()
    }

    /// Tapping mute mid-sentence owes the hub an `audio_end`: otherwise it waits
    /// out its own 1.2 s quiet timer and transcribes a sentence the operator cut
    /// off on purpose.
    @Test func mutingMidSentenceClosesTheUtterance() async throws {
        let channel = GatedChannel()
        await channel.grant(100_000)
        let client = try makeClient(channel: channel, voiceEnabled: true)
        try await client.start()

        for step in 0..<4 {
            await client.offerAudio(samples: tone(0.5), sourceRate: 48_000,
                                    capturedAt: 100 + Double(step) * 0.085)
        }
        #expect(await client.microphoneState == .speaking)
        #expect(await client.setMicrophoneMuted(true) == .muted)

        await waitUntil("the mute closed the utterance") {
            await channel.deliveredMessages().contains { $0.type == "audio_end" }
        }
        let before = await channel.deliveredMessages().filter { $0.type == "audio" }.count
        // Nothing more leaves the phone while muted, however loud the room is.
        for step in 0..<6 {
            await client.offerAudio(samples: tone(0.9), sourceRate: 48_000,
                                    capturedAt: 101 + Double(step) * 0.085)
        }
        #expect(await client.microphoneState == .muted)
        #expect(await channel.deliveredMessages().filter { $0.type == "audio" }.count == before)
        await client.stop()
    }
}
