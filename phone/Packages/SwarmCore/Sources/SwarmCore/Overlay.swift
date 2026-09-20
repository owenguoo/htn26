import Foundation
import simd

/// What the status pill shows. Everything an operator needs to know whether to
/// trust what the phone is telling them, in one line.
public struct StatusPill: Sendable, Equatable {
    public var sessionState: SessionState
    public var trackingState: String
    public var confidence: Double
    public var isStale: Bool
    public var connection: ConnectionState
    public var inFlight: Int
    public var dropped: Int
    public var thermalState: ThermalState
    /// Seconds since the last accepted marker correction. nil means never, which
    /// means nothing this phone reports can be fused.
    public var secondsSinceCorrection: Double?
    /// How long this phone has been unable to reach the hub — measured from
    /// the moment the transport last left `.online`, or from the first attempt
    /// if it has never been online. nil while connected.
    ///
    /// Only `OperatorStatus` reads it, and only to decide how loud to be:
    /// dialling the hub is not a fault until it has been going on a while.
    public var secondsDisconnected: Double?
    /// How this phone knows where it is in the room. Decides what "never
    /// corrected" means: alarming for a marker-locked phone, normal for one
    /// located from a seat tap, which has no marker corrections by definition.
    public var alignment: RoomAligner.Source

    public enum ConnectionState: String, Sendable, Equatable {
        case offline
        case connecting
        case online
        case reconnecting

        public init(_ transport: TransportState) {
            switch transport {
            case .idle, .closed: self = .offline
            case .connecting(let attempt): self = attempt == 0 ? .connecting : .reconnecting
            case .connected: self = .online
            case .waitingToReconnect: self = .reconnecting
            }
        }
    }

    public init(sessionState: SessionState = .idle, trackingState: String = "notAvailable",
                confidence: Double = 0, isStale: Bool = true,
                connection: ConnectionState = .offline, inFlight: Int = 0, dropped: Int = 0,
                thermalState: ThermalState = .nominal, secondsSinceCorrection: Double? = nil,
                secondsDisconnected: Double? = nil,
                alignment: RoomAligner.Source = .marker) {
        self.alignment = alignment
        self.sessionState = sessionState
        self.trackingState = trackingState
        self.confidence = confidence
        self.isStale = isStale
        self.connection = connection
        self.inFlight = inFlight
        self.dropped = dropped
        self.thermalState = thermalState
        self.secondsSinceCorrection = secondsSinceCorrection
        self.secondsDisconnected = secondsDisconnected
    }

    /// True when the operator should be told something is wrong rather than
    /// left to read six numbers.
    public var needsAttention: Bool {
        isStale
            || connection != .online
            || sessionState == .lost
            || sessionState == .recalibrating
            || correctionNeedsAttention
            || thermalState >= .serious
    }
}

extension StatusPill {
    /// A seat-located phone is tracking correctly with no marker correction at
    /// all, so holding it to "corrected in the last 30 s" kept the pill orange
    /// for a phone with nothing wrong. Only a phone with no alignment of any
    /// kind, or a marker lock that has gone old, is worth the operator's eye.
    var correctionNeedsAttention: Bool {
        switch alignment {
        case .none: true
        case .seat: false
        case .marker: secondsSinceCorrection.map { $0 > 30 } ?? true
        }
    }
}

/// The one thing the operator is told about the phone's health: what is going
/// on, in words, and what to do about it.
///
/// The pill used to read `LOST conf 1.00 fix 34s air 1 drop 0`. Every field was
/// true and none of it told the person holding the phone what to do. This picks
/// the single most important problem and says it plainly; the numbers live in
/// Settings for whoever is debugging.
public struct OperatorStatus: Sendable, Equatable {
    public enum Level: String, Sendable, Equatable {
        /// Nothing to do.
        case ok
        /// Working, but the operator can improve it.
        case attention
        /// Not working until something changes.
        case problem
    }

    public var level: Level
    public var title: String
    /// What to do about it. nil when there is nothing to do.
    public var hint: String?

    public init(level: Level, title: String, hint: String? = nil) {
        self.level = level
        self.title = title
        self.hint = hint
    }

    /// **There is one way to get located: look at a printed marker.**
    ///
    /// There used to be two — scan a marker, or open a floor plan, tap where
    /// you think you are standing, and confirm you are facing the stage. Two
    /// methods meant every prompt had to gesture at both ("Point at a marker,
    /// or tap here") and explain neither. The tap path was also much the weaker
    /// of the two: a guess at a position plus a guess at a heading, where a
    /// marker gives both exactly.
    ///
    /// `RoomAligner.setSeat` / `calibrateFacingStage` stay in SwarmCore — the
    /// wire protocol has them, `swarm-replay` uses them, and the drive-mode
    /// end-to-end test drives them through the JS API. What is gone is the
    /// operator-facing way in.
    static let locateHint = "Point the camera at a printed marker"

    /// How long a marker fix has to go unrefreshed before the operator is told
    /// their position may be drifting.
    ///
    /// This was 30 s, which is roughly how long it takes to sweep one corner of
    /// a room — so the warning was up more often than it was down, for a phone
    /// that was tracking perfectly well. A warning an operator learns to ignore
    /// is worse than no warning, because the one time it matters they will
    /// ignore that too. Two minutes is long enough that seeing it means the
    /// operator really has not looked at a marker for a while.
    static let driftHintSeconds: Double = 120

