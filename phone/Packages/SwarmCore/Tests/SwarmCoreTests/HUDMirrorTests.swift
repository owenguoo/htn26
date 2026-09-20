import Foundation
import simd
import Testing
@testable import SwarmCore

/// The console draws whatever this says over the live feed (`web/console.js`
/// `drawHud`), so the shape and the coordinate conventions are the contract.
@Suite("HUD mirror for the operator console")
struct HUDMirrorTests {
    private func overlay(_ configure: (inout OverlayModel) -> Void, heading: Double = 90,
                         intrinsics: CameraIntrinsics? = Sample.intrinsics()) -> OverlayState {
        var model = OverlayModel()
        configure(&model)
        var diagnostics = SessionDiagnostics()
        diagnostics.state = .tracking
        diagnostics.quality = .normal
        // ARKit reports the camera in *sensor* orientation: for a phone held
        // upright, camera +X points down the device and +Y to its right. That
        // quarter roll is what the encoder's rotate-to-portrait undoes, so a
        // test without it would be checking a landscape phone.
        let portrait = simd_quatf(angle: -.pi / 2, axis: [0, 0, 1])
        let pose = Pose(position: [0, 1.5, 5],
                        orientation: simd_quatf(angle: -Float(heading * .pi / 180), axis: [0, 1, 0]) * portrait)
        model.update(pose: pose, alignment: .identity, source: .marker, intrinsics: intrinsics,
                     diagnostics: diagnostics, transport: .init(), transportState: .connected, now: 1)
        return model.state
    }

    private func mirror(_ state: OverlayState) -> HubHUDMirror {
        HUDMirror.make(from: state, captureWidth: 1_920, captureHeight: 1_440, screenAspect: 393.0 / 852.0)
    }

