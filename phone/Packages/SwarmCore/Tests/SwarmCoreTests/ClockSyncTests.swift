import Foundation
import Testing
@testable import SwarmCore

/// Gate 2 — `frame.timestamp` is per-device uptime. Without this, cross-phone
/// pose fusion on the server is meaningless.
@Suite("Gate 2: clock sync")
struct ClockSyncTests {

    /// Two clocks 4 s apart over a link with 80 ms of jitter must agree to within
    /// 20 ms.
    @Test func convergesWithinTwentyMillisecondsDespiteJitter() throws {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: 0.080, seed: 1)
        var sync = ClockSync()
        var deviceTime = 1_000.0

        for id in 0..<32 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: deviceTime)
            sync.ingest(pong, receivedAt: receivedAt)
            deviceTime += 1.0
        }

        let offset = try #require(sync.offset)
        #expect(sync.isSynchronized)
        #expect(isClose(offset, 4.0, within: 0.020),
                "offset \(offset) is \(abs(offset - 4.0) * 1_000) ms from truth")
    }

    /// The same skew, over a range of jitter levels and seeds: convergence is a
    /// property of the filter, not of one lucky sequence.
    @Test(arguments: [0.020, 0.080, 0.150] as [Double], [UInt64](1...4))
    func convergesAcrossJitterLevelsAndSeeds(jitter: Double, seed: UInt64) throws {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: jitter, seed: seed)
        var sync = ClockSync()
        var deviceTime = 500.0
        for id in 0..<40 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: deviceTime)
            sync.ingest(pong, receivedAt: receivedAt)
            deviceTime += 0.5
        }
        let offset = try #require(sync.offset)
        #expect(isClose(offset, 4.0, within: 0.020),
                "jitter \(jitter), seed \(seed): off by \(abs(offset - 4.0) * 1_000) ms")
    }

    /// A single exchange is enough to have an estimate, but not enough to trust
    /// it — `isSynchronized` gates on having seen a few.
    @Test func reportsUnsynchronisedUntilEnoughSamples() {
        var simulator = ClockPairSimulator(skew: 4.0, seed: 7)
        var sync = ClockSync()
        #expect(sync.offset == nil)
        #expect(!sync.isSynchronized)
        #expect(sync.serverTime(forDeviceTime: 100) == nil,
                "an unsynchronised clock must refuse to convert, not guess")

        let (pong, receivedAt) = simulator.exchange(id: 0, at: 10)
        sync.ingest(pong, receivedAt: receivedAt)
        #expect(sync.offset != nil)
        #expect(!sync.isSynchronized)

        for id in 1...3 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: 10 + Double(id))
            sync.ingest(pong, receivedAt: receivedAt)
        }
        #expect(sync.isSynchronized)
    }

    /// Asymmetric paths bias the estimate by half the asymmetry, and no two-way
    /// exchange can detect that. What matters is that the error stays inside the
    /// bound the reported round trip implies, rather than growing without limit.
    @Test func asymmetricLatencyBiasesWithinHalfTheRoundTrip() throws {
        var simulator = ClockPairSimulator(skew: 4.0, upBase: 0.120, downBase: 0.010,
                                           jitter: 0.010, seed: 99)
        var sync = ClockSync()
        var deviceTime = 0.0
        for id in 0..<30 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: deviceTime)
            sync.ingest(pong, receivedAt: receivedAt)
            deviceTime += 0.5
        }

        let offset = try #require(sync.offset)
        let roundTrip = try #require(sync.roundTrip)
        let error = abs(offset - 4.0)
        // True bias is (up − down) / 2 = 55 ms.
        #expect(isClose(error, 0.055, within: 0.010),
                "asymmetry bias was \(error * 1_000) ms, expected about 55 ms")
        #expect(error <= roundTrip / 2 + 1e-6,
                "error \(error) exceeded the half-round-trip bound \(roundTrip / 2)")
    }

    /// Reversing the asymmetry reverses the sign of the bias — proof the estimate
    /// is tracking the path, not an artefact of the filter.
    @Test func reversedAsymmetryReversesTheBias() {
        func offset(up: Double, down: Double) -> Double {
            var simulator = ClockPairSimulator(skew: 4.0, upBase: up, downBase: down,
                                               jitter: 0.005, seed: 3)
            var sync = ClockSync()
            for id in 0..<30 {
                let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id) * 0.5)
                sync.ingest(pong, receivedAt: receivedAt)
            }
            return sync.offset ?? .nan
        }
        #expect(offset(up: 0.120, down: 0.010) > 4.0)
        #expect(offset(up: 0.010, down: 0.120) < 4.0)
    }

    /// The device sleeps and wakes: its monotonic clock keeps counting but the
    /// relationship to the server jumps. The estimate must follow, and quickly.
    @Test func followsAStepChangeWhenTheDeviceSleepsAndWakes() throws {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: 0.040, seed: 11)
        var sync = ClockSync()
        var deviceTime = 0.0
        for id in 0..<20 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: deviceTime)
            sync.ingest(pong, receivedAt: receivedAt)
            deviceTime += 0.5
        }
        #expect(isClose(try #require(sync.offset), 4.0, within: 0.020))

        // Asleep for five minutes of wall clock; CACurrentMediaTime keeps running
        // on some devices and not others, so the offset simply moves.
        simulator.skew = 4.0 - 300.0
        deviceTime += 300.0

        var samplesToConverge = 0
        for id in 20..<40 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: deviceTime)
            sync.ingest(pong, receivedAt: receivedAt)
            deviceTime += 0.5
            samplesToConverge += 1
            if let offset = sync.offset, abs(offset - simulator.skew) < 0.050 { break }
        }

        let offset = try #require(sync.offset)
        #expect(isClose(offset, simulator.skew, within: 0.050),
                "did not follow the step: offset \(offset), expected \(simulator.skew)")
        #expect(samplesToConverge <= 6,
                "took \(samplesToConverge) samples to follow a step change")
    }

    /// One delayed packet looks exactly like a step change. Adopting on a single
    /// outlier would make every phone lurch whenever the Wi-Fi hiccuped.
    @Test func oneOutlierDoesNotTriggerAStep() throws {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: 0.010, seed: 23)
        var sync = ClockSync()
        for id in 0..<20 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id) * 0.5)
            sync.ingest(pong, receivedAt: receivedAt)
        }
        let before = try #require(sync.offset)

        // A pong that sat in a buffer for two seconds on the way back.
        let (pong, receivedAt) = simulator.exchange(id: 100, at: 20)
        sync.ingest(pong, receivedAt: receivedAt + 2.0)

        let after = try #require(sync.offset)
        #expect(isClose(after, before, within: 0.005),
                "a single delayed pong moved the offset by \((after - before) * 1_000) ms")
    }

    /// Two outliers that disagree with each other are still noise, not a step.
    @Test func disagreeingOutliersDoNotTriggerAStep() throws {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: 0.005, seed: 31)
        var sync = ClockSync()
        for id in 0..<20 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id) * 0.5)
            sync.ingest(pong, receivedAt: receivedAt)
        }
        let before = try #require(sync.offset)

        for (index, extra) in [2.0, 9.0, 4.0].enumerated() {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(200 + index), at: 20 + Double(index))
            sync.ingest(pong, receivedAt: receivedAt + extra)
        }
        #expect(isClose(try #require(sync.offset), before, within: 0.005))
    }

    @Test func rejectsPongsThatViolateCausality() {
        var sync = ClockSync()
        // Arrived before it was sent.
        let arrivedEarly = sync.ingest(Pong(id: 1, t0: 10, t1: 1_000, t2: 1_000.01), receivedAt: 9)
        #expect(!arrivedEarly)
        // Server sent it before it received it.
        let sentBeforeReceived = sync.ingest(Pong(id: 2, t0: 10, t1: 1_000.5, t2: 1_000.1), receivedAt: 11)
        #expect(!sentBeforeReceived)
        #expect(sync.offset == nil)
        #expect(sync.sampleCount == 0)
    }

    @Test func conversionIsInvertible() throws {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: 0.020, seed: 5)
        var sync = ClockSync()
        for id in 0..<10 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id))
            sync.ingest(pong, receivedAt: receivedAt)
        }
        let deviceTime = 12_345.678
        let serverTime = try #require(sync.serverTime(forDeviceTime: deviceTime))
        let back = try #require(sync.deviceTime(forServerTime: serverTime))
        #expect(isClose(back, deviceTime, within: 1e-9))
    }

    @Test func windowStaysBounded() {
        var simulator = ClockPairSimulator(skew: 4.0, seed: 13)
        var sync = ClockSync(configuration: .init(windowSize: 8))
        for id in 0..<500 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id) * 0.2)
            sync.ingest(pong, receivedAt: receivedAt)
        }
        #expect(sync.sampleCount <= 8, "window grew to \(sync.sampleCount) over a long session")
    }

    @Test func staleSamplesAreEvicted() {
        var simulator = ClockPairSimulator(skew: 4.0, jitter: 0.005, seed: 17)
        var sync = ClockSync(configuration: .init(windowSize: 64, maxSampleAge: 10))
        for id in 0..<5 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id))
            sync.ingest(pong, receivedAt: receivedAt)
        }
        #expect(sync.sampleCount == 5)
        // An hour later: nothing from before is worth quoting.
        let (pong, receivedAt) = simulator.exchange(id: 99, at: 3_600)
        sync.ingest(pong, receivedAt: receivedAt)
        #expect(sync.sampleCount == 1)
    }

    @Test func resetClearsEverything() {
        var simulator = ClockPairSimulator(skew: 4.0, seed: 19)
        var sync = ClockSync()
        for id in 0..<10 {
            let (pong, receivedAt) = simulator.exchange(id: UInt64(id), at: Double(id))
            sync.ingest(pong, receivedAt: receivedAt)
        }
        #expect(sync.isSynchronized)
        sync.reset()
        #expect(sync.offset == nil)
        #expect(!sync.isSynchronized)
        #expect(sync.sampleCount == 0)
    }
}
