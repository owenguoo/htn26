import Foundation
import Testing
@testable import SwarmCore

/// Gate 1 — backpressure drops, never queues, and reconnect does not replay
/// stale frames. Serialized because several tests assert on settling behaviour
/// under a deliberately starved socket.
@Suite("Gate 1: transport", .serialized)
struct TransportTests {

    private func makeTransport(channels: [GatedChannel],
                               maxInFlight: Int = 1,
                               bufferDepth: Int = 1,
                               sleeper: any Sleeper = RecordingSleeper())
    -> (Transport, ScriptedChannelFactory) {
        let factory = ScriptedChannelFactory(channels: channels)
        let configuration = Transport.Configuration(
            url: URL(string: "ws://127.0.0.1:8765/device")!,
            maxInFlight: maxInFlight, bufferDepth: bufferDepth,
            initialBackoff: 0.01, maxBackoff: 0.04, jitterFraction: 0)
        return (Transport(configuration: configuration, factory: factory, sleeper: sleeper), factory)
    }

    private func poses(_ range: ClosedRange<Int>) -> [WireMessage] {
        range.map { .pose(Sample.poseUpdate(seq: UInt64($0), t: 1_000 + Double($0))) }
    }

    /// The socket accepts one message at a time while the producer emits ten.
    /// In-flight stays bounded, the drop counter rises, and what actually gets
    /// delivered is the newest pose, not the oldest.
    @Test func backpressureDropsStaleMessagesAndDeliversTheNewest() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for message in poses(1...10) {
            await transport.send(message)
            // Give the pump a chance to pick the first one up, so the test is
            // exercising a full pipe rather than an empty one.
            await Task.yield()
        }

