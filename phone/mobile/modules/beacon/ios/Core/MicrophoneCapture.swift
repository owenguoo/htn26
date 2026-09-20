import AVFoundation
import Foundation
import QuartzCore
import SwarmCore

/// The one owner of `AVAudioSession`'s category.
///
/// Two things in this app want the audio session: `SoundPlayer` (the hub's ping
/// and message beeps) and `MicrophoneCapture` (voice). They want *different*
/// categories — `.ambient` for a beep that obeys the ringer switch, and
/// `.playAndRecord` for an input tap — and `AVAudioSession` is a process
/// singleton, so whoever calls `setCategory` last wins for everybody.
///
/// The failure that produces is silent and intermittent: capture starts fine,
/// the operator talks, then the hub sends a ping, `SoundPlayer` sets `.ambient`
/// to beep, the input route disappears under the running `AVAudioEngine`, and
/// the tap stops firing with no error anywhere. Voice dies partway through a
/// session and nothing says why.
///
/// So neither of them calls `setCategory`. They declare what they need here,
/// and this type resolves the union: recording wanted anywhere ⇒
/// `.playAndRecord`, otherwise `.ambient`. It re-applies only when the resolved
/// configuration actually changes, and tells its registered users when it did,
/// because an `AVAudioEngine` whose route moved underneath it has to be
/// restarted.
///
/// The cost, stated plainly: while the microphone is running the session is
/// `.playAndRecord`, and `.playAndRecord` **does not obey the silent switch**.
/// The beeps are audible with the ringer off for exactly as long as voice is
/// capturing. That is the right trade — a phone that stops hearing the operator
/// is worse than a phone that beeps when muted — but it is a behaviour change
/// from `.ambient` and it is on the device checklist.
@MainActor
public final class AudioSessionOwner {
    public static let shared = AudioSessionOwner()

    /// What a caller needs from the session. A caller `begin`s its use and
    /// `end`s it; the union decides the category.
    public struct Use: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Beeps. Happy with `.ambient`.
        public static let playback = Use(rawValue: 1 << 0)
        /// An input tap. Forces `.playAndRecord`.
        public static let record = Use(rawValue: 1 << 1)
    }

    private var uses: Use = []
    private var applied: (category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions)?
    private var handlers: [UUID: () -> Void] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                // A phone call tears the session down. `.ended` is the only
                // moment it is legal to reactivate, and every engine that was
                // running has to be started again.
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                BeaconLog.log("audio interruption notification raw=\(raw.map(String.init) ?? "nil")")
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                // `queue: .main` ≠ MainActor; `assumeIsolated` traps off the
                // executor even when the block is on the main dispatch queue.
                Task { @MainActor in
                    guard let self else { return }
                    self.applied = nil
                    self.apply()
                }
            }
    }

    /// Called after the session has been reconfigured or resumed. Restart your
    /// engine here; do not touch the category.
    @discardableResult
    public func onReconfigure(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func removeHandler(_ id: UUID) {
        handlers.removeValue(forKey: id)
    }

    public func begin(_ use: Use) {
        guard !uses.contains(use) else { return }
        uses.insert(use)
        apply()
    }

    public func end(_ use: Use) {
        guard uses.contains(use) else { return }
        uses.remove(use)
        apply()
    }

    // `prepareDirectionalInput()` used to live here: it asked for the built-in
    // mic's stereo beam with `setPreferredInput`, `setPreferredDataSource`,
    // `setPreferredPolarPattern(.stereo)`, `setPreferredInputOrientation` and
    // `setPreferredInputNumberOfChannels(2)`. Five route mutations on the one
    // process-wide `AVAudioSession` — while ARKit is running the camera off the
    // same session. Stereo input on iOS is bound up with the camera's own
    // orientation handling, and the device trace had `start()` blocking for
    // 3.9 s and ARKit's tracking dropping to `notAvailable` the moment it
    // returned. Voice needs mono; the stereo beam was for the directional SOUND
    // marker, which is a nice-to-have. It is not coming back without a device
    // trace showing it is free.

    private func apply() {
        let session = AVAudioSession.sharedInstance()
        guard !uses.isEmpty else {
            // Nothing wants the session. Hand it back so whatever the operator
            // was listening to before the app resumes at full volume.
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            applied = nil
            return
        }

        let wantsRecord = uses.contains(.record)
        let category: AVAudioSession.Category = wantsRecord ? .playAndRecord : .ambient
        // `.mixWithOthers` throughout: this is a camera the operator carries
        // around a room, not a media player, and it has no business stopping
        // somebody's music. `.defaultToSpeaker` because `.playAndRecord`
        // otherwise routes a beep to the earpiece, which nobody hears while the
        // phone is held up at arm's length.
        // No `.allowBluetooth`. It forces the HFP profile for a two-way route,
        // and negotiating HFP with a connected accessory takes seconds — a
        // prime suspect for the 3.9 s `microphone.start` in the device trace.
        // The operator's voice goes to the hub from the phone in their hand;
        // it does not need to come from their earbuds.
        let options: AVAudioSession.CategoryOptions = wantsRecord
            ? [.mixWithOthers, .defaultToSpeaker]
            : [.mixWithOthers]

        let changed = applied.map { $0.category != category || $0.options != options } ?? true
        do {
            if changed {
                BeaconLog.log("audio → setCategory(\(category.rawValue))")
                try session.setCategory(category, mode: .default, options: options)
                BeaconLog.log("audio ✓ setCategory")
            }
            BeaconLog.log("audio → setActive(true)")
            try session.setActive(true)
            BeaconLog.log("audio ✓ setActive, route=\(session.currentRoute.inputs.map(\.portType.rawValue))")
            applied = (category, options)
        } catch {
            BeaconLog.log("audio ✗ session configuration failed: \(String(describing: error))")
            // A session that will not configure means no beeps and no voice.
            // Both are optional to the demo; the camera and the socket are not.
            applied = nil
            return
        }
        if changed { for handler in handlers.values { handler() } }
    }
}

