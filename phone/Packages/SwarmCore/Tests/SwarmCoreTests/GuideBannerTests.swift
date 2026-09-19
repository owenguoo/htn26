import Foundation
import simd
import Testing
@testable import SwarmCore

/// The guidance banner, string for string against `web/phone.js`
/// `updateGuideBanner` (lines 763-805).
///
/// The wording is not cosmetic. An operator sweeping a room reads this line out
/// of the corner of their eye while the phone is moving; `←` and `→` sit on the
/// side of the line they have to turn toward so the direction lands before the
/// number does. A phone that words it differently from the browser is a phone
/// that has to be explained separately to whoever is holding it.
@Suite("Guide banner: web parity, recomputed live")
struct GuideBannerTests {

    // MARK: - Helpers

    /// Room heading `h` with the camera tilted `pitch` degrees above horizontal.
    /// Room heading is clockwise from above; a right-handed yaw about venue +Y
    /// swings the camera the other way, hence the negation.
    private func facing(_ h: Double, pitch: Double = 0, at position: SIMD3<Float> = [0, 1.5, 5]) -> Pose {
        let yaw = simd_quatf(angle: -Float(h * .pi / 180), axis: VenueAxis.up)
        let tilt = simd_quatf(angle: Float(pitch * .pi / 180), axis: CameraAxis.right)
        return Pose(position: position, orientation: yaw * tilt)
    }

    private func diagnostics() -> SessionDiagnostics {
        var value = SessionDiagnostics()
        value.state = .tracking
        value.quality = .normal
        value.confidence = 0.95
        value.isStale = false
        value.lastCorrectionAge = 2
        return value
    }

    private func tick(_ model: inout OverlayModel, pose: Pose?, now: Double,
                      alignment: RoomAlignment? = .identity) {
        model.update(pose: pose, alignment: alignment, source: alignment == nil ? .none : .marker,
                     intrinsics: nil, diagnostics: diagnostics(), transport: .init(),
                     transportState: .connected, now: now)
    }

    /// Drives a guide and reads the banner back with the operator facing `at`.
    private func banner(_ command: HubCommand, facingHeading at: Double, pitch: Double = 0,
                        appliedFrom: Double = 0) -> GuideBannerCue? {
        var model = OverlayModel()
        model.apply(command, heading: appliedFrom, now: 0)
        tick(&model, pose: facing(at, pitch: pitch), now: 0.1)
        return model.state.banner
    }

    // MARK: - The fourteen strings of §1.5

    /// `search` is the planner's sweep, the most common guide by far.
    @Test func searchWording() {
        // Applied while facing 0 with delta +37 ⇒ target heading 37.
        let turn = HubCommand.guideTurn(sector: "B2", delta: 37, onTarget: false,
                                        text: "Turn right 37°", kind: "search", distance: nil)
        #expect(banner(turn, facingHeading: 0)?.text == "Turn right 37° →")
        #expect(banner(turn, facingHeading: 74)?.text == "← Turn left 37°")
        #expect(banner(turn, facingHeading: 37)?.text == "Scanning B2…")
        // Tilted beats everything else, and only `search` mentions it at all.
        #expect(banner(turn, facingHeading: 37, pitch: 70)?.text == "Hold your phone up")
        #expect(banner(turn, facingHeading: 0, pitch: -70)?.text == "Hold your phone up")
    }

    /// `look` — an operator or the LLM pointing a phone at something.
    @Test func lookWording() {
        let look = HubCommand.guideHeading(kind: "look", sector: "the door", heading: 100,
                                           distance: nil, untilMs: 20_000)
        #expect(banner(look, facingHeading: 100)?.text == "Facing the door ✓ hold it")
        #expect(banner(look, facingHeading: 60)?.text == "Face the door · turn right 40° →")
        #expect(banner(look, facingHeading: 140)?.text == "← Face the door · turn left 40°")
    }

    /// `go` — walk somewhere. Distance is appended when the hub computed the
    /// directive from a point.
    @Test func goWording() {
        let go = HubCommand.guideHeading(kind: "go", sector: "back row", heading: 100,
                                         distance: 9.4, untilMs: 90_000)
        #expect(banner(go, facingHeading: 100)?.text == "↑ Walk to back row · 9.4 m")
        #expect(banner(go, facingHeading: 60)?.text == "Turn right 40° → · walk to back row · 9.4 m")
        #expect(banner(go, facingHeading: 140)?.text == "← Turn left 40° · walk to back row · 9.4 m")

        let bare = HubCommand.guideHeading(kind: "go", sector: "the exit", heading: 0,
                                           distance: nil, untilMs: 90_000)
        #expect(banner(bare, facingHeading: 0)?.text == "↑ Walk to the exit")
        #expect(banner(bare, facingHeading: 40)?.text == "← Turn left 40° · walk to the exit")
    }

