import SwiftUI

/// Puts the splash *over* the app rather than in front of it.
///
/// The content is mounted from the first frame and the splash is only an
/// overlay, so nothing waits for it: `RootView.onAppear` attaches the model,
/// reads `-BeaconJoin` and handles a `beacon://` link exactly when it always
/// did. The splash costs the launch no time, only the first second of the
/// picture.
struct SplashHost<Content: View>: View {
    /// Decided once, at launch. A `-BeaconJoin` run is a headless test recipe
    /// that joins without a tap; a logo animating over it would only put a
    /// second of mint in front of whatever the recipe is trying to screenshot.
    @State private var isShowingSplash = !SplashView.isSuppressedAtLaunch
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            // An overlay *built from* the preference rather than state set in
            // `onPreferenceChange`: that callback is `@Sendable`, and under
            // Swift 6 cannot write main-actor view state.
            .overlayPreferenceValue(SplashTargetKey.self) { headerLogoFrame in
                if isShowingSplash {
                    // No `.transition`: the splash fades itself out and asks to
                    // be removed only once it is already invisible.
                    SplashView(target: headerLogoFrame) { isShowingSplash = false }
                }
            }
    }
}

/// Where the screen underneath actually drew its logo, in global coordinates.
///
/// The splash used to *work out* where the join header's logo would be — this
/// much padding, that much safe area — and land there. It landed near it: a
/// second copy of another view's layout is a guess, and the eye sees a few
/// points of guess as a jump at the dissolve. So the header says where it is
/// (`splashTarget()`), and the splash goes to that rectangle.
struct SplashTargetKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Marks the logo the splash should settle onto.
    func splashTarget() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: SplashTargetKey.self, value: geometry.frame(in: .global))
            }
        }
    }
}

/// The first second of Beacon: the mark arrives, names itself, and walks to
/// where the join screen keeps it.
///
/// Three hand-overs, and each one is meant to be invisible:
///
/// 1. **System launch screen → splash.** `UILaunchScreen` is the flat
///    `LaunchBackground` colour (`ConsoleInk.bg`), so the first SwiftUI frame is
///    that same flat colour with nothing on it.
/// 2. **Flat colour → the join page's wash.** The join screen's radial gradient
///    fades in *behind the mark while it arrives*, so by the time the splash
///    leaves, the page under it and the splash itself are the same picture.
/// 3. **Centred lockup → the join screen's header.** The lockup is laid out at
///    `Metrics.logoSide` and scaled down about its top-leading corner into the
///    exact frame `RootView.joinForm` draws its 44pt logo and "beacon" in. The
///    splash then dissolves over an identical header, so the mark appears to
///    stay put while the form arrives around it.
///
/// Nothing bounces. Every move is a cubic ease with no overshoot: this is the
/// front door of a search tool, and it should arrive the way the rest of the
/// app speaks — flat and certain.
struct SplashView: View {
    /// Called once the splash is fully transparent and can leave the tree.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mark has faded up, and the page wash with it.
    @State private var hasArrived = false
    /// The wordmark is showing and the lockup — not the logo — is centred.
    @State private var isNamed = false
    /// The lockup is in the join screen's header.
    @State private var isSettled = false
    /// The whole surface is dissolving into the screen beneath.
    @State private var isLeaving = false

    /// Twice-and-a-bit `title3`, so that scaled by `Metrics.settledScale` it is
    /// the header's `.title3.weight(.semibold)` — and tracks the operator's
    /// text-size setting the same way the header does.
    @ScaledMetric(relativeTo: .title3) private var wordmarkSize = Metrics.wordmarkSize

    /// The join header's logo, as measured. nil until the screen underneath has
    /// laid out — and for good if it is not the join screen — in which case
    /// the splash falls back to the header's known padding.
    var target: CGRect?

    /// The lockup's laid-out size, so that "centred" can be arithmetic.
    @State private var lockupSize = CGSize(width: Metrics.logoSide, height: Metrics.logoSide)

    init(target: CGRect?, onFinished: @escaping () -> Void) {
        self.target = target
        self.onFinished = onFinished
    }

