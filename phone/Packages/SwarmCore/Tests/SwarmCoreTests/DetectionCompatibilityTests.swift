import Foundation
import Testing
@testable import SwarmCore

@Suite("Current hub detection protocol")
struct DetectionCompatibilityTests {
    private func welcome(_ stream: String) throws -> HubWelcome {
        try JSONDecoder().decode(HubWelcome.self, from: Data("""
        {"phoneId":"phone","index":1,"color":"#ffffff","streamId":"\(stream)"}
        """.utf8))
    }

    private func command(seq: Int = 1, stream: String = "stream", revision: String = "revision",
                         rehearsal: Bool = false, clear: Bool = false) throws -> HubCommand {
        let data = Data("""
        {"type":"command","cmd":"\(rehearsal ? "rehearsal_detections" : "detections")",
        "streamId":"\(stream)","seq":\(seq),"searchRevision":"\(revision)","threshold":0.7,
        "clear":\(clear),"boxes":[{"x":0.1,"y":0.2,"w":0.3,"h":0.4,"label":"person",
        "detectionScore":0.92,"similarity":0.8}],"ttlMs":1500}
        """.utf8)
        guard case .command(let command)? = HubInbound.decode(data) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return command
    }

    @Test func scoresAndRehearsalRemainDistinct() throws {
        for rehearsal in [false, true] {
            var model = OverlayModel()
            model.apply(try welcome("stream"))
            model.recordDetectionCapture(seq: 1, at: 1)
            let cmd = try command(rehearsal: rehearsal)
            let applied = model.apply(cmd, heading: nil, now: 2)
            #expect(applied)
            let cue = try #require(model.state.detections)
            #expect(cue.rehearsal == rehearsal)
            #expect(cue.threshold == 0.7)
            #expect(cue.boxes[0].detectionScore == 0.92)
            #expect(cue.boxes[0].similarity == 0.8)
            #expect(cue.until == 2.5)
        }
    }

    @Test func rejectsWrongStreamUnknownFrameOldFrameAndOutOfOrderResults() throws {
        var model = OverlayModel()
        model.apply(try welcome("stream"))
        model.recordDetectionCapture(seq: 1, at: 1)
        model.recordDetectionCapture(seq: 2, at: 1)
        for cmd in [try command(stream: "old"), try command(seq: 3)] {
            let applied = model.apply(cmd, heading: nil, now: 2)
            #expect(!applied)
        }
        let accepted = model.apply(try command(seq: 2), heading: nil, now: 2)
        #expect(accepted)
        for cmd in [try command(seq: 1), try command(seq: 2)] {
            let applied = model.apply(cmd, heading: nil, now: 2)
            #expect(!applied)
        }
        model.recordDetectionCapture(seq: 3, at: 1)
        let stale = model.apply(try command(seq: 3), heading: nil, now: 2.5)
        #expect(!stale)
    }

    @Test func clearPinsRevisionAndReconnectClearsCaptureHistory() throws {
        var model = OverlayModel()
        model.apply(try welcome("stream"))
        model.recordDetectionCapture(seq: 1, at: 1)
        model.apply(try command(), heading: nil, now: 1)
        model.apply(try command(revision: "next", clear: true), heading: nil, now: 1)
        #expect(model.state.detections == nil)
        let oldRevision = model.apply(try command(), heading: nil, now: 1)
        #expect(!oldRevision)
        let next = model.apply(try command(revision: "next"), heading: nil, now: 1)
        #expect(next)
        model.apply(try welcome("stream2"))
        #expect(model.state.detections == nil)
        let missingCapture = model.apply(try command(stream: "stream2"), heading: nil, now: 1)
        #expect(!missingCapture)
    }
}