    /// How long the phone has to be out of touch with the hub before the
    /// status goes red.
    ///
    /// Joining a room is a websocket handshake over venue Wi-Fi, and a phone
    /// that has just been unlocked may also be waiting on the radio to wake.
    /// Both take a moment, and both are completely normal — but the pill went
    /// straight to a red warning triangle and "Check the venue Wi-Fi" the
    /// instant the app opened, so every single launch began by telling the
    /// operator something was broken. It is the same crying-wolf problem as
    /// `driftHintSeconds`: a warning that is usually wrong gets ignored when
    /// it is right.
    ///
    /// Under this, the same words are amber with no instruction attached —
    /// "Connecting…", which is true and not alarming. Over it, the connection
    /// really has not come up and the operator needs to do something about it.
    ///
    /// Measured from when the transport last left `.online`, not from the
    /// current state, deliberately: the first attempt is `.connecting` and
    /// every retry after it is `.reconnecting`, so keying off the state name
    /// would go red on the second attempt, a second or two in.
    public static let connectingGraceSeconds: Double = 15

    /// Most important first: a phone that cannot reach the hub has no use for
    /// being told its tracking is shaky.
    public init(_ pill: StatusPill) {
        // nil means the caller does not track it: treat that as "just started"
        // rather than "forever", so a pill built by hand is never alarming.
        let settling = (pill.secondsDisconnected ?? 0) < Self.connectingGraceSeconds
        switch pill.connection {
        case .offline, .connecting:
            self.init(level: settling ? .attention : .problem, title: "Connecting…",
                      hint: settling ? nil : "Check the venue Wi-Fi")
            return
        case .reconnecting:
            self.init(level: settling ? .attention : .problem, title: "Reconnecting…",
                      hint: settling ? nil : "Check the venue Wi-Fi")
            return
        case .online:
            break
        }
        switch pill.sessionState {
        case .idle, .permissions:
            self.init(level: .attention, title: "Starting the camera…")
        case .recalibrating:
            self.init(level: .attention, title: "Needs recalibrating", hint: Self.locateHint)
        case .lost:
            self.init(level: .problem, title: "Tracking lost",
                      hint: pill.alignment == .marker ? "Move slowly, find a marker"
                                                      : "Move slowly, look around")
        case .calibrating where pill.alignment == .none:
            self.init(level: .attention, title: "Not located yet", hint: Self.locateHint)
        case .degraded:
            self.init(level: .attention, title: "Tracking is shaky", hint: "Slow down, camera up")
        case .calibrating, .tracking:
            if pill.isStale {
                self.init(level: .problem, title: "Camera stopped", hint: "Reopen the app if it stays")
            } else if pill.alignment == .none {
                self.init(level: .attention, title: "Not located yet", hint: Self.locateHint)
            } else if pill.thermalState >= .serious {
                self.init(level: .attention, title: "Phone is hot", hint: "Sending fewer frames")
            } else if pill.alignment == .marker,
                      (pill.secondsSinceCorrection ?? 0) > Self.driftHintSeconds {
                self.init(level: .attention, title: "Position may be drifting", hint: "Glance at a marker")
            } else {
                self.init(level: .ok, title: pill.alignment == .seat ? "Tracking from your spot" : "Tracking")
            }
        }
    }
}

public struct FlashCue: Sendable, Equatable {
    public var red: Float
    public var green: Float
    public var blue: Float
    /// Big centred text over the colour, e.g. "You're there ✓".
    public var text: String?
    /// Local monotonic time after which the flash stops.
    public var until: Double

    public init(red: Float, green: Float, blue: Float, text: String? = nil, until: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.text = text
        self.until = until
    }
}

/// The angles that decide "you are facing it" and "your phone is pointed at the
/// floor".
///
/// These existed three times with three different values, which meant the arrow,
/// the banner and the console's marker colour could each disagree about whether
/// the operator was on target — the arrow said yes, the pill stayed orange, and
/// nobody could tell which was lying:
///
/// - the hub: `abs(delta) < half_fov * 0.6` (`swarm/planner.py`), which at
///   `room.json`'s `cameraFovDeg: 55` is **16.5°**;
/// - `ArrowCue.isOnTarget`: `0.35` rad, which is **20.05°**;
/// - `HUDMirror`'s marker colour: **16°**, copied from `web/phone.js:723`.
///
/// **16° wins.** It is the web client's number, and matching the web client's
/// feel is the goal; it is already what the console is told, so the phone and the
/// console agree by construction; and it is within half a degree of the hub's own
/// 16.5°, so the banner goes green essentially when the hub also thinks so. The
/// 20.05° was the outlier — four degrees looser than everything else, for no
/// reason anyone recorded.
public enum GuideThresholds {
    public static let onTargetDegrees: Double = 16
    public static let onTargetRadians = Float(onTargetDegrees * .pi / 180)

    /// Past this the phone is pointed at the floor or the ceiling and is
    /// searching nothing. `web/phone.js:773` and `swarm/planner.py`'s
    /// `MAX_PITCH` agree on 65.
    public static let tiltedPitchDegrees: Double = 65

    /// How far back out the operator must swing before "on target" can fire
    /// again. Without it a `go` guide lasting 90 s buzzes every time someone
    /// drifts a degree across the boundary and back.
    public static let onTargetReleaseDegrees: Double = 22

    /// How far the phone may be pointed off the target's height before the
    /// operator is told to raise or lower it.
    ///
    /// 20° is wide on purpose. Nobody holds a phone to better than a few degrees
    /// while walking, and a cue that appears and vanishes as someone breathes is
    /// noise the operator learns to ignore. Below it, a target 6 m away is still
    /// comfortably inside a 55° lens.
    public static let elevationDeadZoneDegrees: Double = 20

