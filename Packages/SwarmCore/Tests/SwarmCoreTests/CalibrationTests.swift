import Foundation
import simd
import Testing
@testable import SwarmCore

/// Gate 3 — marker sightings are continuing pose corrections, not just initial
/// calibration. Operators walk, so drift accumulates and every re-sighting is a
/// fix.
@Suite("Gate 3: calibration and corrections")
struct CalibrationTests {

    private func rigid(x: Float, y: Float, z: Float, yaw: Float, pitch: Float = 0, roll: Float = 0) -> Pose {
        let q = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        return Pose(position: SIMD3<Float>(x, y, z), orientation: simd_normalize(q))
    }

    private func venue(markers: [VenueMarker]? = nil,
                       thresholds: Venue.Thresholds = Venue.Thresholds()) -> Venue {
        let defaults = [
            VenueMarker(id: "primary", physicalWidth: 0.2965,
                        position: [0, 1.6, 0], quaternion: [0, 0, 0, 1], isPrimary: true),
            VenueMarker(id: "east", physicalWidth: 0.21,
                        position: [4.98, 1.55, 3.02],
                        quaternion: Pose(position: .zero,
                                         orientation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
                            .wireQuaternion,
                        isPrimary: false),
        ]
        return Venue(id: "test", name: "test venue", markers: markers ?? defaults, thresholds: thresholds)
    }

    // MARK: - The core identity

    /// If a marker whose true venue pose is `M` is observed at `R · M`, the
    /// transform that re-origins the world is exactly `R`.
    @Test func worldOriginTransformRecoversTheKnownOffset() {
        let markerVenue = rigid(x: 0, y: 1.6, z: 0, yaw: 0)
        let trueOrigin = rigid(x: 2.5, y: 0, z: -1.25, yaw: 0.9)
        let observed = trueOrigin * markerVenue

        let recovered = Calibration.worldOriginTransform(observed: observed, markerVenue: markerVenue)
        #expect(isClose(Geometry.distance(recovered.position, trueOrigin.position), 0, within: 1e-5))
        #expect(isClose(Geometry.angle(between: recovered.orientation, and: trueOrigin.orientation), 0, within: 1e-5))
    }

    /// The point of that transform: applying it puts the camera where it really
    /// is. `setWorldOrigin(R)` maps a point `p` to `R⁻¹ · p`.
    @Test func applyingTheTransformPutsPosesInTheVenueFrame() {
        let markerVenue = rigid(x: 0, y: 1.6, z: 0, yaw: 0)
        let sessionOrigin = rigid(x: -3.1, y: 0, z: 4.4, yaw: -2.2)
        let trueCamera = rigid(x: 1.2, y: 1.5, z: 3.3, yaw: 0.6, pitch: -0.1)

        let reportedCamera = sessionOrigin * trueCamera
        let observedMarker = sessionOrigin * markerVenue
        let correction = Calibration.worldOriginTransform(observed: observedMarker, markerVenue: markerVenue)

        let corrected = correction.inverse * reportedCamera
        #expect(isClose(Geometry.distance(corrected.position, trueCamera.position), 0, within: 1e-4))
        #expect(isClose(Geometry.angle(between: corrected.orientation, and: trueCamera.orientation), 0, within: 1e-4))
    }

    /// A correctly calibrated session sighting the same marker again implies the
    /// identity: nothing to correct.
    @Test func aPerfectlyCalibratedSessionNeedsNoCorrection() {
        let markerVenue = rigid(x: 0, y: 1.6, z: 0, yaw: 0)
        let correction = Calibration.worldOriginTransform(observed: markerVenue, markerVenue: markerVenue)
        #expect(isClose(simd_length(correction.position), 0, within: 1e-6))
        #expect(isClose(Geometry.angle(between: correction.orientation,
                                       and: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), 0, within: 1e-6))
    }

    /// The venue frame is defined by the primary marker, so a marker on the far
    /// wall must produce the same origin as the primary one.
    @Test func differentMarkersAgreeOnTheSameOrigin() throws {
        let venue = venue()
        let trueOrigin = rigid(x: 1.75, y: 0, z: -0.5, yaw: 2.6)
        var poses: [Pose] = []
        for marker in venue.markers {
            let markerVenue = try #require(marker.pose)
            let observed = trueOrigin * markerVenue
            poses.append(Calibration.worldOriginTransform(observed: observed, markerVenue: markerVenue))
        }
        for pose in poses {
            #expect(isClose(Geometry.distance(pose.position, trueOrigin.position), 0, within: 1e-4))
        }
    }

    // MARK: - Multi-marker averaging

    @Test func averagingIsExactWhenEveryMarkerAgrees() {
        let truth = rigid(x: 1, y: 0.5, z: -2, yaw: 0.4)
        let averaged = Calibration.average([truth, truth, truth])
        let result = try! #require(averaged)
        #expect(isClose(Geometry.distance(result.position, truth.position), 0, within: 1e-5))
        #expect(isClose(Geometry.angle(between: result.orientation, and: truth.orientation), 0, within: 1e-5))
    }

    /// Small independent errors on several markers should partly cancel. This is
    /// the entire argument for putting up more than one marker.
    @Test func averagingReducesIndependentMarkerError() {
        var generator = SeededGenerator(seed: 90210)
        let truth = rigid(x: 1, y: 0, z: -2, yaw: 0.4)
        var worstSingle: Float = 0
        var totalSingle: Float = 0
        var estimates: [Pose] = []
        for _ in 0..<4 {
            let noisy = Pose(
                position: truth.position + SIMD3<Float>(Float(generator.gaussian(deviation: 0.05)),
                                                        Float(generator.gaussian(deviation: 0.05)),
                                                        Float(generator.gaussian(deviation: 0.05))),
                orientation: simd_normalize(truth.orientation
                              * simd_quatf(angle: Float(generator.gaussian(deviation: 0.01)),
                                           axis: SIMD3<Float>(0, 1, 0))))
            estimates.append(noisy)
            let error = Geometry.distance(noisy.position, truth.position)
            worstSingle = max(worstSingle, error)
            totalSingle += error
        }
        let averaged = try! #require(Calibration.average(estimates))
        let averagedError = Geometry.distance(averaged.position, truth.position)
        #expect(averagedError < totalSingle / 4,
                "averaging \(averagedError) did not beat the mean single-marker error \(totalSingle / 4)")
        #expect(averagedError < worstSingle)
    }

    @Test func averagingHandlesOppositeQuaternionSigns() {
        let truth = rigid(x: 0, y: 0, z: 0, yaw: 1.1)
        let flipped = Pose(position: truth.position,
                           orientation: simd_quatf(vector: -truth.orientation.vector))
        // q and −q are the same rotation. Summing naively would cancel them.
        let averaged = try! #require(Calibration.average([truth, flipped]))
        #expect(isClose(Geometry.angle(between: averaged.orientation, and: truth.orientation), 0, within: 1e-4))
    }

    @Test func averagingAnEmptySetReturnsNil() {
        #expect(Calibration.average([]) == nil)
    }

    // MARK: - Acceptance, rejection and clamping

    @Test func theFirstSightingEstablishesTheOriginWithoutClamping() throws {
        var engine = CalibrationEngine(venue: venue())
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        // An arbitrary session origin: 6 m away and rotated 100 degrees. Nothing
        // to disagree with yet, so it must be applied in full.
        let sessionOrigin = rigid(x: 4, y: 0, z: -4.5, yaw: 1.75)
        let sighting = MarkerSighting(markerID: "primary",
                                      observedTransform: (sessionOrigin * markerVenue).matrix,
                                      deviceTimestamp: 100, isUpdate: false)

        guard case .originEstablished(let correction) = engine.evaluate(sighting) else {
            Issue.record("first sighting must establish the origin")
            return
        }
        #expect(!correction.wasClamped)
        #expect(engine.correctionAge(at: 100) == 0)
        let applied = Pose(matrix: correction.relativeTransform)
        #expect(isClose(Geometry.distance(applied.position, sessionOrigin.position), 0, within: 1e-4))
    }

    /// A misdetection — the wrong marker, a mirrored print, glare — implies an
    /// origin metres away from the current estimate. Applying it would teleport
    /// the cone across the room.
    @Test func rejectsAnObservationThatDisagreesBeyondTheThreshold() throws {
        var engine = CalibrationEngine(venue: venue())
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))

        let bogus = rigid(x: 9, y: 0, z: 0, yaw: 0) * markerVenue
        let outcome = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: bogus.matrix,
                                                     deviceTimestamp: 10, isUpdate: true))
        guard case .rejected(.disagreesBeyondThreshold(let metres, _)) = outcome else {
            Issue.record("expected rejection, got \(outcome)")
            return
        }
        #expect(metres > 1.5)
        #expect(engine.rejectedCount == 1)
        #expect(engine.correctionAge(at: 10) == 10, "a rejected sighting is not a correction")
    }

    @Test func rejectsARotationThatDisagreesBeyondTheThreshold() throws {
        var engine = CalibrationEngine(venue: venue())
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))
        let spun = rigid(x: 0, y: 0, z: 0, yaw: .pi / 3) * markerVenue
        let outcome = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: spun.matrix,
                                                     deviceTimestamp: 10, isUpdate: true))
        guard case .rejected(.disagreesBeyondThreshold(_, let degrees)) = outcome else {
            Issue.record("expected rejection, got \(outcome)")
            return
        }
        #expect(degrees > 25)
    }

    @Test func rejectsAMarkerThatIsNotInTheVenue() {
        var engine = CalibrationEngine(venue: venue())
        let outcome = engine.evaluate(MarkerSighting(markerID: "poster-in-the-hallway",
                                                     observedTransform: matrix_identity_float4x4,
                                                     deviceTimestamp: 0, isUpdate: false))
        #expect(outcome == .rejected(.unknownMarker("poster-in-the-hallway")))
    }

    /// A large but plausible correction is applied in steps, so the cone
    /// converges instead of teleporting.
    @Test func largeCorrectionsAreClampedToTheConfiguredStep() throws {
        let thresholds = Venue.Thresholds(rejectPositionMeters: 2.0, rejectRotationDegrees: 30,
                                          maxStepMeters: 0.25, maxStepDegrees: 5)
        var engine = CalibrationEngine(venue: venue(thresholds: thresholds))
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))

        let drifted = rigid(x: 1.2, y: 0, z: 0.4, yaw: 0.2) * markerVenue
        let outcome = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: drifted.matrix,
                                                     deviceTimestamp: 10, isUpdate: true))
        guard case .corrected(let correction) = outcome else {
            Issue.record("expected a correction, got \(outcome)")
            return
        }
        #expect(correction.wasClamped)
        #expect(correction.measuredPositionError > 1.2, "the full error must still be reported honestly")
        let applied = Pose(matrix: correction.relativeTransform)
        #expect(simd_length(applied.position) <= 0.25 + 1e-5,
                "applied a \(simd_length(applied.position)) m jump against a 0.25 m limit")
        let degrees = Geometry.angle(between: applied.orientation,
                                     and: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) * 180 / .pi
        #expect(degrees <= 5 + 1e-3, "applied a \(degrees) degree jump against a 5 degree limit")
    }

    @Test func repeatedClampedCorrectionsConverge() throws {
        let thresholds = Venue.Thresholds(rejectPositionMeters: 2.0, rejectRotationDegrees: 30,
                                          maxStepMeters: 0.25, maxStepDegrees: 5)
        var engine = CalibrationEngine(venue: venue(thresholds: thresholds))
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))

        // The world as ARKit currently believes it, drifted 1.2 m.
        var worldOffset = rigid(x: 1.2, y: 0, z: 0.4, yaw: 0.2)
        var errors: [Float] = []
        for step in 1...20 {
            let observed = worldOffset * markerVenue
            let outcome = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: observed.matrix,
                                                         deviceTimestamp: Double(step) * 2, isUpdate: true))
            errors.append(simd_length(worldOffset.position))
            switch outcome {
            case .corrected(let correction):
                // setWorldOrigin composes: the world moves by the inverse.
                worldOffset = Pose(matrix: correction.relativeTransform).inverse * worldOffset
            case .noChangeNeeded:
                break
            default:
                Issue.record("unexpected outcome at step \(step): \(outcome)")
                return
            }
        }
        let finalError = simd_length(worldOffset.position)
        #expect(finalError < 0.05,
                "did not converge: started at \(errors.first ?? 0) m, ended at \(finalError) m")
        #expect(zip(errors, errors.dropFirst()).allSatisfy { $0 >= $1 - 1e-5 },
                "error went back up during convergence: \(errors)")
    }

    @Test func aSightingThatAlreadyAgreesIsNotAppliedAsNoise() throws {
        var engine = CalibrationEngine(venue: venue())
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))
        let tiny = rigid(x: 0.004, y: 0, z: -0.003, yaw: 0.0005) * markerVenue
        let outcome = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: tiny.matrix,
                                                     deviceTimestamp: 10, isUpdate: true))
        #expect(outcome == .noChangeNeeded(markerID: "primary"))
    }

    /// `didUpdate` fires far faster than the world needs re-originning.
    @Test func sightingsFasterThanTheMinimumIntervalAreIgnored() throws {
        var engine = CalibrationEngine(venue: venue(),
                                       configuration: .init(minimumInterval: 0.5))
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))
        let drifted = rigid(x: 0.3, y: 0, z: 0, yaw: 0) * markerVenue
        var applied = 0
        for step in 1...30 {
            let outcome = engine.evaluate(MarkerSighting(
                markerID: "primary", observedTransform: drifted.matrix,
                deviceTimestamp: Double(step) / 60.0, isUpdate: true))
            if case .corrected = outcome { applied += 1 }
        }
        #expect(applied <= 1, "re-originned the world \(applied) times in half a second")
    }

    @Test func interruptionInvalidatesTheOrigin() throws {
        var engine = CalibrationEngine(venue: venue())
        let markerVenue = try #require(venue().marker(id: "primary")?.pose)
        _ = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: markerVenue.matrix,
                                           deviceTimestamp: 0, isUpdate: false))
        #expect(engine.hasOrigin)
        engine.invalidateOrigin()
        #expect(!engine.hasOrigin)

        // After an interruption ARKit's frame is arbitrary again, so even a wild
        // disagreement must be accepted rather than rejected as a misdetection.
        let wild = rigid(x: 12, y: 0, z: -7, yaw: 2.9) * markerVenue
        let outcome = engine.evaluate(MarkerSighting(markerID: "primary", observedTransform: wild.matrix,
                                                     deviceTimestamp: 60, isUpdate: false))
        guard case .originEstablished = outcome else {
            Issue.record("expected the origin to be re-established, got \(outcome)")
            return
        }
    }

    // MARK: - Against the replayed fixture

    /// The real claim: replaying a recorded walk with corrections enabled ends
    /// closer to ground truth than replaying it without, and no single
    /// correction moves the world further than the venue allows.
    @Test func correctionsReduceAccumulatedDriftOverTheReplayedWalk() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let truth = try #require(trajectory.groundTruth,
                                 "this assertion needs a fixture with known ground truth")
        let venue = try Venue.load(from: Fixtures.url("venue.json"))

        let uncorrected = try await replayError(trajectory: trajectory, truth: truth,
                                                venue: venue, applyCorrections: false)
        let corrected = try await replayError(trajectory: trajectory, truth: truth,
                                              venue: venue, applyCorrections: true)

        #expect(corrected.finalError < uncorrected.finalError,
                "corrections did not help: \(corrected.finalError) m vs \(uncorrected.finalError) m")
        #expect(corrected.meanError < uncorrected.meanError,
                "mean error \(corrected.meanError) m vs \(uncorrected.meanError) m")
        #expect(corrected.finalError < 0.30,
                "still \(corrected.finalError) m out after two minutes of corrections")
        let limit = venue.thresholds.maxStepMeters
        #expect(corrected.largestAppliedStep <= limit + 1e-4,
                "a correction jumped \(corrected.largestAppliedStep) m, over the \(limit) m limit")
        #expect(corrected.corrections > 3, "only \(corrected.corrections) corrections were applied")
    }

    private struct ReplayResult {
        var finalError: Float
        var meanError: Float
        var largestAppliedStep: Float
        var corrections: Int
    }

    /// Replays through `MockPoseProvider` in lockstep, so a correction applied on
    /// sighting N actually reaches sample N+1 — which is the whole behaviour
    /// under test.
    private func replayError(trajectory: Trajectory, truth: [Trajectory.Sample],
                             venue: Venue, applyCorrections: Bool) async throws -> ReplayResult {
        let provider = MockPoseProvider(trajectory: trajectory,
                                        configuration: .init(lockstep: true))
        var engine = CalibrationEngine(venue: venue)
        var truthByTime: [Double: Pose] = [:]
        for sample in truth {
            if let pose = sample.pose { truthByTime[sample.t] = pose }
        }

        var errorSum: Float = 0
        var errorCount = 0
        var finalError: Float = 0
        var largestStep: Float = 0
        var corrections = 0
        var established = false

        let stream = try await provider.start()
        for await event in stream {
            switch event {
            case .pose(let sample):
                guard established, let expected = truthByTime[sample.deviceTimestamp] else { break }
                let error = Geometry.distance(sample.pose.position, expected.position)
                errorSum += error
                errorCount += 1
                finalError = error
            case .marker(let sighting):
                let outcome = engine.evaluate(sighting)
                switch outcome {
                case .originEstablished(let correction):
                    established = true
                    await provider.setWorldOrigin(relativeTransform: correction.relativeTransform)
                case .corrected(let correction) where applyCorrections:
                    corrections += 1
                    largestStep = max(largestStep, simd_length(Pose(matrix: correction.relativeTransform).position))
                    await provider.setWorldOrigin(relativeTransform: correction.relativeTransform)
                default:
                    break
                }
            default:
                break
            }
            await provider.advance()
        }

        #expect(established, "the fixture never established an origin")
        #expect(errorCount > 1_000, "only \(errorCount) samples were compared against ground truth")
        return ReplayResult(finalError: finalError,
                            meanError: errorCount > 0 ? errorSum / Float(errorCount) : .infinity,
                            largestAppliedStep: largestStep,
                            corrections: corrections)
    }
}
