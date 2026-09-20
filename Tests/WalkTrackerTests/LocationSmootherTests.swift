//
//  LocationSmootherTests.swift
//
//  Covers LocationSmoother: the stage that averages raw fixes into short time
//  buckets before the matcher sees them.
//
//  Three things are pinned down here.
//
//  Bucket timing: a bucket closes only when a fix arrives that is at least a
//  window past the oldest fix held, and the bucket that is emitted is the one
//  that just closed, not the one the new fix starts.
//
//  Accuracy: averaging n independent fixes shrinks the reported error by
//  sqrt(n), with a floor of 3 m so a long stationary bucket cannot claim
//  implausible precision and dominate the Viterbi chain.
//
//  Course: courses are angles, so they are averaged as unit vectors. The test
//  that matters is 359 and 1 degrees, which a naive arithmetic mean turns into
//  180, exactly the opposite direction. The matcher scores candidate streets
//  on how well the course lines up with the street, so a 180 degree error
//  there is not a rounding problem, it is the wrong street.
//

import Foundation
import XCTest
@testable import WalkTracker

final class LocationSmootherTests: XCTestCase {

    private let here = Coordinate(latitude: 40.7000, longitude: -74.0000)

    // MARK: - Bucket timing

    func testNothingIsEmittedUntilTheWindowElapses() {
        let smoother = LocationSmoother(windowSeconds: 8)

        for second in 0..<8 {
            let emitted = smoother.push(Fixture.point(seconds: TimeInterval(second), coordinate: here))
            XCTAssertNil(emitted, "a bucket closed early at t=\(second)")
        }
    }

    func testBucketIsEmittedOnTheFirstFixPastTheWindow() {
        let smoother = LocationSmoother(windowSeconds: 8)

        for second in 0..<8 {
            _ = smoother.push(Fixture.point(seconds: TimeInterval(second), coordinate: here))
        }
        let emitted = smoother.push(Fixture.point(seconds: 8, coordinate: here))

        XCTAssertNotNil(emitted)
        // The emitted bucket is the eight fixes from t=0 to t=7, so its mean
        // timestamp is t=3.5. The t=8 fix starts the next bucket.
        XCTAssertEqual(
            emitted?.timestamp.timeIntervalSince(Fixture.epoch) ?? -1,
            3.5,
            accuracy: 1e-9
        )
    }

    func testTheFixThatClosedABucketStartsTheNextOne() {
        let smoother = LocationSmoother(windowSeconds: 8)

        for second in 0...8 {
            _ = smoother.push(Fixture.point(seconds: TimeInterval(second), coordinate: here))
        }
        let tail = smoother.flush()

        XCTAssertNotNil(tail)
        XCTAssertEqual(tail?.timestamp.timeIntervalSince(Fixture.epoch) ?? -1, 8, accuracy: 1e-9)
    }

    func testFlushOnAnEmptyBufferReturnsNil() {
        let smoother = LocationSmoother(windowSeconds: 8)
        XCTAssertNil(smoother.flush())

        _ = smoother.push(Fixture.point(seconds: 0, coordinate: here))
        XCTAssertNotNil(smoother.flush())
        // Flushing empties the buffer, so a second flush has nothing to give.
        XCTAssertNil(smoother.flush())
    }

    func testResetDiscardsTheBufferedFixes() {
        let smoother = LocationSmoother(windowSeconds: 8)
        _ = smoother.push(Fixture.point(seconds: 0, coordinate: here))
        _ = smoother.push(Fixture.point(seconds: 1, coordinate: here))

        smoother.reset()

        XCTAssertNil(smoother.flush())
    }

    // MARK: - Averaging

    func testBucketAveragesPosition() {
        let smoother = LocationSmoother(windowSeconds: 8)
        let latitudes = [40.70, 40.71, 40.72, 40.73]

        for (index, latitude) in latitudes.enumerated() {
            _ = smoother.push(Fixture.point(
                seconds: TimeInterval(index),
                coordinate: Coordinate(latitude: latitude, longitude: -74.0)
            ))
        }

        let bucket = smoother.flush()
        XCTAssertEqual(bucket?.coordinate.latitude ?? 0, 40.715, accuracy: 1e-9)
        XCTAssertEqual(bucket?.coordinate.longitude ?? 0, -74.0, accuracy: 1e-9)
        // A smoothed fix has never been persisted, so it carries no row id.
        XCTAssertNil(bucket?.id)
        XCTAssertEqual(bucket?.sessionID, 1)
    }

    func testAccuracyShrinksBySquareRootOfTheSampleCount() {
        let smoother = LocationSmoother(windowSeconds: 8)
        for index in 0..<4 {
            _ = smoother.push(Fixture.point(
                seconds: TimeInterval(index),
                coordinate: here,
                accuracy: 24
            ))
        }

        // Four fixes at 24 m: 24 / sqrt(4) = 12 m.
        XCTAssertEqual(smoother.flush()?.horizontalAccuracy ?? 0, 12, accuracy: 1e-9)
    }

    func testAccuracyShrinksBySquareRootOfTheSampleCountForNineFixes() {
        let smoother = LocationSmoother(windowSeconds: 20)
        for index in 0..<9 {
            _ = smoother.push(Fixture.point(
                seconds: TimeInterval(index),
                coordinate: here,
                accuracy: 18
            ))
        }

        // Nine fixes at 18 m: 18 / sqrt(9) = 6 m.
        XCTAssertEqual(smoother.flush()?.horizontalAccuracy ?? 0, 6, accuracy: 1e-9)
    }