    nonisolated static var isSuppressedAtLaunch: Bool {
        UserDefaults.standard.string(forKey: "BeaconJoin") != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let place = placement(in: geometry)
            lockup
                .onGeometryChange(for: CGSize.self) { $0.size } action: { lockupSize = $0 }
                // Laid out once, at full size, in the top-leading corner of the
                // whole screen; everything after that is one scale about that
                // corner and one offset. Because this reader ignores the safe
                // area its coordinates *are* global ones, so the measured
                // header frame can be used as it comes.
                .scaleEffect(place.scale, anchor: .topLeading)
                .offset(x: place.origin.x, y: place.origin.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .background { backdrop }
        .opacity(isLeaving ? 0 : 1)
        // Opaque means it owns the touches: a tap must not reach a text
        // field nobody can see. Once it starts to dissolve the form is
        // visible and gets them.
        .allowsHitTesting(!isLeaving)
        // The join screen underneath carries the real, labelled content.
        .accessibilityHidden(true)
        .task { await play() }
    }

    /// Where the lockup's top-leading corner goes, and at what scale.
    ///
    /// Three places: the *logo* centred (the cube opens alone in the middle),
    /// the *lockup* centred (the cube has slid left to make room for its name),
    /// and the header. The logo is the lockup's leading edge, so putting the
    /// lockup's corner on the target's corner puts the cube on the cube.
    private func placement(in geometry: GeometryProxy) -> (origin: CGPoint, scale: CGFloat) {
        let screen = geometry.size
        if isSettled {
            if let target, target.width > 0 {
                let scale = target.width / Metrics.logoSide
                // At a very large text size the wordmark is taller than the
                // cube, and the cube sits below the lockup's top edge by half
                // the difference.
                let inset = max(0, lockupSize.height - Metrics.logoSide) / 2 * scale
                return (CGPoint(x: target.minX, y: target.minY - inset), scale)
            }
            return (CGPoint(x: geometry.safeAreaInsets.leading + Metrics.headerLeading,
                            y: geometry.safeAreaInsets.top + Metrics.headerTop),
                    Metrics.settledScale)
        }
        let width = isNamed ? lockupSize.width : Metrics.logoSide
        return (CGPoint(x: (screen.width - width) / 2, y: (screen.height - lockupSize.height) / 2), 1)
    }

    // MARK: - Pieces

    private var lockup: some View {
        HStack(spacing: Metrics.lockupSpacing) {
            Image("BeaconLogo")
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.logoSide, height: Metrics.logoSide)
                // The cube is set down, not dropped: a few points of travel
                // and a breath of scale, both gone by the time it is opaque.
                .scaleEffect(hasArrived || reduceMotion ? 1 : Metrics.arrivalScale)
                .offset(y: hasArrived || reduceMotion ? 0 : Metrics.arrivalRise)
                .opacity(hasArrived ? 1 : 0)
            Text("beacon")
                .font(.system(size: wordmarkSize, weight: .semibold))
                .foregroundStyle(ConsoleInk.fg)
                .lineLimit(1)
                .fixedSize()
                // `hasArrived` as well, so that under Reduce Motion — where the
                // lockup is complete from the start — the word fades up with
                // the cube instead of being there before it.
                .opacity(isNamed && hasArrived ? 1 : 0)
        }
    }

    /// Flat `--bg` first, because that is what the system launch screen left on
    /// the glass; then `joinForm`'s own wash on top of it. **These numbers are
    /// `RootView.joinForm`'s background, value for value** — if that gradient
    /// moves, this one has to, or the dissolve at the end becomes visible.
    private var backdrop: some View {
        ZStack {
            ConsoleInk.bg
            RadialGradient(colors: [MapInk.backdropCentre, ConsoleInk.bg, ConsoleInk.bg1],
                           center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 620)
                .opacity(hasArrived ? 1 : 0)
        }
        .ignoresSafeArea()
    }

    // MARK: - Sequence

