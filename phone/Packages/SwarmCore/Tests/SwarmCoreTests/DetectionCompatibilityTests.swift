import Foundation
import Testing
@testable import SwarmCore

@Suite("Current hub detection protocol")
struct DetectionCompatibilityTests {
    @Test func labelsUseAppearanceSimilarityRatherThanDetectionConfidence() {
        var box = HubDetectionBox(x: 0, y: 0, w: 1, h: 1, label: "person", detectionScore: 0.99, similarity: 0.726)
        #expect(box.displayLabel == "Person · 73% match")
        box.similarity = -0.2
        #expect(box.displayLabel == "Person · 0% match")
        box.similarity = nil
        #expect(box.displayLabel == "person")
        box.label = "Hazard"
        #expect(box.displayLabel == "Hazard")
    }

    private func welcome(_ stream: String) throws -> HubWelcome {
        try JSONDecoder().decode(HubWelcome.self, from: Data("""
        {"phoneId":"phone","index":1,"color":"#ffffff","streamId":"\(stream)"}
        """.utf8))
    }

    private func command(seq: Int = 1, stream: String = "stream", revision: String = "revision",
                         rehearsal: Bool = false, clear: Bool = false, hazard: Bool = false, similarity: Double = 0.8) throws -> HubCommand {
        let data = Data("""
        {"type":"command","cmd":"\(hazard ? "hazard_detections" : rehearsal ? "rehearsal_detections" : "detections")",
        "streamId":"\(stream)","seq":\(seq),"searchRevision":"\(revision)","threshold":0.7,
        "clear":\(clear),"boxes":[{"x":0.1,"y":0.2,"w":0.3,"h":0.4,"label":"person",
        "detectionScore":0.92,"similarity":\(similarity)}],"ttlMs":1500}
        """.utf8)
        guard case .command(let command)? = HubInbound.decode(data) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return command
    }

    @Test func matchFeedbackRequiresFreshConsecutiveResultsAndRespectsCooldown() throws {
        var model = OverlayModel()
        model.apply(try welcome("stream"))
        func deliver(_ seq: Int, _ time: Double, rehearsal: Bool = false) throws {
            model.recordDetectionCapture(seq: UInt64(seq), at: time)
            #expect(model.apply(try command(seq: seq, rehearsal: rehearsal), heading: nil, now: time))
        }
        try deliver(1, 1)
        #expect(model.state.detections?.boxes.first?.displayLabel == "Possible match · 80%")
        #expect(model.consumeHaptic() == nil)
        #expect(!model.apply(try command(seq: 1), heading: nil, now: 1.1))
        #expect(model.consumeHaptic() == nil)
        try deliver(2, 1.5)
        #expect(model.consumeHaptic()?.pattern == "possible_match")
        #expect(model.state.toast?.text == "Possible target found")
        try deliver(3, 2)
        #expect(model.consumeHaptic() == nil)
        try deliver(4, 12)
        #expect(model.consumeHaptic() == nil)
        try deliver(5, 12.5)
        #expect(model.consumeHaptic()?.pattern == "possible_match")
        try deliver(6, 23, rehearsal: true)
        try deliver(7, 23.5, rehearsal: true)
        #expect(model.state.detections?.boxes.first?.possibleMatch == false)
        #expect(model.consumeHaptic() == nil)
        try deliver(8, 24)
        #expect(model.consumeHaptic() == nil)
        model.apply(try command(clear: true), heading: nil, now: 24)
        try deliver(9, 24.5)
        #expect(model.consumeHaptic() == nil)
    }

    @Test func belowThresholdBreaksMatchStreak() throws {
        var model = OverlayModel()
        model.apply(try welcome("stream"))
        for (index, score) in [0.8, 0.69, 0.8, 0.7].enumerated() {
            let seq = index + 1
            let time = Double(seq) * 0.4
            model.recordDetectionCapture(seq: UInt64(seq), at: time)
            model.apply(try command(seq: seq, similarity: score), heading: nil, now: time)
            #expect((model.consumeHaptic() != nil) == (seq == 4))
        }
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
    @Test func hazardsCoexistWithPeopleAndKeepFrameGuards() throws {
        var model = OverlayModel()
        model.apply(try welcome("stream"))
        model.recordDetectionCapture(seq: 1, at: 1)
        #expect(model.apply(try command(), heading: nil, now: 1.1))
        #expect(model.apply(try command(hazard: true), heading: nil, now: 1.1))
        #expect(model.state.detections?.boxes.count == 1)
        #expect(model.state.hazards?.boxes.count == 1)
        #expect(!model.apply(try command(hazard: true), heading: nil, now: 1.2))
        #expect(!model.apply(try command(stream: "old", hazard: true), heading: nil, now: 1.2))
        model.recordDetectionCapture(seq: 2, at: 1)
        #expect(!model.apply(try command(seq: 2, hazard: true), heading: nil, now: 2.5))
        model.apply(try command(revision: "next", clear: true), heading: nil, now: 1.2)
        #expect(model.state.hazards == nil)
        #expect(!model.apply(try command(seq: 2, hazard: true), heading: nil, now: 1.2))
    }
}
