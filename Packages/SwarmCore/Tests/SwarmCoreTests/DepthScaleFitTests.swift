import Foundation
import simd
import Testing
@testable import SwarmCore

/// Gate 5 — VGGT-Ω depth is scene-normalized, not metres. Each chunk comes back
/// with an arbitrary origin and an arbitrary scale, and the only metric thing
/// the phone has is ARKit's camera baselines.
@Suite("Gate 5: depth scale fitting")
struct DepthScaleFitTests {

    /// A camera path with real parallax, in metres.
    private func metricCameras(count: Int = 6, step: Float = 0.22) -> [SIMD3<Float>] {
        (0..<count).map { index in
            SIMD3<Float>(Float(index) * step, 1.5 + Float(index) * 0.01, 3.0 - Float(index) * step * 0.4)
        }
    }

    /// What the network would return for that path in its own units, having
    /// normalized the scene by `factor`.
    private func normalized(_ cameras: [SIMD3<Float>], by factor: Float,
                            origin: SIMD3<Float> = SIMD3<Float>(11, -4, 7)) -> [SIMD3<Float>] {
        // An arbitrary origin as well as an arbitrary scale — the fit must be
        // insensitive to where the reconstruction put its own zero.
        cameras.map { origin + $0 / factor }
    }

    // MARK: - Recovering a known factor

    @Test(arguments: [0.5, 1.0, 2.75, 13.4, 108.0] as [Float])
    func recoversAKnownScaleFactorWithinTwoPercent(factor: Float) throws {
        let metric = metricCameras()
        let predicted = normalized(metric, by: factor)
        let result = try #require(DepthScaleFit.fit(predictedCameras: predicted, metricCameras: metric))
        let error = abs(result.scale - factor) / factor
        #expect(error <= 0.02, "recovered \(result.scale) for a true factor of \(factor): \(error * 100)% out")
        #expect(result.inlierFraction == 1.0)
        #expect(result.method == .cameraBaselines)
    }

