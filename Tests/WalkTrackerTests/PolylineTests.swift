//
//  PolylineTests.swift
//
//  Covers Polyline: the geometry of one walkable block. Cumulative lengths,
//  projecting a noisy fix onto a multi-vertex line, converting between a
//  fraction of the block and a coordinate, slicing out the part that was
//  walked, and the single-coordinate degenerate case.
//
//  Test polylines are built by taking a fixed origin and placing vertices at
//  exact metre offsets with GeoMath.unproject. Polyline projects with its own
//  first coordinate as origin, which is the same origin, so the metre offsets
//  round trip exactly and the expected lengths are known by construction
//  rather than being read back out of the implementation.
//
//  Note that Polyline measures planar length in that local projection, not
//  geodesic length. Over a block the two agree to well under a millimetre
//  (see GeoMathTests), which is why the tolerances here are so tight.
//

import Foundation
import XCTest
@testable import WalkTracker

final class PolylineTests: XCTestCase {

    private let origin = Coordinate(latitude: 40.7000, longitude: -74.0000)

    /// A coordinate `east` metres east and `north` metres north of the origin.
    private func offset(east: Double, north: Double) -> Coordinate {
        GeoMath.unproject(Point2D(x: east, y: north), origin: origin)
    }

    /// An L shape: 100 m east, then 80 m north. Total length 180 m.
    private func makeLShape() -> Polyline {
        Polyline(coordinates: [
            offset(east: 0, north: 0),
            offset(east: 100, north: 0),
            offset(east: 100, north: 80)
        ])
    }

    /// Distance in metres between two coordinates, measured in the same local
    /// projection the polyline uses.
    private func metres(from a: Coordinate, to b: Coordinate) -> Double {
        let pa = GeoMath.project(a, origin: origin)
        let pb = GeoMath.project(b, origin: origin)
        return (pow(pa.x - pb.x, 2) + pow(pa.y - pb.y, 2)).squareRoot()
    }

    // MARK: - Construction and length

    func testCumulativeLengths() {
        let line = makeLShape()

        XCTAssertEqual(line.cumulative.count, line.coordinates.count)
        XCTAssertEqual(line.cumulative[0], 0, accuracy: 1e-9)
        XCTAssertEqual(line.cumulative[1], 100, accuracy: 1e-6)
        XCTAssertEqual(line.cumulative[2], 180, accuracy: 1e-6)
        XCTAssertEqual(line.length, 180, accuracy: 1e-6)
    }

    func testCumulativeLengthsAreMonotonic() {
        let line = Polyline(coordinates: [
            offset(east: 0, north: 0),
            offset(east: 30, north: 0),
            offset(east: 30, north: 0),   // repeated vertex: adds nothing
            offset(east: 30, north: 40),
            offset(east: 0, north: 40)
        ])
        for i in 1..<line.cumulative.count {
            XCTAssertGreaterThanOrEqual(line.cumulative[i], line.cumulative[i - 1])
        }
        // 30 + 0 + 40 + 30
        XCTAssertEqual(line.length, 100, accuracy: 1e-6)
    }

    func testOriginIsTheFirstCoordinate() {
        let line = makeLShape()
        XCTAssertEqual(line.origin, line.coordinates[0])
    }

    func testBoundingBoxContainsEveryVertex() {
        let line = makeLShape()
        let box = line.boundingBox
        for coordinate in line.coordinates {
            XCTAssertTrue(box.contains(coordinate))
        }
    }

    // MARK: - Projection

    func testProjectOntoTheFirstLeg() {
        let line = makeLShape()
        // 10 m north of the halfway point of the first (eastward) leg.
        let fix = offset(east: 50, north: 10)
        let hit = line.project(fix)

        XCTAssertEqual(hit.offset, 50, accuracy: 1e-6)
        XCTAssertEqual(hit.distance, 10, accuracy: 1e-6)
        XCTAssertEqual(hit.fraction, 50.0 / 180.0, accuracy: 1e-9)
        // The first leg runs east. See GeoMathTests for why this is not
        // exactly 90 degrees.
        XCTAssertEqual(hit.bearing, 90, accuracy: 0.01)
    }