    /// Once the cue is up it stays up until the error falls to here — a plain
    /// 20° test would flicker at exactly the angle someone is trying to hold.
    public static let elevationReleaseDegrees: Double = 12
}

/// Where a target sits vertically, given only how far away it is on the floor.
///
/// **Nothing in `swarm/` supplies an elevation.** The hub's whole world model is
/// a 2D floor plan: `planner.py`, `target.py` and `mission.py` deal in `(x, y)`
/// and a bearing, and the only pitch-aware string anywhere in the system is
/// "Hold your phone up". So a "look up / look down" cue has to be derived here,
/// and it is derived from the two constants `web/phone.js` `project()` uses to
/// place its AR diamonds (`phone.js:809-810`) — the same assumed geometry, so
/// the phone's cue and the browser's diamonds put a target in the same place.
public enum TargetGeometry {
    /// A phone held up at chest height.
    public static let cameraHeightMetres: Double = 1.3
    /// Roughly a seated person, or a tabletop.
    public static let targetHeightMetres: Double = 1.0

    /// Radians above the horizon, from the camera to a target `distance` metres
    /// away across the floor. Negative, because the assumed target is below the
    /// assumed camera — the closer you are, the further below.
    ///
    /// The 0.3 m floor on the distance is the web's, and it matters: without it
    /// a target underfoot gives ±90° and the cue swings wildly as someone walks
    /// the last stride.
    public static func elevationRadians(horizontalDistance distance: Double) -> Double {
        atan2(targetHeightMetres - cameraHeightMetres, max(distance, 0.3))
    }
}

/// Raise or lower the phone. The vertical half of a directional cue, which
/// neither the hub nor the web client has ever had.
public struct ElevationCue: Sendable, Equatable {
    /// Where the target sits, radians above the horizon. Also what goes in
    /// `ArrowCue.elevationRadians`.
    public var targetRadians: Float
    /// How far the operator must tilt the phone, in degrees.
    /// **Positive means raise it**: the target is above where the camera points.
    public var neededDegrees: Double

    public init(targetRadians: Float, neededDegrees: Double) {
        self.targetRadians = targetRadians
        self.neededDegrees = neededDegrees
    }

    public var isUp: Bool { neededDegrees > 0 }
    private var whole: Int { Int(abs(neededDegrees).rounded()) }

    /// "Look up 34°" — the leading form, where a turn instruction would go.
    public var text: String { "Look \(isUp ? "up" : "down") \(whole)°" }
    /// "look up 34°" — the trailing form, mid-sentence.
    public var phrase: String { "look \(isUp ? "up" : "down") \(whole)°" }
}

public struct ArrowCue: Sendable, Equatable {
    /// Radians clockwise from straight ahead. Positive means turn right.
    public var bearingRadians: Float
    /// Radians above the horizon, when the target's height is known.
    public var elevationRadians: Float?
    public var label: String?
    /// Metres to the target, when it is a point rather than a bare bearing.
    public var distance: Float?
    public var until: Double?

    public init(bearingRadians: Float, elevationRadians: Float? = nil, label: String? = nil,
                distance: Float? = nil, until: Double? = nil) {
        self.bearingRadians = bearingRadians
        self.elevationRadians = elevationRadians
        self.label = label
        self.distance = distance
        self.until = until
    }

    /// Whether the target is already in front of the operator, within the usable
    /// part of the lens. The arrow can then say "here" rather than "turn".
    public var isOnTarget: Bool { abs(bearingRadians) < GuideThresholds.onTargetRadians }
}

/// The line of text that goes with a guide: "← Turn left 42°",
/// "↑ Walk to door · 6.1 m".
public struct GuideBannerCue: Sendable, Equatable {
    /// "search", "respond", "look" or "go".
    public var kind: String
    public var text: String
    /// Geometrically on target: the offset is inside
    /// `GuideThresholds.onTargetDegrees`. Not the same thing as "show it green"
    /// — see `tone`.
    public var onTarget: Bool
    /// Pointed at the floor or the ceiling. Only `search` cares.
    public var tilted: Bool

    public init(kind: String, text: String, onTarget: Bool, tilted: Bool = false) {
        self.kind = kind
        self.text = text
        self.onTarget = onTarget
        self.tilted = tilted
    }

    /// The console's three pill colours, decided exactly as
    /// `updateGuideBanner` in `web/phone.js` decides its CSS classes.
    public var tone: String {
        // Walking to a confirmed candidate is always the loud one.
        if kind == "respond" { return "alert" }
        // The web never greens a `go`: the operator is pointed the right way but
        // has not arrived, and green would say they had. The hub sends its own
        // green "You're there ✓" flash for that.
        if kind == "go" { return "warn" }
        if kind == "search" && tilted { return "warn" }
        return onTarget ? "ok" : "warn"
    }
}

public struct ToastCue: Sendable, Equatable {
    public var text: String
    public var until: Double

    public init(text: String, until: Double) {
        self.text = text
        self.until = until
    }
}

public struct DetectionsCue: Sendable, Equatable {
    public var threshold: Double? = nil
    public var rehearsal = false
    public var boxes: [HubDetectionBox]
    public var until: Double

    public init(boxes: [HubDetectionBox], until: Double) {
        self.boxes = boxes
        self.until = until
    }
}

/// An operator ping: a spot on the floor someone wants looked at.
public struct PingCue: Sendable, Equatable, Identifiable {
    public var id: Int
    /// Room metres.
    public var x: Double
    public var y: Double
    public var label: String
    public var until: Double
    /// Filled in on every `update` when the phone knows where it is.
    public var bearingRadians: Float?
    public var distance: Float?
    /// Where the spot lands in the *captured* image, in pixels of
    /// `CameraIntrinsics.imageWidth × imageHeight`; nil when it is behind the
    /// camera or the intrinsics are unknown. The view maps this to the screen
    /// the same way it does for marker outlines.
    public var imagePoint: CGPoint?

