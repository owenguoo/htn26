import Foundation
import SwarmCore

// A whole phone, on a Mac, with no camera: replays a recorded walk through
// `SwarmClient` into a real htn26 hub. This is the end-to-end proof of the
// protocol — if the dashboard shows this phone's cone, feed, fps and latency,
// then the only things left unproven are ARKit and the UI.
//
//   uv run python -m swarm.hub                        # repo root, other terminal
//   swift run --package-path phone/Packages/SwarmCore swarm-replay \
//       --hub http://localhost:8000/

struct Options {
    var hub = "http://localhost:8000/"
    var fixture = "trajectory-walk-2min.json"
    var fixturesDirectory: String?
    var name = "replay"
    var phoneId = "swarm-replay-0001"
    var rate = 1.0
    var loops = 1000
    var duration: Double?
    var markers = true
    var seat: HubSeat?
}

func usage() -> Never {
    print("""
    swarm-replay [--hub URL] [--fixture NAME] [--fixtures DIR] [--name NAME] [--phone-id ID]
                 [--rate X] [--loops N] [--duration SECONDS] [--no-markers] [--seat X,Y]

      --no-markers   strip marker sightings, so the phone never reaches the venue frame
      --seat X,Y     tap this spot and calibrate facing the stage (the seat fallback)
    """)
    exit(2)
}

func parse() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value() -> String {
        guard !arguments.isEmpty else { usage() }
        return arguments.removeFirst()
    }
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--hub": options.hub = value()
        case "--fixture": options.fixture = value()
        case "--fixtures": options.fixturesDirectory = value()
        case "--name": options.name = value()
        case "--phone-id": options.phoneId = value()
        case "--rate": options.rate = Double(value()) ?? 1
        case "--loops": options.loops = Int(value()) ?? 1
        case "--duration": options.duration = Double(value())
        case "--no-markers": options.markers = false
        case "--seat":
            let parts = value().split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { usage() }
            options.seat = HubSeat(x: parts[0], y: parts[1])
        default: usage()
        }
    }
    return options
}

/// `phone/Fixtures`, found from this file's own location so the tool works from
/// any working directory.
func defaultFixtures() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
}

setvbuf(stdout, nil, _IOLBF, 0)
let options = parse()
let fixtures = options.fixturesDirectory.map { URL(fileURLWithPath: $0) } ?? defaultFixtures()

guard let socket = HubURL.derive(options.hub) else {
    print("cannot make a hub socket out of \(options.hub)")
    exit(2)
}

do {
    let venue = try Venue.load(from: fixtures.appendingPathComponent("venue.json"))
    var trajectory = try JSONDecoder().decode(
        Trajectory.self, from: Data(contentsOf: fixtures.appendingPathComponent(options.fixture)))
    if !options.markers { trajectory.markerEvents = [] }

    let provider = MockPoseProvider(
        trajectory: trajectory,
        configuration: .init(playbackRate: options.rate, loops: options.loops, maxDuration: options.duration))
    let uptime: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    let client = SwarmClient(
        configuration: .init(socketURL: socket, phoneId: options.phoneId, name: options.name,
                             build: "swarm-replay", venue: venue, anchorsClockToPoses: true),
        dependencies: .init(provider: provider, encoder: SyntheticFrameEncoder(now: uptime), uptime: uptime))

    print("swarm-replay → \(socket.absoluteString) as \(options.phoneId)")
    try await client.start()

    if let seat = options.seat {
        await client.setSeat(x: seat.x, y: seat.y)
        // Wait for a first pose to anchor to, as an operator would wait for the camera.
        for _ in 0..<50 {
            if await client.calibrateFacingStage() { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    let started = uptime()
    while true {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let s = await client.snapshot()
        let pose = s.roomPose.map { String(format: "(%.1f, %.1f) h=%@", $0.x, $0.y,
                                           $0.heading.map { String(format: "%.0f°", $0) } ?? "–") } ?? "–"
        print("[\(Int(uptime() - started))s] \(s.connection.rawValue) #\(s.index.map(String.init) ?? "?") "
              + "\(s.sessionState.rawValue) align=\(s.alignment.rawValue) room=\(pose) "
              + "fps=\(s.frameFPS) sent=\(s.framesSent) dropped=\(s.dropped) "
              + "p50=\(s.latencyP50Ms.map { String(format: "%.1fms", $0) } ?? "–") "
              + "cmd=\(s.lastCommand ?? "–")\(s.lastError.map { " ERROR \($0)" } ?? "")")
        if let duration = options.duration, uptime() - started > duration / options.rate + 2 { break }
    }
    await client.stop()
} catch {
    print("swarm-replay failed: \(error)")
    exit(1)
}