    func testProjectOntoTheSecondLeg() {
        let line = makeLShape()
        // 5 m east of a point 40 m up the second (northward) leg.
        let fix = offset(east: 105, north: 40)
        let hit = line.project(fix)

        XCTAssertEqual(hit.offset, 140, accuracy: 1e-6)
        XCTAssertEqual(hit.distance, 5, accuracy: 1e-6)
        XCTAssertEqual(hit.fraction, 140.0 / 180.0, accuracy: 1e-9)
        XCTAssertEqual(hit.bearing, 0, accuracy: 0.01)
    }

    func testProjectPicksTheNearestLegNotTheFirstMatch() {
        // This point is close to the corner but nearer the second leg. A
        // scan that stopped at the first leg within tolerance would get the
        // offset badly wrong.
        let line = makeLShape()
        let hit = line.project(offset(east: 104, north: 20))
        XCTAssertEqual(hit.distance, 4, accuracy: 1e-6)
        XCTAssertEqual(hit.offset, 120, accuracy: 1e-6)
    }

    func testProjectBeyondTheEndsClampsToTheLine() {
        let line = makeLShape()

        let beforeStart = line.project(offset(east: -50, north: 0))
        XCTAssertEqual(beforeStart.fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(beforeStart.offset, 0, accuracy: 1e-6)
        XCTAssertEqual(beforeStart.distance, 50, accuracy: 1e-6)

        let pastEnd = line.project(offset(east: 100, north: 130))
        XCTAssertEqual(pastEnd.fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(pastEnd.offset, 180, accuracy: 1e-6)
        XCTAssertEqual(pastEnd.distance, 50, accuracy: 1e-6)
    }

    func testProjectedFractionIsAlwaysWithinZeroToOne() {
        let line = makeLShape()
        for (east, north) in [(-500.0, -500.0), (0.0, 0.0), (50.0, 3.0), (400.0, 400.0)] {
            let hit = line.project(offset(east: east, north: north))
            XCTAssertGreaterThanOrEqual(hit.fraction, 0)
            XCTAssertLessThanOrEqual(hit.fraction, 1)
        }
    }

    // MARK: - coordinate(atFraction:)

    func testCoordinateAtZeroAndOneAreTheEndpoints() {
        let line = makeLShape()
        XCTAssertEqual(line.coordinate(atFraction: 0), line.coordinates.first)
        XCTAssertEqual(line.coordinate(atFraction: 1), line.coordinates.last)
    }

    func testCoordinateAtHalf() {
        // Half of 180 m is 90 m, which is 10 m short of the corner, so it is
        // still on the first leg.
        let line = makeLShape()
        let middle = line.coordinate(atFraction: 0.5)
        XCTAssertEqual(metres(from: middle, to: offset(east: 90, north: 0)), 0, accuracy: 1e-6)
    }

    func testCoordinateOnTheSecondLeg() {
        let line = makeLShape()
        // 0.75 of 180 m is 135 m: 35 m up the second leg.
        let point = line.coordinate(atFraction: 0.75)
        XCTAssertEqual(metres(from: point, to: offset(east: 100, north: 35)), 0, accuracy: 1e-6)
    }

    func testCoordinateAtFractionClampsOutOfRangeInput() {
        let line = makeLShape()
        XCTAssertEqual(line.coordinate(atFraction: -1), line.coordinates.first)
        XCTAssertEqual(line.coordinate(atFraction: -0.0001), line.coordinates.first)
        XCTAssertEqual(line.coordinate(atFraction: 2), line.coordinates.last)
        XCTAssertEqual(line.coordinate(atFraction: 1.0001), line.coordinates.last)
    }

    func testCoordinateAtFractionRoundTripsThroughProject() {
        let line = makeLShape()
        for fraction in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            let point = line.coordinate(atFraction: fraction)
            let hit = line.project(point)
            XCTAssertEqual(hit.fraction, fraction, accuracy: 1e-9, "at \(fraction)")
            XCTAssertEqual(hit.distance, 0, accuracy: 1e-6, "at \(fraction)")
        }
    }

    // MARK: - slice

    func testSliceKeepsInteriorVertices() {
        let line = makeLShape()
        // 0.25 to 0.75 is 45 m to 135 m, which spans the corner at 100 m.
        let slice = line.slice(from: 0.25, to: 0.75)

        XCTAssertEqual(slice.count, 3)
        XCTAssertEqual(metres(from: slice[0], to: offset(east: 45, north: 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(metres(from: slice[1], to: offset(east: 100, north: 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(metres(from: slice[2], to: offset(east: 100, north: 35)), 0, accuracy: 1e-6)
    }

    func testSliceWithinASingleLegHasNoInteriorVertices() {
        let line = makeLShape()
        let slice = line.slice(from: 0.1, to: 0.2)
        XCTAssertEqual(slice.count, 2)
        XCTAssertEqual(metres(from: slice[0], to: offset(east: 18, north: 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(metres(from: slice[1], to: offset(east: 36, north: 0)), 0, accuracy: 1e-6)
    }

    func testSliceNormalisesReversedBounds() {
        let line = makeLShape()
        XCTAssertEqual(line.slice(from: 0.75, to: 0.25), line.slice(from: 0.25, to: 0.75))
    }

    func testSliceClampsOutOfRangeBoundsToTheWholeLine() {
        let line = makeLShape()
        let whole = line.slice(from: -1, to: 2)
        XCTAssertEqual(whole.count, line.coordinates.count)
        XCTAssertEqual(whole.first, line.coordinates.first)
        XCTAssertEqual(whole.last, line.coordinates.last)
    }

    func testSliceOfZeroWidthIsEmpty() {
        let line = makeLShape()
        XCTAssertTrue(line.slice(from: 0.5, to: 0.5).isEmpty)
        XCTAssertTrue(line.slice(from: 0, to: 0).isEmpty)
        XCTAssertTrue(line.slice(from: 1, to: 1).isEmpty)
    }

    // MARK: - Degenerate polyline

    func testSingleCoordinatePolyline() {
        // A one-vertex block should never reach the app, but a malformed pack
        // could produce one, and every accessor has to stay defined rather
        // than dividing by a zero length.
        let point = offset(east: 10, north: 10)
        let line = Polyline(coordinates: [point])

        XCTAssertEqual(line.length, 0)
        XCTAssertEqual(line.cumulative, [0])
        XCTAssertEqual(line.coordinate(atFraction: 0), point)
        XCTAssertEqual(line.coordinate(atFraction: 0.5), point)
        XCTAssertEqual(line.coordinate(atFraction: 1), point)
        XCTAssertTrue(line.slice(from: 0, to: 1).isEmpty)

        let box = line.boundingBox
        XCTAssertEqual(box.minLatitude, box.maxLatitude, accuracy: 1e-12)
        XCTAssertEqual(box.minLongitude, box.maxLongitude, accuracy: 1e-12)
    }

    func testProjectOntoSingleCoordinatePolylineReportsGeodesicDistance() {
        let point = offset(east: 10, north: 10)
        let line = Polyline(coordinates: [point])
        let fix = offset(east: 10, north: 40)

        let hit = line.project(fix)
        XCTAssertEqual(hit.fraction, 0)
        XCTAssertEqual(hit.offset, 0)
        XCTAssertEqual(hit.bearing, 0)
        XCTAssertEqual(hit.distance, GeoMath.haversine(fix, point), accuracy: 1e-9)
        XCTAssertEqual(hit.distance, 30, accuracy: 1e-3)
    }
}
