import Foundation
import Testing
@testable import SwarmCore

/// Simulates the whole round trip for one frame, so a replay can be held to the
/// budget without a server or a device.
struct PipelineSimulator {
    var captureToEncode: Double = 0.018
    var encodeToSend: Double = 0.009
    var network: Double = 0.022
    var serverQueue: Double = 0.031
    var inference: Double = 0.084
    var paint: Double = 0.016
    var jitter: Double = 0.0
    var generator = SeededGenerator(seed: 7)

    mutating func trace(for ticket: FrameTicket) -> LatencyTrace {
        var trace = ticket.trace
        var t = ticket.serverTimestamp
        for (stage, base) in [(LatencyStage.encoded, captureToEncode),
                              (.sent, encodeToSend),
                              (.serverReceived, network),
                              (.serverDequeued, serverQueue),
                              (.inferenceComplete, inference),
                              (.painted, paint)] {
            let noise = jitter > 0 ? generator.uniform(0...jitter) : 0
            t += base + noise
            trace.stamp(stage, at: t)
        }
        return trace
    }
}

/// Gate 7 — the web prototype measures ~1000 ms median, which is fatal for the
/// "look left" directive: people turn, see nothing, and read it as broken.
@Suite("Gate 7: latency instrumentation")
struct LatencyTests {

    // MARK: - The trace itself