    /// One straight-line script rather than chained completion handlers: the
    /// order is the design, and it should be readable top to bottom.
    ///
    /// A cancelled sleep returns at once, so a torn-down splash runs straight
    /// through to `onFinished` instead of stranding an opaque sheet of mint
    /// over the app.
    private func play() async {
        // Not from the first frame. A cold launch spends its first few hundred
        // milliseconds with the main thread busy — the scene connecting,
        // `RootView.onAppear` attaching the model and reading `venue.json` —
        // and an animation started then has its opening frames dropped: the
        // cube would simply *be there*, the one move that says "launch"
        // swallowed. The flat colour is what the system launch screen left on
        // the glass, so holding it a beat longer is invisible.
        await pause(Timing.startDelay)

        if reduceMotion {
            // No travel at all: the finished lockup fades up in the middle,
            // stands, and fades away.
            isNamed = true
            withAnimation(.easeOut(duration: Timing.arrive)) { hasArrived = true }
            await pause(Timing.reducedHold)
        } else {
            withAnimation(Timing.easeOut(Timing.arrive)) { hasArrived = true }
            await pause(Timing.nameAt)

            withAnimation(Timing.easeOut(Timing.name)) { isNamed = true }
            await pause(Timing.name + Timing.hold)

            withAnimation(Timing.easeInOut(Timing.settle)) { isSettled = true }
            // Start dissolving just before it lands, so the last points of
            // travel happen over the real header and there is no beat where
            // two finished pictures sit on top of each other.
            await pause(Timing.settle - Timing.leaveOverlap)
        }

        withAnimation(.easeInOut(duration: Timing.leave)) { isLeaving = true }
        await pause(Timing.leave)
        onFinished()
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Numbers

/// The header these are derived from is `RootView.joinForm`'s: a 44pt logo,
/// `Space.xs` from a `title3` wordmark, `Space.l` below the safe area and
/// `Space.xl + Space.xs` in from the edge. Everything here is that, times
/// `logoSide / 44`, so the settled lockup is that header and not a lookalike.
private enum Metrics {
    static let headerLogoSide: CGFloat = 44
    /// `title3` at the default text size; `@ScaledMetric` does the rest.
    static let headerWordmarkSize: CGFloat = 20
    static let headerLeading = Space.xl + Space.xs
    static let headerTop = Space.l

    /// The PNG carries its own margin — the cube is about 60% of the canvas —
    /// so this draws a cube roughly 58pt across: present, not a poster.
    static let logoSide: CGFloat = 96
    static let settledScale = headerLogoSide / logoSide
    static let lockupSpacing = Space.xs / settledScale
    static let wordmarkSize = headerWordmarkSize / settledScale

    static let arrivalScale: CGFloat = 0.92
    static let arrivalRise: CGFloat = 6
}

/// About 2 s from first frame to gone, and the join form is readable under
/// the dissolve from about 1.8 s.
///
/// It was 1.4 s, which is long enough on paper and not on a phone: each step
/// was shorter than the eye needs to register it as a step (a 0.15 s hold is
/// not a hold), and the first of them was spent under the launch's own dropped
/// frames. These are close to the reference this was modelled on — a ~0.7 s
/// slide, a ~0.36 s hold, a ~0.4 s fade — and every step is sequenced off the
/// previous one's `pause`, so a busy main thread makes the splash late, never
/// short.
private enum Timing {
    /// Flat colour only, while the launch settles. See `play()`.
    static let startDelay = 0.15
    static let arrive = 0.45
    /// Naming starts before the arrival has finished, so the two read as one
    /// gesture rather than as two steps with a gap.
    static let nameAt = 0.35
    static let name = 0.55
    static let hold = 0.25
    static let settle = 0.5
    /// None. The dissolve used to start a tenth of a second before the lockup
    /// landed, which meant it cross-faded while still a few points short of
    /// the header — the same misregistration, from timing instead of layout.
    static let leaveOverlap = 0.0
    static let leave = 0.25
    static let reducedHold = 1.0

    /// Cubic ease-out and ease-in-out. Deliberately not `Motion`'s springs:
    /// those are for things a thumb has just moved, and are under-damped on
    /// purpose. Nothing here should overshoot.
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.33, 1, 0.68, 1, duration: duration)
    }

    static func easeInOut(_ duration: Double) -> Animation {
        .timingCurve(0.65, 0, 0.35, 1, duration: duration)
    }
}
