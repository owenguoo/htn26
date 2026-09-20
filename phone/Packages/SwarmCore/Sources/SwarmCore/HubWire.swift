import Foundation

/// The htn26 hub's phone protocol, as spoken on `/ws/phone`.
///
/// Source of truth: `swarm/hub.py` and `swarm/protocol.py` at the
/// repo root. **The hub wins.** Nothing here is negotiated; this file mirrors
/// what the hub already does so a native phone is indistinguishable from a web
/// one.
///
/// - Text messages are one flat JSON object with a `type` field — no envelope.
/// - The first message on every socket must be a *text* `hello`; the hub reads
///   it with `receive_json()` and drops the connection on anything else.
/// - Camera frames are binary: `[u32 big-endian header length][JSON][JPEG]`.
/// - The hub pings; the phone pongs with its own epoch-ms clock in `tp`. The
///   hub works out the clock offset itself.
///
/// Decoding is tolerant by design. The protocol is still moving (`hud`, `build`,
/// `mapVersion` arrived on branches while this was written), so an unknown
/// message type, command or field is ignored rather than an error.
public enum HubWire {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// MARK: - Shared shapes

public struct HubSeat: Sendable, Equatable, Codable {
    /// Room metres. x is 0 at the stage centre line, y is 0 at the stage wall.
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// `room.json`, as delivered in `welcome`.
public struct HubRoom: Sendable, Equatable, Codable {
    public struct Stage: Sendable, Equatable, Codable {
        public var width: Double
        public var depth: Double
    }

    public var name: String?
    public var width: Double
    public var depth: Double
    public var stage: Stage?
    public var cameraFovDeg: Double?
    public var coneLength: Double?

    public init(name: String? = nil, width: Double, depth: Double, stage: Stage? = nil,
                cameraFovDeg: Double? = nil, coneLength: Double? = nil) {
        self.name = name
        self.width = width
        self.depth = depth
        self.stage = stage
        self.cameraFovDeg = cameraFovDeg
        self.coneLength = coneLength
    }
}

// MARK: - Phone → hub

public struct HubHello: Sendable, Equatable, Codable {
    public var type = "hello"
    /// Persisted per install. The hub keys index and colour on it, so a phone
    /// that reconnects within 30 s keeps both.
    public var phoneId: String
    public var name: String
    public var seat: HubSeat?
    /// The hub labels the device from this: it must contain "iPhone".
    public var ua: String
    public var sim: Bool
    public var build: String
    /// Tells the hub this is an app, not its web page. Without it the console
    /// badges the phone "Old page · reload": the hub compares `build` with a
    /// hash of the web files, which an app can never equal.
    public var native = true

    public init(phoneId: String, name: String, seat: HubSeat? = nil,
                ua: String = "Beacon (iPhone; ARKit)", sim: Bool = false, build: String = "") {
        self.phoneId = phoneId
        self.name = name
        self.seat = seat
        self.ua = ua
        self.sim = sim
        self.build = build
    }
}

/// The 1 Hz diagnostics blob. The hub stores it verbatim and *replaces* the
/// previous one wholesale (`hub.py` `on_message` "debug"), so everything the
/// dashboard tooltip or the LLM should see has to be in every message.
public struct HubDebug: Sendable, Equatable, Codable {
    public struct LastCommand: Sendable, Equatable, Codable {
        public var cmd: String
        public var ageMs: Int
        public init(cmd: String, ageMs: Int) {
            self.cmd = cmd
            self.ageMs = ageMs
        }
    }

    public struct TransportInfo: Sendable, Equatable, Codable {
        public var state: String
        public var sent: Int
        public var dropped: Int
        public var reconnects: Int
        public init(state: String, sent: Int, dropped: Int, reconnects: Int) {
            self.state = state
            self.sent = sent
            self.dropped = dropped
            self.reconnects = reconnects
        }
    }

