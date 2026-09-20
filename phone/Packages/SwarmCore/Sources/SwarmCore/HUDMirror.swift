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
        /// Outline only. A filled diamond is what a *find* looks like, so a
        /// teammate gets a hollow one — a searcher must never be mistaken for
        /// the person being searched for, at a glance, from across a field.
        /// Additive: a renderer that has never heard of it fills as before.
        public var hollow = false
    }

    /// The one thing this phone is being sent to, named and measured, kept in a
    /// fixed corner so the operator always knows where to look for it.
    ///
    /// The banner already says what to do *right now* ("Turn right 40°") and
    /// rewrites itself every tick; it is an instruction, not a standing answer
    /// to "who am I walking to and how far is it". Pre-formatted, like `banner`
    /// and `lookingFor`, so the two renderers cannot round the same metre two
    /// different ways.
    public struct Objective: Sendable, Equatable, Encodable {
        public var title: String
        public var detail: String
        /// "alert", "ok" or "warn" — the console's three pill colours, taken
        /// straight from the banner so the card and the banner never disagree.
        public var tone: String
    }

    /// A standing wash of colour over the whole screen saying what situation
    /// this operator is in. Not an event — a state, held for as long as it is
    /// true.
    ///
    /// The flash announces; this remains. Somebody being found and you being
    /// one of the people on them lasts minutes, and the screen should go on
    /// saying so without being told again. Translucent by contract: the
    /// renderers paint it at the bezel and leave the middle clear, because the
    /// operator is walking through a crowded room while it is up.
    public struct Ambient: Sendable, Equatable, Encodable {
        /// "find" — on the way to somebody, pulsing.
        /// "with" — standing with them, steady.
        /// "hazard" — about to walk into something.
        public var kind: String
        public var color: String
        /// 0…1, how hard to paint the bezel.
        public var intensity: Double
    }

    /// Something in the way. Amber, because the colour language of this HUD is
    /// three words long: red is a person to reach, green is you are with them,
    /// amber is something between you and them.
    public struct Warning: Sendable, Equatable, Encodable {
        public var text: String
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
    public var objective: Objective?
    public var warning: Warning?
    public var ambient: Ambient?
    /// "142 m² swept · 2nd of 5 · room 46%". One pre-formatted line: the hub
    /// has been sending every phone its own swept area and rank since the
    /// beginning and nothing has ever shown it to the person doing the walking.
    public var stats: String?
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

    /// - Parameter again: this phone had a lock and lost it — an interruption,
    ///   a tracking failure, or the operator asking for a reset. The prompt is
    ///   the same one, but "Calibrate" reads as a step that has not happened
    ///   yet, and someone who has already scanned a marker and is being shown
    ///   it a second time needs to know that this is the *same* card coming
    ///   back rather than the app having forgotten where it was.
    public static func title(for phase: String, again: Bool = false) -> String {
        switch phase {
        case "lobby": "You're in"
        case "calibrate": again ? "Recalibrate" : "Calibrate"
        default: "Search complete"
        }
    }

    public static func detail(for phase: String, again: Bool = false) -> String {
        switch phase {
        case "lobby": "You may begin searching."
        case "calibrate": again
            ? "Point at a printed marker again."
            : "Point at a printed marker until it locks."
        default: "You can lower your phone."
        }
    }

    // No confirmed ("Calibrated") state here on purpose. A lock is already
    // announced by the full-screen green `FlashCue` (`OverlayEngine`'s
    // `lockFlashText`), and holding the card open to say the same word again
    // meant the operator read "Calibrated" twice — once over the whole screen,
    // once on a card — for one event. The card's job ends when the prompt is
    // answered, so it gets out of the way and lets the flash do the confirming.
}

