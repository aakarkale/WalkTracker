//
//  GeoMathTests.swift
//
//  Covers GeoMath: the geodesic helpers (haversine distance, initial bearing,
//  bearing difference) and the local tangent-plane projection that every other
//  piece of geometry in the app is built on (project, unproject and the
//  point-to-segment projection used by Polyline and the matcher).
//
//  A note on the expected distances below. They are NOT figures recalled from
//  an atlas. Each one was computed from the same haversine formula the code
//  implements, on a sphere of radius GeoMath.earthRadius (6 371 008.8 m). That
//  matters because a great-circle distance on a sphere and a true WGS-84
//  geodesic can differ by a few tenths of a percent, which is thousands of
//  metres at continental scale. These tests check that the implementation is
//  the spherical model it claims to be, not that the spherical model matches
//  the ellipsoid.
//
//  Tolerances are therefore tight. Both sides of each comparison are double
//  precision evaluations of the same expression, so anything looser would hide
//  a real mistake.
//

import Foundation
import XCTest
@testable import WalkTracker

final class GeoMathTests: XCTestCase {

    /// R * pi / 180: the length of one degree of arc on the model sphere.
    /// 6371008.8 * pi / 180 = 111195.08023353292 m.
    private let metresPerDegree = 111_195.080_233_532_92

    // MARK: - Haversine

    func testHaversineIsZeroForIdenticalCoordinates() {
        let c = Coordinate(latitude: 40.7128, longitude: -74.0060)
        XCTAssertEqual(GeoMath.haversine(c, c), 0, accuracy: 1e-9)
    }

