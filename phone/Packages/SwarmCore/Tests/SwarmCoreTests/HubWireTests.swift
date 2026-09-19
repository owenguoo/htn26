import Foundation
import Testing
@testable import SwarmCore

@Suite("Hub wire: what the htn26 hub actually speaks")
struct HubWireTests {
    private func message(_ name: String) throws -> HubInbound? {
        HubInbound.decode(try Data(contentsOf: Fixtures.url("hub-messages/\(name).json")))
    }

    private func object(_ frame: SocketFrame) throws -> [String: Any] {
        guard case .text(let text) = frame else {
            Issue.record("expected a text frame")
            return [:]
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: Framing

    @Test func goldenFramePackedByTheHubUnpacksHere() throws {
        let b64 = try String(contentsOf: Fixtures.url("hub-frame-golden.b64"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buffer = try #require(Data(base64Encoded: b64))
        let (headerJSON, jpeg) = try HubFrame.unpack(buffer)
        let header = try JSONDecoder().decode(HubFrameHeader.self, from: headerJSON)
        #expect(header.type == "frame")
        #expect(header.seq == 7)
        #expect(header.tCapture == 1789834632484.5)
        #expect(header.heading == 90)
        #expect(header.pitch == -3.5)
        #expect(header.calibrated)
        #expect(jpeg.count == 22)
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(jpeg.suffix(2) == Data([0xFF, 0xD9]))
    }

    @Test func packIsBigEndianLengthThenJSONThenJPEG() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let header = HubFrameHeader(seq: 1, tCapture: 1000, heading: nil, pitch: 2, calibrated: false)
        let packed = try HubFrame.pack(header: header, jpeg: jpeg)
        let length = packed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(packed.count == 4 + length + jpeg.count)
        let (json, payload) = try HubFrame.unpack(packed)
        #expect(json.count == length)
        #expect(payload == jpeg)
        #expect(try JSONDecoder().decode(HubFrameHeader.self, from: json) == header)
    }

    @Test func unpackSurvivesASlicedBuffer() throws {
        let packed = try HubFrame.pack(headerJSON: Data("{}".utf8), payload: Data([9, 9]))
        let padded = Data([0, 0, 0]) + packed
        let (json, payload) = try HubFrame.unpack(padded.dropFirst(3))
        #expect(json == Data("{}".utf8))
        #expect(payload == Data([9, 9]))
    }

    @Test func truncatedFramesThrowRatherThanCrash() {
        #expect(throws: HubWireError.truncatedFrame) { try HubFrame.unpack(Data([0, 0])) }
        #expect(throws: HubWireError.truncatedFrame) { try HubFrame.unpack(Data([0, 0, 0, 9, 1])) }
    }

    // MARK: Outbound

    @Test func helloIsTextAndCarriesWhatRegisterReads() throws {
        let hello = HubHello(phoneId: "p-1", name: "Dawson", seat: HubSeat(x: 1, y: 2), build: "ios-1")
        let o = try object(HubOutbound.hello(hello).encoded())
        #expect(o["type"] as? String == "hello")
        #expect(o["phoneId"] as? String == "p-1")
        #expect(o["name"] as? String == "Dawson")
        #expect((o["ua"] as? String)?.contains("iPhone") == true)
        #expect(o["sim"] as? Bool == false)
        #expect(o["build"] as? String == "ios-1")
        #expect((o["seat"] as? [String: Any])?["y"] as? Double == 2)
    }

    @Test func slamIsFlatRoomMetres() throws {
        let o = try object(HubOutbound.slam(x: 1.5, y: 6, heading: 270, pitch: -4).encoded())
        #expect(o["type"] as? String == "slam")
        #expect(o["x"] as? Double == 1.5)
        #expect(o["y"] as? Double == 6)
        #expect(o["heading"] as? Double == 270)
        #expect(o["pitch"] as? Double == -4)
    }

    @Test func pongEchoesTheHubTimestampExactly() throws {
        guard case .ping(let ts)? = try message("ping") else {
            Issue.record("ping did not decode")
            return
        }
        #expect(ts == 1789834632484.4612)
        let o = try object(HubOutbound.pong(ts: ts, tp: 5).encoded())
        #expect(o["ts"] as? Double == 1789834632484.4612)
        #expect(o["tp"] as? Double == 5)
    }

    @Test func debugIsFlattenedNextToType() throws {
        let debug = HubDebug(session: "tracking", venuePosition: [1, 1.5, 2], venueQuaternion: [0, 0, 0, 1],
                             trackingState: "normal", confidence: 0.9, correctionAgeS: 2,
                             correctionMarker: "marker-primary", stale: false, alignment: "marker",
                             thermal: "nominal", frameFPS: 2,
                             transport: .init(state: "connected", sent: 4, dropped: 0, reconnects: 0),
                             latency: .init(p50Ms: 40, p95Ms: 70, overBudget: 0),
                             lastCommand: .init(cmd: "flash", ageMs: 120))
        let o = try object(HubOutbound.debug(debug).encoded())
        #expect(o["type"] as? String == "debug")
        #expect(o["alignment"] as? String == "marker")
        #expect((o["lastCommand"] as? [String: Any])?["cmd"] as? String == "flash")
        #expect((o["venuePosition"] as? [Double])?.count == 3)
    }

    @Test func onlyFramesAreBinaryAndOnlyPerishablesAreDroppable() throws {
        let header = HubFrameHeader(seq: 1, tCapture: 0, heading: nil, pitch: nil, calibrated: false)
        guard case .binary = try HubOutbound.frame(header, jpeg: Data([1])).encoded() else {
            Issue.record("frame must be binary")
            return
        }
        #expect(HubOutbound.hello(HubHello(phoneId: "a", name: "")).lane == .control)
        #expect(HubOutbound.pong(ts: 0, tp: 0).lane == .control)
        #expect(HubOutbound.seat(HubSeat(x: 0, y: 0)).lane == .control)
        #expect(HubOutbound.name("x").lane == .control)
        #expect(HubOutbound.slam(x: 0, y: 0, heading: nil, pitch: nil).lane == .slam)
        #expect(HubOutbound.orient(heading: nil, pitch: nil, calibrated: false, tCapture: 0).lane == .slam)
        #expect(HubOutbound.frame(header, jpeg: Data()).lane == .frame)
    }

    // MARK: Inbound

    @Test func welcomeCarriesIdentityAndRoom() throws {
        guard case .welcome(let w)? = try message("welcome") else {
            Issue.record("welcome did not decode")
            return
        }
        #expect(w.index == 3)
        #expect(w.color == "#b8f35a")
        #expect(w.room?.width == 20)
        #expect(w.room?.stage?.depth == 2.5)
        #expect(w.phase == "search")
    }

    @Test func worldToleratesNullsAndFieldsFromTheFuture() throws {
        guard case .world(let world)? = try message("world") else {
            Issue.record("world did not decode")
            return
        }
        #expect(world.phones?.count == 2)
        #expect(world.phones?[1].h == nil)
        #expect(world.coverage?.cells == "0110")
        #expect(world.candidate == nil)
        #expect(world.pings?.first?.id == 1)
        #expect(world.stats?.rank == 1)
    }

    @Test func phaseDecodes() throws {
        #expect(try message("phase") == .phase("calibrate"))
    }

    @Test func everyGuideVariant() throws {
        #expect(try message("cmd-guide-clear") == .command(.guideClear))
        #expect(try message("cmd-guide-turn") == .command(
            .guideTurn(sector: "B2", delta: -42.5, onTarget: false, text: "Turn left 42°",
                       kind: "search", distance: nil)))
        #expect(try message("cmd-guide-respond") == .command(
            .guideTurn(sector: "CANDIDATE", delta: 12, onTarget: false, text: nil,
                       kind: "respond", distance: 4.2)))
        #expect(try message("cmd-guide-heading") == .command(
            .guideHeading(kind: "go", sector: "door", heading: 135, distance: 6.1, untilMs: 90_000)))
        #expect(try message("cmd-guide-compass") == .command(
            .guideCompass(kind: "look", sector: "north", compass: 10, untilMs: 20_000)))
    }

    @Test func theOtherCommandsWithPhoneJSDefaults() throws {
        #expect(try message("cmd-flash") == .command(
            .flash(color: "#7ae582", text: "You're there ✓", ttlMs: 1500)))
        #expect(try message("cmd-flash-bare") == .command(.flash(color: nil, text: nil, ttlMs: 1500)))
        #expect(try message("cmd-rate") == .command(.rate(fps: 8)))
        #expect(try message("cmd-rate-reset") == .command(.rate(fps: nil)))
        #expect(try message("cmd-ping") == .command(
            .ping(id: 5, x: 1, y: 2, label: "Check here", ttlMs: 12_000)))
        #expect(try message("cmd-message") == .command(.message(text: "Spread out", ttlMs: 8000)))
        #expect(try message("cmd-hud") == .command(.hud(on: true)))
        guard case .command(.detections(let detections))? = try message("cmd-detections") else {
            Issue.record("detections did not decode")
            return
        }
        #expect(detections.ttlMs == 1500)
        #expect(detections.boxes.count == 2)
        #expect(detections.boxes[0].label == "backpack")
        #expect(detections.boxes[1].label == nil)
        #expect(!detections.isRehearsal)
    }

    // MARK: Detections — the shapes `swarm/` really emits

    /// Verbatim from `hub.py:992`: `{'type':'command','cmd':'detections',
    /// **DetectionResult.model_dump(), 'threshold':…, 'ttlMs':1500}`, with the
    /// boxes shaped by `detection.py` `Box`.
    private static let realDetections = """
    {"type":"command","cmd":"detections","phoneId":"abc","streamId":"abc-7","seq":41,\
    "t":1789834632484.5,"searchRevision":"rev-3","targetVersion":"tv-2","width":720,"height":960,\
    "boxes":[{"x":0.1,"y":0.2,"w":0.3,"h":0.4,"label":"person","detectionScore":0.87,"similarity":0.42},\
    {"x":0.5,"y":0.05,"w":0.2,"h":0.6,"label":"person","detectionScore":0.55,"similarity":-0.31}],\
    "queueMs":12.5,"inferenceMs":88.0,"matchingMs":4.25,"threshold":0.35,"ttlMs":1500}
    """

    /// `hub.py:428`. No `threshold`, no frame size, no timings — and a different
    /// `cmd` string for what the phone draws identically.
    private static let realRehearsalDetections = """
    {"type":"command","cmd":"rehearsal_detections",\
    "boxes":[{"x":0.25,"y":0.3,"w":0.2,"h":0.5,"label":"person","detectionScore":0.62,"similarity":0.11}],\
    "streamId":"abc-7","seq":41,"searchRevision":"rev-3","ttlMs":1500}
    """

    /// The hub spells a box's confidence `detectionScore` and its match
    /// `similarity` (`swarm/detection.py` `Box`). This type spelled the first one
    /// `score`, so every box decoded with a nil confidence and the overlay drew a
    /// bare "person" tag with nothing to grade it by.
    @Test func aRealDetectionCarriesDetectionScoreAndSimilarity() throws {
        guard case .command(.detections(let d))? = HubInbound.decode(Data(Self.realDetections.utf8)) else {
            Issue.record("the hub's own detections shape did not decode")
            return
        }
        #expect(d.boxes.count == 2)
        #expect(d.boxes[0].detectionScore == 0.87)
        #expect(d.boxes[0].similarity == 0.42)
        #expect(d.boxes[0].confidence == 0.87)
        #expect(d.boxes[0].label == "person")
        // Negative similarity is legal (`Field(ge=-1)`): it is a person who is
        // definitely not the one being looked for.
        #expect(d.boxes[1].similarity == -0.31)
        #expect(d.threshold == 0.35)
        #expect(d.ttlMs == 1500)
        #expect(!d.isRehearsal)
    }

    /// The freshness keys `web/inference-ui.js` `acceptDetection` gates on. No
    /// gate exists on this side yet; decoding them is what lets one be added
    /// without changing the wire type again.
    @Test func aRealDetectionCarriesTheFreshnessKeys() throws {
        guard case .command(.detections(let d))? = HubInbound.decode(Data(Self.realDetections.utf8)) else {
            Issue.record("the hub's own detections shape did not decode")
            return
        }
        #expect(d.streamId == "abc-7")
        #expect(d.seq == 41)
        #expect(d.searchRevision == "rev-3")
    }

    /// `rehearsal_detections` used to fall through to `.unknown` and its boxes
    /// were dropped silently — the phone showed nothing during a rehearsal and
    /// there was no error to notice.
    @Test func rehearsalDetectionsAreDrawnNotDropped() throws {
        let decoded = HubInbound.decode(Data(Self.realRehearsalDetections.utf8))
        guard case .command(let command)? = decoded else {
            Issue.record("rehearsal_detections did not decode: \(String(describing: decoded))")
            return
        }
        guard case .detections(let d) = command else {
            Issue.record("rehearsal_detections decoded as \(command), not detections")
            return
        }
        #expect(d.isRehearsal)
        #expect(d.boxes.count == 1)
        #expect(d.boxes[0].detectionScore == 0.62)
        #expect(d.boxes[0].similarity == 0.11)
        #expect(d.threshold == nil, "the rehearsal path sends no threshold")
        #expect(d.streamId == "abc-7")
        // `debug.lastCommand` must report the cmd the hub actually sent, or the
        // console's tooltip says the phone got something it never got.
        #expect(command.name == "rehearsal_detections")
    }

    /// `hub.py` `clear_detection_overlays`: empty boxes, a `clear` flag this
    /// client has no use for, and a zero TTL so the overlay goes on the next tick.
    @Test func theDetectionClearMessageDecodesToNoBoxesAndNoLifetime() throws {
        let json = #"{"type":"command","cmd":"detections","boxes":[],"searchRevision":"rev-3","clear":true,"ttlMs":0}"#
        guard case .command(.detections(let d))? = HubInbound.decode(Data(json.utf8)) else {
            Issue.record("the clear message did not decode")
            return
        }
        #expect(d.boxes.isEmpty)
        #expect(d.ttlMs == 0)
        #expect(d.searchRevision == "rev-3")
    }

    /// Detections ride back out to the console in `HubHUDMirror.dets`, so the
    /// box has to survive a decode-then-encode without losing what grades it.
    @Test func aBoxRoundTripsThroughTheConsoleMirrorWithoutLosingItsScores() throws {
        guard case .command(.detections(let d))? = HubInbound.decode(Data(Self.realDetections.utf8)) else {
            Issue.record("the hub's own detections shape did not decode")
            return
        }
        let encoded = try HubWire.makeEncoder().encode(d.boxes[0])
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["detectionScore"] as? Double == 0.87)
        #expect(object["similarity"] as? Double == 0.42)
        #expect(object["label"] as? String == "person")
        // Nothing sent it, so nothing should appear: a null `score` would have
        // the console believing the hub speaks a field it does not.
        #expect(object["score"] == nil)
        #expect(try JSONDecoder().decode(HubDetectionBox.self, from: encoded) == d.boxes[0])
    }

    /// Everything else `DetectionResult.model_dump()` splats in — `phoneId`,
    /// `targetVersion`, `queueMs` — must stay non-fatal.
    @Test func theFieldsThisClientDoesNotUseAreIgnoredNotFatal() throws {
        guard case .command(.detections(let d))? = HubInbound.decode(Data(Self.realDetections.utf8)) else {
            Issue.record("the hub's own detections shape did not decode")
            return
        }
        #expect(d.boxes.count == 2, "an unknown sibling field must not cost us the boxes")
    }

    /// `hub.py:845` puts `streamId` in every `welcome`, and it changes on every
    /// reconnect. A freshness gate has nothing to compare against without it.
    @Test func welcomeCarriesTheStreamIdAFreshnessGateNeeds() throws {
        // Doubled delimiter: the colour literal contains `"#`, which would close
        // a single-`#` raw string mid-JSON.
        let json = ##"{"type":"welcome","phoneId":"abc","index":3,"streamId":"abc-7","color":"#b8f35a","room":{"width":20,"depth":15},"phase":"search"}"##
        guard case .welcome(let w)? = HubInbound.decode(Data(json.utf8)) else {
            Issue.record("welcome did not decode")
            return
        }
        #expect(w.streamId == "abc-7")
        #expect(w.index == 3)
    }

    /// The fixture predates `streamId`, and an older hub omits it. Optional, so
    /// a welcome without one still registers the phone.
    @Test func aWelcomeWithoutAStreamIdStillWorks() throws {
        guard case .welcome(let w)? = try message("welcome") else {
            Issue.record("welcome did not decode")
            return
        }
        #expect(w.streamId == nil)
        #expect(w.room?.width == 20)
    }

    @Test func unknownThingsAreIgnoredNotErrors() throws {
        #expect(try message("cmd-unknown") == .command(.unknown(cmd: "teleport")))
        #expect(try message("unknown-type") == .unknown(type: "weather"))
        #expect(HubInbound.decode(Data("not json".utf8)) == nil)
        #expect(HubInbound.decode(Data("[1,2]".utf8)) == nil)
        #expect(HubInbound.decode(Data(#"{"type":"welcome"}"#.utf8)) == .unknown(type: "welcome"))
    }

    @Test func commandNamesMatchTheHubsCmdStrings() {
        #expect(HubCommand.guideClear.name == "guide")
        #expect(HubCommand.flash(color: nil, text: nil, ttlMs: 1).name == "flash")
        #expect(HubCommand.rate(fps: nil).name == "rate")
    }
}