    /// The point of the factor: a depth map in the network's units becomes metres.
    @Test func scaledDepthMapsComeOutInMetres() throws {
        let factor: Float = 7.25
        let metric = metricCameras()
        let predicted = normalized(metric, by: factor)
        let trueDepthsInMetres: [Float] = [0.8, 1.2, 2.4, 3.9, 5.0, 12.5]
        let sceneNormalized = trueDepthsInMetres.map { $0 / factor }

        let result = try #require(DepthScaleFit.fit(predictedCameras: predicted, metricCameras: metric))
        let metres = try #require(DepthScaleFit.toMetres(sceneNormalized, scale: result.scale))
        for (recovered, expected) in zip(metres, trueDepthsInMetres) {
            #expect(abs(recovered - expected) / expected <= 0.02,
                    "recovered \(recovered) m where the truth is \(expected) m")
        }
    }

    @Test func fittingIsInsensitiveToTheReconstructionsOwnOrigin() throws {
        let metric = metricCameras()
        let near = normalized(metric, by: 3.0, origin: .zero)
        let far = normalized(metric, by: 3.0, origin: SIMD3<Float>(-940, 512, 77))
        let a = try #require(DepthScaleFit.fit(predictedCameras: near, metricCameras: metric))
        let b = try #require(DepthScaleFit.fit(predictedCameras: far, metricCameras: metric))
        #expect(isClose(a.scale, b.scale, within: 1e-3))
    }

    // MARK: - Outliers

    /// One badly reconstructed camera in a chunk of six is well inside what a
    /// median survives. A least-squares fit would be dragged by it.
    @Test func survivesAWildlyWrongCamera() throws {
        let factor: Float = 4.0
        let metric = metricCameras()
        var predicted = normalized(metric, by: factor)
        predicted[3] += SIMD3<Float>(9, -4, 6)

        let result = try #require(DepthScaleFit.fit(predictedCameras: predicted, metricCameras: metric))
        #expect(abs(result.scale - factor) / factor <= 0.02,
                "one bad camera moved the scale to \(result.scale) from \(factor)")
        #expect(result.inlierFraction < 1.0, "the bad pairs should be visible in the inlier fraction")
        #expect(result.relativeSpread > 0)
    }

    /// Twenty percent of depth readings corrupted, which is a realistic figure
    /// for a reconstruction over a reflective floor or a blank wall.
    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func recoversScaleWithTwentyPercentOutlierDepths(seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed)
        let factor: Float = 6.3
        var normalizedDepths: [Float] = []
        var metricDepths: [Float] = []

        for index in 0..<200 {
            let metres = Float(generator.uniform(0.6...9.0))
            metricDepths.append(metres)
            if index % 5 == 0 {
                // A fifth of them are nonsense: a hole, a mirror, a blown-out
                // sky region the network guessed at.
                normalizedDepths.append(Float(generator.uniform(0.01...4.0)))
            } else {
                // The rest carry a little honest noise.
                normalizedDepths.append(metres / factor * Float(1 + generator.gaussian(deviation: 0.01)))
            }
        }

        let result = try #require(DepthScaleFit.fit(normalizedDepths: normalizedDepths,
                                                    metricDepths: metricDepths))
        let error = abs(result.scale - factor) / factor
        #expect(error <= 0.02, "seed \(seed): recovered \(result.scale) against \(factor), \(error * 100)% out")
        #expect(result.method == .depthCorrespondences)
        #expect(result.inlierFraction >= 0.6, "inlier fraction \(result.inlierFraction) with 20% outliers")
    }

    @Test func nonFiniteAndNegativeDepthsAreIgnoredRatherThanPoisoning() throws {
        let factor: Float = 2.5
        var normalizedDepths: [Float] = (1...20).map { Float($0) / factor }
        var metricDepths: [Float] = (1...20).map { Float($0) }
        normalizedDepths.append(contentsOf: [.nan, .infinity, -1, 0])
        metricDepths.append(contentsOf: [1, 1, 1, 1])

        let result = try #require(DepthScaleFit.fit(normalizedDepths: normalizedDepths,
                                                    metricDepths: metricDepths))
        #expect(abs(result.scale - factor) / factor <= 0.02)
        #expect(result.sampleCount == 20, "junk readings were counted as samples")
    }

    // MARK: - Refusing to guess

    /// A stationary phone gives no parallax and no scale. Returning a number here
    /// would be worse than returning nothing, because the dashboard would draw it
    /// as though it had been measured.
    @Test func returnsNilWhenTheBaselineIsNearZero() {
        let stationary = (0..<6).map { index in
            SIMD3<Float>(0.002 * Float(index), 1.5, 3.0 + 0.001 * Float(index))
        }
        let predicted = normalized(stationary, by: 4.0)
        #expect(DepthScaleFit.fit(predictedCameras: predicted, metricCameras: stationary) == nil)
    }

    @Test(arguments: [0.0, 0.01, 0.05, 0.11] as [Float])
    func refusesEveryBaselineBelowTheMinimum(step: Float) {
        let cameras = (0..<6).map { SIMD3<Float>(Float($0) * step / 5, 1.5, 3) }
        let predicted = normalized(cameras, by: 3.0)
        #expect(DepthScaleFit.fit(predictedCameras: predicted, metricCameras: cameras,
                                  minimumBaseline: 0.12) == nil,
                "invented a scale from \(step) m of parallax")
    }

    @Test func returnsNilForMismatchedOrEmptyInput() {
        #expect(DepthScaleFit.fit(predictedCameras: [], metricCameras: []) == nil)
        #expect(DepthScaleFit.fit(predictedCameras: [.zero], metricCameras: [.zero]) == nil)
        #expect(DepthScaleFit.fit(predictedCameras: [.zero, .one],
                                  metricCameras: [.zero]) == nil)
        #expect(DepthScaleFit.fit(normalizedDepths: [], metricDepths: []) == nil)
        #expect(DepthScaleFit.fit(normalizedDepths: [1, 2], metricDepths: [1]) == nil)
    }

    /// Every predicted camera identical: the reconstruction collapsed. There is
    /// no ratio to take.
    @Test func returnsNilWhenTheReconstructionCollapsed() {
        let metric = metricCameras()
        let collapsed = Array(repeating: SIMD3<Float>(1, 1, 1), count: metric.count)
        #expect(DepthScaleFit.fit(predictedCameras: collapsed, metricCameras: metric) == nil)
    }

    // MARK: - Baselines

    @Test func widestBaselineIsTheWidestPairNotTheFirstToLast() {
        // A path that goes out and comes back: the endpoints are close together
        // but the excursion is what gave the reconstruction its parallax.
        let cameras = [
            SIMD3<Float>(0, 1.5, 3),
            SIMD3<Float>(0.9, 1.5, 3),
            SIMD3<Float>(1.4, 1.5, 3),
            SIMD3<Float>(0.1, 1.5, 3),
        ]
        #expect(isClose(DepthScaleFit.widestBaseline(of: cameras), 1.4, within: 1e-5))
    }

    @Test func widestBaselineOfFewerThanTwoCamerasIsZero() {
        #expect(DepthScaleFit.widestBaseline(of: [] as [SIMD3<Float>]) == 0)
        #expect(DepthScaleFit.widestBaseline(of: [SIMD3<Float>(1, 2, 3)]) == 0)
    }

    // MARK: - ServerDepthSource

    @Test func serverDepthSourceReturnsMetricDepth() async throws {
        let factor: Float = 9.1
        let metric = metricCameras()
        let request = DepthRequest(chunkID: 4, frames: metric.enumerated().map { index, position in
            DepthChunk.FrameRef(frameID: UInt64(index), serverTimestamp: 1_000 + Double(index) * 0.7,
                                position: [position.x, position.y, position.z], quaternion: [0, 0, 0, 1])
        })
        let trueMetres: [Float] = [1.0, 2.0, 3.0, 4.0]
        let estimate = ServerDepthEstimate(
            chunkID: 4,
            predictedCameras: normalized(metric, by: factor),
            maps: [DepthMap(width: 2, height: 2, values: trueMetres.map { $0 / factor })])

        let source = ServerDepthSource { _ in estimate }
        #expect(!source.isNativelyMetric)
        let result = try #require(try await source.depth(for: request))
        #expect(abs(result.appliedScale - factor) / factor <= 0.02)
        for (recovered, expected) in zip(result.maps[0].values, trueMetres) {
            #expect(abs(recovered - expected) / expected <= 0.02)
        }
    }

    @Test func serverDepthSourceThrowsRatherThanGuessingWithoutParallax() async throws {
        let stationary = (0..<6).map { SIMD3<Float>(0.001 * Float($0), 1.5, 3) }
        let request = DepthRequest(chunkID: 5, frames: stationary.enumerated().map { index, position in
            DepthChunk.FrameRef(frameID: UInt64(index), serverTimestamp: Double(index),
                                position: [position.x, position.y, position.z], quaternion: [0, 0, 0, 1])
        })
        let source = ServerDepthSource { _ in
            ServerDepthEstimate(chunkID: 5, predictedCameras: stationary,
                                maps: [DepthMap(width: 1, height: 1, values: [0.5])])
        }
        await #expect(throws: DepthSourceError.scaleNotRecoverable) {
            _ = try await source.depth(for: request)
        }
    }

    @Test func serverDepthSourceRejectsAMalformedEstimate() async throws {
        let metric = metricCameras()
        let request = DepthRequest(chunkID: 6, frames: metric.map { position in
            DepthChunk.FrameRef(frameID: 0, serverTimestamp: 0,
                                position: [position.x, position.y, position.z], quaternion: [0, 0, 0, 1])
        })
        let source = ServerDepthSource { _ in
            // A map whose values do not match its declared size.
            ServerDepthEstimate(chunkID: 6, predictedCameras: metric,
                                maps: [DepthMap(width: 4, height: 4, values: [1, 2, 3])])
        }
        await #expect(throws: DepthSourceError.malformedEstimate) {
            _ = try await source.depth(for: request)
        }
    }

    @Test func serverDepthSourceRefusesAChunkThatDisagreesWithItself() async throws {
        let metric = metricCameras()
        let request = DepthRequest(chunkID: 7, frames: metric.map { position in
            DepthChunk.FrameRef(frameID: 0, serverTimestamp: 0,
                                position: [position.x, position.y, position.z], quaternion: [0, 0, 0, 1])
        })
        var generator = SeededGenerator(seed: 4)
        // Cameras scattered at random: there is no consistent scale to find, and
        // the source must say so rather than publish the median of nonsense.
        let scattered = metric.map { _ in
            SIMD3<Float>(Float(generator.uniform(-5...5)),
                         Float(generator.uniform(-5...5)),
                         Float(generator.uniform(-5...5)))
        }
        let source = ServerDepthSource(minimumInlierFraction: 0.9) { _ in
            ServerDepthEstimate(chunkID: 7, predictedCameras: scattered,
                                maps: [DepthMap(width: 1, height: 1, values: [1])])
        }
        await #expect(throws: DepthSourceError.scaleNotRecoverable) {
            _ = try await source.depth(for: request)
        }
    }

    // MARK: - Against the replayed fixtures

    /// The walk gives parallax; the stationary sweep does not. Both come from
    /// the recorded fixtures rather than from numbers invented here.
    @Test func replayedWalkHasUsableParallaxAndTheStationarySweepDoesNot() async throws {
        func baselines(fixture: String) async throws -> [Float] {
            let harness = try ReplayHarness(fixture: fixture)
            let chunks = try await harness.run().depthChunks
            return chunks.map(\.baseline)
        }

        let walking = try await baselines(fixture: "trajectory-walk-2min.json")
        #expect(!walking.isEmpty)
        #expect(walking.allSatisfy { $0 >= 0.12 })

        let still = try await baselines(fixture: "trajectory-stationary-30s.json")
        #expect(still.isEmpty, "the stationary sweep produced \(still.count) chunks with parallax")
    }
}
