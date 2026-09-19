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
            url: URL(string: "ws://127.0.0.1:8000/ws/phone")!,
            maxInFlight: maxInFlight, bufferDepth: bufferDepth,
            initialBackoff: 0.01, maxBackoff: 0.04, jitterFraction: 0)
        return (Transport(configuration: configuration, factory: factory, sleeper: sleeper), factory)
    }

    /// `slam` messages whose `x` is their ordinal, so order survives the wire.
    private func poses(_ range: ClosedRange<Int>) -> [HubOutbound] {
        range.map(Sample.slam)
    }

    private func slamOrdinals(_ messages: [DeliveredMessage]) -> [Int] {
        messages.filter { $0.type == "slam" }.compactMap { $0.number("x").map(Int.init) }
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

        let deliveredSeqs = slamOrdinals(await channel.deliveredMessages())
        #expect(!deliveredSeqs.isEmpty)
        #expect(deliveredSeqs.last == 10, "the newest pose must survive; got \(deliveredSeqs)")
        #expect(deliveredSeqs.count < 10, "some poses must have been dropped")

        let finalStats = await transport.currentStats()
        #expect(finalStats.sent + finalStats.dropped == 10,
                "every offered message is either sent or counted as dropped")
        #expect(finalStats.droppedByLane[.slam] == finalStats.dropped)
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

    /// Control traffic is not perishable. A lost pong leaves the hub with no
    /// clock offset for this phone, and so no latency figure.
    @Test func controlTrafficIsNeverDropped() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        for index in 1...20 {
            await transport.send(.pong(ts: Double(index), tp: 0))
            await transport.send(Sample.slam(index))
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

        let pongs = await channel.deliveredMessages().filter { $0.type == "pong" }
            .compactMap { $0.number("ts").map(Int.init) }
        #expect(pongs == Array(1...20), "every pong must arrive, in order")
        let stats = await transport.currentStats()
        #expect(stats.droppedByLane[.control] == nil)
        await transport.stop()
    }

    /// The hub registers a phone from the first message on the socket, reading
    /// it with `receive_json()`. So on every connect the hello must be first,
    /// text, and alone — nothing else may be in flight beside it, because
    /// concurrent sends do not promise order.
    @Test func helloIsSentFirstAloneAndAsTextOnEveryConnect() async throws {
        let first = GatedChannel(failAfterSends: 2)
        let second = GatedChannel()
        let (transport, factory) = makeTransport(channels: [first, second], maxInFlight: 3)
        let names = NameBox()
        await transport.setHello { HubHello(phoneId: "phone-a", name: await names.next()) }
        // Offered before the socket exists, and racing the hello for it.
        await transport.send(.pong(ts: 1, tp: 1))
        await transport.send(Sample.slam(1))
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        try? await Task.sleep(nanoseconds: 10_000_000)
        let peakBesideHello = await first.concurrentSendPeak
        #expect(peakBesideHello == 1, "something was sent alongside the hello: \(peakBesideHello) concurrent sends")

        await first.grant(6)
        await waitUntil("first socket died") { await factory.attempts() >= 2 }
        await waitUntil("second channel connected") { await transport.currentState() == .connected }
        await transport.send(.pong(ts: 2, tp: 2))
        await second.grant(6)
        await waitUntil("second socket drained") { await second.deliveredCount() >= 2 }

        for (label, channel) in [("fresh", first), ("reconnected", second)] {
            let delivered = await channel.delivered
            guard case .text? = delivered.first else {
                Issue.record("hello on the \(label) socket was not a text frame")
                continue
            }
            #expect(DeliveredMessage(delivered[0]).type == "hello",
                    "hello must be the first message on a \(label) socket")
        }
        // Re-evaluated, not replayed: a rename between connects reaches the hub.
        let helloNames = await [first, second].asyncMap { channel in
            await channel.deliveredMessages().first?.json["name"] as? String
        }
        #expect(helloNames == ["name-1", "name-2"])
        let hellos = await second.deliveredMessages().filter { $0.type == "hello" }.count
        #expect(hellos == 1)
        await transport.stop()
    }

    @Test func aHelloOfferedThroughSendIsIgnored() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }
        await transport.send(.hello(Sample.hello()))
        #expect(await transport.bufferedMessageCount() == 0)
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

        let replayed = await second.deliveredMessages().filter { $0.type == "slam" }
        #expect(replayed.isEmpty, "stale poses were replayed onto the new socket: \(replayed.count)")
        let stats = await transport.currentStats()
        #expect(stats.reconnects == 1)
        #expect(stats.sent + stats.dropped + stats.sendFailures == 5)
        await transport.stop()
    }

    @Test func framesGoOutBinaryAndEverythingElseText() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel], maxInFlight: 1, bufferDepth: 1)
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }
        await transport.send(Sample.slam(1))
        await transport.send(Sample.frame(1, bytes: 9))
        await transport.send(.pong(ts: 1, tp: 2))
        await channel.grant(3)
        await waitUntil("delivered") { await channel.deliveredCount() == 3 }
        for message in await channel.deliveredMessages() {
            #expect(message.isBinary == (message.type == "frame"), "\(message.type)")
        }
        let frame = try #require(await channel.deliveredMessages().first { $0.type == "frame" })
        #expect(frame.payload == Data(repeating: 0xAB, count: 9))
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

    /// A socket slow enough that the pose buffer is never empty at a send
    /// opportunity. Strict priority would send nothing but poses forever, and no
    /// frames means no inference — the entire point of the system.
    @Test func aContinuousPoseStreamDoesNotStarveFrames() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        // Ten poses per frame, which is the real ratio, into a socket that
        // accepts one message for every eleven offered.
        for round in 1...30 {
            for index in 1...10 {
                await transport.send(Sample.slam(round * 10 + index))
                await Task.yield()
            }
            await transport.send(Sample.frame(round))
            await Task.yield()
            await channel.grant(1)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await channel.grant(20)
        await waitUntil("drained and settled") {
            let buffered = await transport.bufferedMessageCount()
            let inFlight = await transport.currentStats().inFlight
            return buffered == 0 && inFlight == 0
        }

        let delivered = await channel.deliveredMessages()
        let poses = delivered.filter { $0.type == "slam" }.count
        let frames = delivered.filter { $0.type == "frame" }.count
        #expect(poses > 0)
        #expect(frames > 0, "the pose stream starved frames out entirely over 30 rounds")
        #expect(frames >= 5, "only \(frames) of 30 frames got a turn against \(poses) poses")
    }

    @Test func inboundHubMessagesAreDecodedAndDelivered() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        let inbound = await transport.inbound()
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        let names = ["welcome", "ping", "cmd-flash", "cmd-guide-turn", "world"]
        let collector = Task { () -> [HubInbound] in
            var received: [HubInbound] = []
            for await message in inbound {
                received.append(message)
                if received.count == names.count { break }
            }
            return received
        }
        for name in names {
            await channel.deliverInbound(try String(contentsOf: Fixtures.url("hub-messages/\(name).json"),
                                                    encoding: .utf8))
        }
        let received = await collector.value
        #expect(received.count == names.count)
        guard case .welcome = received[0], case .ping = received[1],
              case .command(.flash) = received[2], case .command(.guideTurn) = received[3],
              case .world = received[4] else {
            Issue.record("decoded out of order or as the wrong thing: \(received)")
            return
        }
        await transport.stop()
    }

    @Test func garbageInboundIsIgnoredRatherThanFatal() async throws {
        let channel = GatedChannel()
        let (transport, _) = makeTransport(channels: [channel])
        let inbound = await transport.inbound()
        await transport.start()
        await waitUntil("connected") { await transport.currentState() == .connected }

        await channel.deliverInbound("not json at all")
        await channel.deliverInbound(.binary(Data([0, 1, 2])))
        await channel.deliverInbound(#"{"type":"phase","phase":"found"}"#)

        let first = await Task { () -> HubInbound? in
            for await message in inbound { return message }
            return nil
        }.value
        #expect(first == .phase("found"),
                "a malformed frame must not kill the socket or be mistaken for a message")
        await waitUntil("all three frames read") { await transport.currentStats().received == 3 }
        await transport.stop()
    }
}

/// Hands out "name-1", "name-2", … so a test can tell one hello from the next.
actor NameBox {
    private var count = 0
    func next() -> String {
        count += 1
        return "name-\(count)"
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for element in self { out.append(await transform(element)) }
        return out
    }
}
