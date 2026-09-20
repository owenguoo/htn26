import Foundation

/// What is on this phone's screen, described for the operator console.
///
/// While a console has a phone expanded, the hub sends `{cmd: "hud", on: true}`
/// and expects `{type: "hud", …}` back about five times a second, so the console
/// can draw the same guidance over the live feed that the operator is looking
/// at (`web/console.js` `drawHud`). Without it an iOS phone's expanded tile is
/// bare video: no compass, no banner, no markers.
///
/// Everything positional is in **frame fractions**: 0…1 across the upright JPEG
/// the hub received. `screen` says which part of that frame the phone's display
/// actually shows, because the preview is aspect-filled and crops the sides.
public struct HubHUDMirror: Sendable, Equatable, Encodable {
    public struct Compass: Sendable, Equatable, Encodable {
        public struct Marker: Sendable, Equatable, Encodable {
            /// Degrees right of where the phone is facing.
            public var off: Double
            public var label: String
            public var color: String
            public var big: Bool
        }
        /// The heading at the centre of the tape.
        public var center: Double
        /// Whether `center` is a true compass bearing. Never, here: ARKit runs
        /// with `.gravity`, so this is a room heading (0 = facing the stage) and
        /// the console labels it in degrees rather than N/E/S/W.
        public var abs: Bool
        public var markers: [Marker]
    }

    public struct Banner: Sendable, Equatable, Encodable {
        public var text: String
        /// "alert", "ok" or "warn" — the console's three pill colours.
        public var tone: String
    }

    public struct Card: Sendable, Equatable, Encodable {
        public var title: String
        public var text: String
    }

    public struct ARMarker: Sendable, Equatable, Encodable {
        public var x: Double
        public var y: Double
        /// Radius as a fraction of the screen's height.
        public var r: Double
        public var label: String
        public var color: String
    }

    public struct SoundEdge: Sendable, Equatable, Encodable {
        /// "left", "right", or "ahead".
        public var side: String
        public var color: String
    }

    public var compass: Compass?
    public var banner: Banner?
    public var lookingFor: String?
    public var toast: String?
    public var card: Card?
    public var ar: [ARMarker]
    /// `[x0, y0, x1, y1]`: the part of the frame the phone's screen shows.
    public var screen: [Double]?
    public var dets: [HubDetectionBox]?
    public var soundEdge: SoundEdge?
}

/// The words on the lobby / calibrate / end cards. Here rather than in the
/// SwiftUI view so the phone and the console's mirror of it cannot drift apart.
public enum PhaseCardText {
    public static func covers(_ phase: String) -> Bool {
        phase == "lobby" || phase == "calibrate" || phase == "end"
    }

    /// Whether the card should actually be on screen, given what this phone has
    /// managed to do about it.
    ///
    /// `covers(_:)` alone is the hub's phase and nothing else, and the hub sits
    /// in `calibrate` until the operator advances it from the console — which
    /// is long after any individual phone has locked. So a phone that had found
    /// its marker went on staring at a full-screen "Calibrate · point at a
    /// printed marker · Locked to a marker ✓" card with the camera behind it,
    /// with no way to dismiss it and nothing left to do about it.
    ///
    /// The calibrate card is a prompt. Once this phone is located the prompt is
    /// answered, so it goes, and the operator gets the camera and the compass
    /// back while the rest of the team finishes. It comes back if alignment is
    /// ever lost again. `lobby` and `end` are not prompts — there is genuinely
    /// nothing to do in either — so they keep covering.
    public static func covers(_ phase: String, alignment: RoomAligner.Source) -> Bool {
        guard covers(phase) else { return false }
        return phase != "calibrate" || alignment == .none
    }

    public static func title(for phase: String) -> String {
        switch phase {
        case "lobby": "You're in"
        case "calibrate": "Calibrate"
        default: "Search complete"
        }
    }

    public static func detail(for phase: String) -> String {
        switch phase {
        case "lobby": "The operator starts the search."
        case "calibrate": "Point at a printed marker until it locks."
        default: "You can lower your phone."
        }
    }

