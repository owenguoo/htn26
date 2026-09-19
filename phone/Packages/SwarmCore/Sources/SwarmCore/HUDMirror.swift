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

    public var compass: Compass?
    public var banner: Banner?
    public var lookingFor: String?
    public var toast: String?
    public var card: Card?
    public var ar: [ARMarker]
    /// `[x0, y0, x1, y1]`: the part of the frame the phone's screen shows.
    public var screen: [Double]?
    public var dets: [HubDetectionBox]?
}

/// The words on the lobby / calibrate / end cards. Here rather than in the
/// SwiftUI view so the phone and the console's mirror of it cannot drift apart.
public enum PhaseCardText {
    public static func covers(_ phase: String) -> Bool {
        phase == "lobby" || phase == "calibrate" || phase == "end"
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
        case "lobby": "Hold tight. The search starts when the operator says go."
        case "calibrate": "Point the camera at any printed marker until it locks."
        default: "Thanks — you can lower your phone."
        }
    }
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
                ? "CANDIDATE" + (arrow.distance.map { String(format: " %.1fm", $0) } ?? "")
                : (arrow.label ?? "TARGET")
            let color = responding ? alertColor
                : abs(off) < GuideThresholds.onTargetDegrees ? onTargetColor
                : (kind == "look" || kind == "go") ? directedColor : turnColor
            markers.append(.init(off: off, label: label, color: color, big: true))
        }
        let targets = overlay.pings.map { ($0, "◆ " + $0.label, pingColor) }
            + (responding ? [] : (overlay.candidate.map { [($0, "CANDIDATE", alertColor)] } ?? []))
        for (cue, label, color) in targets {
            guard let bearing = cue.bearingRadians else { continue }
            let metres = cue.distance.map { String(format: " %.0fm", $0) } ?? ""
            markers.append(.init(off: Double(bearing) * 180 / .pi, label: label + metres, color: color, big: false))
        }
        let compass = overlay.roomPose?.heading.map {
            HubHUDMirror.Compass(center: $0, abs: false, markers: markers)
        }

        // The tone rules live on the cue, next to the wording they colour, so the
        // console pill and the phone banner cannot disagree about whether the
        // operator is there yet.
        let banner = overlay.banner.map { HubHUDMirror.Banner(text: $0.text, tone: $0.tone) }

        let searching = overlay.phase == "search" || overlay.phase == "found"
        let lookingFor = overlay.world?.lookingFor.flatMap { $0.isEmpty || !searching ? nil : $0 }

        let card = overlay.phase.flatMap { phase in
            PhaseCardText.covers(phase)
                ? HubHUDMirror.Card(title: PhaseCardText.title(for: phase), text: PhaseCardText.detail(for: phase))
                : nil
        }

        let floating = overlay.pings.map { ($0, $0.label, pingColor) }
            + (overlay.candidate.map { [($0, "CANDIDATE", alertColor)] } ?? [])
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

        return HubHUDMirror(compass: compass, banner: banner, lookingFor: lookingFor,
                            toast: overlay.toast.map { "📣 " + $0.text }, card: card, ar: ar,
                            screen: visibleFrame(captureWidth: captureWidth, captureHeight: captureHeight,
                                                 screenAspect: screenAspect),
                            dets: overlay.detections?.boxes)
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