    func testAccuracyNeverDropsBelowTheFloor() {
        let smoother = LocationSmoother(windowSeconds: 20)
        for index in 0..<9 {
            _ = smoother.push(Fixture.point(
                seconds: TimeInterval(index),
                coordinate: here,
                accuracy: 6
            ))
        }

        // 6 / 3 = 2 m, which is below the 3 m floor.
        XCTAssertEqual(smoother.flush()?.horizontalAccuracy ?? 0, 3, accuracy: 1e-9)
    }

    func testNegativeSpeedsAreTreatedAsZeroRatherThanDraggingTheMeanDown() {
        // CoreLocation reports a negative speed when it has none. Averaging
        // that in would report a walker moving backwards.
        let smoother = LocationSmoother(windowSeconds: 8)
        _ = smoother.push(Fixture.point(seconds: 0, coordinate: here, speed: -1))
        _ = smoother.push(Fixture.point(seconds: 1, coordinate: here, speed: 2))

        XCTAssertEqual(smoother.flush()?.speed ?? -1, 1, accuracy: 1e-9)
    }

    func testAltitudeIsAveragedIncludingNegativeValues() {
        // Altitude below sea level is real data, not a sentinel.
        let smoother = LocationSmoother(windowSeconds: 8)
        _ = smoother.push(Fixture.point(seconds: 0, coordinate: here, altitude: -4))
        _ = smoother.push(Fixture.point(seconds: 1, coordinate: here, altitude: 10))

        XCTAssertEqual(smoother.flush()?.altitude ?? 0, 3, accuracy: 1e-9)
    }

    // MARK: - Circular mean of course

    func testCourseAcrossNorthAveragesToNorthNotSouth() {
        // The whole reason meanCourse exists. (359 + 1) / 2 is 180.
        let points = [
            Fixture.point(seconds: 0, coordinate: here, course: 359),
            Fixture.point(seconds: 1, coordinate: here, course: 1)
        ]

        let mean = LocationSmoother.meanCourse(points)

        // Compared with bearingDelta because the answer is allowed to come
        // back as either 0 or 360 minus a rounding error, and those are the
        // same direction.
        XCTAssertEqual(GeoMath.bearingDelta(mean, 0), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(GeoMath.bearingDelta(mean, 180), 179.9)
    }

    func testCourseAcrossNorthThroughTheSmoother() {
        // The same case through push and flush, so the wiring is covered and
        // not just the helper.
        let smoother = LocationSmoother(windowSeconds: 8)
        _ = smoother.push(Fixture.point(seconds: 0, coordinate: here, course: 350))
        _ = smoother.push(Fixture.point(seconds: 1, coordinate: here, course: 10))

        let course = smoother.flush()?.course ?? -1
        XCTAssertEqual(GeoMath.bearingDelta(course, 0), 0, accuracy: 1e-6)
        // Not "strictly less than 360": the unit vectors cancel to a hair
        // either side of zero, and a hair below zero plus 360 rounds to
        // exactly 360 in double precision. Every consumer goes through
        // bearingDelta, which treats 360 and 0 as the same direction.
        XCTAssertGreaterThanOrEqual(course, 0)
        XCTAssertLessThanOrEqual(course, 360)
    }

    func testCourseWithinOneQuadrantIsTheOrdinaryMean() {
        let points = [
            Fixture.point(seconds: 0, coordinate: here, course: 80),
            Fixture.point(seconds: 1, coordinate: here, course: 100)
        ]
        XCTAssertEqual(LocationSmoother.meanCourse(points), 90, accuracy: 1e-6)
    }

    func testInvalidCoursesAreIgnored() {
        // A negative course means "unknown", so it must not pull the mean
        // toward some arbitrary direction.
        let points = [
            Fixture.point(seconds: 0, coordinate: here, course: -1),
            Fixture.point(seconds: 1, coordinate: here, course: 90),
            Fixture.point(seconds: 2, coordinate: here, course: -1)
        ]
        XCTAssertEqual(LocationSmoother.meanCourse(points), 90, accuracy: 1e-6)
    }

    func testAllInvalidCoursesReturnMinusOne() {
        let points = [
            Fixture.point(seconds: 0, coordinate: here, course: -1),
            Fixture.point(seconds: 1, coordinate: here, course: -1)
        ]
        XCTAssertEqual(LocationSmoother.meanCourse(points), -1)
    }

    func testEmptyInputReturnsMinusOne() {
        XCTAssertEqual(LocationSmoother.meanCourse([]), -1)
    }

    func testOpposingCoursesCancelToUnknownRatherThanAnArtefact() {
        // Two exactly opposite headings have no meaningful average. Reporting
        // the perpendicular, which is what atan2 of a zero vector would give,
        // would be worse than admitting there is no answer.
        let points = [
            Fixture.point(seconds: 0, coordinate: here, course: 0),
            Fixture.point(seconds: 1, coordinate: here, course: 180)
        ]
        XCTAssertEqual(LocationSmoother.meanCourse(points), -1)
    }

    func testSmoothedCourseIsUnknownWhenNoFixHadOne() {
        let smoother = LocationSmoother(windowSeconds: 8)
        _ = smoother.push(Fixture.point(seconds: 0, coordinate: here, course: -1))
        _ = smoother.push(Fixture.point(seconds: 1, coordinate: here, course: -1))

        XCTAssertEqual(smoother.flush()?.course ?? 0, -1)
    }
}