    public init(id: Int, x: Double, y: Double, label: String, until: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.label = label
        self.until = until
    }
}

public struct HapticCue: Sendable, Equatable {
    public var pattern: String
    public var intensity: Float
    /// Distinguishes one firing from the next, so the view's change handler
    /// fires for two identical cues in a row.
    public var serial: UInt64

    public init(pattern: String, intensity: Float, serial: UInt64) {
        self.pattern = pattern
        self.intensity = intensity
        self.serial = serial
    }
}

public struct SoundCue: Sendable, Equatable {
    public var name: String
    public var serial: UInt64

    public init(name: String, serial: UInt64) {
        self.name = name
        self.serial = serial
    }
}

/// A loud, short sound fixed to the room direction where it was heard.
public struct HeardSoundCue: Sendable, Equatable {
    /// Absolute room heading when the phone was localized. Nil leaves the cue
    /// screen-relative, which is still useful before calibration.
    public var roomBearingDegrees: Double?
    public var fallbackRelativeBearingDegrees: Double
    public var confidence: Double
    public var until: Double

    public init(roomBearingDegrees: Double?, fallbackRelativeBearingDegrees: Double,
                confidence: Double, until: Double) {
        self.roomBearingDegrees = roomBearingDegrees
        self.fallbackRelativeBearingDegrees = fallbackRelativeBearingDegrees
        self.confidence = confidence
        self.until = until
    }

    public func offset(from heading: Double?) -> Double {
        guard let roomBearingDegrees, let heading else { return fallbackRelativeBearingDegrees }
        return RoomMath.signedDiff(roomBearingDegrees, heading)
    }
}

/// Everything the SwiftUI overlay renders, as plain data.
public struct OverlayState: Sendable, Equatable {
    public var pill = StatusPill()
    /// What the operator is actually shown. Derived from `pill`.
    public var status: OperatorStatus { OperatorStatus(pill) }
    public var flash: FlashCue?
    public var arrow: ArrowCue?
    public var banner: GuideBannerCue?
    /// "Look up / look down", when the phone is pointed well off the target's
    /// height and the operator is already turned the right way. nil the rest of
    /// the time. Surfaced separately from `banner` so the view can draw a
    /// vertical chevron without parsing a sentence.
    public var elevation: ElevationCue?
    public var toast: ToastCue?
    public var detections: DetectionsCue?
    public var hazards: DetectionsCue?
    public var pings: [PingCue] = []
    /// The hub's found candidate (`world.candidate`), located like a ping so it
    /// can sit on the compass and float in the camera view. `id` is −1.
    public var candidate: PingCue?
    /// "lobby", "calibrate", "search", "found", "end".
    public var phase: String?
    /// From `welcome`: "#3", and the colour the dashboard draws this phone in.
    public var index: Int?
    public var colorHex: String?
    public var room: HubRoom?
    /// The shared picture, 2 Hz, for the mini-map.
    public var world: HubWorld?
    /// This phone in the room frame, for the mini-map and the seat picker.
    public var roomPose: RoomPose?
    /// "none", "seat" or "marker".
    public var alignment: RoomAligner.Source = .none
    /// Consumed once and cleared: a haptic is an event, not a state.
    public var pendingHaptic: HapticCue?
    public var pendingSound: SoundCue?
    public var directionalSound: HeardSoundCue?

    public init() {}
}

/// Turns hub commands and diagnostics into what to draw.
///
/// Lives here rather than in the SwiftUI layer because the arrow's sign
/// convention is the single most consequential piece of maths in the app: get
/// it backwards and every operator turns the wrong way, and no amount of
/// looking at the screen tells you which way is right.
///
/// The hub has no haptic or sound commands — a web page cannot do the first and
/// barely does the second. This client adds them locally, on the events where
/// `phone.js` beeps (ping, message) plus flash and coming on target.
///
/// All times are the phone's own monotonic clock. Hub TTLs are durations, so no
/// shared clock is needed to honour them.
public struct OverlayModel: Sendable {
    public private(set) var state = OverlayState()

    private enum Guide: Sendable, Equatable {
        /// A room heading to turn to. `text` is the hub's own wording, kept only
        /// as the fallback for when this phone has no heading of its own and
        /// cannot work out which way to turn.
        case heading(target: Double, kind: String, label: String?, text: String?, distance: Double?,
                     until: Double)
        /// True-north bearing. This client has no compass (`.gravity`), so: text.
        case compass(kind: String, label: String?, bearing: Double, until: Double)
    }

    private var detectionStream: String?
    private var detectionRevision: String?
    private var detectionSeq: UInt64?
    private var hazardSeq: UInt64?
    private var previousMatches: [HubDetectionBox] = []
    private var previousMatchTime: Double = -.infinity
    private var lastMatchAlert: Double = -.infinity
    private var detectionCaptures: [UInt64: Double] = [:]

    public mutating func recordDetectionCapture(seq: UInt64, at time: Double) {
        detectionCaptures = detectionCaptures.filter { time - $0.value < 1.5 }
        detectionCaptures[seq] = time
        if detectionCaptures.count > 32, let oldest = detectionCaptures.keys.min() {
            detectionCaptures.removeValue(forKey: oldest)
        }
    }