    public struct Latency: Sendable, Equatable, Codable {
        /// Capture → handed to the socket, milliseconds.
        public var p50Ms: Double?
        public var p95Ms: Double?
        public var overBudget: Int
        public init(p50Ms: Double?, p95Ms: Double?, overBudget: Int) {
            self.p50Ms = p50Ms
            self.p95Ms = p95Ms
            self.overBudget = overBudget
        }
    }

    public var client = "beacon-ios"
    public var session: String
    /// Venue frame, metres: +X east along the stage, +Y up, +Z out from the stage.
    public var venuePosition: [Float]?
    /// Venue frame, x, y, z, w.
    public var venueQuaternion: [Float]?
    public var trackingState: String
    public var confidence: Float
    public var correctionAgeS: Double?
    public var correctionMarker: String?
    public var stale: Bool
    /// "none", "seat" or "marker".
    public var alignment: String
    public var thermal: String
    public var frameFPS: Double
    public var transport: TransportInfo
    public var latency: Latency
    public var lastCommand: LastCommand?

    public init(session: String, venuePosition: [Float]?, venueQuaternion: [Float]?,
                trackingState: String, confidence: Float, correctionAgeS: Double?,
                correctionMarker: String?, stale: Bool, alignment: String, thermal: String,
                frameFPS: Double, transport: TransportInfo, latency: Latency,
                lastCommand: LastCommand?) {
        self.session = session
        self.venuePosition = venuePosition
        self.venueQuaternion = venueQuaternion
        self.trackingState = trackingState
        self.confidence = confidence
        self.correctionAgeS = correctionAgeS
        self.correctionMarker = correctionMarker
        self.stale = stale
        self.alignment = alignment
        self.thermal = thermal
        self.frameFPS = frameFPS
        self.transport = transport
        self.latency = latency
        self.lastCommand = lastCommand
    }
}

/// Header of a binary frame message. Mirrors `sendCapture()` in `phone.js`.
public struct HubFrameHeader: Sendable, Equatable, Codable {
    public var type = "frame"
    public var seq: UInt64
    /// Phone epoch milliseconds at capture. The hub subtracts its own estimate
    /// of this phone's clock offset to get latency.
    public var tCapture: Double
    public var heading: Double?
    public var pitch: Double?
    public var calibrated: Bool
    public var width: Int?
    public var height: Int?

    public init(seq: UInt64, tCapture: Double, heading: Double?, pitch: Double?, calibrated: Bool,
                width: Int? = nil, height: Int? = nil) {
        self.seq = seq
        self.tCapture = tCapture
        self.heading = heading
        self.pitch = pitch
        self.calibrated = calibrated
        self.width = width
        self.height = height
    }
}

/// Header of a binary audio message. Mirrors `sendVoice()` in `phone.js`.
///
/// The hub reads none of it (`hub.py` `on_frame` appends the payload and assumes
/// 16 kHz), but the web client sends all three and so does this: divergence from
/// the reference client is the exact thing this file exists to prevent, and a
/// later hub may well start reading `seq` to spot a gap.
public struct HubAudioHeader: Sendable, Equatable, Codable {
    public var type = "audio"
    /// This phone's own counter, independent of the frame sequence.
    public var seq: UInt64
    public var rate: Int
    /// Phone epoch milliseconds at capture.
    public var tCapture: Double

    public init(seq: UInt64, rate: Int = VoiceGate.rate, tCapture: Double) {
        self.seq = seq
        self.rate = rate
        self.tCapture = tCapture
    }
}

public enum HubOutbound: Sendable, Equatable {
    case hello(HubHello)
    /// Phone-side world tracking, already in room metres. The hub treats it as
    /// an external pose with `source == "slam"`.
    case slam(x: Double, y: Double, heading: Double?, pitch: Double?)
    /// Orientation only, for when the phone has no room position yet.
    case orient(heading: Double?, pitch: Double?, calibrated: Bool, tCapture: Double)
    case seat(HubSeat)
    case name(String)
    case debug(HubDebug)
    /// `ts` echoed exactly as received; `tp` is this phone's epoch ms.
    case pong(ts: Double, tp: Double)
    case frame(HubFrameHeader, jpeg: Data)
    /// What is on screen, for a console that has this phone expanded.
    case hud(HubHUDMirror)
    /// One chunk of 16 kHz mono Int16 little-endian PCM.
    case audio(HubAudioHeader, pcm: Data)
    /// The utterance is over. The hub assembles everything since the last one
    /// into a WAV and transcribes it.
    case audioEnd

