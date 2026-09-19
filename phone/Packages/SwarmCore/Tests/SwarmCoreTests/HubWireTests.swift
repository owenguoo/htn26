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
        guard case .command(.detections(let boxes, let ttl, _))? = try message("cmd-detections") else {
            Issue.record("detections did not decode")
            return
        }
        #expect(ttl == 1500)
        #expect(boxes.count == 2)
        #expect(boxes[0].label == "backpack")
        #expect(boxes[1].label == nil)
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
