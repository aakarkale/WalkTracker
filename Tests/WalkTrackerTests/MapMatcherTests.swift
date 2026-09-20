//
//  MapMatcherTests.swift
//
//  Covers MapMatcher, the stage that turns a noisy GPS trace into claims on
//  particular blocks.
//
//  The street network under test is built in memory, not read from a city
//  pack: a small grid of blocks with explicit node ids, handed to the matcher
//  through a trivial SegmentIndex. That keeps these tests about the matching
//  algorithm rather than about SQLite, and it means the correct answer is
//  known by construction.
//
//  The properties being checked are the ones that decide whether the app lies
//  to its user:
//
//    * a clean walk down one block claims that block, and claims nothing on
//      the parallel street 45 m away that was never walked,
//    * fixes that are too inaccurate, impossible, or plainly a vehicle are
//      dropped rather than matched,
//    * two blocks that do not share an intersection produce no bridging
//      claim, because there is no known way to walk from one to the other,
//    * flush() emits the tail still sitting in the Viterbi window, so the
//      last stretch of a walk is not silently lost.
//
//  Coordinates are built from metre offsets against a fixed origin, so
//  distances in the fixtures below are literally metres.
//

import Foundation
import XCTest
@testable import WalkTracker

// MARK: - In-memory network

/// The smallest thing that satisfies SegmentIndex: a fixed array of blocks.
///
/// `segments(near:)` filters on an expanded bounding box, which is what the
/// real r-tree query does. That is a superset of "within the radius", and the
/// matcher measures true distance afterwards, so the two agree.
private final class ArraySegmentIndex: SegmentIndex {

    private let all: [StreetSegment]

    init(_ segments: [StreetSegment]) {
        self.all = segments
    }

    func segments(near coordinate: Coordinate, radiusMetres: Double) -> [StreetSegment] {
        all.filter { $0.boundingBox.expanded(byMetres: radiusMetres).contains(coordinate) }
    }

    func segment(id: Int64) -> StreetSegment? {
        all.first { $0.id == id }
    }
}

final class MapMatcherTests: XCTestCase {

    private let origin = Coordinate(latitude: 40.7000, longitude: -74.0000)

    /// A coordinate `east` metres east and `north` metres north of the origin.
    private func at(_ east: Double, _ north: Double) -> Coordinate {
        GeoMath.unproject(Point2D(x: east, y: north), origin: origin)
    }

    private func block(
        id: Int64,
        from start: (Double, Double),
        to end: (Double, Double),
        startNode: Int64,
        endNode: Int64,
        name: String? = nil
    ) -> StreetSegment {
        StreetSegment(
            id: id,
            wayID: id,
            name: name,
            wayClass: .residential,
            startNodeID: startNode,
            endNodeID: endNode,
            geometry: Polyline(coordinates: [at(start.0, start.1), at(end.0, end.1)]),
            districtID: nil
        )
    }

    /// Two east-west streets 45 m apart, each split into three 120 m blocks,
    /// joined by two cross streets. 45 m is inside the matcher's 60 m search
    /// radius on purpose: the parallel street is a real candidate for every
    /// fix, and the matcher has to reject it on the evidence rather than
    /// because it was never offered.
    ///
    ///     11 --11-- 12 --12-- 13 --13-- 14      north = 45
    ///               |         |
    ///               21        22
    ///               |         |
    ///      1 -- 1 -- 2 -- 2 -- 3 -- 3 -- 4      north = 0
    ///      x=0      120       240      360
    private func makeGrid() -> ArraySegmentIndex {
        ArraySegmentIndex([
            block(id: 1, from: (0, 0), to: (120, 0), startNode: 1, endNode: 2, name: "South Street"),
            block(id: 2, from: (120, 0), to: (240, 0), startNode: 2, endNode: 3, name: "South Street"),
            block(id: 3, from: (240, 0), to: (360, 0), startNode: 3, endNode: 4, name: "South Street"),
            block(id: 11, from: (0, 45), to: (120, 45), startNode: 11, endNode: 12, name: "North Street"),
            block(id: 12, from: (120, 45), to: (240, 45), startNode: 12, endNode: 13, name: "North Street"),
            block(id: 13, from: (240, 45), to: (360, 45), startNode: 13, endNode: 14, name: "North Street"),
            block(id: 21, from: (120, 0), to: (120, 45), startNode: 2, endNode: 12, name: "First Cross"),
            block(id: 22, from: (240, 0), to: (240, 45), startNode: 3, endNode: 13, name: "Second Cross")
        ])
    }

    /// A clean eastward walk along the southern street, from 30 m before the
    /// second block to 30 m past it. One fix every 6 m, four seconds apart,
    /// which is 1.5 m/s: an ordinary walking pace.
    private func straightWalk(
        fromEast: Double = 90,
        toEast: Double = 270,
        step: Double = 6,
        interval: TimeInterval = 4,
        accuracy: Double = 5
    ) -> [TrackPoint] {
        var points: [TrackPoint] = []
        var east = fromEast
        var seconds: TimeInterval = 0
        while east <= toEast {
            let here = at(east, 0)
            let next = at(east + step, 0)
            points.append(Fixture.point(
                seconds: seconds,
                coordinate: here,
                accuracy: accuracy,
                speed: step / interval,
                course: GeoMath.bearing(from: here, to: next)
            ))
            east += step
            seconds += interval
        }
        return points
    }