    /// Which transport lane this rides in.
    public enum Lane: Sendable, Equatable, Hashable, CaseIterable {
        /// Never dropped, FIFO.
        case control
        /// Never dropped either, but rotated with the perishable lanes rather
        /// than sent ahead of them. See `Transport`.
        case audio
        /// Latest-wins. A stale one is worse than none.
        case slam, frame, debug, hud
    }

    public var lane: Lane {
        switch self {
        case .hello, .seat, .name, .pong: .control
        case .slam, .orient: .slam
        case .frame: .frame
        case .debug: .debug
        case .hud: .hud
        // `audioEnd` rides the audio lane, not the control lane, and that is
        // load-bearing: control is drained ahead of everything else, so an
        // `audio_end` sent as control would overtake the chunks still queued
        // behind it and cut the utterance short at the hub.
        case .audio, .audioEnd: .audio
        }
    }

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .slam: "slam"
        case .orient: "orient"
        case .seat: "seat"
        case .name: "name"
        case .debug: "debug"
        case .pong: "pong"
        case .frame: "frame"
        case .hud: "hud"
        case .audio: "audio"
        case .audioEnd: "audio_end"
        }
    }

    /// What goes on the socket. Everything is text except frames and audio.
    public func encoded() throws -> SocketFrame {
        let encoder = HubWire.makeEncoder()
        switch self {
        case .hello(let hello):
            return .text(try Self.string(encoder.encode(hello)))
        case .slam(let x, let y, let heading, let pitch):
            return .text(try Self.string(encoder.encode(
                Slam(x: x, y: y, heading: heading, pitch: pitch))))
        case .orient(let heading, let pitch, let calibrated, let tCapture):
            return .text(try Self.string(encoder.encode(
                Orient(tCapture: tCapture, heading: heading, pitch: pitch, calibrated: calibrated))))
        case .seat(let seat):
            return .text(try Self.string(encoder.encode(SeatMessage(seat: seat))))
        case .name(let name):
            return .text(try Self.string(encoder.encode(NameMessage(name: name))))
        case .debug(let debug):
            return .text(try Self.string(encoder.encode(Tagged(type: "debug", body: debug))))
        case .pong(let ts, let tp):
            return .text(try Self.string(encoder.encode(PongMessage(ts: ts, tp: tp))))
        case .hud(let mirror):
            return .text(try Self.string(encoder.encode(Tagged(type: "hud", body: mirror))))
        case .frame(let header, let jpeg):
            return .binary(try HubFrame.pack(header: header, jpeg: jpeg))
        case .audio(let header, let pcm):
            return .binary(try HubFrame.pack(headerJSON: encoder.encode(header), payload: pcm))
        case .audioEnd:
            return .text(try Self.string(encoder.encode(AudioEndMessage())))
        }
    }

    private static func string(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw HubWireError.notUTF8
        }
        return string
    }

    private struct Slam: Encodable {
        var type = "slam"
        var x: Double, y: Double, heading: Double?, pitch: Double?
    }
    private struct Orient: Encodable {
        var type = "orient"
        var tCapture: Double, heading: Double?, pitch: Double?, calibrated: Bool
    }
    private struct SeatMessage: Encodable {
        var type = "seat"
        var seat: HubSeat
    }
    private struct NameMessage: Encodable {
        var type = "name"
        var name: String
    }
    private struct AudioEndMessage: Encodable {
        var type = "audio_end"
    }
    private struct PongMessage: Encodable {
        var type = "pong"
        var ts: Double, tp: Double
    }
    /// Flattens `body`'s keys alongside `type`, which is what the hub expects.
    private struct Tagged<Body: Encodable>: Encodable {
        var type: String
        var body: Body
        enum Keys: String, CodingKey { case type }
        func encode(to encoder: any Encoder) throws {
            try body.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(type, forKey: .type)
        }
    }
}

