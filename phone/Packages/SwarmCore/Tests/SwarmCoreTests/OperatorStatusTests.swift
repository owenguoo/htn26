import Foundation
import Testing
@testable import SwarmCore

/// The status line replaced `LOST conf 1.00 fix 34s air 1 drop 0`. It has to say
/// one thing, the most important thing, and what to do about it.
@Suite("Operator status: one plain sentence")
struct OperatorStatusTests {
    private func pill(_ state: SessionState = .tracking, alignment: RoomAligner.Source = .marker,
                      connection: StatusPill.ConnectionState = .online, stale: Bool = false,
                      thermal: ThermalState = .nominal, correction: Double? = 2) -> StatusPill {
        StatusPill(sessionState: state, confidence: 1, isStale: stale, connection: connection,
                   thermalState: thermal, secondsSinceCorrection: correction, alignment: alignment)
    }

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
        #expect(status.offersSeatPicker, "tapping the status must be the way out")
    }

    @Test func notLocatedYetOffersTheSeatPicker() {
        let status = OperatorStatus(pill(.calibrating, alignment: .none, correction: nil))
        #expect(status.title == "Not located yet")
        #expect(status.offersSeatPicker)
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
            let status = OperatorStatus(pill(state, connection: .reconnecting, stale: true, thermal: .critical))
            #expect(status.title == "Reconnecting…", "\(state) hid the dropped connection")
            #expect(status.level == .problem)
        }
    }

    @Test func secondaryConditionsOnlySurfaceWhenNothingWorseIsWrong() {
        #expect(OperatorStatus(pill(thermal: .serious)).title == "Phone is hot")
        #expect(OperatorStatus(pill(correction: 45)).title == "Position may be drifting")
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