public enum HUDMirror {
    // The colour language, in three words. Everything on this HUD that means
    // something to an operator mid-search resolves to one of them, and nothing
    // else is allowed to wear them:
    //
    //   red   `alertColor`    — a person to reach. Go.
    //   green `onTargetColor` — you are on them, or with them. Stay.
    //   amber `hazardColor`   — something between you and where you are going.
    //
    // Everything else on screen (the stage chip, pings, the alignment marker,
    // teammates) is navigation furniture and wears its own map colour, so the
    // three that mean *act now* stay scarce enough to still mean it.

    // The web phone's palette (`web/phone.js`), so a native phone and a browser
    // phone look the same on the console and to each other.
    static let stageColor = "#4cc9f0"
    static let alertColor = "#ff5d73"
    static let onTargetColor = "#7ae582"
    static let directedColor = "#4cc9f0"
    static let turnColor = "#ffb703"
    static let pingColor = "#ffd166"
    /// The console's `warn` pill. A hazard and a turn-you-have-not-made-yet are
    /// the same kind of thing — caution, not emergency — so they share it.
    static let hazardColor = "#ffb703"
    public static let soundColor = "#ff3b30"
    /// `MARKER_COLOR` in `web/console.js`, which is what the map — both the
    /// console's and the phone's — fills the alignment marker with. Before the
    /// search starts the hub pushes that marker down the ping channel
    /// (`hub.py` `marker_cue`), and drawn in `pingColor` it was one more yellow
    /// ping chip among the operator's own. It is the one thing on the tape that
    /// is a fixed piece of the room rather than a temporary cue, so it wears
    /// the colour the map already gives it.
    static let markerColor = "#6b4fbb"

    /// `PALETTE` in `swarm/hub.py`, indexed the way `Phone.color` indexes it, so
    /// a teammate's chip on the tape is the colour the console already paints
    /// that phone on its map and its feed wall. One person, one colour, three
    /// surfaces.
    static let peerPalette = ["#4cc9f0", "#f72585", "#b8f35a", "#ffb703", "#9b5de5", "#00f5d4",
                              "#fb5607", "#3a86ff", "#ff006e", "#8ac926", "#ffd166", "#06d6a0"]
    /// The chip for teammates who are off the tape entirely — a count, not a
    /// person, so it does not wear anybody's colour.
    static let teamMutedColor = "#9aa3b2"

    // How a crowd of teammates is thinned. A 120° tape fits about a dozen chips;
    // five phones all reporting at once is enough to make it unreadable.
    /// Chips closer together than this become one.
    static let teamMergeDegrees = 8.0
    /// Teammates further off-axis than this get counted, not drawn.
    static let teamTapeHalfSpan = 55.0
    /// Where the two "and N more that way" chips sit.
    static let teamEdgeDegrees = 58.0
    /// At most this many teammate chips, nearest to where the operator is
    /// already looking.
    static let teamTapeLimit = 4
    /// No diamond on somebody standing next to you.
    static let teamNearMetres = 2.0
    static let teamARLimit = 3

    /// The chip colour for a ping cue: the alignment marker keeps its map
    /// colour, everything else is a ping.
    static func cueColor(_ cue: PingCue) -> String {
        cue.label == "MARKER" ? markerColor : pingColor
    }

    static func peerColor(index: Int) -> String {
        peerPalette[((index % peerPalette.count) + peerPalette.count) % peerPalette.count]
    }