public enum HubWireError: Error, Sendable, Equatable {
    case notUTF8
    case truncatedFrame
    case headerTooLarge
}

/// What a WebSocket actually carries. The hub cares which: `hello` as binary
/// kills the connection, a frame as text is ignored.
public enum SocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// `swarm/protocol.py` `pack` / `unpack`.
public enum HubFrame {
    public static func pack(header: HubFrameHeader, jpeg: Data) throws -> Data {
        try pack(headerJSON: HubWire.makeEncoder().encode(header), payload: jpeg)
    }

    public static func pack(headerJSON: Data, payload: Data) throws -> Data {
        guard let length = UInt32(exactly: headerJSON.count) else { throw HubWireError.headerTooLarge }
        var out = Data(capacity: 4 + headerJSON.count + payload.count)
        withUnsafeBytes(of: length.bigEndian) { out.append(contentsOf: $0) }
        out.append(headerJSON)
        out.append(payload)
        return out
    }

    public static func unpack(_ buffer: Data) throws -> (headerJSON: Data, payload: Data) {
        guard buffer.count >= 4 else { throw HubWireError.truncatedFrame }
        let start = buffer.startIndex
        let length = buffer[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        guard buffer.count >= 4 + length else { throw HubWireError.truncatedFrame }
        let headerEnd = start + 4 + length
        return (Data(buffer[(start + 4)..<headerEnd]), Data(buffer[headerEnd...]))
    }
}

// MARK: - Hub → phone

public struct HubWelcome: Sendable, Equatable, Decodable {
    /// The hub's identifier for *this* run of this phone's camera stream
    /// (`hub.py` `ws_phone`, sent in every `welcome`). It changes when the phone
    /// reconnects, and `swarm/detection.py` stamps it into every result. It is
    /// the key a detection-freshness gate matches on: a box carrying the
    /// previous stream's id describes a frame from before the reconnect and must
    /// not be drawn over the live camera. Decoded here so that gate has
    /// something to compare against.
    public var streamId: String? = nil
    public var phoneId: String
    public var index: Int
    /// `#rrggbb`. Also the default flash colour.
    public var color: String
    public var room: HubRoom?
    public var phase: String?
}

public struct HubWorld: Sendable, Equatable, Decodable {
    public struct Peer: Sendable, Equatable, Decodable {
        public var id: String
        public var i: Int
        public var x: Double
        public var y: Double
        public var h: Double?
    }
    public struct Coverage: Sendable, Equatable, Decodable {
        public var cols: Int
        public var rows: Int
        public var cell: Double
        public var x0: Double
        /// Row-major "0"/"1" string, `cols * rows` long: has any camera looked
        /// at this cell yet. A one-way latch — it reaches 100% within about
        /// half a minute of a real search, after which it says nothing.
        public var cells: String
        /// Row-major base-36 string, `cols * rows` long: the cell's
        /// probability relative to the hottest cell (`HEAT_LEVELS` in
        /// `swarm/coverage.py`). This is the field the operator console draws
        /// as its heatmap, and unlike `cells` it keeps evolving for the whole
        /// search — every look pushes the cells it swept down and every
        /// detection lifts the cells around it.
        ///
        /// **Optional because `hub.py`'s `world_loop` does not send it yet**;
        /// it forwards only `("cols", "rows", "cell", "x0", "cells")` of
        /// `Coverage.snapshot()`. Add `"heat"` to that tuple and the phone's
        /// map becomes the same picture as the console's. Until then the map
        /// falls back to inverting `cells`, which is a fair approximation for
        /// the first few seconds and blank after that.
        public var heat: String? = nil
    }
    public struct Ping: Sendable, Equatable, Decodable {
        public var id: Int
        public var x: Double
        public var y: Double
        public var label: String?
        public var ageMs: Double?
    }
    public struct Stats: Sendable, Equatable, Decodable {
        public var m2: Double?
        public var rank: Int?
        public var of: Int?
    }
    public struct Point: Sendable, Equatable, Decodable {
        public var x: Double
        public var y: Double
    }