    // MARK: - Claim helpers

    private func coverage(ofSegment id: Int64, in claims: [CoverageClaim]) -> Double {
        var set = IntervalSet()
        for claim in claims where claim.segmentID == id {
            set.insert(from: claim.from, to: claim.to)
        }
        return set.coverage
    }

    private func totalCoverage(in claims: [CoverageClaim]) -> Double {
        Set(claims.map(\.segmentID)).reduce(0.0) { $0 + coverage(ofSegment: $1, in: claims) }
    }

    private func matchAll(_ points: [TrackPoint], through matcher: MapMatcher) -> [CoverageClaim] {
        var claims: [CoverageClaim] = []
        for point in points {
            claims.append(contentsOf: matcher.ingest(point))
        }
        return claims
    }

    // MARK: - A clean walk

    func testCleanWalkClaimsTheBlockItWalked() {
        let matcher = MapMatcher(index: makeGrid())
        var claims = matchAll(straightWalk(), through: matcher)
        claims.append(contentsOf: matcher.flush())

        // The walk crosses the whole of block 2 and enters the blocks on
        // either side, so block 2 should come out essentially complete.
        XCTAssertGreaterThan(coverage(ofSegment: 2, in: claims), 0.9)

        // It also spent 30 m on each neighbour.
        XCTAssertGreaterThan(coverage(ofSegment: 1, in: claims), 0)
        XCTAssertGreaterThan(coverage(ofSegment: 3, in: claims), 0)
    }

    func testCleanWalkClaimsNothingOnStreetsItDidNotWalk() {
        // The failure this guards against is the one that makes the app
        // worthless: painting a street the user never set foot on. The
        // parallel street is 45 m away, well inside the search radius.
        let matcher = MapMatcher(index: makeGrid())
        var claims = matchAll(straightWalk(), through: matcher)
        claims.append(contentsOf: matcher.flush())

        for id: Int64 in [11, 12, 13, 21, 22] {
            XCTAssertEqual(
                coverage(ofSegment: id, in: claims), 0,
                "claimed coverage on segment \(id), which was never walked"
            )
        }
    }

    func testEveryClaimIsOrientedAndNonEmpty() {
        let matcher = MapMatcher(index: makeGrid())
        var claims = matchAll(straightWalk(), through: matcher)
        claims.append(contentsOf: matcher.flush())

        XCTAssertFalse(claims.isEmpty)
        for claim in claims {
            XCTAssertLessThanOrEqual(claim.from, claim.to)
            XCTAssertGreaterThanOrEqual(claim.from, 0)
            XCTAssertLessThanOrEqual(claim.to, 1)
            XCTAssertFalse(claim.isEmpty)
        }
    }

    // MARK: - Gating

    func testFixesWorseThanTheAccuracyCeilingAreRejected() {
        // Default configuration drops anything above 30 m.
        let matcher = MapMatcher(index: makeGrid())
        let claims = matchAll(straightWalk(accuracy: 45), through: matcher)

        XCTAssertTrue(claims.isEmpty)
        // Nothing entered the window either, so there is no tail to flush.
        XCTAssertTrue(matcher.flush().isEmpty)
    }

    func testTheAccuracyCeilingIsConfigurable() {
        var configuration = MapMatcher.Configuration()
        configuration.maxHorizontalAccuracy = 50

        let matcher = MapMatcher(index: makeGrid(), configuration: configuration)
        var claims = matchAll(straightWalk(accuracy: 45), through: matcher)
        claims.append(contentsOf: matcher.flush())

        XCTAssertFalse(claims.isEmpty, "raising the ceiling should let these fixes through")
    }

    func testNullIslandFixesAreRejected() {
        // (0, 0) is what some hardware emits when it has no fix at all. It is
        // in the Gulf of Guinea, and it must never match anything.
        let matcher = MapMatcher(index: makeGrid())

        var claims: [CoverageClaim] = []
        for second in 0..<10 {
            claims.append(contentsOf: matcher.ingest(Fixture.point(
                seconds: TimeInterval(second * 4),
                coordinate: Coordinate(latitude: 0, longitude: 0)
            )))
        }

        XCTAssertTrue(claims.isEmpty)
        XCTAssertTrue(matcher.flush().isEmpty)
    }

    func testOtherInvalidCoordinatesAreRejected() {
        let matcher = MapMatcher(index: makeGrid())
        let invalid = [
            Coordinate(latitude: .nan, longitude: -74.0),
            Coordinate(latitude: 40.7, longitude: .infinity),
            Coordinate(latitude: 91, longitude: -74.0),
            Coordinate(latitude: 40.7, longitude: -181)
        ]

        for (index, coordinate) in invalid.enumerated() {
            let claims = matcher.ingest(Fixture.point(
                seconds: TimeInterval(index * 4),
                coordinate: coordinate
            ))
            XCTAssertTrue(claims.isEmpty, "matched an invalid coordinate: \(coordinate)")
        }
        XCTAssertTrue(matcher.flush().isEmpty)
    }