    /// `respond` — the find team walking in on a confirmed candidate.
    @Test func respondWording() {
        let respond = HubCommand.guideTurn(sector: "CANDIDATE", delta: 40, onTarget: false, text: nil,
                                           kind: "respond", distance: 6.3)
        #expect(banner(respond, facingHeading: 0)?.text == "Turn right 40° → · 6.3 m")
        #expect(banner(respond, facingHeading: 80)?.text == "← Turn left 40° · 6.3 m")
        #expect(banner(respond, facingHeading: 40)?.text == "↑ Candidate ahead · 6.3 m")
    }

    /// `.gravity` alignment has no true north, so a compass-referenced directive
    /// cannot be resolved. The banner used to read "Look the door · 137° NE" —
    /// a bearing invented from a number this phone cannot act on, phrased as an
    /// instruction. The web's wording says so instead.
    @Test func aCompassDirectiveSaysThePhoneCannotResolveIt() {
        let compass = HubCommand.guideCompass(kind: "look", sector: "the door", compass: 137,
                                              untilMs: 20_000)
        let cue = banner(compass, facingHeading: 0)
        #expect(cue?.text == "Face the door (no compass on this phone)")
        #expect(cue?.text.contains("137") == false, "a bearing this phone cannot resolve must not appear")
        #expect(cue?.text.contains("NE") == false)
    }

    /// JavaScript prints a hub distance of `6.0` as `6`. Matching the web's
    /// wording means matching that, or every whole-metre readout differs from
    /// the browser's by a trailing zero.
    @Test func wholeMetreDistancesPrintLikeJavaScript() {
        let go = HubCommand.guideHeading(kind: "go", sector: "stage", heading: 0, distance: 6,
                                         untilMs: 90_000)
        #expect(banner(go, facingHeading: 0)?.text == "↑ Walk to stage · 6 m")
        let half = HubCommand.guideHeading(kind: "go", sector: "stage", heading: 0, distance: 12.5,
                                           untilMs: 90_000)
        #expect(banner(half, facingHeading: 0)?.text == "↑ Walk to stage · 12.5 m")
    }

    // MARK: - Live recomputation