    func testHaversineOneDegreeOfLatitude() {
        // Along a meridian, one degree is one degree of arc by definition.
        let distance = GeoMath.haversine(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 0)
        )
        XCTAssertEqual(distance, metresPerDegree, accuracy: 1e-3)
        XCTAssertEqual(distance, GeoMath.metresPerDegreeLatitude, accuracy: 1e-3)
    }

    func testHaversineOneDegreeOfLongitudeAtTheEquator() {
        // The equator is itself a great circle, so a degree of longitude there
        // is the same arc length as a degree of latitude anywhere.
        let distance = GeoMath.haversine(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1)
        )
        XCTAssertEqual(distance, metresPerDegree, accuracy: 1e-3)
    }

    func testHaversineOneDegreeOfLongitudeShrinksWithLatitude() {
        // cos(60 degrees) is exactly 0.5, so a degree of longitude at 60 N is
        // half the equatorial one.
        let atSixty = GeoMath.haversine(
            Coordinate(latitude: 60, longitude: 0),
            Coordinate(latitude: 60, longitude: 1)
        )
        XCTAssertEqual(atSixty, metresPerDegree / 2, accuracy: 0.5)
    }

    func testHaversineHalfwayAroundTheEquator() {
        // (0, 0) to (0, 180) is half the circumference of the model sphere:
        // pi * 6371008.8 = 20015114.442035925 m.
        let distance = GeoMath.haversine(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 180)
        )
        XCTAssertEqual(distance, .pi * GeoMath.earthRadius, accuracy: 1e-3)
        XCTAssertEqual(distance, 20_015_114.442_035_925, accuracy: 1.0)
    }

    func testHaversineQuarterMeridian() {
        // Equator to pole is a quarter of the great circle: pi * R / 2.
        let distance = GeoMath.haversine(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 90, longitude: 0)
        )
        XCTAssertEqual(distance, 10_007_557.221_017_96, accuracy: 1.0)
    }

    func testHaversineContinentalDistances() {
        // Both expected values were computed from this exact formula and
        // radius, then rounded to the metre. See the file header.
        let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let london = Coordinate(latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(GeoMath.haversine(newYork, london), 5_570_229.87, accuracy: 1.0)

        let paris = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let berlin = Coordinate(latitude: 52.5200, longitude: 13.4050)
        XCTAssertEqual(GeoMath.haversine(paris, berlin), 877_464.54, accuracy: 1.0)
    }

    func testHaversineIsSymmetric() {
        let a = Coordinate(latitude: 35.6762, longitude: 139.6503)
        let b = Coordinate(latitude: -33.8688, longitude: 151.2093)
        XCTAssertEqual(GeoMath.haversine(a, b), GeoMath.haversine(b, a), accuracy: 1e-6)
    }

    func testHaversineAgreesWithTheLocalProjectionOverShortDistances() {
        // The whole design rests on the claim that the equirectangular
        // approximation is sub-millimetre over a city block. This is that
        // claim, measured: 100 m built from the projection, then measured back
        // with the geodesic formula.
        let origin = Coordinate(latitude: 40.7, longitude: -74.0)

        let north = GeoMath.unproject(Point2D(x: 0, y: 100), origin: origin)
        XCTAssertEqual(GeoMath.haversine(origin, north), 100, accuracy: 1e-6)

        let east = GeoMath.unproject(Point2D(x: 100, y: 0), origin: origin)
        XCTAssertEqual(GeoMath.haversine(origin, east), 100, accuracy: 1e-6)
    }

    // MARK: - Bearing

    func testBearingAtCardinalDirections() {
        let origin = Coordinate(latitude: 0, longitude: 0)

        // These four are exact at the equator: the formula's y or x term is
        // identically zero in each case.
        XCTAssertEqual(
            GeoMath.bearing(from: origin, to: Coordinate(latitude: 1, longitude: 0)),
            0, accuracy: 1e-9
        )
        XCTAssertEqual(
            GeoMath.bearing(from: origin, to: Coordinate(latitude: 0, longitude: 1)),
            90, accuracy: 1e-9
        )
        XCTAssertEqual(
            GeoMath.bearing(from: Coordinate(latitude: 1, longitude: 0), to: origin),
            180, accuracy: 1e-9
        )
        XCTAssertEqual(
            GeoMath.bearing(from: Coordinate(latitude: 0, longitude: 1), to: origin),
            270, accuracy: 1e-9
        )
    }

    func testBearingIsNormalisedToZeroThreeSixty() {
        // Anything pointing west would come out of atan2 negative.
        let start = Coordinate(latitude: 40.7, longitude: -74.0)
        for (dLat, dLon) in [(0.01, -0.01), (-0.01, -0.01), (-0.01, 0.0), (0.0, -0.01)] {
            let end = Coordinate(latitude: 40.7 + dLat, longitude: -74.0 + dLon)
            let bearing = GeoMath.bearing(from: start, to: end)
            XCTAssertGreaterThanOrEqual(bearing, 0)
            XCTAssertLessThan(bearing, 360)
        }
    }

    func testBearingDueEastAtMidLatitude() {
        // Not exactly 90: a rhumb line due east is not a great circle, so the
        // initial bearing of the great circle tilts very slightly north of 90.
        // Over 100 m the tilt is about 0.0004 degrees.
        let start = Coordinate(latitude: 40.7, longitude: -74.0)
        let end = GeoMath.unproject(Point2D(x: 100, y: 0), origin: start)
        XCTAssertEqual(GeoMath.bearing(from: start, to: end), 90, accuracy: 0.01)
        XCTAssertLessThan(GeoMath.bearing(from: start, to: end), 90)
    }

    // MARK: - Bearing delta

    func testBearingDeltaWrapsAroundZero() {
        // The case that matters: 359 and 1 are two degrees apart, not 358.
        XCTAssertEqual(GeoMath.bearingDelta(359, 1), 2, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(1, 359), 2, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(0, 360), 0, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(0, 0), 0, accuracy: 1e-9)
    }

    func testBearingDeltaIsCappedAtOneEighty() {
        XCTAssertEqual(GeoMath.bearingDelta(0, 180), 180, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(90, 270), 180, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(0, 181), 179, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(181, 0), 179, accuracy: 1e-9)
    }

    func testBearingDeltaHandlesOutOfRangeAndNegativeInputs() {
        // Courses arrive from CoreLocation and from segment geometry, so the
        // helper should not assume they have been normalised first.
        XCTAssertEqual(GeoMath.bearingDelta(-10, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(370, 10), 0, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(720, 0), 0, accuracy: 1e-9)
    }

    func testBearingDeltaIsSymmetricAndWithinRange() {
        let values: [Double] = [0, 1, 45, 89.9, 90, 179, 180, 181, 270, 359, 359.9]
        for a in values {
            for b in values {
                let forward = GeoMath.bearingDelta(a, b)
                let backward = GeoMath.bearingDelta(b, a)
                XCTAssertEqual(forward, backward, accuracy: 1e-9, "delta(\(a), \(b))")
                XCTAssertGreaterThanOrEqual(forward, 0)
                XCTAssertLessThanOrEqual(forward, 180)
            }
        }
    }

    // MARK: - Local projection

    func testProjectAtTheOriginIsZero() {
        let origin = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let point = GeoMath.project(origin, origin: origin)
        XCTAssertEqual(point.x, 0, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0, accuracy: 1e-9)
    }

    func testProjectUsesMetresPerDegree() {
        let origin = Coordinate(latitude: 40.7, longitude: -74.0)
        let north = Coordinate(latitude: 40.701, longitude: -74.0)
        let east = Coordinate(latitude: 40.7, longitude: -73.999)

        XCTAssertEqual(
            GeoMath.project(north, origin: origin).y,
            0.001 * GeoMath.metresPerDegreeLatitude,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            GeoMath.project(east, origin: origin).x,
            0.001 * GeoMath.metresPerDegreeLongitude(atLatitude: 40.7),
            accuracy: 1e-6
        )
        // Signs: north is +y, east is +x.
        XCTAssertGreaterThan(GeoMath.project(north, origin: origin).y, 0)
        XCTAssertGreaterThan(GeoMath.project(east, origin: origin).x, 0)
    }

    func testProjectUnprojectRoundTrip() {
        let origin = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let coordinates = [
            Coordinate(latitude: 40.7128, longitude: -74.0060),
            Coordinate(latitude: 40.7200, longitude: -74.0000),
            Coordinate(latitude: 40.7000, longitude: -74.0200),
            Coordinate(latitude: 40.7128, longitude: -73.9000)
        ]

        for coordinate in coordinates {
            let round = GeoMath.unproject(GeoMath.project(coordinate, origin: origin), origin: origin)
            // 1e-9 degrees is about a tenth of a millimetre. The round trip is
            // two multiplications and two divisions, so only float noise
            // should show up here.
            XCTAssertEqual(round.latitude, coordinate.latitude, accuracy: 1e-9)
            XCTAssertEqual(round.longitude, coordinate.longitude, accuracy: 1e-9)
        }
    }

    func testUnprojectProjectRoundTripInMetres() {
        let origin = Coordinate(latitude: 52.3676, longitude: 4.9041)
        for point in [Point2D(x: 0, y: 0), Point2D(x: 250, y: -80), Point2D(x: -1_500, y: 3_000)] {
            let round = GeoMath.project(GeoMath.unproject(point, origin: origin), origin: origin)
            XCTAssertEqual(round.x, point.x, accuracy: 1e-6)
            XCTAssertEqual(round.y, point.y, accuracy: 1e-6)
        }
    }

    // MARK: - Point to segment

    func testProjectOntoSegmentAtTheMiddle() {
        let hit = GeoMath.projectOntoSegment(
            Point2D(x: 50, y: 12),
            Point2D(x: 0, y: 0),
            Point2D(x: 100, y: 0)
        )
        XCTAssertEqual(hit.t, 0.5, accuracy: 1e-12)
        XCTAssertEqual(hit.distance, 12, accuracy: 1e-12)
    }

    func testProjectOntoSegmentClampsBeforeTheStart() {
        // Perpendicular foot would be at t = -0.5, so it clamps to the start
        // point and the distance becomes the straight-line distance to it.
        let hit = GeoMath.projectOntoSegment(
            Point2D(x: -50, y: 30),
            Point2D(x: 0, y: 0),
            Point2D(x: 100, y: 0)
        )
        XCTAssertEqual(hit.t, 0, accuracy: 1e-12)
        XCTAssertEqual(hit.distance, (50.0 * 50 + 30 * 30).squareRoot(), accuracy: 1e-9)
    }

    func testProjectOntoSegmentClampsAfterTheEnd() {
        // Perpendicular foot would be at t = 1.6.
        let hit = GeoMath.projectOntoSegment(
            Point2D(x: 160, y: -40),
            Point2D(x: 0, y: 0),
            Point2D(x: 100, y: 0)
        )
        XCTAssertEqual(hit.t, 1, accuracy: 1e-12)
        XCTAssertEqual(hit.distance, (60.0 * 60 + 40 * 40).squareRoot(), accuracy: 1e-9)
    }

    func testProjectOntoSegmentAtTheExactEndpoints() {
        let a = Point2D(x: 10, y: 10)
        let b = Point2D(x: 110, y: 10)

        let atStart = GeoMath.projectOntoSegment(a, a, b)
        XCTAssertEqual(atStart.t, 0, accuracy: 1e-12)
        XCTAssertEqual(atStart.distance, 0, accuracy: 1e-12)

        let atEnd = GeoMath.projectOntoSegment(b, a, b)
        XCTAssertEqual(atEnd.t, 1, accuracy: 1e-12)
        XCTAssertEqual(atEnd.distance, 0, accuracy: 1e-12)
    }

    func testProjectOntoZeroLengthSegment() {
        // A degenerate segment has no direction to project along, so t is 0
        // and the distance is simply the distance to the point. Reaching this
        // path through a division would produce NaN and poison every score in
        // the matcher.
        let a = Point2D(x: 10, y: 10)
        let hit = GeoMath.projectOntoSegment(Point2D(x: 13, y: 14), a, a)
        XCTAssertEqual(hit.t, 0, accuracy: 1e-12)
        XCTAssertEqual(hit.distance, 5, accuracy: 1e-12)
        XCTAssertFalse(hit.distance.isNaN)
    }

    func testProjectOntoNearlyZeroLengthSegmentTakesTheDegeneratePath() {
        // Below the 1e-12 squared-length guard, which is 1 micrometre of
        // segment. Packs are built from fixed-point coordinates, so repeated
        // vertices really do occur.
        let a = Point2D(x: 0, y: 0)
        let b = Point2D(x: 1e-7, y: 0)
        let hit = GeoMath.projectOntoSegment(Point2D(x: 3, y: 4), a, b)
        XCTAssertEqual(hit.t, 0, accuracy: 1e-12)
        XCTAssertEqual(hit.distance, 5, accuracy: 1e-6)
    }
}
