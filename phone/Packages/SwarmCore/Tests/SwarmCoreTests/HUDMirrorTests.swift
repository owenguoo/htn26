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

    @Test func tonesMatchTheConsolesThreePills() {
        let ok = overlay { $0.apply(.guideTurn(sector: "A1", delta: 2, onTarget: true, text: "Scanning A1…",
                                               kind: "search", distance: nil), heading: 90, now: 0) }
        #expect(mirror(ok).banner?.tone == "ok")
        let alert = overlay { $0.apply(.guideTurn(sector: "CANDIDATE", delta: 10, onTarget: false, text: nil,
                                                  kind: "respond", distance: 4), heading: 90, now: 0) }
        #expect(mirror(alert).banner?.tone == "alert")
        let candidate = mirror(alert).compass?.markers.first { $0.big }
        #expect(candidate?.color == HUDMirror.alertColor)
        #expect(candidate?.label == "CANDIDATE 4.0m")
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
        #expect(idle.compass?.markers.contains { $0.label == "CANDIDATE 3m" && $0.color == HUDMirror.alertColor } == true)
        #expect(idle.ar.contains { $0.label == "CANDIDATE · 3.0 m" })

        let responding = mirror(overlay { model in
            model.apply(world, now: 0)
            model.apply(.guideTurn(sector: "CANDIDATE", delta: 0, onTarget: false, text: nil, kind: "respond",
                                   distance: 3), heading: 90, now: 0)
        })
        #expect(responding.compass?.markers.filter { $0.label.hasPrefix("CANDIDATE") }.count == 1)
        #expect(responding.ar.contains { $0.label.hasPrefix("CANDIDATE") }, "still floats in the view")
    }

    /// The phone draws its own HUD from the same value it sends the console.
    @Test func everyOverlayFrameCarriesTheMirrorItWouldSend() {
        let state = overlay { $0.apply(.message(text: "hi", ttlMs: 8000), heading: nil, now: 0) }
        let frame = OverlayFrame(overlay: state)
        #expect(frame.hud.toast == "📣 hi")
        #expect(frame.hud == mirror(state))
    }
}
