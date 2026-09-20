import SwiftUI

/// The one place a colour, a gap, a corner or a type size is allowed to be a
/// number. Everywhere else names one of these.
///
/// The governing rule is **use an Apple semantic colour wherever one exists**.
/// A semantic colour is a live UIKit dynamic colour: it re-resolves on a trait
/// change, so light mode, dark mode and increased contrast are the system's
/// problem and not ours. Inventing a hex means opting out of all three.
///
/// Invented colour is legitimate in exactly three places, and each has its own
/// namespace here so that the choice is visible at the call site:
///
/// 1. **`HUDInk` / `MapInk` — chrome drawn over the live camera feed.** The
///    backdrop is an arbitrary video frame, not a themed surface, so the colour
///    scheme tells us nothing about contrast. `Color(.label)` would flip to
///    black in light mode and vanish against a bright frame. Fixed
///    light-on-dark in both themes, on purpose.
/// 2. **The console-mirror palette** — `HUDStyle` in `UnifiedHUDView.swift`.
///    Those values are `web/console.js` `drawHud`'s, not ours: they are
///    protocol, and "one HUD, two renderers" means they must never be "fixed"
///    to system colours. They stay in that file, next to the drawing code they
///    have to be read against.
/// 3. **The per-phone identity colour** — `overlay.colorHex`, assigned by the
///    hub so the console and the operator name the same phone the same way.
///
/// Everything else — the phase card, the seat picker, the legacy join form —
/// is semantic and adapts.

// MARK: - Colour

/// There are deliberately **no** `ssLabel` / `ssBackground` / `ssSeparator`
/// tokens here, though the obvious design system has them.
///
/// Adaptive *text* in SwiftUI is `.primary` / `.secondary` — that is already the
/// native spelling of `label` / `secondaryLabel`, and the phase card and seat
/// picker use it. Adaptive *surfaces* here are materials, not flat fills,
/// because everything in this layer floats over a camera. And the grouped-form
/// colours (`systemGroupedBackground`, `separator`, row fills) belong to the
/// join and settings screens, which are `@expo/ui` and take them from
/// `mobile/src/theme/tokens.ts`. A Swift token with no Swift caller is worse
/// than no token: it reads as permission to put `Color(.label)` on the HUD.
extension ShapeStyle where Self == Color {
    /// Meaning. These carry the `OperatorStatus.level` mapping, so a level and a
    /// colour cannot drift apart: `.ok` is `ssOK` wherever it is drawn.
    ///
    /// They are system colours, so inside `.cameraChrome()` they resolve to the
    /// brighter dark-mode variants — which is what you want over video.
    static var ssAccent: Color { Color(.tintColor) }
    static var ssOK: Color { Color(.systemGreen) }
    static var ssAttention: Color { Color(.systemOrange) }
    static var ssProblem: Color { Color(.systemRed) }

    // MARK: Ink for chrome over the camera — deliberately not adaptive.

    /// Titles and glyphs on camera chrome.
    static var hudInk: Color { .white }
    /// Supporting sentences: the status hint.
    static var hudInkSecondary: Color { .white.opacity(0.8) }
    /// Affordances that should be present but not loud: the disclosure chevron.
    static var hudInkTertiary: Color { .white.opacity(0.7) }
    /// Behind the camera before its first frame, and behind the whole hosted
    /// view. Black in both themes rather than a system background: a camera
    /// that has not started is black, and a white flash reads as a crash.
    static var hudVoid: Color { .black }
}

/// The mini-map and seat-plan palette. Drawn over the camera like the rest of
/// the chrome, so it is fixed rather than semantic — but named, because
/// `.white.opacity(0.35)` appearing twice for two different reasons is how a map
/// stops being legible one edit at a time.
enum MapInk {
    /// Fixed colours mirror the operator console's light search-map palette.
    /// This map floats over arbitrary video, so these deliberately do not
    /// resolve from the surrounding light/dark appearance.
    static let outside = Color(red: 0.91, green: 0.95, blue: 0.92)
    static let floor = Color.white.opacity(0.96)
    static let searched = Color(red: 0.09, green: 0.51, blue: 0.29).opacity(0.16)
    static let stage = Color(red: 0.87, green: 0.93, blue: 0.89)
    static let outline = Color(red: 0.47, green: 0.61, blue: 0.52)
    static let searcher = Color(red: 0.09, green: 0.51, blue: 0.29)
    static let possible = Color(red: 0.85, green: 0.47, blue: 0.02)
    static let found = Color(red: 0.72, green: 0.18, blue: 0.21)
    static let markerBorder = Color.white
    static let plateBorder = Color(red: 0.70, green: 0.81, blue: 0.74)
    static let label = Color(red: 0.09, green: 0.22, blue: 0.15)
    static let labelSecondary = Color(red: 0.27, green: 0.40, blue: 0.33)
    static let legendBackground = Color.white.opacity(0.9)
    /// The seat the operator has tapped but not yet confirmed.
    static let seatRing = possible
    /// The hub only sends this point after the person has been found.
    static let candidateRing = found
    static let candidateHalo = found.opacity(0.24)
    static let ping = Color(red: 1.0, green: 0.82, blue: 0.40)
    /// Used when the hub has not named a colour for this phone yet.
    static let meFallback = searcher
}