    /// When the transport last left `.online` — or, before it has ever been
    /// online, when this phone started trying. Drives
    /// `OperatorStatus.connectingGraceSeconds`, which is why it is measured
    /// here rather than derived from the transport state: the state alone
    /// cannot tell a fresh attempt from one that has been failing for a minute.
    private var offlineSince: Double?
    private var guide: Guide?
    private var cueSerial: UInt64 = 0
    private var wasOnTarget = false
    /// Latched so the elevation cue can be released at a gentler angle than it
    /// appears at. See `GuideThresholds.elevationReleaseDegrees`.
    private var showingElevation = false

    /// A `delta` guide is a snapshot of where the phone was facing; the hub
    /// refreshes it several times a second. Three seconds without one means the
    /// hub has stopped steering this phone. Same constant as `phone.js`.
    public static let turnGuideLifetime: Double = 3

    public init() {}

    /// Adds a local microphone event without putting audio on the wire. The
    /// room bearing makes the cue remain spatially stable as the phone turns.
    public mutating func hearDirectionalSound(_ event: DirectionalSoundEvent,
                                              heading: Double?, now: Double) {
        let relative = max(-90, min(90, event.relativeBearingDegrees))
        state.directionalSound = HeardSoundCue(
            roomBearingDegrees: heading.map { RoomMath.wrap360($0 + relative) },
            fallbackRelativeBearingDegrees: relative,
            confidence: max(0, min(1, event.confidence)),
            until: now + 2
        )
    }

    // MARK: - Hub messages

    public mutating func apply(_ welcome: HubWelcome) {
        previousMatches = []
        detectionStream = welcome.streamId
        detectionRevision = nil
        detectionSeq = nil
        hazardSeq = nil
        state.hazards = nil
        detectionCaptures.removeAll()
        state.detections = nil
        state.index = welcome.index
        state.colorHex = welcome.color
        state.room = welcome.room ?? state.room
        if let phase = welcome.phase { state.phase = phase }
    }

    public mutating func apply(phase: String) {
        state.phase = phase
    }

    public mutating func apply(_ world: HubWorld, now: Double) {
        state.world = world
        if let phase = world.phase { state.phase = phase }
        // `world.pings` is the hub's authoritative list; it covers a ping whose
        // command was lost to a reconnect. Do not beep for these.
        for ping in world.pings ?? [] where !state.pings.contains(where: { $0.id == ping.id }) {
            let remaining = max(0, 12 - (ping.ageMs ?? 0) / 1000)
            state.pings.append(PingCue(id: ping.id, x: ping.x, y: ping.y,
                                       label: ping.label ?? "Check here", until: now + remaining))
        }
    }

    /// Applies a hub command. `heading` is the phone's live room heading, needed
    /// to turn a relative `delta` into something that survives the operator
    /// turning before the next update.
    ///
    /// Returns false for commands the overlay does not render (`rate`, `hud`,
    /// anything unknown).
    @discardableResult
    public mutating func apply(_ command: HubCommand, heading: Double?, now: Double) -> Bool {
        switch command {
        case .guideClear:
            guide = nil
            state.arrow = nil
            state.banner = nil
            state.elevation = nil
            wasOnTarget = false
            showingElevation = false
        case .guideTurn(let sector, let delta, _, let text, let kind, let distance):
            // Same as phone.js: without a heading there is nothing to anchor to.
            guard let heading else { return false }
            // The hub's own `onTarget` is discarded, exactly as the web discards
            // it. It describes where the phone was pointing when the hub last
            // ticked, up to 200 ms ago; the live offset is recomputed every
            // frame in `updateGuide`.
            guide = .heading(target: RoomMath.wrap360(heading + delta), kind: kind, label: sector,
                             text: text, distance: distance, until: now + Self.turnGuideLifetime)
        case .guideHeading(let kind, let sector, let target, let distance, let untilMs):
            guide = .heading(target: RoomMath.wrap360(target), kind: kind, label: sector, text: nil,
                             distance: distance, until: now + untilMs / 1000)
        case .guideCompass(let kind, let sector, let compass, let untilMs):
            guide = .compass(kind: kind, label: sector, bearing: compass, until: now + untilMs / 1000)
        case .flash(let color, let text, let ttlMs):
            let rgb = HexColor.parse(color) ?? HexColor.parse(state.colorHex) ?? (1, 1, 1)
            state.flash = FlashCue(red: rgb.0, green: rgb.1, blue: rgb.2,
                                   text: (text?.isEmpty ?? true) ? nil : text, until: now + ttlMs / 1000)
            cue(haptic: "flash", intensity: 1)
        case .ping(let id, let x, let y, let label, let ttlMs):
            let isNew = !state.pings.contains { $0.id == id }
            state.pings.removeAll { $0.id == id }
            state.pings.append(PingCue(id: id, x: x, y: y, label: label, until: now + ttlMs / 1000))
            if isNew {
                cue(haptic: "ping", intensity: 0.8)
                cue(sound: "ping")
            }
        case .message(let text, let ttlMs):
            state.toast = ToastCue(text: text, until: now + ttlMs / 1000)
            cue(haptic: "message", intensity: 0.8)
            cue(sound: "message")
        case .detections(let boxes, let ttlMs, let context):
            var until = now + ttlMs / 1000
            if let context {
                if context.clear {
                    previousMatches = []
                    detectionRevision = context.searchRevision
                    detectionSeq = nil
                    state.detections = nil
                    state.hazards = nil
                    hazardSeq = nil
                    return true
                }
                guard let stream = context.streamId, stream == detectionStream,
                      let seq = context.seq, detectionSeq.map({ seq > $0 }) ?? true,
                      let revision = context.searchRevision,
                      detectionRevision == nil || detectionRevision == revision,
                      let captured = detectionCaptures[seq], now - captured < 1.5 else { return false }
                detectionRevision = revision
                detectionSeq = seq
                until = min(until, captured + 1.5)
            }
            let markedBoxes = boxes.map { box in
                var marked = box
                marked.possibleMatch = context?.rehearsal != true
                    && box.label?.lowercased() == "person"
                    && box.similarity.map { $0.isFinite && $0 >= (context?.threshold ?? 0.7) } == true
                return marked
            }
            let matches = markedBoxes.filter { $0.possibleMatch == true }
            // Overlap avoids combining two people at unrelated positions into one alert.
            let repeated = now - previousMatchTime < 1.5 && matches.contains { box in
                previousMatches.contains { prior in
                    guard box.targetId == prior.targetId else { return false }
                    let width = max(0, min(box.x + box.w, prior.x + prior.w) - max(box.x, prior.x))
                    let height = max(0, min(box.y + box.h, prior.y + prior.h) - max(box.y, prior.y))
                    let intersection = width * height
                    let union = box.w * box.h + prior.w * prior.h - intersection
                    return union > 0 && intersection / union >= 0.3
                }
            }
            if context != nil && repeated && now - lastMatchAlert >= 10 {
                state.toast = ToastCue(text: "Possible target found", until: now + 3)
                cue(haptic: "possible_match", intensity: 1)
                lastMatchAlert = now
            }
            previousMatches = matches
            previousMatchTime = now
            state.detections = DetectionsCue(boxes: markedBoxes, until: until)
            state.detections?.threshold = context?.threshold
            state.detections?.rehearsal = context?.rehearsal ?? false
        case .hazards(let boxes, let ttlMs, let context):
            guard let stream = context.streamId, stream == detectionStream,
                  let seq = context.seq, hazardSeq.map({ seq > $0 }) ?? true,
                  let revision = context.searchRevision,
                  detectionRevision == nil || detectionRevision == revision,
                  let captured = detectionCaptures[seq], now - captured < 1.5 else { return false }
            detectionRevision = revision
            hazardSeq = seq
            state.hazards = DetectionsCue(boxes: boxes, until: min(now + ttlMs / 1000, captured + 1.5))
        case .rate, .hud, .unknown:
            return false
        }
        return true
    }

