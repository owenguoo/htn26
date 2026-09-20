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

/// The map palette, and it is **`web/console.js`'s, value for value**.
///
/// The phone's map and the operator console's search map are the same picture
/// of the same room, so they are drawn from one set of colours. Every constant
/// below is a hex literal out of `console.html`'s `:root` or a `ctx.fillStyle`
/// in `console.js`, named after what the console calls it. They are fixed
/// rather than semantic for the usual reason — this map floats over arbitrary
/// video — but the stronger reason is that they are shared with another
/// renderer, like `HUDStyle`: "fixing" one to a system colour silently makes
/// the two maps different products.
enum MapInk {
    /// Colours as the console writes them, so a value here can be diffed
    /// against the CSS by eye.
    private static func hex(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    // `#mapWrap`: radial-gradient(circle at 50% 45%, #fbfdfb 0, #f1f7f3 72%, #e8f1eb 100%)
    static let backdropCentre = hex(0xfb, 0xfd, 0xfb)
    static let backdropMid = hex(0xf1, 0xf7, 0xf3)
    static let backdropEdge = hex(0xe8, 0xf1, 0xeb)

    /// `drawRoom` colours, from the one call `console.js` makes.
    static let floor = Color.white.opacity(0.5)          // 'rgba(255,255,255,.5)'
    static let wall = hex(0x78, 0x9b, 0x85)              // '#789b85'
    static let stage = hex(0xde, 0xee, 0xe3)             // '#deeee3'
    static let stageLabel = hex(0x46, 0x66, 0x53)        // '#466653'

    /// `HEAT_RGB` in `web/room.js`. **Deliberately not the accent.** The
    /// probability field used to be painted in the same green as the searcher
    /// dots, their view cones and the chrome, so the one layer on the map that
    /// is data looked like more furniture. Blue, and not the amber or red that
    /// belong to sightings and the found person: a likely area is somewhere to
    /// look, not an alarm.
    static let heatField = hex(0x25, 0x63, 0xeb)         // '#2563eb'
    /// `drawCone` and the ping ring paint in the accent, at their own alpha.
    static let searcher = hex(0x18, 0x83, 0x4b)          // `--accent`
    static let sighting = hex(0xd9, 0x77, 0x06)          // '#d97706'
    static let found = hex(0xb7, 0x2f, 0x36)             // `--red`
    static let ping = hex(0x17, 0x37, 0x26)              // '#173726', = `--fg`
    static let marker = hex(0x6b, 0x4f, 0xbb)           // `MARKER_COLOR`

    static let markerBorder = Color.white
    static let markerShadow = hex(0x17, 0x37, 0x26).opacity(0.16)

    static let line = hex(0xd5, 0xe5, 0xda)              // `--line`
    static let legendBackground = hex(0xed, 0xf6, 0xef)  // `--bg-1`
    static let labelSecondary = hex(0x46, 0x66, 0x53)    // `--fg-2`
    static let labelTertiary = hex(0x59, 0x75, 0x62)     // `--fg-3`
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

// MARK: - Motion

/// Durations and curves, in one place for the same reason the gaps are.
enum Motion {
    /// The map coming out of the mini-map and going back into it. Slightly
    /// under-damped on purpose: the card should read as having been pulled out
    /// of the thumbnail, not as having faded up over it.
    static let genie: Animation = .spring(response: 0.42, dampingFraction: 0.78)
    /// The mini-map settling after a drag.
    static let settle: Animation = .spring(response: 0.3, dampingFraction: 0.86)
    /// A small piece of chrome picking itself up or putting itself down.
    static let lift: Animation = .easeOut(duration: 0.15)
}

/// macOS's genie, near enough for a phone: the card is drawn down into the
/// mini-map, narrowing to a sliver on the way, and comes back out of it.
///
/// The anchor is the mini-map's own centre as a fraction of the screen —
/// recomputed after every drag — so the map always collapses back into
/// wherever the operator has parked the thumbnail rather than into the corner
/// it started in.
///
/// The blur is what makes the squeeze read as suction rather than as a shrink:
/// without it the eye tracks the sliver and sees a rectangle getting small. It
/// is kept small — this is a full-screen blur on a phone that is also running
/// ARKit, an encoder and a socket, for the third of a second it is on screen.
struct GenieTransition: Transition {
    var anchor: UnitPoint

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(x: phase.isIdentity ? 1 : 0.16, y: phase.isIdentity ? 1 : 0.04,
                         anchor: anchor)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 6)
    }
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