        let bufferedAfterBurst = await transport.bufferedMessageCount()
        #expect(bufferedAfterBurst <= 1,
                "backpressure must drop, not queue: buffer held \(bufferedAfterBurst)")
        let midStats = await transport.currentStats()
        #expect(midStats.inFlight <= 1)
        #expect(midStats.dropped > 0, "a burst into a blocked socket must drop")

        for _ in 0..<12 {
            await channel.grant(1)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        await waitUntil("socket drained and settled") {
            let buffered = await transport.bufferedMessageCount()
            let inFlight = await transport.currentStats().inFlight
            return buffered == 0 && inFlight == 0
        }

        let delivered = await channel.deliveredEnvelopes()
        let deliveredSeqs: [UInt64] = delivered.compactMap {
            if case .pose(let update) = $0.message { return update.seq }
            return nil
        }
        #expect(!deliveredSeqs.isEmpty)
        #expect(deliveredSeqs.last == 10, "the newest pose must survive; got \(deliveredSeqs)")
        #expect(deliveredSeqs.count < 10, "some poses must have been dropped")

        let finalStats = await transport.currentStats()
        #expect(finalStats.sent + finalStats.dropped == 10,
                "every offered message is either sent or counted as dropped")
        #expect(finalStats.droppedByType[.pose] == finalStats.dropped)
        #expect(finalStats.inFlight == 0)
        await transport.stop()
    }

    @Test func inFlightNeverExceedsTheConfiguredLimit() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel], maxInFlight: 3, bufferDepth: 2)
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for message in poses(1...200) {
            await transport.send(message)
            await Task.yield()
        }
        let stats = await transport.currentStats()
        #expect(stats.inFlight <= 3)
        #expect(await transport.bufferedMessageCount() <= 2)
        let peak = await channel.concurrentSendPeak
        #expect(peak <= 3, "socket saw \(peak) concurrent sends")
        await transport.stop()
    }

    /// Control traffic is not perishable. Losing a hello makes the device
    /// silently stop existing to the server.
    @Test func controlTrafficIsNeverDropped() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for index in 1...20 {
            await transport.send(.ping(Ping(id: UInt64(index), t0: Double(index))))
            await transport.send(.pose(Sample.poseUpdate(seq: UInt64(index))))
            await Task.yield()
        }
        for _ in 0..<80 {
            await channel.grant(1)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await waitUntil("drained and settled") {
            let buffered = await transport.bufferedMessageCount()
            let inFlight = await transport.currentStats().inFlight
            return buffered == 0 && inFlight == 0
        }

        let delivered = await channel.deliveredEnvelopes()
        let pingIDs: [UInt64] = delivered.compactMap {
            if case .ping(let ping) = $0.message { return ping.id }
            return nil
        }
        #expect(pingIDs == Array(1...20).map(UInt64.init), "every ping must arrive, in order")
        let stats = await transport.currentStats()
        #expect(stats.droppedByType[.ping] == nil)
        await transport.stop()
    }

    @Test func helloIsSentFirstOnEveryConnect() async throws {
        let first = GatedChannel(failAfterSends: 2)
        let second = GatedChannel()
        let (transport, factory) = makeTransport(channels: [first, second])
        await transport.setHello(Sample.hello())
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        await transport.send(.pose(Sample.poseUpdate(seq: 1)))
        await first.grant(6)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await transport.send(.pose(Sample.poseUpdate(seq: 2)))
        await transport.send(.pose(Sample.poseUpdate(seq: 3)))
        await first.grant(6)

        await waitUntil("reconnected") { await factory.attempts() >= 2 }
        await waitUntil("second channel connected") { await transport.currentState() == .connected }
        await second.grant(6)
        await waitUntil("hello resent") {
            await second.deliveredEnvelopes().contains {
                if case .hello = $0.message { return true }
                return false
            }
        }

        let firstDelivered = await first.deliveredEnvelopes()
        #expect(firstDelivered.first.map { if case .hello = $0.message { true } else { false } } == true,
                "hello must be the first message on a fresh socket")
        let secondDelivered = await second.deliveredEnvelopes()
        #expect(secondDelivered.first.map { if case .hello = $0.message { true } else { false } } == true,
                "hello must be re-sent on reconnect")
        await transport.stop()
    }

    /// A pose buffered when the socket died describes a moment that has passed.
    /// It must be counted as dropped, not replayed onto the new socket.
    @Test func reconnectDoesNotReplayStaleFrames() async throws {
        let first = GatedChannel(failAfterSends: 1)
        let second = GatedChannel()
        let (transport, factory) = makeTransport(channels: [first, second])
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for message in poses(1...5) { await transport.send(message) }
        await first.grant(10)
        await waitUntil("reconnected") { await factory.attempts() >= 2 }
        await waitUntil("second connected") { await transport.currentState() == .connected }
        await second.grant(10)
        try? await Task.sleep(nanoseconds: 30_000_000)

        let replayed = await second.deliveredEnvelopes().filter {
            if case .pose = $0.message { return true }
            return false
        }
        #expect(replayed.isEmpty, "stale poses were replayed onto the new socket: \(replayed.count)")
        let stats = await transport.currentStats()
        #expect(stats.reconnects == 1)
        #expect(stats.sent + stats.dropped + stats.sendFailures == 5)
        await transport.stop()
    }

    @Test func noDuplicateSequenceNumbersAcrossAReconnect() async throws {
        let first = GatedChannel(failAfterSends: 3)
        let second = GatedChannel()
        let (transport, factory) = makeTransport(channels: [first, second], maxInFlight: 1, bufferDepth: 4)
        await transport.setHello(Sample.hello())
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for message in poses(1...4) {
            await transport.send(message)
            await first.grant(1)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        await first.grant(8)
        await waitUntil("reconnected") { await factory.attempts() >= 2 }
        await second.grant(8)
        for message in poses(5...8) {
            await transport.send(message)
            await second.grant(1)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)

        let all = await first.deliveredEnvelopes() + second.deliveredEnvelopes()
        let sequences = all.map(\.seq)
        #expect(Set(sequences).count == sequences.count,
                "sequence numbers repeated across the reconnect: \(sequences)")
        await transport.stop()
    }

    @Test func backoffGrowsExponentiallyAndIsCapped() async throws {
        let sleeper = RecordingSleeper(stopAfter: 8)
        let configuration = Transport.Configuration(
            url: URL(string: "ws://127.0.0.1:1/never")!,
            initialBackoff: 0.1, maxBackoff: 1.0, backoffMultiplier: 2, jitterFraction: 0)
        let transport = Transport(configuration: configuration,
                                  factory: AlwaysFailingFactory(), sleeper: sleeper)
        await transport.start()
        await waitUntil("backoff recorded") { await sleeper.recorded().count >= 8 }
        let delays = await sleeper.recorded()
        #expect(Array(delays.prefix(5)) == [0.1, 0.2, 0.4, 0.8, 1.0])
        #expect(delays.allSatisfy { $0 <= 1.0 }, "backoff exceeded its cap: \(delays)")
        await transport.stop()
    }

    @Test func jitterKeepsBackoffWithinBounds() async throws {
        let sleeper = RecordingSleeper(stopAfter: 40)
        let configuration = Transport.Configuration(
            url: URL(string: "ws://127.0.0.1:1/never")!,
            initialBackoff: 0.5, maxBackoff: 0.5, backoffMultiplier: 1, jitterFraction: 0.2)
        let transport = Transport(configuration: configuration,
                                  factory: AlwaysFailingFactory(), sleeper: sleeper)
        await transport.start()
        await waitUntil("jittered delays recorded") { await sleeper.recorded().count >= 40 }
        let delays = await sleeper.recorded()
        #expect(delays.allSatisfy { $0 >= 0.4 - 1e-9 && $0 <= 0.6 + 1e-9 },
                "jitter escaped +/-20%: \(delays.filter { $0 < 0.4 || $0 > 0.6 })")
        #expect(Set(delays.map { Int($0 * 1_000) }).count > 5,
                "delays are identical, so jitter is not being applied")
        await transport.stop()
    }

    @Test func inboundCommandsAreDecodedAndDelivered() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        let inbound = await transport.inbound()
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        let collector = Task { () -> [Command] in
            var received: [Command] = []
            for await message in inbound {
                if case .command(let command) = message { received.append(command) }
                if received.count == Sample.commands.count { break }
            }
            return received
        }
        for (index, command) in Sample.commands.enumerated() {
            let data = try WireCoder.encode(WireEnvelope(seq: UInt64(index), message: .command(command)))
            await channel.deliverInbound(data)
        }
        #expect(await collector.value == Sample.commands)
        await transport.stop()
    }

    @Test func garbageInboundIsIgnoredRatherThanFatal() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        let inbound = await transport.inbound()
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        await channel.deliverInbound(Data("not json at all".utf8))
        await channel.deliverInbound(Data(#"{"type":"nonsense"}"#.utf8))
        let good = try WireCoder.encode(WireEnvelope(seq: 1, message: .command(Sample.commands[0])))
        await channel.deliverInbound(good)

        let first = await Task { () -> WireMessage? in
            for await message in inbound { return message }
            return nil
        }.value
        #expect(first == .command(Sample.commands[0]),
                "a malformed frame must not kill the socket or be mistaken for a command")
        await waitUntil("all three frames read") { await transport.currentStats().received == 3 }
        await transport.stop()
    }
}