    /// Teammate chips for the compass tape, thinned so five phones stay legible.
    ///
    /// Chips within `teamMergeDegrees` of each other become one (`#2#4 9m`); the
    /// tape keeps the `teamTapeLimit` nearest to where the operator is already
    /// looking; and anyone outside `teamTapeHalfSpan` is *counted* into a single
    /// chip on that edge rather than clamped to the rail.
    ///
    /// Not clamping is the deliberate part. Clamping is right for a find — one
    /// thing, and you have to turn to it — and wrong for people, where three
    /// teammates behind you stack on the same pixel and say nothing. "Where is
    /// everyone" is the mini-map's question, not the tape's.
    static func teamMarkers(_ teammates: [TeammateCue]) -> [HubHUDMirror.Compass.Marker] {
        let placed = teammates.compactMap { mate -> (off: Double, metres: Double, index: Int)? in
            guard let bearing = mate.bearingRadians else { return nil }
            return (Double(bearing) * 180 / .pi, Double(mate.distance ?? 0), mate.index)
        }
        var groups: [[(off: Double, metres: Double, index: Int)]] = []
        for mate in placed.filter({ abs($0.off) <= teamTapeHalfSpan }).sorted(by: { $0.off < $1.off }) {
            if let anchor = groups.last?.first, mate.off - anchor.off <= teamMergeDegrees {
                groups[groups.count - 1].append(mate)
            } else {
                groups.append([mate])
            }
        }
        var chips = groups.map { group -> HubHUDMirror.Compass.Marker in
            let off = group.reduce(0.0) { $0 + $1.off } / Double(group.count)
            let nearest = group.map { $0.metres }.min() ?? 0
            let who = group.map { "#\($0.index)" }.joined()
            // One teammate wears their own colour; a merged chip is more than
            // one person, so it cannot claim any single one of them.
            let color = group.count == 1 ? peerColor(index: group[0].index) : teamMutedColor
            return .init(off: off, label: String(format: "%@ %.0fm", who, nearest),
                         color: color, big: false)
        }
        if chips.count > teamTapeLimit {
            chips = Array(chips.sorted { abs($0.off) < abs($1.off) }.prefix(teamTapeLimit))
        }
        for behind in [-1.0, 1.0] {
            let count = placed.filter {
                behind < 0 ? $0.off < -teamTapeHalfSpan : $0.off > teamTapeHalfSpan
            }.count
            guard count > 0 else { continue }
            chips.append(.init(off: behind * teamEdgeDegrees,
                               label: behind < 0 ? "◀ \(count)" : "\(count) ▶",
                               color: teamMutedColor, big: false))
        }
        return chips
    }

    /// What the corner card calls the thing you are being sent to.
    ///
    /// The hub packs it into the guide's `sector` field, and what it means
    /// depends on the kind: a find team's is the person (`swarm/target.py` sends
    /// the victim's label upper-cased, or "CANDIDATE" when there is only one),
    /// a planner sweep's is a grid square, an operator's `look` is whatever they
    /// typed. Labels are used as the hub wrote them — the banner does the same,
    /// and shouting an operator's free text back at them helps nobody.
    static func objectiveTitle(kind: String, label: String?) -> String {
        let name = (label ?? "").trimmingCharacters(in: .whitespaces)
        switch kind {
        case "respond":
            guard !name.isEmpty, name != "CANDIDATE" else { return "Person found" }
            return name.capitalized
        case "go": return name.isEmpty ? "Walk over" : "Walk to \(name)"
        case "look": return name.isEmpty ? "Look over there" : "Look at \(name)"
        default: return name.isEmpty ? "Sweeping" : "Sweeping \(name)"
        }
    }

