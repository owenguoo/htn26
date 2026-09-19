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
    public var isOnTarget: Bool { abs(bearingRadians) < 0.35 }
}

/// The line of text that goes with a guide: "Turn left 42°", "door · 6.1 m".
public struct GuideBannerCue: Sendable, Equatable {
    /// "search", "respond", "look" or "go".
    public var kind: String
    public var text: String
    public var onTarget: Bool

    public init(kind: String, text: String, onTarget: Bool) {
        self.kind = kind
        self.text = text
        self.onTarget = onTarget
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

/// Everything the SwiftUI overlay renders, as plain data.
public struct OverlayState: Sendable, Equatable {
    public var pill = StatusPill()
    public var flash: FlashCue?
    public var arrow: ArrowCue?
    public var banner: GuideBannerCue?
    public var toast: ToastCue?
    public var detections: DetectionsCue?
    public var pings: [PingCue] = []
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
        /// A room heading to turn to. `refreshed` is when the hub last said so.
        case heading(target: Double, kind: String, label: String?, text: String?, distance: Double?,
                     onTarget: Bool, until: Double)
        /// True-north bearing. This client has no compass (`.gravity`), so: text.
        case compass(kind: String, label: String?, bearing: Double, until: Double)
    }

    private var detectionStream: String?
    private var detectionRevision: String?
    private var detectionSeq: UInt64?
    private var detectionCaptures: [UInt64: Double] = [:]

    public mutating func recordDetectionCapture(seq: UInt64, at time: Double) {
        detectionCaptures = detectionCaptures.filter { time - $0.value < 1.5 }
        detectionCaptures[seq] = time
        if detectionCaptures.count > 32, let oldest = detectionCaptures.keys.min() {
            detectionCaptures.removeValue(forKey: oldest)
        }
    }

    private var guide: Guide?
    private var cueSerial: UInt64 = 0
    private var wasOnTarget = false

    /// A `delta` guide is a snapshot of where the phone was facing; the hub
    /// refreshes it several times a second. Three seconds without one means the
    /// hub has stopped steering this phone. Same constant as `phone.js`.
    public static let turnGuideLifetime: Double = 3

    public init() {}

    // MARK: - Hub messages

    public mutating func apply(_ welcome: HubWelcome) {
        detectionStream = welcome.streamId
        detectionRevision = nil
        detectionSeq = nil
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
            wasOnTarget = false
        case .guideTurn(let sector, let delta, let onTarget, let text, let kind, let distance):
            // Same as phone.js: without a heading there is nothing to anchor to.
            guard let heading else { return false }
            guide = .heading(target: RoomMath.wrap360(heading + delta), kind: kind, label: sector,
                             text: text, distance: distance, onTarget: onTarget,
                             until: now + Self.turnGuideLifetime)
            if onTarget && !wasOnTarget { cue(haptic: "onTarget", intensity: 0.6) }
            wasOnTarget = onTarget
        case .guideHeading(let kind, let sector, let target, let distance, let untilMs):
            guide = .heading(target: RoomMath.wrap360(target), kind: kind, label: sector, text: nil,
                             distance: distance, onTarget: false, until: now + untilMs / 1000)
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
                    detectionRevision = context.searchRevision
                    detectionSeq = nil
                    state.detections = nil
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
            state.detections = DetectionsCue(boxes: boxes, until: until)
            state.detections?.threshold = context?.threshold
            state.detections?.rehearsal = context?.rehearsal ?? false
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
        state.pill = StatusPill(sessionState: diagnostics.state,
                                trackingState: diagnostics.quality.wireValue,
                                confidence: diagnostics.confidence,
                                isStale: diagnostics.isStale,
                                connection: StatusPill.ConnectionState(transportState),
                                inFlight: transport.inFlight,
                                dropped: transport.dropped,
                                thermalState: diagnostics.thermalState,
                                secondsSinceCorrection: diagnostics.lastCorrectionAge,
                                alignment: source)
        state.alignment = source

        if let flash = state.flash, now > flash.until { state.flash = nil }
        if let toast = state.toast, now > toast.until { state.toast = nil }
        if let detections = state.detections, now > detections.until { state.detections = nil }
        state.pings.removeAll { now > $0.until }

        let usablePose = diagnostics.isStale ? nil : pose
        let roomPose = usablePose.flatMap { pose in alignment.map { $0.project(pose) } }
        state.roomPose = roomPose

        updateGuide(heading: roomPose?.heading, now: now)
        updatePings(pose: usablePose, roomPose: roomPose, alignment: alignment, intrinsics: intrinsics)
    }

    private mutating func updateGuide(heading: Double?, now: Double) {
        switch guide {
        case nil:
            state.arrow = nil
            state.banner = nil
        case .heading(let target, let kind, let label, let text, let distance, let onTarget, let until):
            guard now <= until else {
                guide = nil
                state.arrow = nil
                state.banner = nil
                wasOnTarget = false
                return
            }
            state.banner = GuideBannerCue(kind: kind,
                                          text: Self.bannerText(kind: kind, label: label, text: text,
                                                                distance: distance),
                                          onTarget: onTarget)
            // We do not know where the camera is looking, so we cannot say which
            // way to turn. Showing the last arrow would point at nothing.
            guard let heading else {
                state.arrow = nil
                return
            }
            let off = RoomMath.signedDiff(target, heading)
            state.arrow = ArrowCue(bearingRadians: Float(off * .pi / 180), label: label,
                                   distance: distance.map(Float.init), until: until)
        case .compass(let kind, let label, let bearing, let until):
            guard now <= until else {
                guide = nil
                state.banner = nil
                return
            }
            state.arrow = nil
            let name = label.map { "\($0) · " } ?? ""
            state.banner = GuideBannerCue(kind: kind,
                                          text: "\(kind == "go" ? "Walk" : "Look") \(name)\(Int(bearing.rounded()))° \(Self.cardinal(bearing))",
                                          onTarget: false)
        }
    }

    private mutating func updatePings(pose: Pose?, roomPose: RoomPose?, alignment: RoomAlignment?,
                                      intrinsics: CameraIntrinsics?) {
        for index in state.pings.indices {
            var ping = state.pings[index]
            ping.bearingRadians = nil
            ping.distance = nil
            ping.imagePoint = nil
            if let pose, let roomPose, let alignment {
                ping.distance = Float(hypot(ping.x - roomPose.x, ping.y - roomPose.y))
                if let heading = roomPose.heading {
                    let bearing = RoomMath.bearing(fromX: roomPose.x, y: roomPose.y, toX: ping.x, y: ping.y)
                    ping.bearingRadians = Float(RoomMath.signedDiff(bearing, heading) * .pi / 180)
                }
                if let intrinsics {
                    // A spot on the floor, in the same 3D frame the pose is in. The
                    // venue origin is on the floor; a seat-tap frame's origin is
                    // wherever ARKit started, so assume a phone held at chest height.
                    let floor: Float = state.alignment == .marker ? 0 : pose.position.y - 1.4
                    let point = alignment.unproject(x: ping.x, y: ping.y, height: floor)
                    ping.imagePoint = Projection.project(venuePoint: point, camera: pose, intrinsics: intrinsics)
                }
            }
            state.pings[index] = ping
        }
    }

    static func bannerText(kind: String, label: String?, text: String?, distance: Double?) -> String {
        if let text, !text.isEmpty { return text }
        let metres = distance.map { String(format: " · %.1f m", $0) } ?? ""
        switch kind {
        case "respond": return "Candidate found\(metres)"
        case "go": return "Walk to \(label ?? "the spot")\(metres)"
        case "look": return "Look \(label ?? "this way")\(metres)"
        default: return (label ?? "") + metres
        }
    }

    static func cardinal(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((RoomMath.wrap360(degrees) + 22.5) / 45) % 8]
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