    private mutating func cue(haptic pattern: String, intensity: Float) {
        cueSerial += 1
        state.pendingHaptic = HapticCue(pattern: pattern, intensity: intensity, serial: cueSerial)
    }

    private mutating func cue(sound name: String) {
        cueSerial += 1
        state.pendingSound = SoundCue(name: name, serial: cueSerial)
    }

    // MARK: - Per-tick

    /// Recomputes the overlay for the current pose and diagnostics. Called every
    /// time the camera moves, which is what makes the arrow point at a fixed
    /// direction in the room rather than at a fixed place on the screen.
    ///
    /// - Parameters:
    ///   - pose: the camera in whichever 3D frame `alignment` maps from.
    ///   - alignment: nil when the phone does not know where it is in the room.
    public mutating func update(pose: Pose?, alignment: RoomAlignment?, source: RoomAligner.Source,
                                intrinsics: CameraIntrinsics?, diagnostics: SessionDiagnostics,
                                transport: Transport.Stats, transportState: TransportState,
                                now: Double) {
        let connection = StatusPill.ConnectionState(transportState)
        if connection == .online { offlineSince = nil } else if offlineSince == nil { offlineSince = now }
        state.pill = StatusPill(sessionState: diagnostics.state,
                                trackingState: diagnostics.quality.wireValue,
                                confidence: diagnostics.confidence,
                                isStale: diagnostics.isStale,
                                connection: connection,
                                inFlight: transport.inFlight,
                                dropped: transport.dropped,
                                thermalState: diagnostics.thermalState,
                                secondsSinceCorrection: diagnostics.lastCorrectionAge,
                                secondsDisconnected: offlineSince.map { now - $0 },
                                alignment: source)
        state.alignment = source

        if let flash = state.flash, now > flash.until { state.flash = nil }
        if let toast = state.toast, now > toast.until { state.toast = nil }
        if let hazards = state.hazards, now > hazards.until { state.hazards = nil }
        if let detections = state.detections, now > detections.until { state.detections = nil }
        if let sound = state.directionalSound, now > sound.until { state.directionalSound = nil }
        state.pings.removeAll { now > $0.until }

        let usablePose = diagnostics.isStale ? nil : pose
        let roomPose = usablePose.flatMap { pose in alignment.map { $0.project(pose) } }
        state.roomPose = roomPose

        updateGuide(heading: roomPose?.heading, pitch: roomPose?.pitch, now: now)
        updatePings(pose: usablePose, roomPose: roomPose, alignment: alignment, intrinsics: intrinsics)
    }