/// Feeds the real microphone to `SwarmClient.offerAudio`.
///
/// Adapter only, and deliberately so. The gate (loudness threshold, 600 ms
/// hang, one chunk of pre-roll), the decimation to 16 kHz, the `Int16`
/// little-endian framing, the `seq`/`tCapture` header and the never-dropped
/// send order are all in `SwarmCore` — `VoiceGate` and `SwarmClient` — where
/// they are tested on macOS. This file exists because `AVAudioEngine` cannot
/// be, and it does nothing a test could have caught.
///
/// Mirrors what `web/phone.js` does with a `ScriptProcessor(4096, 1, 1)`: same
/// buffer size, same mono float samples, same "hand it over and let the gate
/// decide".
///
// DEVICE-VERIFY: none of this runs meaningfully in the Simulator — it has no
// microphone of its own, and `AVAudioSession` there is a stub over the Mac's
// audio. On hardware a human must check, and tick off in DEVICE_CHECKLIST.md:
//   1. The microphone permission alert appears on the first join, and denying
//      it leaves the app joined, streaming frames, with the mic control struck
//      through — not wedged, and not asking again every frame.
//   2. Speaking makes the console show a caption, and the green ring on the
//      mic control matches when words are actually leaving the phone.
//   3. A hub `ping` beep mid-sentence does NOT stop capture — the failure this
//      file's `AudioSessionOwner` exists to prevent. Talk, have the console
//      ping you, keep talking, confirm the second half still transcribes.
//   4. Starting the audio engine does not disturb ARKit tracking (existing
//      checklist item), and the pose rate does not drop when voice is live.
//   5. Muting clears iOS's orange microphone indicator; unmuting brings it back
//      within a second and the next sentence is not clipped.
//   6. A phone call interrupts and, on hanging up, capture resumes by itself.
//   7. On a built-in stereo route, a hand clap on each side produces the
//      matching edge flash and SOUND compass marker; speech, the phone's own
//      ping, and AirPods produce no false directional cue.
@MainActor
public final class MicrophoneCapture {
    /// Whether there is a live tap, and if not, why not. Process-wide because
    /// there is one microphone and one audio session; read from the Expo module
    /// so the mic control can say "unavailable" rather than "idle" when the
    /// operator declined the prompt.
    public enum Availability: String, Sendable {
        /// Not started: no session, or this session does not want voice.
        case stopped
        /// The operator said no. Nothing will ask again this launch.
        case denied
        /// No usable input route, or the engine refused to start.
        case unsupported
        /// A tap is installed. `SwarmClient.micState` is then the truth.
        case running
    }

    public nonisolated static var availability: Availability { Registry.shared.availability }

    /// Mute for the session that owns the live microphone, if there is one.
    /// Returns `nil` when nothing is capturing, so the caller can fall back to
    /// the client directly and keep the snapshot coherent.
    public nonisolated static func setMuted(_ muted: Bool) async -> MicrophoneState? {
        guard let capture = Registry.shared.capture else { return nil }
        return await capture.setMuted(muted)
    }

    private let client: SwarmClient
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Chunk>.Continuation?
    private var pump: Task<Void, Never>?
    private var reconfigureHandler: UUID?
    private var configurationObserver: NSObjectProtocol?
    private var isTapped = false
    private var isMuted = false

    public init(client: SwarmClient) {
        self.client = client
    }

