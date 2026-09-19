import Foundation
import simd
import Testing
@testable import SwarmCore

/// Gate 1 — round-trip Codable for every message type.
@Suite("Gate 1: wire protocol")
struct WireTests {

    private func roundTrip(_ message: WireMessage, seq: UInt64 = 17,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let envelope = WireEnvelope(seq: seq, message: message)
        let data = try WireCoder.encode(envelope)
        let decoded = try WireCoder.decode(data)
        #expect(decoded == envelope, sourceLocation: sourceLocation)
        #expect(decoded.seq == seq, sourceLocation: sourceLocation)
        #expect(decoded.version == WireProtocol.version, sourceLocation: sourceLocation)
        #expect(decoded.message.type == message.type, sourceLocation: sourceLocation)
    }

    @Test func helloRoundTrips() throws {
        try roundTrip(.hello(Sample.hello()))
    }

    @Test func poseUpdateRoundTrips() throws {
        try roundTrip(.pose(Sample.poseUpdate()))
    }

    @Test func frameChunkRoundTrips() throws {
        try roundTrip(.frame(Sample.frameChunk()))
    }

    @Test func depthChunkRoundTrips() throws {
        try roundTrip(.depth(Sample.depthChunk()))
    }

    @Test func pingAndPongRoundTrip() throws {
        try roundTrip(.ping(Ping(id: 9, t0: 12_345.678)))
        try roundTrip(.pong(Pong(id: 9, t0: 12_345.678, t1: 1_726_000.1, t2: 1_726_000.2)))
    }

    @Test(arguments: Sample.commands)
    func everyCommandKindRoundTrips(command: Command) throws {
        try roundTrip(.command(command))
    }

    /// A new case in `WireMessageType` with no round-trip test is the kind of gap
    /// that shows up as a silent decode failure at the venue.
    @Test func everyMessageTypeIsCovered() throws {
        let covered: [WireMessage] = [
            .hello(Sample.hello()),
            .pose(Sample.poseUpdate()),
            .frame(Sample.frameChunk()),
            .depth(Sample.depthChunk()),
            .command(Sample.commands[0]),
            .ping(Ping(id: 1, t0: 0)),
            .pong(Pong(id: 1, t0: 0, t1: 0, t2: 0)),
        ]
        #expect(Set(covered.map(\.type)) == Set(WireMessageType.allCases))
        for message in covered { try roundTrip(message) }
    }

    /// The dashboard and orchestrator already exist. If this shape has to change,
    /// it changes here and nowhere else.
    @Test func envelopeShapeIsStable() throws {
        let data = try WireCoder.encode(WireEnvelope(seq: 3, message: .ping(Ping(id: 1, t0: 2))))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["type"] as? String == "ping")
        #expect(object["seq"] as? Int == 3)
        #expect(object["data"] != nil)
    }

    @Test func decodeToleratesMissingVersionAndSeq() throws {
        let json = #"{"type":"ping","data":{"id":4,"t0":1.5}}"#
        let decoded = try WireCoder.decode(Data(json.utf8))
        #expect(decoded.version == WireProtocol.version)
        #expect(decoded.seq == 0)
        #expect(decoded.message == .ping(Ping(id: 4, t0: 1.5)))
    }

    @Test func decodeRejectsUnknownType() {
        let json = #"{"v":1,"type":"telemetry","seq":1,"data":{}}"#
        #expect(throws: (any Error).self) {
            try WireCoder.decode(Data(json.utf8))
        }
    }

    @Test func jpegSurvivesBase64RoundTrip() throws {
        let jpeg = Data((0..<4_096).map { UInt8($0 % 251) })
        let chunk = FrameChunk(deviceID: "phone-a", frameID: 1, serverTimestamp: 1, width: 4, height: 4,
                               jpegQuality: 0.7, intrinsics: nil, pose: nil, jpeg: jpeg, trace: nil)
        let data = try WireCoder.encode(WireEnvelope(seq: 1, message: .frame(chunk)))
        guard case .frame(let decoded) = try WireCoder.decode(data).message else {
            Issue.record("expected a frame")
            return
        }
        #expect(decoded.jpeg == jpeg)
    }

    @Test func poseSurvivesTheWireWithinFloatPrecision() throws {
        let pose = Pose(position: SIMD3<Float>(1.25, -0.5, 3.75),
                        orientation: simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(0.2, 1, -0.3))))
        let update = PoseUpdate(deviceID: "phone-a", serverTimestamp: 1, deviceTimestamp: 0,
                                position: pose.wirePosition, quaternion: pose.wireQuaternion,
                                trackingState: TrackingQuality.normal.wireValue, confidence: 1,
                                lastCorrectionAge: nil, lastCorrectionMarker: nil, stale: false, seq: 1)
        let data = try WireCoder.encode(WireEnvelope(seq: 1, message: .pose(update)))
        guard case .pose(let decoded) = try WireCoder.decode(data).message,
              let recovered = decoded.venuePose else {
            Issue.record("expected a pose")
            return
        }
        #expect(isClose(Geometry.distance(recovered.position, pose.position), 0, within: 1e-6))
        #expect(isClose(Geometry.angle(between: recovered.orientation, and: pose.orientation), 0, within: 1e-5))
    }

    @Test func malformedPoseArraysDoNotTrap() {
        var update = Sample.poseUpdate()
        update.position = [1, 2]
        #expect(update.venuePose == nil)
        update.position = [1, 2, 3]
        update.quaternion = []
        #expect(update.venuePose == nil)
    }

    @Test func trackingQualityWireValuesRoundTrip() {
        var all: [TrackingQuality] = [.normal, .notAvailable]
        all.append(contentsOf: LimitedReason.allCases.map { .limited($0) })
        for quality in all {
            #expect(TrackingQuality(wireValue: quality.wireValue) == quality)
        }
        #expect(TrackingQuality(wireValue: "limited.somethingElse") == nil)
        #expect(TrackingQuality(wireValue: "great") == nil)
    }

    @Test func onlyPerishableTrafficIsDroppable() {
        #expect(WireMessage.pose(Sample.poseUpdate()).isDroppable)
        #expect(WireMessage.frame(Sample.frameChunk()).isDroppable)
        #expect(WireMessage.depth(Sample.depthChunk()).isDroppable)
        #expect(!WireMessage.hello(Sample.hello()).isDroppable)
        #expect(!WireMessage.command(Sample.commands[0]).isDroppable)
        #expect(!WireMessage.ping(Ping(id: 1, t0: 0)).isDroppable)
        #expect(!WireMessage.pong(Pong(id: 1, t0: 0, t1: 0, t2: 0)).isDroppable)
    }
}