    /// Shown in the calibrate card's place for a couple of seconds once this
    /// phone locks on, before the card gets out of the way.
    ///
    /// `covers(_:alignment:)` drops the prompt the instant alignment arrives,
    /// which is correct — there is nothing left to do — but it meant the
    /// operator's reward for finally getting the marker to lock was a
    /// full-screen card silently disappearing. They could not tell whether it
    /// had worked or whether the app had moved on for some other reason. The
    /// prompt asked for something; this is the card answering.
    public static let confirmedTitle = "Calibrated"
    public static let confirmedDetail = "You're located. The operator starts the search."
}

public enum HUDMirror {
    // The web phone's palette (`web/phone.js`), so a native phone and a browser
    // phone look the same on the console and to each other.
    static let stageColor = "#4cc9f0"
    static let alertColor = "#ff5d73"
    static let onTargetColor = "#7ae582"
    static let directedColor = "#4cc9f0"
    static let turnColor = "#ffb703"
    static let pingColor = "#ffd166"
    public static let soundColor = "#ff3b30"
    /// `MARKER_COLOR` in `web/console.js`, which is what the map — both the
    /// console's and the phone's — fills the alignment marker with. Before the
    /// search starts the hub pushes that marker down the ping channel
    /// (`hub.py` `marker_cue`), and drawn in `pingColor` it was one more yellow
    /// ping chip among the operator's own. It is the one thing on the tape that
    /// is a fixed piece of the room rather than a temporary cue, so it wears
    /// the colour the map already gives it.
    static let markerColor = "#6b4fbb"

    /// The chip colour for a ping cue: the alignment marker keeps its map
    /// colour, everything else is a ping.
    static func cueColor(_ cue: PingCue) -> String {
        cue.label == "MARKER" ? markerColor : pingColor
    }