    @Test func stagesSortIntoPipelineOrderHoweverTheyArrive() {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.painted, at: 6)
        trace.stamp(.capture, at: 0)
        trace.stamp(.sent, at: 2)
        trace.stamp(.inferenceComplete, at: 5)
        trace.stamp(.encoded, at: 1)
        trace.stamp(.serverDequeued, at: 4)
        trace.stamp(.serverReceived, at: 3)
        #expect(trace.stamps.map(\.stage) == LatencyStage.allCases)
        #expect(trace.isMonotonic)
        #expect(trace.isComplete)
        #expect(trace.total == 6)
    }

    /// A retried encode must not produce two `encoded` entries, or every
    /// duration downstream of it is measured from the wrong instant.
    @Test func restampingAStageOverwritesRatherThanAppends() {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 0)
        trace.stamp(.encoded, at: 1)
        trace.stamp(.encoded, at: 2)
        #expect(trace.stamps.count == 2)
        #expect(trace.time(of: .encoded) == 2)
    }

    /// A clock offset that moves mid-frame invalidates every duration in the
    /// trace, so it has to be visible rather than silently producing a negative
    /// stage time.
    @Test func nonMonotonicTracesAreDetected() {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 10)
        trace.stamp(.encoded, at: 9)
        #expect(!trace.isMonotonic)
    }

    @Test func incompleteTracesAreDetectedSeparatelyFromSlowOnes() {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 0)
        trace.stamp(.encoded, at: 0.01)
        trace.stamp(.sent, at: 0.015)
        #expect(trace.isClientComplete)
        #expect(!trace.isComplete)
        // A missing server stage is not a budget violation.
        #expect(trace.violations().isEmpty)
    }

    @Test func violationsNameTheStageAndTheOverage() throws {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 0)
        trace.stamp(.encoded, at: 0.020)
        trace.stamp(.sent, at: 0.030)
        trace.stamp(.serverReceived, at: 0.060)
        trace.stamp(.serverDequeued, at: 0.110)
        // 400 ms of inference against a 100 ms budget.
        trace.stamp(.inferenceComplete, at: 0.510)
        trace.stamp(.painted, at: 0.530)

        let violations = trace.violations()
        #expect(violations.count == 1)
        let violation = try #require(violations.first)
        #expect(violation.stage == .inferenceComplete)
        #expect(isClose(violation.measured, 0.400, within: 1e-6))
        #expect(violation.description.contains("inferenceComplete"))
        #expect(trace.exceedsEndToEnd())
    }

    /// The stage budgets leave 40 ms of slack against the end-to-end target, so
    /// a frame can pass every stage and still be checked against the whole.
    /// If that slack ever goes negative the two limits contradict each other and
    /// the end-to-end check becomes unreachable.
    @Test func stageBudgetsAddUpToLessThanTheEndToEndTarget() {
        let budget = LatencyBudget()
        #expect(budget.sumOfStages <= budget.endToEnd,
                "the stage budgets add to \(budget.sumOfStages * 1_000) ms, over the end-to-end target")

        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 0)
        var t = 0.0
        for (stage, duration) in [(LatencyStage.encoded, 0.029), (.sent, 0.019),
                                  (.serverReceived, 0.029), (.serverDequeued, 0.049),
                                  (.inferenceComplete, 0.099), (.painted, 0.029)] {
            t += duration
            trace.stamp(stage, at: t)
        }
        #expect(trace.violations().isEmpty, "no single stage was over its own budget")
        #expect(!trace.exceedsEndToEnd(), "\((trace.total ?? 0) * 1_000) ms should be inside 300 ms")
    }

    /// A frame that slips past the end-to-end target while every stage stays
    /// inside its own allowance still has to be caught.
    @Test func endToEndIsCheckedIndependentlyOfTheStages() {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 0)
        // Only two stages recorded, so nothing pairs up against a stage budget
        // except the encode — but 320 ms have passed.
        trace.stamp(.encoded, at: 0.020)
        trace.stamp(.painted, at: 0.320)
        #expect(trace.exceedsEndToEnd(), "a 320 ms frame was not flagged")
    }

    /// A trace missing a stage must not charge the span across the gap to
    /// whichever stage happens to come next. Blaming the network for a slow
    /// encode sends somebody to look at the Wi-Fi.
    @Test func aMissingStageIsNotChargedToItsNeighbour() {
        var trace = LatencyTrace(frameID: 1)
        trace.stamp(.capture, at: 0)
        trace.stamp(.encoded, at: 0.020)
        // .sent never happened. 100 ms passed before the server saw it, which
        // spans both the encode-to-send and network budgets.
        trace.stamp(.serverReceived, at: 0.120)
        trace.stamp(.serverDequeued, at: 0.150)

        let violations = trace.violations()
        #expect(!violations.contains { $0.stage == .serverReceived },
                "a 100 ms gap across a missing .sent was charged to the network")
        // The one interval that is genuinely adjacent and genuinely fine.
        #expect(violations.isEmpty, "unexpected violations: \(violations.map(\.description))")
        #expect(!trace.isClientComplete, "the gap is reported as incompleteness instead")
    }

    @Test func statisticsRingStaysBoundedOverALongRun() throws {
        var statistics = LatencyStatistics(capacity: 64)
        for index in 0..<10_000 {
            var trace = LatencyTrace(frameID: UInt64(index))
            trace.stamp(.capture, at: Double(index))
            trace.stamp(.painted, at: Double(index) + 0.2)
            statistics.record(trace)
        }
        #expect(statistics.count == 10_000)
        let median = try #require(statistics.median)
        #expect(isClose(median, 0.2, within: 1e-6))
        #expect(statistics.p95 != nil)
    }

    @Test func statisticsCountViolationsAndIncompleteTraces() {
        var statistics = LatencyStatistics()
        var good = LatencyTrace(frameID: 1)
        good.stamp(.capture, at: 0)
        good.stamp(.encoded, at: 0.01)
        good.stamp(.sent, at: 0.015)
        statistics.record(good)

        var slow = LatencyTrace(frameID: 2)
        slow.stamp(.capture, at: 0)
        slow.stamp(.encoded, at: 0.2)
        statistics.record(slow)

        #expect(statistics.count == 2)
        #expect(statistics.violationCount == 1)
        #expect(statistics.incompleteCount == 1, "the slow trace is also missing .sent")
    }

    // MARK: - Against the replay

    /// Every frame the session asks for comes with a trace already stamped at
    /// capture. A frame sent without one cannot be held to the budget at all.
    @Test func everyFrameTicketCarriesATraceStampedAtCapture() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let tickets = try await harness.run().frames
        #expect(!tickets.isEmpty)
        for ticket in tickets {
            #expect(ticket.trace.frameID == ticket.frameID)
            #expect(ticket.trace.time(of: .capture) == ticket.serverTimestamp)
            #expect(!ticket.trace.isClientComplete, "encode and send have not happened yet")
        }
    }

    /// The gate: replay the fixture through a pipeline inside budget, and assert
    /// every trace is complete, monotonic and under 300 ms end to end.
    @Test func replayedFramesStayInsideTheLatencyBudget() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let tickets = try await harness.run().frames
        #expect(tickets.count > 100, "only \(tickets.count) frames to measure")

        var simulator = PipelineSimulator(jitter: 0.004)
        var statistics = LatencyStatistics()
        var worst: LatencyTrace?
        for ticket in tickets {
            let trace = simulator.trace(for: ticket)
            #expect(trace.isComplete, "frame \(ticket.frameID) has a gap in its trace")
            #expect(trace.isMonotonic, "frame \(ticket.frameID) has a trace that goes backwards")
            let violations = trace.violations()
            #expect(violations.isEmpty,
                    "frame \(ticket.frameID): \(violations.map(\.description).joined(separator: "; "))")
            statistics.record(trace)
            if (trace.total ?? 0) > (worst?.total ?? 0) { worst = trace }
        }
        let median = try #require(statistics.median)
        #expect(median < 0.300, "median end to end was \(median * 1_000) ms against a 300 ms target")
        #expect(statistics.violationCount == 0)
        #expect(statistics.incompleteCount == 0)
        let worstTotal = try #require(worst?.total)
        #expect(worstTotal < 0.300, "worst frame was \(worstTotal * 1_000) ms")
    }

    /// The same replay with inference regressed to the web prototype's numbers
    /// must fail the gate. A budget check that cannot fail is not a check.
    @Test func aRegressedPipelineIsCaughtByTheSameAssertions() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let tickets = try await harness.run().frames
        #expect(!tickets.isEmpty)

        // ~1000 ms median, which is what the web prototype measures.
        var simulator = PipelineSimulator(captureToEncode: 0.040, encodeToSend: 0.030,
                                          network: 0.060, serverQueue: 0.220,
                                          inference: 0.600, paint: 0.050)
        var statistics = LatencyStatistics()
        var stagesFlagged = Set<LatencyStage>()
        for ticket in tickets {
            let trace = simulator.trace(for: ticket)
            statistics.record(trace)
            for violation in trace.violations() { stagesFlagged.insert(violation.stage) }
        }
        #expect(statistics.violationCount == tickets.count,
                "the budget check let a 1 s pipeline through")
        #expect(stagesFlagged.contains(.inferenceComplete))
        #expect(stagesFlagged.contains(.serverDequeued))
        let median = try #require(statistics.median)
        #expect(median > 0.300)
    }

    // MARK: - The trace on the wire

    /// The hub carries no trace; it measures latency from `tCapture`. The
    /// phone-side stages still have to be stamped, because they are the only
    /// way to tell "the phone was slow" from "the network was".
    @Test func theAssembledFrameKeepsItsTraceAndPutsTCaptureOnTheWire() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let ticket = try #require(try await harness.run().frames.first)
        let encoded = EncodedFrame(frameID: ticket.frameID, jpeg: Data([0xFF, 0xD8]),
                                   width: 720, height: 960, intrinsics: Sample.intrinsics())
        let room = RoomPose(x: 1, y: 2, heading: 45, pitch: -3)
        let (message, trace) = FrameAssembly.frame(ticket: ticket, encoded: encoded, room: room,
                                                   calibrated: true, tCaptureMs: 1_789_834_632_484,
                                                   encodedAt: ticket.serverTimestamp + 0.018,
                                                   sentAt: ticket.serverTimestamp + 0.027)
        #expect(trace.isClientComplete)
        #expect(trace.isMonotonic)
        #expect(isClose(trace.duration(from: .capture, to: .sent) ?? 0, 0.027, within: 1e-6))
        #expect(trace.violations().isEmpty)

        let onWire = DeliveredMessage(try message.encoded())
        #expect(onWire.isBinary)
        #expect(onWire.type == "frame")
        #expect(onWire.number("tCapture") == 1_789_834_632_484)
        #expect(onWire.number("seq") == Double(ticket.frameID))
        #expect(onWire.number("heading") == 45)
        #expect(onWire.json["calibrated"] as? Bool == true)
        #expect(onWire.payload == Data([0xFF, 0xD8]))
    }

    /// Depth that has not been made metric must never look like metres on the
    /// wire.
    @Test func anUnscaledDepthChunkCarriesNoMetricScale() async throws {
        let harness = try ReplayHarness(fixture: "trajectory-walk-2min.json")
        let ticket = try #require(try await harness.run().depthChunks.first)
        let chunk = FrameAssembly.chunk(deviceID: "phone-a", ticket: ticket, source: .server,
                                        sentAt: 1_000, depth: nil)
        #expect(chunk.metricScale == nil)
        #expect(chunk.depth == nil)
        #expect(chunk.frames.count == ticket.frames.count)
    }
}