/// Ink for the Simulator's drive room. Light on purpose: this is a rehearsal
/// wireframe, not a stand-in for a dark camera feed. The HUD chrome over it
/// still opts into dark via `cameraChrome()`.
enum DriveInk {
    static let skyTop = Color(red: 0.88, green: 0.91, blue: 0.96)
    static let skyBottom = Color(red: 0.78, green: 0.82, blue: 0.88)
    static let floor = Color(red: 0.72, green: 0.75, blue: 0.80)
    static let grid = Color.black.opacity(0.12)
    static let outline = Color.black.opacity(0.45)
    static let stage = Color.black.opacity(0.12)
    static let stageLabel = Color.black.opacity(0.55)
    static let prop = Color.black.opacity(0.28)
    static let person = Color.black.opacity(0.38)
}

// MARK: - Metrics

/// A 4pt grid. Used with `spacing:` and `padding:`, never as a magic literal.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

enum Radius {
    /// The mini-map plate and the seat plan.
    static let plate: CGFloat = 8
    /// The status pill when it has a hint and is no longer a capsule.
    static let card: CGFloat = 14
    /// Cards that cover the camera: the phase card, the seat picker.
    static let sheet: CGFloat = 22

    /// Always `.continuous`. Every `RoundedRectangle` in this module used to be
    /// the default `.circular`, which is not the corner iOS draws anywhere else.
    /// Capsules and circles use `Capsule()` / `Circle()`, never a radius.
    static func rect(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Apple's minimum comfortable hit target. The chrome buttons are drawn small
/// so they do not cover the feed, but they are *tapped* at this size.
enum HitTarget {
    static let minimum: CGFloat = 44
}

enum Surface {
    /// Chrome floating over the camera. Thin enough to keep the feed readable.
    static let hudChrome: Material = .ultraThinMaterial
    /// Cards that deliberately interrupt: the phase card, the seat picker. The
    /// camera behind them is not the point while they are up, and a thicker
    /// material is what makes `.secondary` body text legible over arbitrary
    /// video instead of merely usually legible.
    static let card: Material = .regularMaterial
}

// MARK: - Type

/// Every role is a Dynamic Type text style, so the operator's text-size setting
/// reaches all of it. The one exception is the HUD canvas in
/// `UnifiedHUDView.swift`, which draws at `size × k` because those glyphs have
/// to land on the pixels `web/console.js` draws them on; a compass tape that
/// reflowed with the text-size setting would stop matching the console.
enum TypeScale {
    /// The phase card's headline — the only thing on screen while it is up.
    static let coverTitle = Font.title.bold()
    /// A card that shares the screen: the seat picker.
    static let sheetTitle = Font.title3.bold()
    /// Primary buttons, and the identity badge, which is read at a glance
    /// across a room and so wants the same weight as an action.
    static let action = Font.headline
    static let identity = Font.headline.monospacedDigit().weight(.heavy)
    /// The status pill's sentence.
    static let statusTitle = Font.subheadline.weight(.bold)
    /// Body copy on a card.
    static let detail = Font.callout
    static let footnote = Font.footnote
    /// The status pill's second line.
    static let hint = Font.caption
    /// Chevrons and other small bold affordances.
    static let affordance = Font.caption.weight(.bold)
    /// The glyph inside a round chrome button.
    static let chromeGlyph = Font.footnote.weight(.bold)
    /// Anything numeric small enough to jitter: the map caption, marker labels.
    static let readout = Font.caption2.monospacedDigit().weight(.semibold)
    /// A glyph sitting in a row of text.
    static let inlineSymbol = Font.body.weight(.bold)
}

// MARK: - Environment

extension View {
    /// Marks a subtree as chrome drawn over the live camera feed.
    ///
    /// Pinning the colour scheme here rather than on the whole screen is the
    /// point. `OperatorView` used to carry `.preferredColorScheme(.dark)`,
    /// which also pinned the phase card and the seat picker — so a light-mode
    /// operator got a dark modal card for no reason. But a material *is*
    /// scheme-dependent: `.ultraThinMaterial` resolved light would put the
    /// gear's white glyph on a white blur. So the camera layers opt in
    /// explicitly, and everything else follows the window (light by default).
    func cameraChrome() -> some View {
        environment(\.colorScheme, .dark)
    }

    /// Gives a small piece of chrome a full-size tap area without growing it.
    func hitTarget(_ side: CGFloat = HitTarget.minimum) -> some View {
        frame(width: side, height: side).contentShape(Circle())
    }
}
