//
//  IntervalSetTests.swift
//
//  Covers IntervalSet: the normalised set of covered stretches of one block,
//  which is what makes a partly walked street report a partial percentage
//  instead of all or nothing.
//
//  The behaviour being pinned down here is: inserts merge when they overlap or
//  nearly touch, stay separate when they do not, normalise reversed and
//  out-of-range input, drop zero-length inserts, and survive a round trip
//  through the compact string that gets written to SQLite, including the empty
//  case and input that has been corrupted.
//
//  Two constants from the implementation matter to these tests. Intervals
//  closer than an epsilon of 1e-3 (a tenth of a percent of a block, about 8 cm
//  on a typical one) are fused. The storage string keeps five decimal places,
//  so values with more precision than that do not round trip exactly, and the
//  tests use values that are exact at five places.
//

import Foundation
import XCTest
@testable import WalkTracker

final class IntervalSetTests: XCTestCase {

    // MARK: - Merging

    func testAdjacentIntervalsMergeIntoOne() {
        var set = IntervalSet()
        set.insert(from: 0, to: 0.5)
        set.insert(from: 0.5, to: 1.0)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.coverage, 1.0, accuracy: 1e-12)
        XCTAssertEqual(set.intervals.first?.start, 0)
        XCTAssertEqual(set.intervals.first?.end, 1)
    }

    func testNearlyAdjacentIntervalsMergeWithinEpsilon() {
        // A 0.0005 gap is float noise from two projections of the same walk,
        // not a stretch of street that was missed.
        var set = IntervalSet()
        set.insert(from: 0, to: 0.5)
        set.insert(from: 0.5005, to: 1.0)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.coverage, 1.0, accuracy: 1e-12)
    }

    func testOverlappingIntervalsMerge() {
        var set = IntervalSet()
        set.insert(from: 0.1, to: 0.6)
        set.insert(from: 0.4, to: 0.9)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.intervals.first?.start ?? -1, 0.1, accuracy: 1e-12)
        XCTAssertEqual(set.intervals.first?.end ?? -1, 0.9, accuracy: 1e-12)
        // Not 1.0: the overlap is counted once.
        XCTAssertEqual(set.coverage, 0.8, accuracy: 1e-12)
    }

    func testContainedIntervalChangesNothing() {
        var set = IntervalSet()
        set.insert(from: 0.2, to: 0.8)
        set.insert(from: 0.4, to: 0.5)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.coverage, 0.6, accuracy: 1e-12)
    }

    func testDisjointIntervalsStaySeparate() {
        var set = IntervalSet()
        set.insert(from: 0, to: 0.2)
        set.insert(from: 0.5, to: 0.7)

        XCTAssertEqual(set.intervals.count, 2)
        XCTAssertEqual(set.coverage, 0.4, accuracy: 1e-12)
        XCTAssertEqual(set.intervals[0].start, 0, accuracy: 1e-12)
        XCTAssertEqual(set.intervals[1].start, 0.5, accuracy: 1e-12)
    }

    func testIntervalsAreKeptSortedRegardlessOfInsertOrder() {
        var set = IntervalSet()
        set.insert(from: 0.8, to: 0.9)
        set.insert(from: 0.1, to: 0.2)
        set.insert(from: 0.4, to: 0.5)

        XCTAssertEqual(set.intervals.count, 3)
        for i in 1..<set.intervals.count {
            XCTAssertLessThan(set.intervals[i - 1].start, set.intervals[i].start)
        }
    }

    func testOneInsertCanSwallowSeveralExistingIntervals() {
        var set = IntervalSet(intervals: [
            IntervalSet.Interval(start: 0, end: 0.1),
            IntervalSet.Interval(start: 0.3, end: 0.4),
            IntervalSet.Interval(start: 0.6, end: 0.7)
        ])
        XCTAssertEqual(set.intervals.count, 3)

        set.insert(from: 0.05, to: 0.65)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.coverage, 0.7, accuracy: 1e-12)
    }

    func testFormUnionMergesAnotherSet() {
        var a = IntervalSet()
        a.insert(from: 0, to: 0.3)
        var b = IntervalSet()
        b.insert(from: 0.25, to: 0.6)
        b.insert(from: 0.8, to: 1.0)

        let union = a.union(b)
        XCTAssertEqual(union.intervals.count, 2)
        XCTAssertEqual(union.coverage, 0.8, accuracy: 1e-12)
        // union(_:) is non-mutating, so the receiver is untouched.
        XCTAssertEqual(a.coverage, 0.3, accuracy: 1e-12)

        a.formUnion(b)
        XCTAssertEqual(a, union)
    }

    // MARK: - Normalisation

    func testReversedInsertIsNormalised() {
        var set = IntervalSet()
        set.insert(from: 0.8, to: 0.3)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.intervals[0].start, 0.3, accuracy: 1e-12)
        XCTAssertEqual(set.intervals[0].end, 0.8, accuracy: 1e-12)
        XCTAssertEqual(set.coverage, 0.5, accuracy: 1e-12)
    }

    func testZeroLengthInsertIsDropped() {
        // A single GPS fix is a point, not walked distance.
        var set = IntervalSet()
        set.insert(from: 0.4, to: 0.4)

        XCTAssertTrue(set.isEmpty)
        XCTAssertEqual(set.coverage, 0)
        XCTAssertEqual(set.storageString, "")
    }

    func testZeroLengthInsertDoesNotDisturbExistingIntervals() {
        var set = IntervalSet()
        set.insert(from: 0.2, to: 0.6)
        set.insert(from: 0.4, to: 0.4)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.coverage, 0.4, accuracy: 1e-12)
    }

    func testOutOfRangeInsertIsClampedToZeroOne() {
        var set = IntervalSet()
        set.insert(from: -0.5, to: 1.5)

        XCTAssertEqual(set.intervals.count, 1)
        XCTAssertEqual(set.intervals[0].start, 0, accuracy: 1e-12)
        XCTAssertEqual(set.intervals[0].end, 1, accuracy: 1e-12)
        XCTAssertEqual(set.coverage, 1, accuracy: 1e-12)
    }

    func testInsertEntirelyOutOfRangeCollapsesToNothing() {
        // Clamping turns [2, 3] into [1, 1], which is zero length and so is
        // dropped rather than becoming a spurious claim on the block's end.
        var set = IntervalSet()
        set.insert(from: 2, to: 3)
        XCTAssertTrue(set.isEmpty)

        set.insert(from: -3, to: -2)
        XCTAssertTrue(set.isEmpty)
    }

    func testCoverageNeverExceedsOne() {
        var set = IntervalSet()
        for start in stride(from: 0.0, to: 1.0, by: 0.05) {
            set.insert(from: start, to: start + 0.2)
        }
        XCTAssertLessThanOrEqual(set.coverage, 1.0)
        XCTAssertEqual(set.coverage, 1.0, accuracy: 1e-9)
    }

    // MARK: - Gaps

    func testGapsOfAnEmptySetIsTheWholeBlock() {
        let set = IntervalSet()
        XCTAssertEqual(set.gaps.count, 1)
        XCTAssertEqual(set.gaps[0].start, 0, accuracy: 1e-12)
        XCTAssertEqual(set.gaps[0].end, 1, accuracy: 1e-12)
    }

    func testGapsAroundASingleMiddleInterval() {
        var set = IntervalSet()
        set.insert(from: 0.2, to: 0.5)

        let gaps = set.gaps
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].start, 0, accuracy: 1e-12)
        XCTAssertEqual(gaps[0].end, 0.2, accuracy: 1e-12)
        XCTAssertEqual(gaps[1].start, 0.5, accuracy: 1e-12)
        XCTAssertEqual(gaps[1].end, 1, accuracy: 1e-12)
    }

    func testGapsBetweenTwoIntervals() {
        var set = IntervalSet()
        set.insert(from: 0, to: 0.3)
        set.insert(from: 0.7, to: 1)

        let gaps = set.gaps
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 0.3, accuracy: 1e-12)
        XCTAssertEqual(gaps[0].end, 0.7, accuracy: 1e-12)
    }

    func testFullyCoveredBlockHasNoGaps() {
        var set = IntervalSet()
        set.insert(from: 0, to: 1)
        XCTAssertTrue(set.gaps.isEmpty)
    }

    func testGapsAndCoverageAccountForTheWholeBlock() {
        var set = IntervalSet()
        set.insert(from: 0.1, to: 0.25)
        set.insert(from: 0.6, to: 0.9)

        let gapTotal = set.gaps.reduce(0) { $0 + $1.length }
        XCTAssertEqual(set.coverage + gapTotal, 1.0, accuracy: 1e-12)
    }

    // MARK: - Storage string

    func testStorageStringRoundTrip() {
        var set = IntervalSet()
        set.insert(from: 0.125, to: 0.5)
        set.insert(from: 0.75, to: 0.875)

        let encoded = set.storageString
        XCTAssertEqual(encoded, "0.12500:0.50000,0.75000:0.87500")

        let decoded = IntervalSet(storageString: encoded)
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(decoded.coverage, set.coverage, accuracy: 1e-12)
    }

    func testEmptySetRoundTrip() {
        let empty = IntervalSet()
        XCTAssertEqual(empty.storageString, "")
        XCTAssertTrue(IntervalSet(storageString: "").isEmpty)
        XCTAssertEqual(IntervalSet(storageString: ""), empty)
        // Whitespace only, which is what a blank column can look like.
        XCTAssertTrue(IntervalSet(storageString: "   ").isEmpty)
    }

    func testMalformedStorageStringsDecodeToNothingRatherThanThrowing() {
        // Never crash on a corrupted row: coverage is derived data and can be
        // rebuilt from the raw trace, so losing a row is recoverable, while a
        // crash on launch is not.
        for broken in ["garbage", "0.1", "0.1:", ":0.2", "a:b", ":", ",", "0.1:0.2:0.3", "nan:0.5", "1e400:0.5"] {
            XCTAssertTrue(
                IntervalSet(storageString: broken).isEmpty,
                "expected \(broken) to decode to an empty set"
            )
        }
    }

    func testMalformedStorageStringKeepsTheValidPairs() {
        let decoded = IntervalSet(storageString: "0.10000:0.20000,broken,0.30000:0.40000")

        XCTAssertEqual(decoded.intervals.count, 2)
        XCTAssertEqual(decoded.coverage, 0.2, accuracy: 1e-9)
    }

    func testStorageStringOfOutOfRangeValuesIsClamped() {
        // A row written by an older or buggier build should still load as
        // something valid rather than poisoning the percentage.
        let decoded = IntervalSet(storageString: "-4.00000:0.50000,0.90000:7.00000")

        XCTAssertEqual(decoded.intervals.count, 2)
        XCTAssertEqual(decoded.coverage, 0.6, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(decoded.intervals[0].start, 0)
        XCTAssertLessThanOrEqual(decoded.intervals[1].end, 1)
    }

    func testStorageStringSurvivesRepeatedRoundTrips() {
        // The apply path reads, merges and rewrites this string on every walk,
        // so five decimal places must be a fixed point rather than something
        // that drifts.
        var set = IntervalSet()
        set.insert(from: 0.33333, to: 0.66667)

        var current = set
        for _ in 0..<5 {
            current = IntervalSet(storageString: current.storageString)
        }
        XCTAssertEqual(current.storageString, set.storageString)
        XCTAssertEqual(current.coverage, set.coverage, accuracy: 1e-9)
    }
}