    /// Rewrites the banner from the *live* offset, every tick.
    ///
    /// It used to echo the hub's `text` field verbatim, which meant the operator
    /// read "Turn left 37°" for up to 200 ms after they had already turned — and
    /// for a `look` or `go`, where the hub sends no `text` at all, they read a
    /// line that never changed and never went green. `web/phone.js`
    /// `updateGuideBanner` recomputes on every animation frame for exactly this
    /// reason, and the wording here is its wording.
    private mutating func updateGuide(heading: Double?, pitch: Double?, now: Double) {
        switch guide {
        case nil:
            state.arrow = nil
            state.banner = nil
            state.elevation = nil
            wasOnTarget = false
            showingElevation = false
        case .heading(let target, let kind, let label, let text, let distance, let until):
            guard now <= until else {
                guide = nil
                state.arrow = nil
                state.banner = nil
                state.elevation = nil
                wasOnTarget = false
                showingElevation = false
                return
            }
            // We do not know where the camera is looking, so we cannot say which
            // way to turn. Showing the last arrow would point at nothing.
            //
            // The web drops the banner outright here, but it has nothing else:
            // it never stores the hub's wording, and its banner is the only
            // place a directive appears. Dropping ours would blink the whole
            // directive off for the second a stale pose takes to recover, and
            // then back on — which reads as the hub having cancelled it. So say
            // what was asked for without claiming a direction.
            guard let heading else {
                state.arrow = nil
                let fallback = text.flatMap { $0.isEmpty ? nil : $0 }
                    ?? Self.directionlessText(kind: kind, label: label, distance: distance)
                state.banner = fallback.map { GuideBannerCue(kind: kind, text: $0, onTarget: false) }
                state.elevation = nil
                wasOnTarget = false
                showingElevation = false
                return
            }
            let off = RoomMath.signedDiff(target, heading)
            let onTarget = abs(off) < GuideThresholds.onTargetDegrees
            let tilted = pitch.map { abs($0) > GuideThresholds.tiltedPitchDegrees } ?? false
            let elevation = elevationCue(kind: kind, distance: distance, pitch: pitch,
                                         onTarget: onTarget, tilted: tilted)
            state.elevation = elevation
            state.banner = GuideBannerCue(
                kind: kind,
                text: Self.bannerText(kind: kind, offsetDegrees: off, label: label,
                                      distance: distance, tilted: tilted, elevation: elevation),
                onTarget: onTarget, tilted: tilted)
            state.arrow = ArrowCue(bearingRadians: Float(off * .pi / 180),
                                   elevationRadians: distance.map {
                                       Float(TargetGeometry.elevationRadians(horizontalDistance: $0))
                                   },
                                   label: label, distance: distance.map(Float.init), until: until)
            // Edge-triggered, with a release band: a 90 s `go` would otherwise
            // buzz every time the operator drifted a degree over the boundary.
            if onTarget && !wasOnTarget {
                cue(haptic: "onTarget", intensity: 0.6)
                wasOnTarget = true
            } else if abs(off) > GuideThresholds.onTargetReleaseDegrees {
                wasOnTarget = false
            }
        case .compass(let kind, let label, let bearing, let until):
            guard now <= until else {
                guide = nil
                state.banner = nil
                state.elevation = nil
                wasOnTarget = false
                showingElevation = false
                return
            }
            state.arrow = nil
            // A compass directive has no distance, so no target geometry.
            state.elevation = nil
            // ARKit runs `.gravity`; this phone has no true north and cannot
            // resolve a real-world bearing. It used to render
            // "Look the door · 137° NE", which reads like a direction the
            // operator could follow. The web's wording is the honest one.
            _ = bearing
            state.banner = GuideBannerCue(kind: kind,
                                          text: "Face \(label ?? "that way") (no compass on this phone)",
                                          onTarget: false)
        }
    }

    /// "Look up" / "look down", or nil.
    ///
    /// Four things have to be true before the operator is told to tilt:
    ///
    /// 1. **The target's distance is known.** Elevation is derived from it and
    ///    `TargetGeometry`; a `search` sweep or a bare `look` at a sector carries
    ///    no distance, so there is no geometry and no cue.
    /// 2. **The phone's pitch is known.** No pitch, no error to correct.
    /// 3. **The operator is already facing it.** Turning and tilting at once is
    ///    two instructions; the horizontal one is the bigger error and wins. So
    ///    the cue is suppressed off target — turn first, then tilt.
    /// 4. **The error is outside the dead zone**, latched so it does not flicker.
    private mutating func elevationCue(kind: String, distance: Double?, pitch: Double?,
                                       onTarget: Bool, tilted: Bool) -> ElevationCue? {
        // A `search` guide past 65° already owns the banner with "Hold your
        // phone up", which is the hub's and the web's wording and is not being
        // regressed. Two vertical instructions at once is one too many.
        guard let distance, let pitch, onTarget, !(kind == "search" && tilted) else {
            showingElevation = false
            return nil
        }
        let target = TargetGeometry.elevationRadians(horizontalDistance: distance)
        let targetDegrees = target * 180 / .pi
        // Positive = the target is above where the camera points = raise the
        // phone. `pitch` is positive tilted up, so this is a plain difference —
        // getting it backwards tells the operator to look at the ceiling when
        // the candidate is at their feet.
        let needed = targetDegrees - pitch
        let threshold = showingElevation ? GuideThresholds.elevationReleaseDegrees
                                         : GuideThresholds.elevationDeadZoneDegrees
        guard abs(needed) > threshold else {
            showingElevation = false
            return nil
        }
        showingElevation = true
        return ElevationCue(targetRadians: Float(target), neededDegrees: needed)
    }

    private mutating func updatePings(pose: Pose?, roomPose: RoomPose?, alignment: RoomAlignment?,
                                      intrinsics: CameraIntrinsics?) {
        state.candidate = state.world?.candidate.map {
            PingCue(id: -1, x: $0.x, y: $0.y, label: "CANDIDATE", until: .infinity)
        }
        for index in state.pings.indices {
            state.pings[index] = located(state.pings[index], pose: pose, roomPose: roomPose,
                                         alignment: alignment, intrinsics: intrinsics)
        }
        state.candidate = state.candidate.map {
            located($0, pose: pose, roomPose: roomPose, alignment: alignment, intrinsics: intrinsics)
        }
    }

