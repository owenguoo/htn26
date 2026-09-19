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
                thermalState: ThermalState = .nominal, secondsSinceCorrection: Double? = nil) {
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
            || secondsSinceCorrection == nil
            || (secondsSinceCorrection ?? 0) > 30
            || thermalState >= .serious
    }
}

public struct FlashCue: Sendable, Equatable {
    public var red: Float
    public var green: Float
    public var blue: Float
    /// Server-clock time after which the flash stops.
    public var until: Double

    public init(red: Float, green: Float, blue: Float, until: Double) {
        self.red = red
        self.green = green
        self.blue = blue
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

public struct HapticCue: Sendable, Equatable {
    public var pattern: String
    public var intensity: Float
    public var commandID: String

    public init(pattern: String, intensity: Float, commandID: String) {
        self.pattern = pattern
        self.intensity = intensity
        self.commandID = commandID
    }
}

public struct SoundCue: Sendable, Equatable {
    public var name: String
    public var commandID: String

    public init(name: String, commandID: String) {
        self.name = name
        self.commandID = commandID
    }
}

/// Everything the SwiftUI overlay renders, as plain data.
public struct OverlayState: Sendable, Equatable {
    public var pill = StatusPill()
    public var flash: FlashCue?
    public var arrow: ArrowCue?
    /// Consumed once and cleared: a haptic is an event, not a state.
    public var pendingHaptic: HapticCue?
    public var pendingSound: SoundCue?

    public init(pill: StatusPill = StatusPill(), flash: FlashCue? = nil, arrow: ArrowCue? = nil,
                pendingHaptic: HapticCue? = nil, pendingSound: SoundCue? = nil) {
        self.pill = pill
        self.flash = flash
        self.arrow = arrow
        self.pendingHaptic = pendingHaptic
        self.pendingSound = pendingSound
    }
}

/// Turns commands and diagnostics into what to draw.
///
/// Lives here rather than in the SwiftUI layer because the arrow's sign
/// convention is the single most consequential piece of maths in the app: get
/// it backwards and every operator turns the wrong way, and no amount of
/// looking at the screen tells you which way is right.
public struct OverlayModel: Sendable {
    public private(set) var state = OverlayState()
    /// Set by whichever command last asked for an arrow at a venue-frame point,
    /// so the arrow keeps pointing at it as the operator turns.
    public private(set) var trackedTarget: SIMD3<Float>?
    private var trackedLabel: String?
    private var trackedUntil: Double?
    private var handledCommandIDs: Set<String> = []
    /// Bounded: this runs for the whole demo and a set of every command ever
    /// seen is a leak with a schedule.
    private var handledOrder: [String] = []
    private let handledCapacity = 256

    public init() {}

    /// Applies a server command.
    ///
    /// A command that has already expired is discarded rather than painted late.
    /// A "look left" that arrives two seconds after the moment has passed reads
    /// as broken, which is worse than never having sent it.
    @discardableResult
    public mutating func apply(_ command: Command, now: Double) -> Bool {
        guard !handledCommandIDs.contains(command.id) else { return false }
        if let expiresInMs = command.expiresInMs {
            let deadline = command.serverTimestamp + Double(expiresInMs) / 1_000
            guard now <= deadline else { return false }
        }
        remember(command.id)

        switch command.kind {
        case .flash(let r, let g, let b, let durationMs):
            state.flash = FlashCue(red: r, green: g, blue: b,
                                   until: now + Double(durationMs) / 1_000)
        case .arrow(let target, let bearingRadians, let label):
            let until = command.expiresInMs.map { command.serverTimestamp + Double($0) / 1_000 }
            if let target, target.count == 3 {
                trackedTarget = SIMD3<Float>(target[0], target[1], target[2])
                trackedLabel = label
                trackedUntil = until
            } else if let bearingRadians {
                // A bearing the server computed: it goes stale the moment the
                // operator turns, so it is not tracked, only shown.
                trackedTarget = nil
                trackedLabel = nil
                trackedUntil = nil
                state.arrow = ArrowCue(bearingRadians: bearingRadians, label: label, until: until)
            }
        case .sound(let name):
            state.pendingSound = SoundCue(name: name, commandID: command.id)
        case .haptic(let pattern, let intensity):
            state.pendingHaptic = HapticCue(pattern: pattern, intensity: intensity, commandID: command.id)
        case .setRates:
            // Handled by the session, not the overlay.
            break
        case .clear:
            state.flash = nil
            state.arrow = nil
            trackedTarget = nil
            trackedLabel = nil
            trackedUntil = nil
        }
        return true
    }

    private mutating func remember(_ id: String) {
        guard handledCommandIDs.insert(id).inserted else { return }
        handledOrder.append(id)
        if handledOrder.count > handledCapacity {
            let evicted = handledOrder.removeFirst()
            handledCommandIDs.remove(evicted)
        }
    }

    /// Recomputes the overlay for the current pose and diagnostics. Called every
    /// time the camera moves, which is what makes a tracked arrow point at a
    /// fixed place in the room rather than at a fixed place on the screen.
    public mutating func update(pose: Pose?, diagnostics: SessionDiagnostics,
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
                                secondsSinceCorrection: diagnostics.lastCorrectionAge)

        if let flash = state.flash, now > flash.until {
            state.flash = nil
        }
        if let until = state.arrow?.until, now > until, trackedTarget == nil {
            state.arrow = nil
        }
        if let until = trackedUntil, now > until {
            trackedTarget = nil
            trackedLabel = nil
            trackedUntil = nil
            state.arrow = nil
        }

        guard let target = trackedTarget else { return }
        guard let pose, !diagnostics.isStale else {
            // We do not know where the camera is looking, so we cannot say which
            // way to turn. Showing the last arrow would point at nothing.
            state.arrow = nil
            return
        }
        guard let bearing = Geometry.relativeBearing(from: pose, to: target) else {
            state.arrow = nil
            return
        }
        state.arrow = ArrowCue(bearingRadians: bearing,
                               elevationRadians: Geometry.relativeElevation(from: pose, to: target),
                               label: trackedLabel,
                               distance: simd_distance(pose.position, target),
                               until: trackedUntil)
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
