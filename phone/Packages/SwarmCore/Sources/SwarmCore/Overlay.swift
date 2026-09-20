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
    /// Four words. The pill sits under the compass tape with the settings
    /// control beside it, and a sentence this long — it was "Point the camera
    /// at a printed marker" — wrapped to two lines and ran into the gear.
    /// What the operator has to do is find the marker; the camera is already
    /// in their hand and pointed at something.
    static let locateHint = "Find a printed marker"

    /// How long the phone has to be out of touch with the hub before the
    /// status goes red.
    ///
    /// Joining a room is a websocket handshake over venue Wi-Fi, and a phone
    /// that has just been unlocked may also be waiting on the radio to wake.
    /// Both take a moment, and both are completely normal — but the pill went
    /// straight to a red warning triangle and "Check the venue Wi-Fi" the
    /// instant the app opened, so every single launch began by telling the
    /// operator something was broken. It is the same crying-wolf problem
    /// that took out the drift hint, the recalibrating notice and the shaky
    /// tracking one: a warning that is usually wrong gets ignored when it is
    /// right.
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
            // Kept, where the drift hint and the shaky-tracking notice were
            // not: this is the one tracking state the operator can actually do
            // something about, and the something is in the hint.
            self.init(level: .attention, title: "Needs recalibrating", hint: Self.locateHint)
        case .lost:
            self.init(level: .problem, title: "Tracking lost",
                      hint: pill.alignment == .marker ? "Move slowly, find a marker"
                                                      : "Move slowly, look around")
        case .calibrating where pill.alignment == .none:
            self.init(level: .attention, title: "Not located yet", hint: Self.locateHint)
        case .degraded:
            // `.ok`, so the pill stays down. ARKit reports degraded tracking
            // constantly and briefly — a fast pan, a blank wall, somebody
            // walking through frame — and it recovers on its own within a
            // second or two without the operator doing anything. The only
            // status worth stopping somebody mid-sweep for is the one they have
            // to act on, which is having no position at all.
            self.init(level: .ok, title: "Tracking")
        case .calibrating, .tracking:
            if pill.isStale {
                self.init(level: .problem, title: "Camera stopped", hint: "Reopen the app if it stays")
            } else if pill.alignment == .none {
                self.init(level: .attention, title: "Not located yet", hint: Self.locateHint)
            } else if pill.thermalState >= .serious {
                self.init(level: .attention, title: "Phone is hot", hint: "Sending fewer frames")
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

    /// Seconds this cue lives for in total. `until` alone cannot say how much
    /// of that has already gone, and the fade needs the fraction.
    /// `PING_TTL_MS` in `swarm/hub.py`.
    public var lifetime: Double = 12
    /// How solid to draw it, 1 down to 0.25 as it ages out — `drawPings()` in
    /// `web/console.js` sets `globalAlpha = Math.max(0.25, 1 - age)`, so a ping
    /// that has been up a while is visibly on its way out. Resolved on every
    /// overlay tick rather than at the draw site, because the map's animation
    /// clock is not the clock `until` is measured on.
    public var fade: Double = 1

    public init(id: Int, x: Double, y: Double, label: String, until: Double, lifetime: Double = 12) {
        self.id = id
        self.x = x
        self.y = y
        self.label = label
        self.until = until
        self.lifetime = lifetime
    }
}

/// Another searcher, placed relative to this phone.
///
/// The hub already tells every phone where all the others are (`world.phones`);
/// until now only the mini-map read it. On a floor plan the size of a postage
/// stamp that was enough. In a large space the operator is looking at the world,
/// not at the corner of their screen, so the team belongs on the compass tape
/// and in the camera view as well — both of which need a bearing and a distance
/// this phone works out for itself.
public struct TeammateCue: Sendable, Equatable, Identifiable {
    /// Roughly where a person's head is. Their marker belongs on them, not on
    /// the floor in front of their feet.
    public static let headHeightMetres: Float = 1.5