    func testNegativeAccuracyIsRejected() {
        // CoreLocation uses a negative accuracy to mean "no horizontal fix".
        let matcher = MapMatcher(index: makeGrid())
        let claims = matchAll(straightWalk(accuracy: -1), through: matcher)

        XCTAssertTrue(claims.isEmpty)
        XCTAssertTrue(matcher.flush().isEmpty)
    }

    func testVehicleSpeedFixesAreRejected() {
        // 12 m/s is about 43 km/h. Whatever this is, it is not walking, and
        // the streets it passes have not been walked.
        let matcher = MapMatcher(index: makeGrid())

        var claims: [CoverageClaim] = []
        var east: Double = 90
        for second in stride(from: 0, to: 60, by: 5) {
            claims.append(contentsOf: matcher.ingest(Fixture.point(
                seconds: TimeInterval(second),
                coordinate: at(east, 0),
                speed: 12,
                course: 90
            )))
            east += 60
        }

        XCTAssertTrue(claims.isEmpty)
        XCTAssertTrue(matcher.flush().isEmpty)
    }

    // MARK: - Bridging between blocks

    /// Two 150 m blocks laid end to end. When `sharingNode` is false they have
    /// the same geometry but no intersection in common, which is what a pack
    /// looks like where two streets happen to meet on the map without being
    /// connected: a road passing over a footpath on a bridge, say.
    private func makeTwoBlocks(sharingNode: Bool) -> ArraySegmentIndex {
        ArraySegmentIndex([
            block(id: 1, from: (0, 0), to: (150, 0), startNode: 1, endNode: 2),
            block(
                id: 2,
                from: (150, 0),
                to: (300, 0),
                startNode: sharingNode ? 2 : 3,
                endNode: sharingNode ? 3 : 4
            )
        ])
    }

    /// One fix in the middle of each block. Each one is 75 m from the other
    /// block, which is outside the 60 m search radius, so each fix has exactly
    /// one candidate and the path through the window is not in doubt.
    private func twoBlockWalk() -> [TrackPoint] {
        [
            Fixture.point(seconds: 0, coordinate: at(75, 0), accuracy: 10, speed: 1.9, course: 90),
            Fixture.point(seconds: 80, coordinate: at(225, 0), accuracy: 10, speed: 1.9, course: 90)
        ]
    }

    func testBridgingAcrossASharedIntersection() {
        let matcher = MapMatcher(index: makeTwoBlocks(sharingNode: true))
        let duringWalk = matchAll(twoBlockWalk(), through: matcher)
        XCTAssertTrue(duringWalk.isEmpty, "two fixes should not fill the window")

        let claims = matcher.flush()

        // Leaving block 1 by its far end, entering block 2 at its near end.
        XCTAssertEqual(claims.count, 2)

        let first = claims.first { $0.segmentID == 1 }
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.from ?? -1, 0.5, accuracy: 0.02)
        XCTAssertEqual(first?.to ?? -1, 1.0, accuracy: 1e-9)

        let second = claims.first { $0.segmentID == 2 }
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.from ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(second?.to ?? -1, 0.5, accuracy: 0.02)
    }

    func testBlocksThatShareNoNodeProduceNoBridgingClaims() {
        // Identical geometry and identical fixes to the test above. The only
        // difference is that the two blocks no longer share an intersection,
        // so there is no known route between them and the matcher claims
        // nothing rather than inventing one.
        let matcher = MapMatcher(index: makeTwoBlocks(sharingNode: false))
        let duringWalk = matchAll(twoBlockWalk(), through: matcher)

        XCTAssertTrue(duringWalk.isEmpty)
        XCTAssertTrue(matcher.flush().isEmpty)
    }

    // MARK: - Flush

    func testFlushEmitsTheTailLeftInTheWindow() {
        // The default window holds twelve fixes, so a walk of thirty ends with
        // a substantial tail that only flush() can release. Dropping it would
        // quietly lose the last minute or two of every walk.
        let matcher = MapMatcher(index: makeGrid())
        let duringWalk = matchAll(straightWalk(), through: matcher)
        let tail = matcher.flush()

        XCTAssertFalse(tail.isEmpty)
        XCTAssertGreaterThan(
            totalCoverage(in: duringWalk + tail),
            totalCoverage(in: duringWalk)
        )
    }

    func testFlushIsIdempotent() {
        let matcher = MapMatcher(index: makeGrid())
        _ = matchAll(straightWalk(), through: matcher)

        XCTAssertFalse(matcher.flush().isEmpty)
        XCTAssertTrue(matcher.flush().isEmpty, "a second flush should have nothing left to emit")
    }

    func testResetDiscardsTheWindow() {
        let matcher = MapMatcher(index: makeGrid())
        _ = matchAll(straightWalk(), through: matcher)

        matcher.reset()

        XCTAssertTrue(matcher.flush().isEmpty)
    }
}
