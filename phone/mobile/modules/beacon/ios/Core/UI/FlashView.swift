import SwiftUI
import SwarmCore

/// A colour over the whole screen for a moment, with a word on it: the marker
/// locking, or anything else the hub chooses to flash.
///
/// **It is deliberately not opaque.** It used to be a flat fill at full alpha,
/// which is unbeatable at getting attention and actively dangerous at getting
/// anyone anywhere: the operator is holding this phone up in front of their
/// face, in a crowded room, and for the whole time it was up they could not see
/// the floor. So the colour lives at the edges and clears the middle — a
/// vignette, strong enough to read across a room, transparent enough to walk
/// through.
///
/// **It fades in and it fades out, and it does nothing else.** It used to
/// contract upward as it left, which was right when the flash was the
/// announcement of a find: it read as the alert *becoming* the badge at the top
/// of the screen, which is where that message carries on. The find announcement
/// is `TakeoverView`'s job now, and this is left with the moments that have no
/// badge to become — a marker locking is finished when it is finished. Sliding
/// it toward a corner where nothing is waiting made a completed thing look like
/// it had gone somewhere.
///
/// **The view owns both halves of that, which is why it is always mounted and
/// takes an optional cue.** It used to be built inside an `if let` in
/// `OperatorView` and lean on an ambient `.animation(value:)` there to carry it
/// back out; in practice the cue expiring took the view out of the tree in the
/// same beat, and the green vanished in a single frame — a clean fade in and a
/// cut out. Now the cue going away is a state change *inside* a view that is
/// already on screen, and it keeps the last cue it was given so there is still
/// something to look at while it leaves. Same shape as `HUDAmbientView`, for
/// the same reason.
struct FlashView: View {
    /// The live cue, or nil when nothing is flashing. Nil is the normal state:
    /// the view sits mounted at zero opacity waiting for one.
    let flash: FlashCue?

    /// Symmetric-ish, and slower than a transition would give on its own. A
    /// flash that snaps in reads as a glitch; one that eases in and out reads
    /// as the app answering. The way out is the longer of the two — leaving is
    /// the half nobody is waiting on.
    static let fadeIn: Double = 0.25
    static let fadeOut: Double = 0.45

    @State private var shown = false
    /// The last cue handed over, kept after `flash` goes nil so the colour and
    /// the word are still there to fade rather than disappearing a frame before
    /// the fade starts.
    @State private var held: FlashCue?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let held {
                    vignette(held, in: geometry.size)
                    if let text = held.text {
                        label(text)
                            // Smaller and lighter than a takeover plate, which
                            // is the louder moment of the two. At 40pt `.black`
                            // this line was the biggest, heaviest type in the
                            // app, spread across two rows of a phone, for a
                            // word that only confirms something went right.
                            .font(TypeScale.alert(26, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.hudInk)
                            // The text sits on clear camera, not on a wash of
                            // colour, so it carries its own contrast with it.
                            .shadow(color: .hudVoid.opacity(0.85), radius: 8)
                            .shadow(color: .hudVoid.opacity(0.5), radius: 2)
                            .padding(Space.xxl)
                    }
                }
            }
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { arrive(flash, animated: false) }
        .onChange(of: flash) { _, cue in arrive(cue, animated: true) }
    }

    /// A cue arriving replaces what is held and eases in; a cue ending eases
    /// out and leaves what is held alone, so the last frame of the fade is the
    /// same picture as the first.
    private func arrive(_ cue: FlashCue?, animated: Bool) {
        if let cue {
            held = cue
            guard animated else { shown = true; return }
            withAnimation(.easeInOut(duration: Self.fadeIn)) { shown = true }
        } else {
            guard animated else { shown = false; return }
            withAnimation(.easeInOut(duration: Self.fadeOut)) { shown = false }
        }
    }

    /// The hub ends a success line with "✓", whose tail curves. SF Symbols'
    /// `checkmark` is two straight strokes and sits on the text baseline at the
    /// right weight for whatever size the line is drawn at, so the phone swaps
    /// the character for the symbol. The same substitution `HUDStyle.label`
    /// makes for the toast's megaphone, and for the same reason: the shared
    /// string has to stay plain text for the console to draw it. The lock's own
    /// page no longer ends in one — see `OverlayModel.lockFlashText`.
    private func label(_ text: String) -> Text {
        guard text.hasSuffix("✓") else { return Text(text) }
        let rest = text.dropLast().trimmingCharacters(in: .whitespaces)
        return Text(rest) + Text(" ") + Text(Image(systemName: "checkmark"))
    }

    /// Colour at the bezel, clear camera in the middle. The radii are in the
    /// smaller screen dimension so a landscape frame does not lose the clear
    /// centre entirely.
    private func vignette(_ cue: FlashCue, in size: CGSize) -> some View {
        let color = Color(.sRGB, red: Double(cue.red), green: Double(cue.green),
                          blue: Double(cue.blue), opacity: 1)
        let reach = max(size.width, size.height)
        return RadialGradient(
            colors: [color.opacity(0), color.opacity(0.15), color.opacity(0.36), color.opacity(0.6)],
            center: .center,
            startRadius: min(size.width, size.height) * 0.18,
            endRadius: reach * 0.78)
    }
}