    public var id: String
    /// The `#3` the console, the mini-map and the operators all already use.
    public var index: Int
    /// Room metres.
    public var x: Double
    public var y: Double
    /// Filled in on every `update` when this phone knows where it is.
    public var bearingRadians: Float?
    public var distance: Float?
    /// Where they land in the captured image, in pixels of
    /// `CameraIntrinsics.imageWidth × imageHeight`; nil behind the camera.
    public var imagePoint: CGPoint?

    public init(id: String, index: Int, x: Double, y: Double) {
        self.id = id
        self.index = index
        self.x = x
        self.y = y
    }
}

/// A full-screen card, and when it stops being one.
///
/// Only the name and the clock live here. The wording, the colour, the glyph
/// and how long it holds are all in `HUDMirror.takeover(kind:name:)`, so the
/// phone and the console show one card rather than two that resemble each
/// other.
public struct TakeoverCue: Sendable, Equatable {
    public var kind: String
    public var name: String?
    /// Local monotonic time after which the card contracts away.
    public var until: Double

    public init(kind: String, name: String?, until: Double) {
        self.kind = kind
        self.name = name
        self.until = until
    }
}

/// This phone's standing part in a find: on the way, or there.
///
/// Red does not stop at the door. A flash is an event — it announces something
/// and then it is over — but "somebody has been found and you are one of the
/// people on them" is a situation that lasts minutes, and for all of those
/// minutes the screen should say so without being asked again. The hub already
/// marks both edges: a `respond` guide starts it, and that guide clearing is
/// how the hub says you have arrived.
public enum FindInvolvement: String, Sendable, Equatable {
    /// Walking to them. The wash pulses.
    case heading
    /// Standing with them. The wash holds, steady and dimmer — the same red,
    /// because the emergency did not end when you got there, but no longer
    /// pulsing at somebody who has already arrived.
    case with
}

/// Something in the room to get around, placed relative to this phone.
///
/// The hub tracks hazards on the floor plan (`world.hazards`) and the mini-map
/// draws them, but a map in the corner is not what stops somebody walking into
/// a chair while they are running toward a person they have just found. That
/// needs a bearing and a distance, and it needs to be in front of their eyes.
public struct HazardCue: Sendable, Equatable, Identifiable {
    /// Hazards are obstacles at roughly waist height, not marks on the carpet.
    public static let heightMetres: Float = 0.8
    /// Close enough to say something about.
    public static let warnMetres: Float = 3
    /// Close enough that it outranks everything else on the bezel: you are
    /// about to walk into it.
    public static let imminentMetres: Float = 2
    /// Close enough to stop reading the phone. At this range the obstacle is
    /// the only thing that matters and it takes the whole screen.
    public static let blockingMetres: Float = 1.2

    /// How close, on the three-step ladder: nil, warn, imminent, blocking.
    public var blocking: Bool { (distance ?? .infinity) <= Self.blockingMetres }

    public var id: String
    public var x: Double
    public var y: Double
    public var bearingRadians: Float?
    public var distance: Float?
    public var imagePoint: CGPoint?

    public init(id: String, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }

    /// "left", "right" or "ahead" — which way to step to miss it.
    public var side: String? {
        guard let bearingRadians else { return nil }
        let degrees = Double(bearingRadians) * 180 / .pi
        if degrees < -20 { return "left" }
        if degrees > 20 { return "right" }
        return "ahead"
    }
}