    public var phase: String?
    public var phones: [Peer]?
    public var coverage: Coverage?
    public var searched: Double?
    public var searchers: Int?
    public var lookingFor: String?
    public var missionComplete: Bool?
    public var candidate: Point?
    /// The printed alignment marker, wherever the operator dropped it on the
    /// console. `hub.py`'s `world_loop` has always sent it; nothing decoded it,
    /// so the phone's map had no marker on it while the console's did.
    ///
    /// It also rides the ping channel as a cue labelled "MARKER" before the
    /// search starts, which is how it reaches the compass and the camera view.
    /// The map ignores that cue and draws this instead, the way the console
    /// does — otherwise the two would stack on the same spot.
    public var marker: Point?
    public var me: String?
    public var pings: [Ping]?
    public var stats: Stats?
}

public struct HubDetectionBox: Sendable, Equatable, Codable {
    /// 0…1 fractions of the frame as the hub received it (portrait, upright).
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var label: String?
    /// How sure the detector is that this is a person at all, 0…1.
    /// **The hub's name for it is `detectionScore`** (`swarm/detection.py` `Box`),
    /// which this type used to spell `score`. Nothing matched, so every box
    /// arrived with a nil confidence and rendered as a bare "person" tag.
    public var detectionScore: Double?
    /// Appearance-embedding similarity to the search target, −1…1. Compared
    /// against the `threshold` on the command to decide "likely" from "maybe".
    public var similarity: Double?
    /// Kept only because a box round-trips through `HubHUDMirror.dets` to the
    /// console, and an older hub or a hand-written fixture may still spell it
    /// this way. The hub as it stands never sends it.
    public var score: Double?

    public init(x: Double, y: Double, w: Double, h: Double, label: String? = nil,
                detectionScore: Double? = nil, similarity: Double? = nil, score: Double? = nil) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.label = label
        self.detectionScore = detectionScore
        self.similarity = similarity
        self.score = score
    }

    /// The confidence to show, whichever spelling arrived.
    public var confidence: Double? { detectionScore ?? score }
}

public struct HubDetectionContext: Sendable, Equatable {
    public var streamId: String?
    public var seq: UInt64?
    public var searchRevision: String?
    public var threshold: Double?
    public var clear: Bool
    public var rehearsal: Bool
}

public enum HubCommand: Sendable, Equatable {
    case guideClear
    /// Planner and find-team guidance: turn by `delta` degrees from where the
    /// phone was facing when the hub computed it. Positive is clockwise/right.
    case guideTurn(sector: String?, delta: Double, onTarget: Bool, text: String?, kind: String,
                   distance: Double?)
    /// Operator "look"/"go": an absolute room heading (0 = facing the stage).
    case guideHeading(kind: String, sector: String?, heading: Double, distance: Double?, untilMs: Double)
    /// Operator "look" by real-world compass bearing. This client runs ARKit
    /// with `.gravity` and has no true north, so it shows the text only.
    case guideCompass(kind: String, sector: String?, compass: Double, untilMs: Double)
    case flash(color: String?, text: String?, ttlMs: Double)
    /// nil means "back to your default rate".
    case rate(fps: Double?)
    case ping(id: Int, x: Double, y: Double, label: String, ttlMs: Double)
    case message(text: String, ttlMs: Double)
    case detections(boxes: [HubDetectionBox], ttlMs: Double, context: HubDetectionContext? = nil)
    case hud(on: Bool)
    case unknown(cmd: String)

    /// The hub's `cmd` string, for `debug.lastCommand`.
    public var name: String {
        switch self {
        case .guideClear, .guideTurn, .guideHeading, .guideCompass: "guide"
        case .flash: "flash"
        case .rate: "rate"
        case .ping: "ping"
        case .message: "message"
        case .detections(_, _, let context): context?.rehearsal == true ? "rehearsal_detections" : "detections"
        case .hud: "hud"
        case .unknown(let cmd): cmd
        }
    }
}