    /// The banner used to echo the hub's `text` field verbatim, so it showed a
    /// value frozen at the hub's last 200 ms tick: the operator turned, the
    /// arrow moved, and the words underneath still said to turn the other way.
    @Test func theBannerFollowsTheOperatorBetweenHubTicks() {
        var model = OverlayModel()
        // One guide, applied once. The hub says nothing else for the next second.
        model.apply(.guideTurn(sector: "B2", delta: 60, onTarget: false, text: "Turn right 60°",
                               kind: "search", distance: nil), heading: 0, now: 0)
        tick(&model, pose: facing(0), now: 0.05)
        #expect(model.state.banner?.text == "Turn right 60° →")
        tick(&model, pose: facing(30), now: 0.1)
        #expect(model.state.banner?.text == "Turn right 30° →",
                "the banner froze at the hub's wording instead of following the phone")
        tick(&model, pose: facing(60), now: 0.15)
        #expect(model.state.banner?.text == "Scanning B2…")
        tick(&model, pose: facing(90), now: 0.2)
        #expect(model.state.banner?.text == "← Turn left 30°", "overshot: the words must turn back too")
    }

    /// `guideHeading` hard-coded `onTarget: false`, so a `look` never went green
    /// and never said which way to turn — the two things the directive exists to
    /// tell the operator.
    @Test func aLookDirectiveGoesGreenWhenTheOperatorArrives() {
        var model = OverlayModel()
        model.apply(.guideHeading(kind: "look", sector: "the door", heading: 90, distance: nil,
                                  untilMs: 20_000), heading: nil, now: 0)
        tick(&model, pose: facing(0), now: 0.1)
        #expect(model.state.banner?.onTarget == false)
        #expect(model.state.banner?.tone == "warn")
        tick(&model, pose: facing(88), now: 0.2)
        #expect(model.state.banner?.onTarget == true)
        #expect(model.state.banner?.tone == "ok", "a look that never greens never tells you you arrived")
    }

    // MARK: - Tone

    /// The web's rules, which are not "green when on target".
    @Test func toneFollowsTheWebsRulesNotJustTheOffset() {
        // respond: always the loud one, arrived or not.
        let respond = HubCommand.guideTurn(sector: "CANDIDATE", delta: 0, onTarget: false, text: nil,
                                           kind: "respond", distance: 2)
        #expect(banner(respond, facingHeading: 0)?.tone == "alert")

        // go: never green. Pointed the right way is not the same as arrived, and
        // the hub sends its own "You're there ✓" flash when it is.
        let go = HubCommand.guideHeading(kind: "go", sector: "back row", heading: 0, distance: 9,
                                         untilMs: 90_000)
        let arrivedCue = banner(go, facingHeading: 0)
        #expect(arrivedCue?.onTarget == true)
        #expect(arrivedCue?.tone == "warn")

        // search: green only when on target *and* the phone is up.
        let search = HubCommand.guideTurn(sector: "B2", delta: 0, onTarget: false, text: nil,
                                          kind: "search", distance: nil)
        #expect(banner(search, facingHeading: 0)?.tone == "ok")
        #expect(banner(search, facingHeading: 0, pitch: 70)?.tone == "warn")
    }

    // MARK: - One threshold, not three

    /// The arrow, the banner and the console's marker colour each decided "on
    /// target" for themselves: 0.35 rad (20.05°) in `ArrowCue`, 16° in
    /// `HUDMirror`, and `half_fov * 0.6` (16.5° at `cameraFovDeg: 55`) in the
    /// hub. Between 16° and 20.05° the arrow claimed the operator had arrived
    /// while the banner still told them to turn, and nothing on screen said
    /// which was right.
    @Test func theArrowAndTheBannerAgreeAboutOnTarget() {
        for offset in stride(from: -40.0, through: 40.0, by: 0.5) {
            var model = OverlayModel()
            model.apply(.guideTurn(sector: "B2", delta: offset, onTarget: false, text: nil,
                                   kind: "search", distance: nil), heading: 0, now: 0)
            tick(&model, pose: facing(0), now: 0.1)
            guard let arrow = model.state.arrow, let cue = model.state.banner else {
                Issue.record("no cue at offset \(offset)")
                return
            }
            #expect(arrow.isOnTarget == cue.onTarget,
                    "arrow and banner disagreed at \(offset)°: arrow \(arrow.isOnTarget), banner \(cue.onTarget)")
        }
    }

    /// 16° is the web's number and already what the console is told; it is also
    /// within half a degree of the hub's own `half_fov * 0.6`. Pinned so a later
    /// change has to be deliberate.
    @Test func theSharedThresholdIsTheWebClientsSixteenDegrees() {
        #expect(GuideThresholds.onTargetDegrees == 16)
        #expect(GuideThresholds.tiltedPitchDegrees == 65)
        #expect(ArrowCue(bearingRadians: Float(15.9 * .pi / 180)).isOnTarget)
        #expect(!ArrowCue(bearingRadians: Float(16.1 * .pi / 180)).isOnTarget)
        #expect(ArrowCue(bearingRadians: Float(-15.9 * .pi / 180)).isOnTarget)
        #expect(!ArrowCue(bearingRadians: Float(-16.1 * .pi / 180)).isOnTarget)
    }

    // MARK: - No heading

    /// Without a room heading there is no offset to recompute from, so no line
    /// may claim a direction. The hub's own `text` is one tick stale but true;
    /// for the directives that carry no text, the banner falls back to naming
    /// what was asked for and nothing else.
    @Test func withoutAHeadingNothingClaimsADirection() {
        var model = OverlayModel()
        model.apply(.guideTurn(sector: "B2", delta: 37, onTarget: false, text: "Turn left 37°",
                               kind: "search", distance: nil), heading: 10, now: 0)
        tick(&model, pose: facing(0), now: 0.1, alignment: nil)
        #expect(model.state.arrow == nil, "an arrow with no heading points at nothing")
        #expect(model.state.banner?.text == "Turn left 37°")

        // `look` and `go` carry no `text`: name the target, say nothing about
        // turning. Blanking them instead would blink the directive off and back
        // on through a one-second tracking hiccup, which reads as a cancel.
        var look = OverlayModel()
        look.apply(.guideHeading(kind: "look", sector: "the door", heading: 90, distance: nil,
                                 untilMs: 20_000), heading: nil, now: 0)
        tick(&look, pose: facing(0), now: 0.1, alignment: nil)
        #expect(look.state.banner?.text == "Face the door")

        var go = OverlayModel()
        go.apply(.guideHeading(kind: "go", sector: "back row", heading: 90, distance: 9.4,
                               untilMs: 90_000), heading: nil, now: 0)
        tick(&go, pose: facing(0), now: 0.1, alignment: nil)
        let text = try? #require(go.state.banner?.text)
        #expect(text == "Walk to back row · 9.4 m")
        for glyph in ["←", "→", "↑", "right", "left"] {
            #expect(text?.contains(glyph) == false, "claimed a direction it cannot know: \(glyph)")
        }
    }
}