public struct HapticCue: Sendable, Equatable {
    /// One of `locked`, `flash`, `ping`, `message`, `onTarget`. The client
    /// decides how each one feels — `Haptics` in the beacon iOS module — so
    /// the name has to say what *happened*, not what it should feel like.
    /// A client that does not know a name still plays something.
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
    /// This phone had an origin and lost it — an interruption, a tracking
    /// failure, or the operator asking for a reset — rather than never having
    /// had one. `SessionMachine` keeps the two apart precisely
    /// (`calibrating` → first time, `recalibrating` → again), so the prompt can
    /// say which of the two this is.
    public var isRecalibrating: Bool { pill.sessionState == .recalibrating }
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
    /// Everyone else on the search, from `world.phones`, placed on every tick.
    public var teammates: [TeammateCue] = []
    /// The closest hazard worth mentioning, or nil when the way is clear.
    public var nearestHazard: HazardCue?
    /// Whether this phone is part of a find, and how far into it.
    public var find: FindInvolvement?
    /// Who that find is, when the hub named them.
    public var findName: String?
    /// The full-screen card currently up, if any.
    public var takeover: TakeoverCue?
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
    /// When a hazard was last actually reported — see `hazardHoldSeconds`.
    private var hazardSeenAt: Double = -.infinity
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
    /// Whether this phone knew where it was on the previous tick, so that
    /// *becoming* located can be celebrated once rather than every tick.
    private var wasLocated = false
    /// Latched so the elevation cue can be released at a gentler angle than it
    /// appears at. See `GuideThresholds.elevationReleaseDegrees`.
    private var showingElevation = false
    /// Metres above the floor of the printed alignment marker, from
    /// `venue.json`. Set by `SwarmClient`; the hub's marker cue carries only a
    /// floor position, and a marker is the one cue that is never on the floor.
    public var markerHeightMetres: Double = 0

