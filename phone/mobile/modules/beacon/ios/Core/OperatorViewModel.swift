import Foundation
import Observation
import SwarmCore

/// What the operator view observes. Wires the runtime's streams to the screen,
/// the haptic engine and the speaker, and owns nothing else.
///
/// Every decision this class could plausibly make already lives in SwarmCore:
/// state transitions in `SessionMachine`, backpressure in `Transport`, the arrow
/// in `OverlayModel`, the whole hub conversation in `SwarmClient`. What is left
/// here is plumbing — which is the point, since none of this file can be tested
/// without a device.
@MainActor
@Observable
public final class OperatorViewModel {
    public private(set) var frame = OverlayFrame()
    public private(set) var preview: CameraPreviewSource?
    public private(set) var isJoined = false
    public private(set) var isReplay = false
    /// True while the operator is driving the pose with their thumbs. Gates the
    /// gesture layer and the synthetic room, so neither can appear on a device.
    public private(set) var isDrive = false

    private let runtime: SwarmRuntime
    private var observer: UUID?
    private var tasks: [Task<Void, Never>] = []
    private var client: SwarmClient?
    private var drive: DrivePoseProvider?
    /// The last dimensions handed to the provider, so a 30 Hz overlay stream
    /// does not become 30 actor hops a second saying the same thing.
    private var driveBounds: DriveBounds?
    private let haptics = Haptics()
    private var pulseSerial: UInt64 = 0

    public init(runtime: SwarmRuntime = .shared) {
        self.runtime = runtime
    }

    /// One beat of the ambient wash, felt as well as seen.
    ///
    /// Driven by `HUDAmbientView`, not by the cue stream: a cue is something
    /// that happened once, and this is a rhythm. It is the same loop that
    /// animates the light, so the two cannot drift apart.
    public func pulse(_ intensity: Double, kind: String) {
        pulseSerial &+= 1
        haptics.play(HapticCue(pattern: kind == "hazard" ? "pulseHazard" : "pulse",
                               intensity: Float(intensity), serial: pulseSerial))
    }

    public func attach() {
        guard observer == nil else { return }
        BeaconLog.log("view model attach")
        observer = runtime.observe { [weak self] session in
            Task { @MainActor in self?.bind(session) }
        }
    }

    public func detach() {
        BeaconLog.log("view model detach")
        if let observer { runtime.removeObserver(observer) }
        observer = nil
        bind(nil)
    }

    private func bind(_ session: RuntimeSession?) {
        BeaconLog.log("bind session=\(session == nil ? "nil" : "live") preview=\(session?.preview != nil)")
        for task in tasks { task.cancel() }
        tasks.removeAll()
        client = session?.client
        preview = session?.preview
        drive = session?.drive
        driveBounds = nil
        isJoined = session != nil
        isReplay = session != nil && session?.preview == nil
        isDrive = session?.drive != nil
        guard let client = session?.client else {
            frame = OverlayFrame()
            return
        }
        tasks.append(Task { @MainActor [weak self] in
            for await next in await client.overlayFrames() {
                // `@Observable`'s setter calls `withMutation` whether or not the
                // value changed, and every view in `OperatorView` reads `frame`
                // — so an unconditional assignment invalidated the camera host,
                // the reticle, the flash and the takeover on every tick. The
                // client already gates its yields; this is the second belt,
                // for the seed frame and for any future producer.
                if self?.frame != next { self?.frame = next }
                self?.forwardRoomBounds(next.overlay.room)
            }
        })
        // Haptics and beeps were the two optional device subsystems on this
        // screen, and both went out together when the device bring-up stopped
        // being trustworthy: `CHHapticEngine` and a second `AVAudioEngine`
        // sharing the one `AVAudioSession` with voice.
        //
        // Haptics are back, on `UIFeedbackGenerator` rather than the engine —
        // no audio session, no lifecycle, nothing to restart after an
        // interruption. Every cue goes through `Haptics`, which owns the
        // mapping from cue name to feel — `possible_match` included, rather
        // than one pattern being answered with a generator built inline here.
        // Beeps are still only logged: a second `AVAudioEngine` is exactly the
        // thing that caused the trouble, and audio has no equivalent free ride.
        haptics.prepare()
        tasks.append(Task { @MainActor [weak self] in
            for await cue in await client.cues() {
                switch cue {
                case .haptic(let haptic): self?.haptics.play(haptic)
                case .sound(let sound): BeaconLog.log("cue sound \(sound.name) (ignored)")
                }
            }
        })
    }

    // MARK: - Driving, in the Simulator only

    /// One gesture update from `DriveControlsView`.
    ///
    /// Deltas accumulate inside the provider and are consumed once per emitted
    /// pose, so a burst of touch events between two frames is one movement. The
    /// stick, by contrast, latches until the view sends `walk: .zero`.
    public func drive(_ input: DriveInput) {
        guard let drive else { return }
        Task { await drive.apply(input) }
    }

    /// The room's real dimensions, which arrive in the hub's `welcome` and not
    /// in `venue.json`.
    ///
    /// This is the whole bounds mechanism: `PoseProvider` was deliberately left
    /// alone rather than grown a room-shaped parameter that ARKit has no use
    /// for, and the view model is the one object that already sees both the
    /// overlay stream and the provider.
    private func forwardRoomBounds(_ room: HubRoom?) {
        guard let drive, let room, room.width > 0, room.depth > 0 else { return }
        let bounds = DriveBounds(width: room.width, depth: room.depth)
        guard bounds != driveBounds else { return }
        driveBounds = bounds
        Task { await drive.setBounds(bounds) }
    }

    // MARK: - Operator actions, from the native seat picker

    public func setSeat(x: Double, y: Double) {
        guard let client else { return }
        Task { await client.setSeat(x: x, y: y) }
    }

    /// "I see something": a ping for everyone, where this operator stands.
    public func mark() {
        guard let client else { return }
        Task { await client.mark() }
    }

    /// For a marker lock that has gone wrong and is not fixing itself.
    public func resetOrigin() {
        guard let client else { return }
        Task { await client.resetOrigin() }
    }

    /// So the console's HUD mirror knows which part of the frame this screen shows.
    public func reportScreenSize(_ size: CGSize) {
        guard let client, size.width > 0, size.height > 0 else { return }
        Task { await client.setScreenSize(width: size.width, height: size.height) }
    }

    public func calibrateFacingStage() async -> Bool {
        guard let client else { return false }
        return await client.calibrateFacingStage()
    }
}