    /// The contribution line, worded and rounded here because neither renderer
    /// gets to phrase it — an ordinal written twice in two languages is an
    /// ordinal that will eventually disagree with itself.
    static func statsLine(squareMetres: Double?, rank: Int?, of: Int?, searched: Double?) -> String? {
        var parts: [String] = []
        if let squareMetres, squareMetres >= 1 {
            parts.append(String(format: "%.0f m² swept", squareMetres))
        }
        // Rank means nothing on your own, and reads as a taunt rather than a
        // nudge when there is nobody to be ahead of.
        if let rank, let of, of > 1 {
            parts.append("\(ordinal(rank)) of \(of)")
        }
        if let searched {
            parts.append(String(format: "room %.0f%%", searched * 100))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 1st, 2nd, 3rd, 4th — and 11th, 12th, 13th, which are the ones a naive
    /// last-digit rule gets wrong.
    static func ordinal(_ n: Int) -> String {
        switch (n % 100, n % 10) {
        case (11...13, _): "\(n)th"
        case (_, 1): "\(n)st"
        case (_, 2): "\(n)nd"
        case (_, 3): "\(n)rd"
        default: "\(n)th"
        }
    }

    static func objectiveDetail(offsetDegrees: Double, distance: Double?, onTarget: Bool) -> String {
        let turn = onTarget ? "straight ahead"
            : String(format: "%.0f° %@", abs(offsetDegrees), offsetDegrees < 0 ? "left" : "right")
        guard let distance else { return turn }
        return String(format: "%.0f m · %@", distance, turn)
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
        // Being walked to somebody, or having just heard them, is a
        // one-instruction moment: the team stands down off the tape and out of
        // the view so nothing competes with it.
        let showTeam = !responding && soundOffset == nil
        if showTeam {
            markers += teamMarkers(overlay.teammates)
        }
        // A hazard keeps its chip even while responding. Everything else stands
        // down for a find; the thing you are about to trip over on the way to
        // that find is the one exception.
        let hazard = overlay.nearestHazard
        if let hazard, let bearing = hazard.bearingRadians {
            markers.append(.init(off: Double(bearing) * 180 / .pi,
                                 label: String(format: "⚠ %.0fm", Double(hazard.distance ?? 0)),
                                 color: hazardColor, big: false))
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
        // **One voice at a time.** The status pill is the phone's own account of
        // itself and it is actionable; a hub directive is neither while
        // tracking is lost — it was computed from a heading this phone no
        // longer has. Both on screen together read as the app arguing with
        // itself: "Hold your phone up" stacked over "Tracking lost". The
        // directive stands down until the phone can act on it again.
        let banner = overlay.status.level == .problem ? nil
            : soundSide.map { HubHUDMirror.Banner(text: "Sound heard · \($0)", tone: "alert") }
            ?? overlay.banner.map { HubHUDMirror.Banner(text: $0.text, tone: $0.tone) }

        let searching = overlay.phase == "search" || overlay.phase == "found"
        let lookingFor = overlay.world?.lookingFor.flatMap { $0.isEmpty || !searching ? nil : $0 }

        // The same test the phone's own renderer uses, so the console is not
        // told about a card the operator cannot see.
        let again = overlay.isRecalibrating
        let card = overlay.phase.flatMap { phase in
            PhaseCardText.covers(phase, alignment: overlay.alignment)
                ? HubHUDMirror.Card(title: PhaseCardText.title(for: phase, again: again),
                                    text: PhaseCardText.detail(for: phase, again: again))
                : nil
        }

        let floating = overlay.pings.map { ($0, $0.label, cueColor($0)) }
            + (overlay.candidate.map { [($0, "FIND", alertColor)] } ?? [])
        func onScreen(_ point: CGPoint?) -> (x: Double, y: Double)? {
            guard let point,
                  let fraction = uprightFraction(ofCapturePoint: point, captureWidth: captureWidth,
                                                 captureHeight: captureHeight),
                  (0...1).contains(fraction.x), (0...1).contains(fraction.y) else { return nil }
            return fraction
        }
        // Same sizing as phone.js: nearer is bigger, clamped, over a ~844 pt screen.
        func radius(_ metres: Double) -> Double { max(9, min(22, 60 / max(metres, 1))) / 844 }

        var ar: [HubHUDMirror.ARMarker] = floating.compactMap { cue, label, color in
            guard let fraction = onScreen(cue.imagePoint) else { return nil }
            let distance = Double(cue.distance ?? 3)
            return .init(x: fraction.x, y: fraction.y, r: radius(distance),
                         label: String(format: "%@ · %.1f m", label, distance), color: color)
        }
        // The nearest few teammates who are actually in frame. Somebody standing
        // beside you needs no marker — you can see them — and a field full of
        // outlines is the clutter this is meant to cut through.
        if showTeam {
            let inFrame = overlay.teammates
                .filter { Double($0.distance ?? 0) > teamNearMetres }
                .sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
            for mate in inFrame.prefix(teamARLimit) {
                guard let fraction = onScreen(mate.imagePoint) else { continue }
                let distance = Double(mate.distance ?? 0)
                ar.append(.init(x: fraction.x, y: fraction.y, r: radius(distance),
                                label: String(format: "#%d · %.0f m", mate.index, distance),
                                color: peerColor(index: mate.index), hollow: true))
            }
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
        // Close enough to walk into: the bezel is the hazard's, ahead of both the
        // sound and the find. Running to somebody is the moment an operator is
        // least likely to be watching their feet, which is exactly why the
        // obstacle outranks the person for those last two metres.
        let imminent = (hazard?.distance ?? .infinity) <= HazardCue.imminentMetres
        let hazardEdge: HubHUDMirror.SoundEdge? = {
            guard imminent, let side = hazard?.side else { return nil }
            return .init(side: side, color: hazardColor)
        }()
        let edge = hazardEdge
            ?? soundSide.map { HubHUDMirror.SoundEdge(side: $0, color: soundColor) }
            ?? guideSide.map { HubHUDMirror.SoundEdge(side: $0, color: alertColor) }

        let warning = hazard.flatMap { hazard -> HubHUDMirror.Warning? in
            guard let side = hazard.side, let metres = hazard.distance else { return nil }
            let where_ = side == "ahead" ? "ahead" : "to your \(side)"
            return .init(text: String(format: "Hazard %.0f m %@", Double(metres), where_),
                         color: hazardColor)
        }

        // The standing answer to "who am I walking to, and how far". It exists
        // only while there is somewhere to be sent — no arrow, no card.
        let objective = overlay.arrow.flatMap { arrow -> HubHUDMirror.Objective? in
            guard let cue = overlay.banner else { return nil }
            let off = Double(arrow.bearingRadians) * 180 / .pi
            return .init(title: objectiveTitle(kind: cue.kind, label: arrow.label),
                         detail: objectiveDetail(offsetDegrees: off,
                                                 distance: arrow.distance.map(Double.init),
                                                 onTarget: cue.onTarget),
                         tone: cue.tone)
        }

        // What the whole screen is saying, for as long as it is true. A hazard
        // you are about to hit takes it, the same way it takes the bezel — for
        // those two metres the obstacle is the emergency.
        let ambient: HubHUDMirror.Ambient? = {
            if imminent, hazard != nil {
                return .init(kind: "hazard", color: hazardColor, intensity: 0.7)
            }
            switch overlay.find {
            case .heading: return .init(kind: "find", color: alertColor, intensity: 0.85)
            case .with: return .init(kind: "with", color: alertColor, intensity: 0.45)
            case nil: return nil
            }
        }()

        // The least important thing on the screen, so the first to go: a
        // scoreboard has no business sharing a glance with a find, a shout or
        // the operator's voice.
        let quiet = overlay.toast == nil && banner?.tone != "alert" && edge == nil
            && warning == nil && ambient == nil
        let stats = searching && quiet
            ? statsLine(squareMetres: overlay.world?.stats?.m2, rank: overlay.world?.stats?.rank,
                        of: overlay.world?.stats?.of, searched: overlay.world?.searched)
            : nil

        return HubHUDMirror(compass: compass, banner: banner, lookingFor: lookingFor,
                            toast: overlay.toast.map { "📣 " + $0.text }, card: card, ar: ar,
                            screen: visibleFrame(captureWidth: captureWidth, captureHeight: captureHeight,
                                                 screenAspect: screenAspect),
                            dets: overlay.hazards == nil ? overlay.detections?.boxes
                                : (overlay.detections?.boxes ?? []) + (overlay.hazards?.boxes ?? []),
                            soundEdge: edge, objective: objective, warning: warning,
                            ambient: ambient, stats: stats)
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