    /// The success page a marker scan produces: `--accent` (#18834b), the same
    /// green the console and the map use for "this is fine". Keeping it on the
    /// palette matters more here than anywhere else — the flash is the largest
    /// single block of colour the app ever puts on screen.
    public static let lockFlashRGB: (red: Float, green: Float, blue: Float) =
        (24 / 255, 131 / 255, 75 / 255)
    /// Long enough to read at arm's length, short enough not to be in the way
    /// of whatever the operator does next. This is the *only* confirmation a
    /// lock gets: the calibrate card used to hold a second "Calibrated" state
    /// open behind it, which said the same word twice for one event — so the
    /// one page that remains is given time to be read rather than caught.
    ///
    /// This is the *held* part only. `FlashView` eases the page in before this
    /// starts and eases it out after it ends, so what the operator sees is
    /// roughly this plus three quarters of a second of fade.
    public static let lockFlashSeconds: Double = 2.2
    /// No "✓". The page is a full screen of green with one word on it; the
    /// tick was a second, smaller way of saying the same thing, and it made
    /// the line sit off-centre for the sake of it.
    public static let lockFlashText = "Calibrated"

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
        // Lobby, calibrate and end are not a search. Whatever this phone was
        // part of, it is over, and the screen stops saying otherwise.
        if phase != "search" && phase != "found" {
            state.find = nil
            state.findName = nil
        }
    }

    /// A `respond` guide means a find team; being steered anywhere else means
    /// the operator has been taken off it.
    private mutating func noteInvolvement(_ kind: String) {
        guard kind != "respond" else {
            // Already `with` them? A respond guide is the hub topping the team
            // up, not this phone being sent away again.
            if state.find == nil { state.find = .heading }
            return
        }
        state.find = nil
        state.findName = nil
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
            // The hub clears a find team's guide exactly once: when that phone
            // gets within `ARRIVE_M` of the person. Anything else it clears was
            // never a find in the first place, so only a phone that was on its
            // way can be promoted to being there.
            if state.find == .heading { state.find = .with }
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
            noteInvolvement(kind)
            guide = .heading(target: RoomMath.wrap360(heading + delta), kind: kind, label: sector,
                             text: text, distance: distance, until: now + Self.turnGuideLifetime)
        case .guideHeading(let kind, let sector, let target, let distance, let untilMs):
            noteInvolvement(kind)
            guide = .heading(target: RoomMath.wrap360(target), kind: kind, label: sector, text: nil,
                             distance: distance, until: now + untilMs / 1000)
        case .guideCompass(let kind, let sector, let compass, let untilMs):
            guide = .compass(kind: kind, label: sector, bearing: compass, until: now + untilMs / 1000)
        case .flash(let color, let text, let ttlMs, let takeover, let name):
            // A named card owns the screen for as long as its own row says, and
            // brings its own words; the bare colour flash the hub has always
            // been able to send still works underneath it.
            if let takeover {
                // The hub's cards are also how this phone learns its part in a
                // find — the finder is never sent a `respond` guide, because
                // they are already standing there, so the guide alone would
                // have left the one person who actually found somebody with a
                // screen that said nothing.
                switch takeover {
                case "found_stay": state.find = .with
                case "found_go": state.find = .heading
                default: break
                }
                if let name { state.findName = name }
                // "Stay with them" is not an announcement, it is what you are
                // doing. It has no clock; it is derived from `find` and holds
                // until the search moves on. Everything else is a moment.
                if takeover != "found_stay", let card = HUDMirror.takeover(kind: takeover, name: name) {
                    state.takeover = TakeoverCue(kind: takeover, name: name, until: now + card.seconds)
                }
                cue(haptic: "flash", intensity: 1)
                return true
            }
            let rgb = HexColor.parse(color) ?? HexColor.parse(state.colorHex) ?? (1, 1, 1)
            state.flash = FlashCue(red: rgb.0, green: rgb.1, blue: rgb.2,
                                   text: (text?.isEmpty ?? true) ? nil : text, until: now + ttlMs / 1000)
            cue(haptic: "flash", intensity: 1)
        case .ping(let id, let x, let y, let label, let ttlMs):
            let isNew = !state.pings.contains { $0.id == id }
            state.pings.removeAll { $0.id == id }
            state.pings.append(PingCue(id: id, x: x, y: y, label: label,
                                       until: now + ttlMs / 1000, lifetime: ttlMs / 1000))
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

        // A marker scan landing is the one moment on this phone that earns the
        // whole screen. The operator is holding the phone up at a printed
        // marker, often at arm's length across a room, and the only
        // confirmation used to be a status line quietly changing colour — so
        // people kept scanning a marker they had already scanned. `FlashCue`
        // is what the hub uses when it needs to be seen from the back of a
        // hall; success borrows it.
        //
        // **Every lock, including mid-search.** This used to stand down once
        // the hub reached `search` or `found`, on the grounds that a
        // full-screen page over the camera obstructs someone who is looking
        // for a person. What that actually meant was that the one moment worth
        // confirming — a phone that had lost its origin getting it back, in
        // the middle of a live search — was the one moment confirmed by
        // nothing but a status line going quiet. A second of green is worth
        // it: the operator has just stopped searching to scan a marker anyway.
        let located = source != .none
        if located, !wasLocated {
            state.flash = FlashCue(red: Self.lockFlashRGB.red, green: Self.lockFlashRGB.green,
                                   blue: Self.lockFlashRGB.blue, text: Self.lockFlashText,
                                   until: now + Self.lockFlashSeconds)
            cue(haptic: "locked", intensity: 1)
        }
        wasLocated = located

        if let flash = state.flash, now > flash.until { state.flash = nil }
        if let toast = state.toast, now > toast.until { state.toast = nil }
        if let hazards = state.hazards, now > hazards.until { state.hazards = nil }
        if let takeover = state.takeover, now > takeover.until { state.takeover = nil }
        if let detections = state.detections, now > detections.until { state.detections = nil }
        if let sound = state.directionalSound, now > sound.until { state.directionalSound = nil }
        state.pings.removeAll { now > $0.until }
        // `drawPings()`: `globalAlpha = Math.max(0.25, 1 - age)` over the cue's
        // whole life, so the two maps agree on how faded an old ping looks.
        for i in state.pings.indices where state.pings[i].lifetime > 0 {
            let left = (state.pings[i].until - now) / state.pings[i].lifetime
            state.pings[i].fade = max(0.25, min(1, left))
        }

        let usablePose = diagnostics.isStale ? nil : pose
        let roomPose = usablePose.flatMap { pose in alignment.map { $0.project(pose) } }
        state.roomPose = roomPose

        updateGuide(heading: roomPose?.heading, pitch: roomPose?.pitch, now: now)
        // Nothing is located through an alignment this phone has stopped
        // trusting. A recalibration takes the compass, the marker chip and the
        // floating tag with it, on purpose: an unaligned phone drawing the
        // marker through the mapping it just threw away is pointing at where
        // the marker *was*, which is worse than pointing at nothing. The
        // reticle is what says what to do instead.
        updatePings(pose: usablePose, roomPose: roomPose, alignment: alignment,
                    intrinsics: intrinsics)
        updateTeammates(pose: usablePose, roomPose: roomPose, alignment: alignment,
                        intrinsics: intrinsics)
        updateHazards(pose: usablePose, roomPose: roomPose, alignment: alignment,
                      intrinsics: intrinsics, now: now)
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
                // Arriving on your own sector is the one card the hub does not
                // send: it is geometry this phone works out for itself, every
                // frame, from a heading the hub only sees five times a second.
                if kind != "respond", let card = HUDMirror.takeover(kind: "sector", name: label) {
                    state.takeover = TakeoverCue(kind: "sector", name: label, until: now + card.seconds)
                }
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

    /// Where a point in the room sits relative to this camera right now: how far
    /// to turn for it, how far away it is, and where it lands in the captured
    /// image. Shared by every located cue so they cannot disagree.
    ///
    /// `heightAboveFloor` is the reason this is shared rather than ping-shaped.
    /// A ping is a spot on the floor and takes 0; the alignment marker is taped
    /// to a wall; a teammate is a person, and their marker belongs on them. At
    /// 20 m the difference between a person's head and the carpet at their feet
    /// is most of the screen.
    private func place(x: Double, y: Double, heightAboveFloor: Float, pose: Pose?,
                       roomPose: RoomPose?, alignment: RoomAlignment?, intrinsics: CameraIntrinsics?)
        -> (bearingRadians: Float?, distance: Float?, imagePoint: CGPoint?) {
        guard let pose, let roomPose, let alignment else { return (nil, nil, nil) }
        let distance = Float(hypot(x - roomPose.x, y - roomPose.y))
        var bearingRadians: Float?
        if let heading = roomPose.heading {
            let bearing = RoomMath.bearing(fromX: roomPose.x, y: roomPose.y, toX: x, y: y)
            bearingRadians = Float(RoomMath.signedDiff(bearing, heading) * .pi / 180)
        }
        var imagePoint: CGPoint?
        if let intrinsics {
            // The floor, in the same 3D frame the pose is in. The venue origin is
            // on the floor; a seat-tap frame's origin is wherever ARKit started,
            // so assume a phone held at chest height.
            let floor: Float = state.alignment == .marker ? 0 : pose.position.y - 1.4
            let point = alignment.unproject(x: x, y: y, height: floor + heightAboveFloor)
            imagePoint = Projection.project(venuePoint: point, camera: pose, intrinsics: intrinsics)
        }
        return (bearingRadians, distance, imagePoint)
    }

    private func located(_ cue: PingCue, pose: Pose?, roomPose: RoomPose?, alignment: RoomAlignment?,
                         intrinsics: CameraIntrinsics?) -> PingCue {
        var ping = cue
        // A ping is a spot on the floor — except the alignment marker, which is
        // not. The hub pushes it down the ping channel as a bare `x, y`
        // (`hub.py` `marker_cue`) because that is all the console's map needs,
        // and drawing it at height 0 put the diamond on the carpet under a
        // marker taped to a wall or stood on a table — metres from the thing the
        // operator is being asked to look at. `venue.json` measured it, so use
        // that height.
        let height = ping.label == "MARKER" ? Float(markerHeightMetres) : 0
        (ping.bearingRadians, ping.distance, ping.imagePoint) = place(
            x: ping.x, y: ping.y, heightAboveFloor: height, pose: pose, roomPose: roomPose,
            alignment: alignment, intrinsics: intrinsics)
        return ping
    }

    /// The nearest hazard, if one is close enough to matter.
    ///
    /// Only the closest: a warning that lists three things is a warning nobody
    /// reads while walking. Stale hazards are skipped — the hub marks a hazard
    /// stale when nothing has seen it recently, and steering somebody around a
    /// chair that has been moved is its own hazard.
    /// How long a hazard is remembered after the hub stops reporting it.
    ///
    /// Hazards come from a detector running on 2 Hz frames, and detectors miss
    /// one now and then. Without this, a single missed frame takes the amber
    /// screen away and the next one brings it back — a strobe, at exactly the
    /// range where somebody is about to walk into something.
    private static let hazardHoldSeconds: Double = 1

    /// And one you are standing next to is remembered much longer, because
    /// walking up to something is precisely what stops the camera seeing it:
    /// it fills the frame, or it drops below the lens as you close on it. That
    /// made the warning quietest at the one moment it mattered most — the
    /// operator felt the buzz build as they approached and then fade away just
    /// as they arrived. Proximity beats recency. A chair half a metre away that
    /// nothing has seen for five seconds is still a chair half a metre away,
    /// and its distance keeps being recomputed from the live pose, so it fades
    /// honestly when the operator actually walks off rather than on a timer.
    private static let closeHazardHoldSeconds: Double = 10

    private mutating func updateHazards(pose: Pose?, roomPose: RoomPose?, alignment: RoomAlignment?,
                                        intrinsics: CameraIntrinsics?, now: Double) {
        func locate(id: String, x: Double, y: Double) -> HazardCue? {
            guard x.isFinite, y.isFinite else { return nil }
            var cue = HazardCue(id: id, x: x, y: y)
            (cue.bearingRadians, cue.distance, cue.imagePoint) = place(
                x: x, y: y, heightAboveFloor: HazardCue.heightMetres,
                pose: pose, roomPose: roomPose, alignment: alignment, intrinsics: intrinsics)
            guard let distance = cue.distance, distance <= HazardCue.warnMetres else { return nil }
            return cue
        }

        var placed = (state.world?.hazards ?? []).compactMap { hazard -> HazardCue? in
            guard let cue = locate(id: hazard.id, x: hazard.x, y: hazard.y) else { return nil }
            // Stale means nothing has seen it lately, which is not the same as
            // it not being there — and the surest way to stop seeing something
            // is to walk right up to it.
            guard !hazard.stale || cue.blocking else { return nil }
            return cue
        }
        // The one being remembered is placed again from the live pose, so it
        // gets nearer and further as the operator actually moves.
        let hold = state.nearestHazard?.blocking == true
            ? Self.closeHazardHoldSeconds : Self.hazardHoldSeconds
        if let held = state.nearestHazard, now - hazardSeenAt <= hold,
           !placed.contains(where: { $0.id == held.id }),
           let again = locate(id: held.id, x: held.x, y: held.y) {
            placed.append(again)
        }
        if let nearest = placed.min(by: { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }) {
            state.nearestHazard = nearest
            // Only a real report refreshes the clock; a remembered one must
            // still age out, or a hazard once seen would never be forgotten.
            if state.world?.hazards?.contains(where: { $0.id == nearest.id && !$0.stale }) == true {
                hazardSeenAt = now
            }
        } else {
            state.nearestHazard = nil
        }
    }

    /// Everyone else on the search, placed the same way.
    ///
    /// `world.me` is this phone, and it is excluded: a chip pointing at yourself
    /// is noise. The hub sends peer positions at 2 Hz but this runs on every
    /// overlay tick, because a chip that only moves twice a second visibly lags
    /// the person it labels while the operator is swinging the phone around.
    private mutating func updateTeammates(pose: Pose?, roomPose: RoomPose?,
                                          alignment: RoomAlignment?, intrinsics: CameraIntrinsics?) {
        let me = state.world?.me
        state.teammates = (state.world?.phones ?? []).compactMap { peer in
            guard peer.id != me else { return nil }
            var mate = TeammateCue(id: peer.id, index: peer.i, x: peer.x, y: peer.y)
            (mate.bearingRadians, mate.distance, mate.imagePoint) = place(
                x: peer.x, y: peer.y, heightAboveFloor: TeammateCue.headHeightMetres,
                pose: pose, roomPose: roomPose, alignment: alignment, intrinsics: intrinsics)
            return mate
        }
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