    /// One buffer, on its way from the tap thread to the actor.
    private struct Chunk: Sendable {
        let samples: [Float]
        let stereoLeft: [Float]?
        let stereoRight: [Float]?
        let rate: Double
        /// `CACurrentMediaTime()`'s domain — the same one `SwarmRuntime` hands
        /// the client as `uptime`, or `tCapture` on the wire is nonsense.
        let at: Double
    }

    /// Asks for the microphone if it has not been asked for, then starts
    /// capturing. Safe to call when it is already running.
    ///
    /// Every failure here is soft. A session that cannot record still tracks,
    /// still streams frames and still takes commands; it just has no voice. The
    /// one thing this must never do is leave the audio session half-claimed,
    /// because that is what kills the beeps as well.
    public func start() async {
        guard !isTapped else { return }
        BeaconLog.log("mic → requestPermission")
        guard await Self.requestPermission() else {
            BeaconLog.log("mic ✗ permission denied")
            Registry.shared.set(availability: .denied)
            return
        }
        BeaconLog.log("mic ✓ permission granted")

        BeaconLog.log("mic → AudioSessionOwner.begin(.record)")
        AudioSessionOwner.shared.begin(.record)
        BeaconLog.log("mic ✓ AudioSessionOwner.begin(.record)")
        reconfigureHandler = AudioSessionOwner.shared.onReconfigure { [weak self] in
            Task { @MainActor in self?.restart() }
        }
        // The other half of the same problem: when the route changes, an
        // `AVAudioEngine` stops and drops its tap's format on the floor. It has
        // to be rebuilt, not merely restarted.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                BeaconLog.log("AVAudioEngineConfigurationChange")
                Task { @MainActor in self?.restart() }
            }

