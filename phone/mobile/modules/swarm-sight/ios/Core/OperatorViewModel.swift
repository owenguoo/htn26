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
    private let haptics = HapticPlayer()
    private let sounds = SoundPlayer()
    private var observer: UUID?
    private var tasks: [Task<Void, Never>] = []
    private var client: SwarmClient?
    private var drive: DrivePoseProvider?
    /// The last dimensions handed to the provider, so a 30 Hz overlay stream
    /// does not become 30 actor hops a second saying the same thing.
    private var driveBounds: DriveBounds?

    public init(runtime: SwarmRuntime = .shared) {
        self.runtime = runtime
    }

    public func attach() {
        guard observer == nil else { return }
        haptics.prepare()
        sounds.prepare()
        observer = runtime.observe { [weak self] session in
            Task { @MainActor in self?.bind(session) }
        }
    }

    public func detach() {
        if let observer { runtime.removeObserver(observer) }
        observer = nil
        bind(nil)
    }

    private func bind(_ session: RuntimeSession?) {
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
        tasks.append(Task { [weak self] in
            for await next in await client.overlayFrames() {
                self?.frame = next
                self?.forwardRoomBounds(next.overlay.room)
            }
        })
        tasks.append(Task { [weak self] in
            for await cue in await client.cues() {
                switch cue {
                case .haptic(let haptic): self?.haptics.play(haptic)
                case .sound(let sound): self?.sounds.play(sound)
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
