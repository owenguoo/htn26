import CoreGraphics
import Foundation
import simd
import Testing
@testable import SwarmCore

/// The overlay that draws where the venue thinks a marker is. If this maths is
/// wrong the overlay lies, and an overlay that lies is worse than none — it
/// would have an operator "confirm" a calibration that is broken.
@Suite("Projection")
struct ProjectionTests {

    private let intrinsics = CameraIntrinsics(fx: 1_449.5, fy: 1_449.5, cx: 959.5, cy: 719.5,
                                              imageWidth: 1_920, imageHeight: 1_440)

    /// Camera at the origin looking down venue −Z, which is where a phone points
    /// when `yaw` is zero.
    private func camera(at position: SIMD3<Float> = .zero, yaw: Float = 0) -> Pose {
        Pose(position: position, orientation: simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
    }

    @Test func aPointStraightAheadLandsAtThePrincipalPoint() throws {
        let point = try #require(Projection.project(venuePoint: SIMD3(0, 0, -3),
                                                    camera: camera(), intrinsics: intrinsics))
        #expect(abs(point.x - 959.5) < 0.01)
        #expect(abs(point.y - 719.5) < 0.01)
    }

    /// Image rows count downward while the camera's +Y is up. Getting this
    /// backwards puts the overlay on the floor when the marker is on the wall.
    @Test func aPointAboveTheAxisLandsHigherInTheImage() throws {
        let above = try #require(Projection.project(venuePoint: SIMD3(0, 1, -3),
                                                    camera: camera(), intrinsics: intrinsics))
        let below = try #require(Projection.project(venuePoint: SIMD3(0, -1, -3),
                                                    camera: camera(), intrinsics: intrinsics))
        #expect(above.y < 719.5, "a point above the axis should have a smaller row index")
        #expect(below.y > 719.5)
        #expect(abs((719.5 - above.y) - (below.y - 719.5)) < 0.01, "asymmetric about the centre")
    }

    @Test func aPointToTheRightLandsToTheRightInTheImage() throws {
        let right = try #require(Projection.project(venuePoint: SIMD3(1, 0, -3),
                                                    camera: camera(), intrinsics: intrinsics))
        #expect(right.x > 959.5)
    }

    /// ARKit's camera looks down its own −Z. Forgetting that projects everything
    /// behind you onto the screen as though it were in front, mirrored — which
    /// looks like a plausible overlay pointing at nothing.
    @Test func pointsBehindTheCameraDoNotProject() {
        #expect(Projection.project(venuePoint: SIMD3(0, 0, 3),
                                   camera: camera(), intrinsics: intrinsics) == nil)
        #expect(Projection.project(venuePoint: .zero,
                                   camera: camera(), intrinsics: intrinsics) == nil)
    }

    /// Doubling the distance halves the offset from the centre. If this does not
    /// hold, the outline will not shrink correctly as the operator walks back
    /// and the overlay will disagree with the real marker at every distance but
    /// one.
    @Test func imageOffsetScalesInverselyWithDistance() throws {
        let near = try #require(Projection.project(venuePoint: SIMD3(1, 0, -2),
                                                   camera: camera(), intrinsics: intrinsics))
        let far = try #require(Projection.project(venuePoint: SIMD3(1, 0, -4),
                                                  camera: camera(), intrinsics: intrinsics))
        let nearOffset = near.x - 959.5
        let farOffset = far.x - 959.5
        #expect(abs(nearOffset - 2 * farOffset) < 0.01)
    }

    @Test func projectionFollowsTheCameraAsItTurns() throws {
        let target = SIMD3<Float>(0, 0, -3)
        let straight = try #require(Projection.project(venuePoint: target,
                                                       camera: camera(), intrinsics: intrinsics))
        // Turning the camera left moves the target rightward in the image.
        let turned = try #require(Projection.project(venuePoint: target,
                                                     camera: camera(yaw: 0.2), intrinsics: intrinsics))
        #expect(turned.x > straight.x)
    }

    // MARK: - Marker outlines

    /// The real primary marker, out of `venue.json`.
    ///
    /// Building one inline with an identity rotation is tempting and wrong: that
    /// puts the image in the venue's x–z plane with its normal straight up,
    /// which is a marker lying on the floor. All four corners come out at the
    /// same height and every assertion about "above" becomes vacuous.
    private func marker(width: Float? = nil, height: Float? = nil) throws -> VenueMarker {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        var marker = try #require(venue.primaryMarker)
        if let width { marker.physicalWidth = width }
        marker.physicalHeight = height ?? width ?? marker.physicalWidth
        return marker
    }

    @Test func aMarkerHasFourCornersTheRightDistanceApart() throws {
        let corners = try #require(Projection.corners(of: try marker(width: 0.18, height: 0.18)))
        #expect(corners.count == 4)
        // Adjacent corners are one edge apart; opposite corners are the diagonal.
        #expect(abs(simd_distance(corners[0], corners[1]) - 0.18) < 1e-5)
        #expect(abs(simd_distance(corners[1], corners[2]) - 0.18) < 1e-5)
        let diagonal = 0.18 * 2.0.squareRoot()
        #expect(abs(Double(simd_distance(corners[0], corners[2])) - diagonal) < 1e-4)
    }

    /// The image's up direction is the anchor's local −Z. If that is inverted the
    /// overlay is upside down, which is subtle enough to miss on a symmetric
    /// pattern and catastrophic on an asymmetric one.
    @Test func theFirstTwoCornersAreTheTopEdge() throws {
        let corners = try #require(Projection.corners(of: try marker()))
        #expect(corners[0].y > corners[3].y, "corner 0 should be above corner 3")
        #expect(corners[1].y > corners[2].y, "corner 1 should be above corner 2")
        #expect(corners[0].x < corners[1].x, "corner 0 should be left of corner 1")
    }

    /// Standing in front of a wall marker, its outline should be a sane quad
    /// around the centre of the image, the right way up.
    @Test func aMarkerAheadOutlinesAroundTheImageCentre() throws {
        let viewer = camera(at: SIMD3(0, 1.6, 2))
        let outline = try #require(Projection.outline(of: try marker(), camera: viewer,
                                                      intrinsics: intrinsics))
        #expect(outline.count == 4)
        for point in outline {
            #expect(point.x > 0 && point.x < 1_920, "corner escaped the image horizontally")
            #expect(point.y > 0 && point.y < 1_440, "corner escaped the image vertically")
        }
        // Top edge above bottom edge, in image rows.
        #expect(outline[0].y < outline[3].y)
        #expect(outline[0].x < outline[1].x)
    }

    @Test func aMarkerBehindTheCameraHasNoOutline() throws {
        // Standing behind the wall, looking away.
        let viewer = camera(at: SIMD3(0, 1.6, -2))
        #expect(try Projection.outline(of: marker(), camera: viewer, intrinsics: intrinsics) == nil)
    }

    /// Walking backwards must shrink the outline, and by the right ratio.
    @Test func theOutlineShrinksWithDistance() throws {
        func widthOfOutline(atZ z: Float) throws -> CGFloat {
            let outline = try #require(Projection.outline(of: try marker(),
                                                          camera: camera(at: SIMD3(0, 1.6, z)),
                                                          intrinsics: intrinsics))
            return outline[1].x - outline[0].x
        }
        let near = try widthOfOutline(atZ: 1)
        let far = try widthOfOutline(atZ: 2)
        #expect(near > far)
        #expect(abs(near - 2 * far) < 0.5, "outline did not shrink inversely with distance")
    }

    // MARK: - Against the venue and the replayed walk

    @Test func obliquityIsZeroHeadOnAndGrowsOffAxis() throws {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        // Straight out from the primary marker, which faces +Z.
        let headOn = Projection.visibleMarkers(in: venue, camera: camera(at: SIMD3(0, 1.6, 3)),
                                               intrinsics: intrinsics)
        let primary = try #require(headOn.first { $0.markerID == "marker-primary" })
        #expect(primary.obliquityDegrees < 1, "head-on obliquity was \\(primary.obliquityDegrees)")
        #expect(abs(primary.distance - 3) < 0.01)

        // Off to the side, viewing the same marker at a slant.
        let oblique = Projection.visibleMarkers(in: venue, camera: camera(at: SIMD3(3, 1.6, 3)),
                                                intrinsics: intrinsics)
        if let slanted = oblique.first(where: { $0.markerID == "marker-primary" }) {
            #expect(slanted.obliquityDegrees > 30)
        }
    }

    /// Replaying the recorded walk, the primary marker must be predicted as
    /// visible for a decent stretch — and never at a nonsense distance.
    @Test func theReplayedWalkSeesMarkersWhereItShould() async throws {
        let trajectory = try Fixtures.trajectory("trajectory-walk-2min.json")
        let truth = try #require(trajectory.groundTruth)
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        let intrinsics = try #require(trajectory.intrinsics)

        var framesWithAMarker = 0
        var distances: [Float] = []
        for sample in stride(from: 0, to: truth.count, by: 30).compactMap({ truth[$0].pose }) {
            let visible = Projection.visibleMarkers(in: venue, camera: sample, intrinsics: intrinsics)
                // Only count markers whose outline actually falls inside the frame.
                .filter { projection in
                    projection.outline.allSatisfy {
                        $0.x > 0 && $0.x < CGFloat(intrinsics.imageWidth)
                            && $0.y > 0 && $0.y < CGFloat(intrinsics.imageHeight)
                    }
                }
            if !visible.isEmpty { framesWithAMarker += 1 }
            distances.append(contentsOf: visible.map(\.distance))
        }
        #expect(framesWithAMarker > 20,
                "only \\(framesWithAMarker) sampled frames had a marker in view")
        #expect(distances.allSatisfy { $0 > 0.1 && $0 < 20 },
                "a predicted marker distance was implausible")
    }
}