public enum HubInbound: Sendable, Equatable {
    case welcome(HubWelcome)
    case ping(ts: Double)
    case phase(String)
    case world(HubWorld)
    case command(HubCommand)
    case unknown(type: String)

    /// Returns nil for anything that is not a JSON object with a string `type`.
    /// Never throws: a message this client does not understand is not an error.
    public static func decode(_ frame: SocketFrame) -> HubInbound? {
        switch frame {
        case .text(let text): decode(Data(text.utf8))
        // The hub only sends text to phones. Tolerate the other, do not rely on it.
        case .binary(let data): decode(data)
        }
    }

    public static func decode(_ data: Data) -> HubInbound? {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: data) else { return nil }
        switch head.type {
        case "welcome":
            guard let welcome = try? decoder.decode(HubWelcome.self, from: data) else {
                return .unknown(type: head.type)
            }
            return .welcome(welcome)
        case "ping":
            guard let ts = head.ts else { return .unknown(type: head.type) }
            return .ping(ts: ts)
        case "phase":
            guard let phase = head.phase else { return .unknown(type: head.type) }
            return .phase(phase)
        case "world":
            guard let world = try? decoder.decode(HubWorld.self, from: data) else {
                return .unknown(type: head.type)
            }
            return .world(world)
        case "command":
            guard let raw = try? decoder.decode(RawCommand.self, from: data) else {
                return .unknown(type: head.type)
            }
            return .command(raw.command)
        default:
            return .unknown(type: head.type)
        }
    }

    private struct Head: Decodable {
        var type: String
        var ts: Double?
        var phase: String?
    }

    /// Every field any command uses, all optional. Mirrors the defaults in
    /// `onCommand()` in `phone.js`.
    private struct RawCommand: Decodable {
        var cmd: String?
        var clear: Bool?
        var kind: String?
        var sector: String?
        var delta: Double?
        var onTarget: Bool?
        var text: String?
        var compass: Double?
        var heading: Double?
        var distance: Double?
        var untilMs: Double?
        var color: String?
        var ttlMs: Double?
        var fps: Double?
        var id: Int?
        var x: Double?
        var y: Double?
        var label: String?
        var boxes: [HubDetectionBox]?
        var streamId: String?
        var seq: UInt64?
        var searchRevision: String?
        var threshold: Double?
        var on: Bool?

        var command: HubCommand {
            switch cmd {
            case "guide":
                if clear == true { return .guideClear }
                if kind == "look" || kind == "go" {
                    if let compass {
                        return .guideCompass(kind: kind ?? "look", sector: sector, compass: compass,
                                             untilMs: untilMs ?? 20_000)
                    }
                    if let heading {
                        return .guideHeading(kind: kind ?? "look", sector: sector, heading: heading,
                                             distance: distance, untilMs: untilMs ?? 20_000)
                    }
                    return .unknown(cmd: "guide")
                }
                guard let delta else { return .unknown(cmd: "guide") }
                return .guideTurn(sector: sector, delta: delta, onTarget: onTarget ?? false, text: text,
                                  kind: kind ?? "search", distance: distance)
            case "flash":
                return .flash(color: color, text: text, ttlMs: ttlMs ?? 1500)
            case "rate":
                return .rate(fps: fps)
            case "ping":
                guard let id, let x, let y else { return .unknown(cmd: "ping") }
                return .ping(id: id, x: x, y: y, label: label ?? "Check here", ttlMs: ttlMs ?? 12_000)
            case "message":
                return .message(text: text ?? "", ttlMs: ttlMs ?? 8000)
            case "detections", "rehearsal_detections":
                return .detections(boxes: boxes ?? [], ttlMs: ttlMs ?? 1500,
                    context: HubDetectionContext(streamId: streamId, seq: seq,
                        searchRevision: searchRevision, threshold: threshold,
                        clear: clear ?? false, rehearsal: cmd == "rehearsal_detections"))
            case "hud":
                return .hud(on: on ?? false)
            default:
                return .unknown(cmd: cmd ?? "")
            }
        }
    }
}