    @Test func aGuideBecomesACompassMarkerAndAToneTaggedBanner() throws {
        let state = overlay { model in
            model.apply(.guideTurn(sector: "b2", delta: 40, onTarget: false, text: "Turn right 40°",
                                   kind: "search", distance: nil), heading: 90, now: 0)
        }
        let hud = mirror(state)
        let compass = try #require(hud.compass)
        #expect(isClose(compass.center, 90, within: 1e-3))
        #expect(!compass.abs, "ARKit runs .gravity: this is a room heading, never true north")
        // Same set and order as drawCompass in phone.js: STAGE first, then the guide.
        let stage = try #require(compass.markers.first)
        #expect(stage.label == "STAGE" && isClose(stage.off, -90, within: 1e-3),
                "facing heading 90, the stage (heading 0) is 90° to the left")
        let marker = try #require(compass.markers.first { $0.big })
        #expect(isClose(marker.off, 40, within: 1e-2))
        #expect(marker.label == "b2", "the hub's own sector text, untouched")
        #expect(marker.color == HUDMirror.turnColor)
        // Recomputed from the live pose, not echoed from the hub's `text`.
        #expect(hud.banner == .init(text: "Turn right 40° →", tone: "warn"))
    }

    @Test func aDirectionalSoundBecomesARoomAnchoredAlert() throws {
        var model = OverlayModel()
        model.hearDirectionalSound(.init(relativeBearingDegrees: -90, confidence: 0.8),
                                   heading: 90, now: 0)
        var diagnostics = SessionDiagnostics()
        diagnostics.state = .tracking
        diagnostics.quality = .normal
        let portrait = simd_quatf(angle: -.pi / 2, axis: [0, 0, 1])
        let pose = Pose(position: [0, 1.5, 5],
                        orientation: simd_quatf(angle: -Float(100 * Double.pi / 180), axis: [0, 1, 0]) * portrait)
        model.update(pose: pose, alignment: .identity, source: .marker, intrinsics: Sample.intrinsics(),
                     diagnostics: diagnostics, transport: .init(), transportState: .connected, now: 0.5)

        let hud = mirror(model.state)
        let sound = try #require(hud.compass?.markers.first { $0.label == "SOUND" })
        #expect(isClose(sound.off, -100, within: 0.1),
                "the event stays at room heading 0 while the phone turns to 100")
        #expect(sound.color == HUDMirror.soundColor)
        #expect(hud.banner == .init(text: "Sound heard · left", tone: "alert"))
        #expect(hud.soundEdge?.side == "left")
        let onWire = DeliveredMessage(try HubOutbound.hud(hud).encoded())
        #expect((onWire.json["soundEdge"] as? [String: Any])?["side"] as? String == "left")
    }

    @Test func aDirectionalSoundExpires() {
        var model = OverlayModel()
        model.hearDirectionalSound(.init(relativeBearingDegrees: 70, confidence: 0.7),
                                   heading: 10, now: 0)
        var diagnostics = SessionDiagnostics()
        diagnostics.state = .tracking
        diagnostics.quality = .normal
        model.update(pose: nil, alignment: nil, source: .none, intrinsics: nil,
                     diagnostics: diagnostics, transport: .init(), transportState: .connected, now: 2.1)
        #expect(model.state.directionalSound == nil)
    }

    @Test func tonesMatchTheConsolesThreePills() {
        let ok = overlay { $0.apply(.guideTurn(sector: "A1", delta: 2, onTarget: true, text: "Scanning A1…",
                                               kind: "search", distance: nil), heading: 90, now: 0) }
        #expect(mirror(ok).banner?.tone == "ok")
        let alert = overlay { $0.apply(.guideTurn(sector: "CANDIDATE", delta: 10, onTarget: false, text: nil,
                                                  kind: "respond", distance: 4), heading: 90, now: 0) }
        #expect(mirror(alert).banner?.tone == "alert")
        let candidate = mirror(alert).compass?.markers.first { $0.big }
        #expect(candidate?.color == HUDMirror.alertColor)
        #expect(candidate?.label == "FIND 4m")
        // Within 16° of the target the marker goes green, as on the web phone.
        #expect(mirror(ok).compass?.markers.first { $0.big }?.color == HUDMirror.onTargetColor)
        let look = overlay { $0.apply(.guideHeading(kind: "look", sector: "door", heading: 200, distance: nil,
                                                    untilMs: 20_000), heading: nil, now: 0) }
        #expect(mirror(look).compass?.markers.first { $0.big }?.color == HUDMirror.directedColor)
    }

    /// A ping dead ahead on the floor: centre of the frame horizontally, below
    /// the horizon. If the landscape→upright rotation were wrong this lands on
    /// a side edge instead.
    @Test func aPingInViewLandsInUprightFrameFractions() throws {
        let state = overlay({ $0.apply(.ping(id: 1, x: 3, y: 5, label: "Check here", ttlMs: 12_000),
                                       heading: nil, now: 0) }, heading: 90)
        let hud = mirror(state)
        let marker = try #require(hud.ar.first)
        #expect(isClose(marker.x, 0.5, within: 0.01))
        #expect(marker.y > 0.5 && marker.y < 1)
        #expect(marker.label == "Check here · 3.0 m")
        #expect(hud.compass?.markers.contains { $0.label == "◆ Check here 3m" && abs($0.off) < 0.5 } == true)
        #expect(marker.color == HUDMirror.pingColor)
    }

    /// The alignment marker rides the ping channel (`hub.py` `marker_cue`) but
    /// it is not one of the operator's pings: it is the fixed thing in the room
    /// the map already draws in `MARKER_COLOR`, so the compass chip and the AR
    /// diamond wear that colour too rather than ping yellow.
    @Test func theAlignmentMarkerKeepsItsMapColourOnTheCompass() throws {
        let state = overlay({ $0.apply(.ping(id: 0, x: 3, y: 5, label: "MARKER", ttlMs: 12_000),
                                       heading: nil, now: 0) }, heading: 90)
        let hud = mirror(state)
        let chip = try #require(hud.compass?.markers.first { $0.label.hasPrefix("◆ MARKER") })
        #expect(chip.color == HUDMirror.markerColor)
        #expect(hud.ar.first?.color == HUDMirror.markerColor)
        #expect(HUDMirror.markerColor != HUDMirror.pingColor)
    }

    @Test func aPingBehindIsOnTheCompassButNotInTheARLayer() {
        let state = overlay({ $0.apply(.ping(id: 1, x: -3, y: 5, label: "Back", ttlMs: 12_000),
                                       heading: nil, now: 0) }, heading: 90)
        let hud = mirror(state)
        #expect(hud.ar.isEmpty)
        let ping = hud.compass?.markers.first { $0.label.hasPrefix("◆") }
        #expect(isClose(abs(ping?.off ?? 0), 180, within: 1e-3))
    }

    @Test func aTallPhoneShowsTheCentreStripOfA3By4Frame() throws {
        let screen = try #require(HUDMirror.visibleFrame(captureWidth: 1_920, captureHeight: 1_440,
                                                         screenAspect: 393.0 / 852.0))
        #expect(screen.count == 4)
        #expect(screen[1] == 0 && screen[3] == 1, "full height is visible")
        #expect(isClose(screen[0] + screen[2], 1, within: 1e-9), "cropped equally both sides")
        #expect(isClose(screen[2] - screen[0], (393.0 / 852.0) / 0.75, within: 1e-9))
        // A screen squatter than the frame crops top and bottom instead.
        let squat = try #require(HUDMirror.visibleFrame(captureWidth: 1_920, captureHeight: 1_440, screenAspect: 1))
        #expect(squat[0] == 0 && squat[2] == 1 && squat[1] > 0)
    }

    @Test func toastDetectionsCardAndLookingForFollowTheOverlay() throws {
        guard case .world(var world)? = HubInbound.decode(
            try Data(contentsOf: Fixtures.url("hub-messages/world.json"))) else { return }
        world.pings = []
        let searching = overlay { model in
            model.apply(world, now: 0)
            model.apply(.message(text: "Spread out", ttlMs: 8000), heading: nil, now: 0)
            model.apply(.detections(
                boxes: [HubDetectionBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4, label: "bag")], ttlMs: 1500),
                        heading: nil, now: 0)
        }
        let hud = mirror(searching)
        #expect(hud.toast == "📣 Spread out", "prefixed exactly as phone.js shows it")
        #expect(hud.dets?.first?.label == "bag")
        #expect(hud.lookingFor == "red backpack")
        #expect(hud.card == nil)

        let lobby = overlay { model in
            model.apply(world, now: 0)
            model.apply(phase: "lobby")
        }
        #expect(mirror(lobby).card?.title == "You're in")
        #expect(mirror(lobby).lookingFor == nil, "only shown while searching, as on the web phone")
    }

    @Test func onTheWireItIsAFlatTextHudMessageInItsOwnLane() throws {
        let state = overlay { $0.apply(.message(text: "hi", ttlMs: 8000), heading: nil, now: 0) }
        let message = HubOutbound.hud(mirror(state))
        #expect(message.lane == .hud)
        let onWire = DeliveredMessage(try message.encoded())
        #expect(!onWire.isBinary)
        #expect(onWire.type == "hud")
        #expect(onWire.json["toast"] as? String == "📣 hi")
        #expect((onWire.json["screen"] as? [Double])?.count == 4)
        #expect((onWire.json["compass"] as? [String: Any])?["abs"] as? Bool == false)
    }

    /// The hub's found candidate floats in the camera view and sits on the
    /// compass — unless the phone is already being steered to it, when the guide
    /// marker *is* the candidate and a second one would be noise.
    @Test func theCandidateIsShownOnceNotTwice() throws {
        guard case .world(var world)? = HubInbound.decode(
            try Data(contentsOf: Fixtures.url("hub-messages/world.json"))) else { return }
        world.pings = []
        world.candidate = .init(x: 3, y: 5)
        let idle = mirror(overlay { $0.apply(world, now: 0) })
        #expect(idle.compass?.markers.contains { $0.label == "FIND 3m" && $0.color == HUDMirror.alertColor } == true)
        #expect(idle.ar.contains { $0.label == "FIND · 3.0 m" })

        let responding = mirror(overlay { model in
            model.apply(world, now: 0)
            model.apply(.guideTurn(sector: "CANDIDATE", delta: 0, onTarget: false, text: nil, kind: "respond",
                                   distance: 3), heading: 90, now: 0)
        })
        #expect(responding.compass?.markers.filter { $0.label.hasPrefix("FIND") }.count == 1)
        #expect(responding.ar.contains { $0.label.hasPrefix("FIND") }, "still floats in the view")
        #expect(responding.soundEdge == nil, "on-target respond: no side bleed")

        let offLeft = mirror(overlay { model in
            model.apply(world, now: 0)
            model.apply(.guideTurn(sector: "CANDIDATE", delta: -45, onTarget: false, text: nil, kind: "respond",
                                   distance: 4), heading: 90, now: 0)
        })
        #expect(offLeft.soundEdge?.side == "left")
        #expect(offLeft.soundEdge?.color == HUDMirror.alertColor)
    }

    /// The phone draws its own HUD from the same value it sends the console.
    @Test func everyOverlayFrameCarriesTheMirrorItWouldSend() {
        let state = overlay { $0.apply(.message(text: "hi", ttlMs: 8000), heading: nil, now: 0) }
        let frame = OverlayFrame(overlay: state)
        #expect(frame.hud.toast == "📣 hi")
        #expect(frame.hud == mirror(state))
    }

    // MARK: - The team, the objective, the hazard and the scoreboard

    /// The helper places this phone at room (0, 5) facing heading 90, so a peer
    /// at (5, 5) is dead ahead and one at (0, 0) is 90° to the left.
    private func world(_ json: String) throws -> HubWorld {
        try JSONDecoder().decode(HubWorld.self, from: Data(json.utf8))
    }

    private func teamLabels(_ hud: HubHUDMirror) -> [String] {
        (hud.compass?.markers ?? []).filter { $0.label.hasPrefix("#") || $0.label.contains("▶")
            || $0.label.contains("◀") }.map(\.label)
    }

    @Test func teammatesBecomeChipsAndYouAreNotOneOfThem() throws {
        let peers = try world("""
        {"me": "a", "phones": [{"id": "a", "i": 1, "x": 0, "y": 5},
                               {"id": "b", "i": 4, "x": 5, "y": 5}]}
        """)
        let hud = mirror(overlay { $0.apply(peers, now: 0) })
        let chip = try #require((hud.compass?.markers ?? []).first { $0.label.hasPrefix("#") })
        #expect(chip.label == "#4 5m")
        #expect(isClose(chip.off, 0, within: 1e-3), "dead ahead of a phone facing heading 90")
        #expect(chip.color == HUDMirror.peerColor(index: 4), "the colour the console paints #4")
        #expect(!chip.big, "a teammate is context, never the instruction")
        #expect(teamLabels(hud).count == 1, "this phone does not get a chip pointing at itself")
    }

    @Test func aTeammateGetsAHollowDiamondSoTheyAreNeverAFind() throws {
        let peers = try world("""
        {"me": "a", "phones": [{"id": "b", "i": 2, "x": 5, "y": 5}]}
        """)
        let hud = mirror(overlay { $0.apply(peers, now: 0) })
        let diamond = try #require(hud.ar.first)
        #expect(diamond.hollow)
        #expect(diamond.label == "#2 · 5 m")
    }

    @Test func aTeammateStandingNextToYouNeedsNoDiamond() throws {
        let peers = try world("""
        {"me": "a", "phones": [{"id": "b", "i": 2, "x": 1, "y": 5}]}
        """)
        let hud = mirror(overlay { $0.apply(peers, now: 0) })
        #expect(hud.ar.isEmpty, "you can see somebody a metre away without help")
        #expect(teamLabels(hud).count == 1, "they still get a chip: the tape is cheap")
    }

    /// Two peers within `teamMergeDegrees` are one chip, and a crowd is capped.
    @Test func aCrowdedTapeMergesAndThenCaps() throws {
        // Six peers fanned across the front of a phone facing heading 90, plus
        // one squarely behind it.
        let peers = try world("""
        {"me": "a", "phones": [{"id": "b", "i": 2, "x": 5, "y": 5},
                               {"id": "c", "i": 3, "x": 5, "y": 5.2},
                               {"id": "d", "i": 4, "x": 5, "y": 3},
                               {"id": "e", "i": 5, "x": 5, "y": 7},
                               {"id": "f", "i": 6, "x": 4, "y": 2},
                               {"id": "g", "i": 7, "x": 4, "y": 8},
                               {"id": "h", "i": 8, "x": -6, "y": 5}]}
        """)
        let labels = teamLabels(mirror(overlay { $0.apply(peers, now: 0) }))
        #expect(labels.contains { $0.hasPrefix("#2#3") }, "two peers 2° apart are one chip")
        #expect(labels.contains { $0.contains("◀") || $0.contains("▶") },
                "the one behind is counted on an edge, never clamped onto the rail")
        #expect(labels.filter { $0.hasPrefix("#") }.count <= HUDMirror.teamTapeLimit)
    }

    @Test func beingWalkedToSomebodyStandsTheTeamDown() throws {
        let peers = try world("""
        {"me": "a", "phones": [{"id": "b", "i": 2, "x": 5, "y": 5}]}
        """)
        let hud = mirror(overlay { model in
            model.apply(peers, now: 0)
            model.apply(.guideTurn(sector: "PERSON 2", delta: 30, onTarget: false, text: nil,
                                   kind: "respond", distance: 12), heading: 90, now: 0)
        })
        #expect(teamLabels(hud).isEmpty)
        #expect(hud.ar.allSatisfy { !$0.hollow })
    }

    @Test func theObjectiveNamesWhoYouAreWalkingTo() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "PERSON 2", delta: 40, onTarget: false, text: nil,
                                   kind: "respond", distance: 24), heading: 90, now: 0)
        })
        #expect(hud.objective == .init(title: "Person 2", detail: "24 m · 40° right", tone: "alert"))
    }

    @Test func theObjectiveIsASweepWhenNobodyHasBeenFound() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "B3", delta: -12, onTarget: false, text: nil,
                                   kind: "search", distance: nil), heading: 90, now: 0)
        })
        #expect(hud.objective == .init(title: "Sweeping B3", detail: "12° left", tone: "warn"))
    }

    @Test func thereIsNoObjectiveWithNowhereToBeSent() {
        #expect(mirror(overlay { _ in }).objective == nil)
    }

    @Test func aHazardIsAmberOnTheTapeAndSaysWhichWayToStep() throws {
        let hazards = try world("""
        {"phase": "search", "hazards": [{"id": "chair", "x": 2, "y": 5, "stale": false}]}
        """)
        let hud = mirror(overlay { $0.apply(hazards, now: 0) })
        let chip = try #require((hud.compass?.markers ?? []).first { $0.label.hasPrefix("⚠") })
        #expect(chip.label == "⚠ 2m")
        #expect(chip.color == HUDMirror.hazardColor)
        #expect(hud.warning == .init(text: "Hazard 2 m ahead", color: HUDMirror.hazardColor))
        #expect(hud.soundEdge?.color == HUDMirror.hazardColor,
                "two metres away, the thing you are about to walk into owns the bezel")
    }

    @Test func aHazardYouAreAboutToHitOutranksTheFindYouAreRunningTo() throws {
        let hazards = try world("""
        {"phase": "search", "hazards": [{"id": "chair", "x": 1.5, "y": 5, "stale": false}]}
        """)
        let hud = mirror(overlay { model in
            model.apply(hazards, now: 0)
            model.apply(.guideTurn(sector: "PERSON 1", delta: 50, onTarget: false, text: nil,
                                   kind: "respond", distance: 9), heading: 90, now: 0)
        })
        #expect(hud.soundEdge?.color == HUDMirror.hazardColor)
        #expect(hud.objective?.tone == "alert", "the find is still the mission, still red")
    }

    @Test func aStaleHazardIsNotSteeredAround() throws {
        let hazards = try world("""
        {"phase": "search", "hazards": [{"id": "chair", "x": 2, "y": 5, "stale": true}]}
        """)
        #expect(mirror(overlay { $0.apply(hazards, now: 0) }).warning == nil)
    }

    @Test func theStatsLineIsWordedOnce() throws {
        let numbers = try world("""
        {"phase": "search", "searched": 0.46, "stats": {"m2": 142.4, "rank": 2, "of": 5}}
        """)
        #expect(mirror(overlay { $0.apply(numbers, now: 0) }).stats == "142 m² swept · 2nd of 5 · room 46%")
    }

    @Test func rankIsLeftOutWhenThereIsNobodyToBeAheadOf() throws {
        let alone = try world("""
        {"phase": "search", "searched": 0.1, "stats": {"m2": 20, "rank": 1, "of": 1}}
        """)
        #expect(mirror(overlay { $0.apply(alone, now: 0) }).stats == "20 m² swept · room 10%")
    }

    @Test(arguments: [(1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"),
                      (11, "11th"), (12, "12th"), (13, "13th"), (21, "21st")])
    func ordinalsSurviveTheTeens(_ n: Int, _ expected: String) {
        #expect(HUDMirror.ordinal(n) == expected)
    }

    @Test func theScoreboardStandsDownForAnythingLouder() throws {
        let numbers = try world("""
        {"phase": "search", "searched": 0.46, "stats": {"m2": 142.4, "rank": 2, "of": 5}}
        """)
        let shouted = mirror(overlay { model in
            model.apply(numbers, now: 0)
            model.apply(.message(text: "everyone to the back", ttlMs: 8000), heading: 90, now: 0)
        })
        #expect(shouted.stats == nil)
    }

    // MARK: - The wash that stays on

    /// A `respond` guide is the start of a find, and the screen says so until
    /// something ends it — not until a timer runs out.
    @Test func beingSentToSomebodyWashesTheScreenRedAndKeepsItThere() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "PERSON 1", delta: 20, onTarget: false, text: nil,
                                   kind: "respond", distance: 14), heading: 90, now: 0)
        })
        #expect(hud.ambient == .init(kind: "find", color: HUDMirror.alertColor, intensity: 0.85))
    }

    /// The hub clears a find team's guide when that phone reaches the person.
    /// The wash does not go with it — it settles.
    @Test func arrivingHoldsTheRedAndStopsThePulse() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "PERSON 1", delta: 20, onTarget: false, text: nil,
                                   kind: "respond", distance: 14), heading: 90, now: 0)
            model.apply(.guideClear, heading: 90, now: 1)
        })
        #expect(hud.ambient == .init(kind: "with", color: HUDMirror.alertColor, intensity: 0.45),
                "still red — the emergency did not end when they got there")
        #expect(hud.objective == nil, "the guide is gone, so there is nothing left to steer to")
    }

    @Test func clearingAGuideYouWereNeverOnDoesNotInventAFind() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "B3", delta: 20, onTarget: false, text: nil,
                                   kind: "search", distance: nil), heading: 90, now: 0)
            model.apply(.guideClear, heading: 90, now: 1)
        })
        #expect(hud.ambient == nil)
    }

    @Test func beingTakenOffAFindEndsTheWash() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "PERSON 1", delta: 20, onTarget: false, text: nil,
                                   kind: "respond", distance: 14), heading: 90, now: 0)
            model.apply(.guideTurn(sector: "C2", delta: -10, onTarget: false, text: nil,
                                   kind: "search", distance: nil), heading: 90, now: 1)
        })
        #expect(hud.ambient == nil)
    }

    @Test func theSearchEndingEndsTheWash() {
        let hud = mirror(overlay { model in
            model.apply(.guideTurn(sector: "PERSON 1", delta: 20, onTarget: false, text: nil,
                                   kind: "respond", distance: 14), heading: 90, now: 0)
            model.apply(phase: "end")
        })
        #expect(hud.ambient == nil)
    }

    @Test func aHazardYouAreAboutToHitTakesTheWholeScreenOffTheFind() throws {
        let hazards = try world("""
        {"phase": "search", "hazards": [{"id": "chair", "x": 1.5, "y": 5, "stale": false}]}
        """)
        let hud = mirror(overlay { model in
            model.apply(hazards, now: 0)
            model.apply(.guideTurn(sector: "PERSON 1", delta: 20, onTarget: false, text: nil,
                                   kind: "respond", distance: 14), heading: 90, now: 0)
        })
        #expect(hud.ambient?.kind == "hazard")
        #expect(hud.ambient?.color == HUDMirror.hazardColor)
    }

    @Test func thereIsNoScoreboardBeforeTheSearchStarts() throws {
        let numbers = try world("""
        {"phase": "lobby", "searched": 0.46, "stats": {"m2": 142.4, "rank": 2, "of": 5}}
        """)
        #expect(mirror(overlay { $0.apply(numbers, now: 0) }).stats == nil)
    }
}
