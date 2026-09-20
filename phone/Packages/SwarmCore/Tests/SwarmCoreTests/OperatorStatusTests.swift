import Foundation
import Testing
@testable import SwarmCore

/// The status line replaced `LOST conf 1.00 fix 34s air 1 drop 0`. It has to say
/// one thing, the most important thing, and what to do about it.
@Suite("Operator status: one plain sentence")
struct OperatorStatusTests {
    private func pill(_ state: SessionState = .tracking, alignment: RoomAligner.Source = .marker,
                      connection: StatusPill.ConnectionState = .online, stale: Bool = false,
                      thermal: ThermalState = .nominal, correction: Double? = 2,
                      disconnected: Double? = nil) -> StatusPill {
        StatusPill(sessionState: state, confidence: 1, isStale: stale, connection: connection,
                   thermalState: thermal, secondsSinceCorrection: correction,
                   secondsDisconnected: disconnected, alignment: alignment)
    }

    /// Longer than `connectingGraceSeconds`: the connection is genuinely down.
    private let givenUp: Double = 60

    @Test func healthyIsOneWord() {
        let status = OperatorStatus(pill())
        #expect(status == OperatorStatus(level: .ok, title: "Tracking"))
        #expect(OperatorStatus(pill(.calibrating, alignment: .seat, correction: nil)).title == "Tracking from your spot")
    }

    /// The case from the screenshot that prompted this.
    @Test func recalibratingSaysSoAndOffersTheFix() {
        let status = OperatorStatus(pill(.recalibrating, alignment: .none, correction: nil))
        #expect(status.level == .attention)
        #expect(status.title == "Needs recalibrating")
        #expect(status.hint?.contains("marker") == true)
    }

    /// There is one way to get located, and every prompt that mentions it has
    /// to name that one way. A hint that also offered "or tap here" described a
    /// seat-picker card that no longer exists.
    @Test func gettingLocatedAlwaysMeansTheMarker() {
        let status = OperatorStatus(pill(.calibrating, alignment: .none, correction: nil))
        #expect(status.title == "Not located yet")
        #expect(status.hint == "Point the camera at a printed marker")
        #expect(status.hint?.contains("tap") == false, "there is no tap-your-spot card any more")
    }

    @Test func lostIsAProblemWithAnInstruction() {
        let status = OperatorStatus(pill(.lost))
        #expect(status.level == .problem)
        #expect(status.title == "Tracking lost")
        #expect(status.hint != nil)
    }

    /// A phone that cannot reach the hub has no use for tracking advice.
    @Test func theConnectionOutranksEverything() {
        for state in SessionState.allCases {
            let status = OperatorStatus(pill(state, connection: .reconnecting, stale: true,
                                             thermal: .critical, disconnected: givenUp))
            #expect(status.title == "Reconnecting…", "\(state) hid the dropped connection")
            #expect(status.level == .problem)
        }
        let connecting = OperatorStatus(pill(connection: .connecting, disconnected: givenUp))
        #expect(connecting.title == "Connecting…")
        #expect(connecting.hint == "Check the venue Wi-Fi")
    }

    /// Opening the app used to begin with a red warning triangle and "Check
    /// the venue Wi-Fi", for a phone that was doing nothing worse than dialling
    /// the hub. It says the same thing, quietly, until it has been trying long
    /// enough for that to be news.
    @Test func dialTheHubQuietlyBeforeCallingItAProblem() {
        for connection in [StatusPill.ConnectionState.offline, .connecting, .reconnecting] {
            let fresh = OperatorStatus(pill(connection: connection, disconnected: 2))
            #expect(fresh.level == .attention, "\(connection) went red while it was still dialling")
            #expect(fresh.hint == nil, "\(connection) told the operator to fix a working connection")

            let stuck = OperatorStatus(pill(connection: connection,
                                            disconnected: OperatorStatus.connectingGraceSeconds + 1))
            #expect(stuck.level == .problem, "\(connection) never escalated")
            #expect(stuck.hint == "Check the venue Wi-Fi")
        }
        // A pill nobody is timing is treated as fresh, not as forever.
        #expect(OperatorStatus(pill(connection: .connecting)).level == .attention)
    }

    @Test func secondaryConditionsOnlySurfaceWhenNothingWorseIsWrong() {
        #expect(OperatorStatus(pill(thermal: .serious)).title == "Phone is hot")
        #expect(OperatorStatus(pill(correction: 200)).title == "Position may be drifting")
        #expect(OperatorStatus(pill(correction: 45)).level == .ok,
                "a marker fix 45 s old is an ordinary sweep, not a warning")
        #expect(OperatorStatus(pill(alignment: .seat, correction: nil)).level == .ok,
                "a seat-located phone has no marker fix to go stale")
        #expect(OperatorStatus(pill(.degraded)).title == "Tracking is shaky")
        #expect(OperatorStatus(pill(stale: true)).level == .problem)
        // Hot *and* lost: say the one that stops it working.
        #expect(OperatorStatus(pill(.lost, thermal: .critical)).title == "Tracking lost")
    }

    @Test func everyStateHasSomethingToSayAndProblemsAlwaysSayWhatToDo() {
        for state in SessionState.allCases {
            for alignment in [RoomAligner.Source.none, .seat, .marker] {
                let status = OperatorStatus(pill(state, alignment: alignment))
                #expect(!status.title.isEmpty)
                #expect(!status.title.contains("conf") && !status.title.contains("drop"))
                if status.level == .problem { #expect(status.hint != nil, "\(state)/\(alignment)") }
            }
        }
    }
}