    private func located(_ cue: PingCue, pose: Pose?, roomPose: RoomPose?, alignment: RoomAlignment?,
                         intrinsics: CameraIntrinsics?) -> PingCue {
        var ping = cue
        ping.bearingRadians = nil
        ping.distance = nil
        ping.imagePoint = nil
        guard let pose, let roomPose, let alignment else { return ping }
        ping.distance = Float(hypot(ping.x - roomPose.x, ping.y - roomPose.y))
        if let heading = roomPose.heading {
            let bearing = RoomMath.bearing(fromX: roomPose.x, y: roomPose.y, toX: ping.x, y: ping.y)
            ping.bearingRadians = Float(RoomMath.signedDiff(bearing, heading) * .pi / 180)
        }
        if let intrinsics {
            // A spot on the floor, in the same 3D frame the pose is in. The
            // venue origin is on the floor; a seat-tap frame's origin is wherever
            // ARKit started, so assume a phone held at chest height.
            let floor: Float = state.alignment == .marker ? 0 : pose.position.y - 1.4
            let point = alignment.unproject(x: ping.x, y: ping.y, height: floor)
            ping.imagePoint = Projection.project(venuePoint: point, camera: pose, intrinsics: intrinsics)
        }
        return ping
    }

    /// The fourteen strings `updateGuideBanner` (`web/phone.js:763-805`) can
    /// produce, transcribed including the arrow glyphs.
    ///
    /// The glyphs are not decoration: `←` and `→` sit on the side of the line
    /// the operator has to turn toward, so the direction is readable at a glance
    /// from a phone being swung around, before the degrees have been parsed.
    ///
    /// - Parameters:
    ///   - offsetDegrees: live signed offset to the target. Positive = the target
    ///     is clockwise of where the operator is facing, so turn right.
    ///   - tilted: `|pitch| > 65`. Only `search` says anything about it, exactly
    ///     as the web does — a `look`, `go` or `respond` never shows it.
    ///   - elevation: the new vertical cue, which nothing in `swarm/` or the web
    ///     client has. It is only ever non-nil when the operator is already on
    ///     target horizontally, so it takes the slot the turn instruction would
    ///     have had: one correction at a time, in the same place on the line.
    static func bannerText(kind: String, offsetDegrees off: Double, label: String?,
                           distance: Double?, tilted: Bool, elevation: ElevationCue? = nil) -> String {
        let onTarget = abs(off) < GuideThresholds.onTargetDegrees
        let turn = off > 0 ? "Turn right \(degrees(off))° →" : "← Turn left \(degrees(-off))°"

        switch kind {
        case "respond":
            // The hub's responder guidance always carries a distance
            // (`swarm/target.py`); drop the clause rather than print "null m" if
            // a future one does not.
            let dist = distance.map { " · \(metres($0)) m" } ?? ""
            if let elevation { return elevation.text + dist }
            return onTarget ? "↑ Candidate ahead\(dist)" : turn + dist
        case "go":
            let name = label ?? "the spot"
            let dist = distance.map { " · \(metres($0)) m" } ?? ""
            if let elevation { return "\(elevation.text) · walk to \(name)\(dist)" }
            return onTarget ? "↑ Walk to \(name)\(dist)" : "\(turn) · walk to \(name)\(dist)"
        case "look":
            let name = label ?? "that way"
            if let elevation { return "Face \(name) · \(elevation.phrase)" }
            if onTarget { return "Facing \(name) ✓ hold it" }
            return off > 0 ? "Face \(name) · turn right \(degrees(off))° →"
                           : "← Face \(name) · turn left \(degrees(-off))°"
        default:
            // `search` — the planner's sweep, and anything unrecognised, which
            // `phone.js` also funnels here via `msg.kind || 'search'`.
            if tilted { return "Hold your phone up" }
            if let elevation { return elevation.text }
            return onTarget ? "Scanning \(label ?? "the area")…" : turn
        }
    }

    /// What the directive is, with no claim about which way to turn — for when
    /// this phone has no heading of its own. Nothing here says "left", "right"
    /// or "ahead", because at this point we do not know.
    static func directionlessText(kind: String, label: String?, distance: Double?) -> String? {
        let dist = distance.map { " · \(metres($0)) m" } ?? ""
        switch kind {
        case "respond": return "Candidate found\(dist)"
        case "go": return "Walk to \(label ?? "the spot")\(dist)"
        case "look": return "Face \(label ?? "that way")"
        default:
            // `search`: the planner always sends `text`, so this is the case
            // that should not arise. With no label there is nothing to say.
            return label.map { "Searching \($0)" }
        }
    }

    /// `Math.round` on a positive number, as a string. The web prints whole
    /// degrees.
    private static func degrees(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// The hub rounds a distance to one decimal place and JavaScript prints the
    /// result as `6`, not `6.0`. Matching the web's wording means matching that
    /// too, or every whole-metre readout differs from the browser's by a
    /// trailing zero.
    private static func metres(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// Takes the pending haptic, clearing it. A haptic fires once.
    public mutating func consumeHaptic() -> HapticCue? {
        defer { state.pendingHaptic = nil }
        return state.pendingHaptic
    }

    public mutating func consumeSound() -> SoundCue? {
        defer { state.pendingSound = nil }
        return state.pendingSound
    }
}

/// `#rrggbb` → 0…1 components. The hub only ever sends six-digit hex.
public enum HexColor {
    public static func parse(_ hex: String?) -> (Float, Float, Float)? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Float((value >> 16) & 0xFF) / 255, Float((value >> 8) & 0xFF) / 255,
                Float(value & 0xFF) / 255)
    }
}