    /// - Parameters:
    ///   - captureWidth/captureHeight: the sensor-orientation capture the
    ///     overlay's `imagePoint`s are in (landscape for a phone held upright).
    ///   - screenAspect: the display's width ÷ height, portrait.
    public static func make(from overlay: OverlayState, captureWidth: Int, captureHeight: Int,
                            screenAspect: Double) -> HubHUDMirror {
        let responding = overlay.banner?.kind == "respond"

        // Same markers, same order, same colours as `drawCompass` in phone.js.
        var markers: [HubHUDMirror.Compass.Marker] = []
        if let heading = overlay.roomPose?.heading {
            markers.append(.init(off: RoomMath.signedDiff(0, heading), label: "STAGE", color: stageColor, big: false))
        }
        if let arrow = overlay.arrow {
            let off = Double(arrow.bearingRadians) * 180 / .pi
            let kind = overlay.banner?.kind ?? "search"
            let label = responding
                ? "FIND" + (arrow.distance.map { String(format: " %.0fm", $0) } ?? "")
                : (arrow.label ?? "TARGET")
            let color = responding ? alertColor
                : abs(off) < GuideThresholds.onTargetDegrees ? onTargetColor
                : (kind == "look" || kind == "go") ? directedColor : turnColor
            markers.append(.init(off: off, label: label, color: color, big: true))
        }
        let targets = overlay.pings.map { ($0, "◆ " + $0.label, cueColor($0)) }
            + (responding ? [] : (overlay.candidate.map { [($0, "FIND", alertColor)] } ?? []))
        for (cue, label, color) in targets {
            guard let bearing = cue.bearingRadians else { continue }
            let metres = cue.distance.map { String(format: " %.0fm", $0) } ?? ""
            markers.append(.init(off: Double(bearing) * 180 / .pi, label: label + metres, color: color, big: false))
        }
        let soundOffset = overlay.directionalSound.map { $0.offset(from: overlay.roomPose?.heading) }
        if let soundOffset {
            markers.append(.init(off: soundOffset, label: "SOUND", color: soundColor, big: true))
        }
        let compass = overlay.roomPose?.heading.map {
            HubHUDMirror.Compass(center: $0, abs: false, markers: markers)
        }

        // The tone rules live on the cue, next to the wording they colour, so the
        // console pill and the phone banner cannot disagree about whether the
        // operator is there yet.
        let soundSide = soundOffset.map { offset in
            offset < -20 ? "left" : offset > 20 ? "right" : "ahead"
        }
        let banner = soundSide.map { HubHUDMirror.Banner(text: "Sound heard · \($0)", tone: "alert") }
            ?? overlay.banner.map { HubHUDMirror.Banner(text: $0.text, tone: $0.tone) }

        let searching = overlay.phase == "search" || overlay.phase == "found"
        let lookingFor = overlay.world?.lookingFor.flatMap { $0.isEmpty || !searching ? nil : $0 }

        // The same test the phone's own renderer uses, so the console is not
        // told about a card the operator cannot see.
        let card = overlay.phase.flatMap { phase in
            PhaseCardText.covers(phase, alignment: overlay.alignment)
                ? HubHUDMirror.Card(title: PhaseCardText.title(for: phase), text: PhaseCardText.detail(for: phase))
                : nil
        }

        let floating = overlay.pings.map { ($0, $0.label, cueColor($0)) }
            + (overlay.candidate.map { [($0, "FIND", alertColor)] } ?? [])
        let ar: [HubHUDMirror.ARMarker] = floating.compactMap { cue, label, color in
            guard let point = cue.imagePoint,
                  let fraction = uprightFraction(ofCapturePoint: point, captureWidth: captureWidth,
                                                 captureHeight: captureHeight),
                  (0...1).contains(fraction.x), (0...1).contains(fraction.y) else { return nil }
            let distance = Double(cue.distance ?? 3)
            // Same sizing as phone.js: nearer is bigger, clamped, over a ~844 pt screen.
            let radius = max(9, min(22, 60 / max(distance, 1))) / 844
            return .init(x: fraction.x, y: fraction.y, r: radius,
                         label: String(format: "%@ · %.1f m", label, distance), color: color)
        }

        // Side bleed: loud sound wins when present; otherwise the found /
        // guided person paints the edge they sit on — including after find,
        // so "they're still left of you" stays glanceable while walking in.
        // Only a *find* paints the bezel. The planner hands every phone a sector
        // the moment it reports a heading — on a fresh run that sector comes
        // from a flat probability field, so it is effectively arbitrary — and
        // the arrow for it used to light the whole left or right edge in alert
        // red before the operator had taken a step. The sector still gets its
        // chip on the compass tape, which is where a routine sweep belongs.
        let guideOffset = (responding ? overlay.arrow.map { Double($0.bearingRadians) * 180 / .pi } : nil)
            ?? overlay.candidate.flatMap { cue in cue.bearingRadians.map { Double($0) * 180 / .pi } }
        let guideSide: String? = guideOffset.flatMap { offset in
            if offset < -20 { return "left" }
            if offset > 20 { return "right" }
            return nil
        }
        let edge = soundSide.map { HubHUDMirror.SoundEdge(side: $0, color: soundColor) }
            ?? guideSide.map { HubHUDMirror.SoundEdge(side: $0, color: alertColor) }

        return HubHUDMirror(compass: compass, banner: banner, lookingFor: lookingFor,
                            toast: overlay.toast.map { "📣 " + $0.text }, card: card, ar: ar,
                            screen: visibleFrame(captureWidth: captureWidth, captureHeight: captureHeight,
                                                 screenAspect: screenAspect),
                            dets: overlay.hazards == nil ? overlay.detections?.boxes
                                : (overlay.detections?.boxes ?? []) + (overlay.hazards?.boxes ?? []),
                            soundEdge: edge)
    }
    /// A pixel in the landscape capture → 0…1 in the upright frame the hub has.
    /// The encoder rotates 90° clockwise: (x, y) in W×H lands at (H − y, x) in H×W.
    static func uprightFraction(ofCapturePoint point: CGPoint, captureWidth: Int,
                                captureHeight: Int) -> (x: Double, y: Double)? {
        guard captureWidth > 0, captureHeight > 0 else { return nil }
        return ((Double(captureHeight) - point.y) / Double(captureHeight), point.x / Double(captureWidth))
    }

    /// The preview aspect-fills the screen, so a tall phone crops the sides of a
    /// 3:4 frame (and a squat one would crop top and bottom). Centred.
    static func visibleFrame(captureWidth: Int, captureHeight: Int, screenAspect: Double) -> [Double]? {
        guard captureWidth > 0, captureHeight > 0, screenAspect > 0 else { return nil }
        let frameAspect = Double(captureHeight) / Double(captureWidth)   // upright: width ÷ height
        if screenAspect < frameAspect {
            let visible = screenAspect / frameAspect
            return [(1 - visible) / 2, 0, (1 + visible) / 2, 1]
        }
        let visible = frameAspect / screenAspect
        return [0, (1 - visible) / 2, 1, (1 + visible) / 2]
    }
}