        guard install() else {
            BeaconLog.log("mic ✗ install failed")
            // Both observers registered above have to come off here too.
            // `isTapped` stays false on this path, so a later `start()` walks
            // straight past its guard and registers a second pair — after which
            // every route change fires `restart()` once per accumulated pair.
            if let reconfigureHandler { AudioSessionOwner.shared.removeHandler(reconfigureHandler) }
            reconfigureHandler = nil
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
            AudioSessionOwner.shared.end(.record)
            Registry.shared.set(availability: .unsupported)
            return
        }
        Registry.shared.attach(self)
        Registry.shared.set(availability: .running)
        BeaconLog.log("mic ✓ running")
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        continuation?.finish()
        continuation = nil
        uninstall()
        if let reconfigureHandler { AudioSessionOwner.shared.removeHandler(reconfigureHandler) }
        reconfigureHandler = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        AudioSessionOwner.shared.end(.record)
        Registry.shared.detach(self)
        if Registry.shared.availability == .running { Registry.shared.set(availability: .stopped) }
    }

    /// The mic control. Tells the gate first — it owes the hub an `audio_end`
    /// if the operator muted mid-sentence, and without it the hub waits out its
    /// own 1200 ms quiet timer and transcribes a sentence that was cut off on
    /// purpose — then stops the input running at all.
    ///
    /// Stopping the engine is not just tidiness: a paused engine is not pulling
    /// from the microphone, which is what makes "muted" mean muted rather than
    /// "recorded and discarded". The gate alone would have been enough for the
    /// wire.
    @discardableResult
    public func setMuted(_ muted: Bool) async -> MicrophoneState {
        let state = await client.setMicrophoneMuted(muted)
        isMuted = muted
        if muted {
            engine.pause()
        } else if isTapped, !engine.isRunning {
            try? engine.start()
        }
        return state
    }

    // MARK: - Engine

    private func install() -> Bool {
        BeaconLog.log("mic → engine.inputNode")
        let input = engine.inputNode
        BeaconLog.log("mic ✓ engine.inputNode")
        // Voice processing on the input node has asserted
        // `_dispatch_assert_queue_fail` when brought up alongside ARKit. Echo
        // cancellation for the local beep is nice; a live camera is required.
        // Leave processing off — loud-sound gating still covers most of it.
        try? input.setVoiceProcessingEnabled(false)

        let format = input.outputFormat(forBus: 0)
        BeaconLog.log("mic format \(format.sampleRate) Hz × \(format.channelCount)ch")
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }

        // Bounded on purpose. The consumer only awaits an actor hop, so a
        // backlog means the client is wedged — and five seconds of stale PCM is
        // already a transcript nobody wants. Dropping the oldest here is not the
        // same as dropping inside an utterance on the wire, which `Transport`
        // refuses to do.
        let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.continuation = continuation

        // 4096 frames, exactly `ScriptProcessor(4096, 1, 1)` in `phone.js`, so
        // the pre-roll chunk is the same slice of time on both clients.
        // `hasLoggedFirstBuffer` is touched only from the tap, which AVAudioEngine
        // serialises, and only ever set true — never read for correctness.
        nonisolated(unsafe) var hasLoggedFirstBuffer = false
        // `@Sendable` is load-bearing, and is the prime suspect for
        // `_dispatch_assert_queue_fail`.
        //
        // `AVAudioNodeTapBlock` is imported from ObjC as a plain
        // `@convention(block)` type, *not* `@Sendable`. Under SE-0434 a
        // non-`@Sendable` closure formed inside an actor-isolated context
        // inherits that isolation — and this method belongs to a `@MainActor`
        // class, so without this annotation the block is `@MainActor`. Swift
        // then emits a reabstraction thunk that calls `swift_task_checkIsolated`,
        // which for `MainActor` bottoms out in
        // `dispatch_assert_queue(dispatch_get_main_queue())`. CoreAudio invokes
        // the tap on its own render thread, so that assert fires on the *first*
        // invocation — after `engine.start()` has returned, before the body runs
        // (so "first mic buffer" never prints), on CoreAudio's `RootQueue`, with
        // no frame of ours on the stack. That is exactly the recorded trap.
        //
        // The capture hygiene above was already right, which is why this
        // compiled clean: inferred isolation is not a capture problem.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, when in
            if !hasLoggedFirstBuffer {
                hasLoggedFirstBuffer = true
                BeaconLog.log("first mic buffer")
            }
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
            let right = buffer.format.channelCount > 1
                ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : nil
            // Speech wants mono even when the detector has stereo. Averaging is
            // stable across left/right orientation and keeps the wire unchanged.
            let samples = right.map { right in zip(left, right).map { ($0 + $1) * 0.5 } } ?? left
            // The buffer's own start time, not "now". `AVAudioTime`'s host time
            // is the mach timebase, which is what `CACurrentMediaTime()` reads.
            let at = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : CACurrentMediaTime()
            continuation.yield(Chunk(samples: samples, stereoLeft: right == nil ? nil : left,
                                     stereoRight: right, rate: buffer.format.sampleRate, at: at))
        }
        isTapped = true
        BeaconLog.log("mic ✓ installTap")

        BeaconLog.log("mic → engine.prepare")
        engine.prepare()
        BeaconLog.log("mic ✓ engine.prepare; → engine.start")
        do {
            try engine.start()
            BeaconLog.log("mic ✓ engine.start")
        } catch {
            BeaconLog.log("mic ✗ engine.start: \(String(describing: error))")
            uninstall()
            return false
        }

        // One consumer task, so the actor sees the chunks in the order the
        // microphone produced them. A `Task` per buffer would not: unstructured
        // tasks carry no ordering, and an utterance whose chunks arrive shuffled
        // is a WAV of somebody talking backwards.
        pump = Task { [client] in
            for await chunk in stream {
                await client.offerAudio(samples: chunk.samples, sourceRate: chunk.rate, capturedAt: chunk.at,
                                        stereoLeft: chunk.stereoLeft, stereoRight: chunk.stereoRight)
            }
        }
        return true
    }

    private func uninstall() {
        if isTapped { engine.inputNode.removeTap(onBus: 0) }
        isTapped = false
        if engine.isRunning { engine.stop() }
    }

    /// The route moved or an interruption ended. Rebuild rather than restart —
    /// the tap's format belonged to the old route.
    private func restart() {
        BeaconLog.log("mic → restart")
        guard Registry.shared.capture === self else {
            BeaconLog.log("mic restart skipped (not the live capture)")
            return
        }
        pump?.cancel()
        pump = nil
        continuation?.finish()
        continuation = nil
        uninstall()
        guard install() else {
            Registry.shared.set(availability: .unsupported)
            return
        }
        if isMuted { engine.pause() }
        Registry.shared.set(availability: .running)
        BeaconLog.log("mic ✓ restart")
    }

    // MARK: - Permission

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                // `@Sendable` for the same reason as the tap block: this is a
                // static member of a `@MainActor` class, the completion handler
                // is delivered on an internal queue, and inferred isolation
                // would put a main-queue assert in front of it. Only reachable
                // on the undetermined branch — first launch after an install.
                AVAudioApplication.requestRecordPermission { @Sendable granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    /// One microphone, one session, one truth about both. Lock-guarded rather
    /// than main-actor so the Expo module can read the availability from
    /// whatever executor an `AsyncFunction` body happens to be on.
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var _availability: Availability = .stopped
        private weak var _capture: MicrophoneCapture?

        var availability: Availability { lock.withLock { _availability } }
        var capture: MicrophoneCapture? { lock.withLock { _capture } }

        func set(availability: Availability) { lock.withLock { _availability = availability } }
        func attach(_ capture: MicrophoneCapture) { lock.withLock { _capture = capture } }
        func detach(_ capture: MicrophoneCapture) {
            lock.withLock { if _capture === capture { _capture = nil } }
        }
    }
}
