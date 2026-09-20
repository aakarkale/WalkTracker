//
//  MilestoneDetectorTests.swift
//
//  Covers MilestoneDetector: the thresholds a walk crosses, computed by
//  comparing the state before it with the state after.
//
//  The behaviour being pinned down here is that each threshold fires exactly
//  once, on the walk that crosses it, and never again. That property is the
//  whole design: milestones are not stored anywhere, so if the comparison were
//  wrong the app would either celebrate the same thing repeatedly or miss it
//  entirely, and there would be no record to correct it from.
//

import XCTest
@testable import WalkTracker

final class MilestoneDetectorTests: XCTestCase {

    private let detector = MilestoneDetector()

    private func snapshot(
        blocks: Int = 0,
        totalBlocks: Int = 1_000,
        metres: Double = 0,
        fraction: Double = 0,
        districts: Set<String> = [],
        walks: Int = 1
    ) -> MilestoneDetector.Snapshot {
        MilestoneDetector.Snapshot(
            cityName: "Testville",
            completedBlocks: blocks,
            totalBlocks: totalBlocks,
            walkedMetres: metres,
            cityFraction: fraction,
            completedDistricts: districts,
            walkCount: walks
        )
    }

    // MARK: - Nothing crossed

    func testNoMilestonesWhenNothingChanges() {
        let state = snapshot(blocks: 30, metres: 12_000, fraction: 0.06)
        XCTAssertTrue(detector.milestones(from: state, to: state).isEmpty)
    }

    func testNoMilestonesForProgressBetweenThresholds() {
        let before = snapshot(blocks: 26, metres: 11_000, fraction: 0.011)
        let after = snapshot(blocks: 49, metres: 24_000, fraction: 0.049)
        XCTAssertTrue(detector.milestones(from: before, to: after).isEmpty)
    }

    // MARK: - First walk

    func testFirstWalkFiresOnlyOnTheFirstWalk() {
        let before = snapshot(walks: 0)
        let after = snapshot(blocks: 3, walks: 1)
        XCTAssertEqual(detector.milestones(from: before, to: after).map(\.kind), [.firstWalk])

        let later = snapshot(blocks: 6, walks: 2)
        XCTAssertFalse(detector.milestones(from: after, to: later).contains { $0.kind == .firstWalk })
    }

    // MARK: - Blocks

    func testBlockThresholdFiresOnCrossing() {
        let before = snapshot(blocks: 9)
        let after = snapshot(blocks: 10)
        XCTAssertEqual(detector.milestones(from: before, to: after).map(\.kind), [.blocks(10)])
    }

    func testBlockThresholdDoesNotRefireOnceCrossed() {
        let before = snapshot(blocks: 10)
        let after = snapshot(blocks: 24)
        XCTAssertTrue(detector.milestones(from: before, to: after).isEmpty)
    }

    /// A single long walk can pass several thresholds at once, and all of them
    /// should be reported rather than only the last.
    func testOneWalkCanCrossSeveralBlockThresholds() {
        let before = snapshot(blocks: 8)
        let after = snapshot(blocks: 120)
        let kinds = detector.milestones(from: before, to: after).map(\.kind)
        XCTAssertEqual(kinds, [.blocks(10), .blocks(25), .blocks(50), .blocks(100)])
    }

    // MARK: - Distance

    func testDistanceThresholdFiresOnCrossing() {
        let before = snapshot(metres: 9_999)
        let after = snapshot(metres: 10_001)
        XCTAssertEqual(detector.milestones(from: before, to: after).map(\.kind), [.distance(10_000)])
    }

    func testDistanceThresholdIsInclusiveAtExactlyTheThreshold() {
        let before = snapshot(metres: 9_000)
        let after = snapshot(metres: 10_000)
        XCTAssertEqual(detector.milestones(from: before, to: after).map(\.kind), [.distance(10_000)])
    }

    // MARK: - Percentage

    func testPercentThresholdFiresOnCrossing() {
        let before = snapshot(fraction: 0.049)
        let after = snapshot(fraction: 0.051)
        XCTAssertEqual(detector.milestones(from: before, to: after).map(\.kind), [.cityPercent(5)])
    }

    /// Reaching 100% is reported as finishing the city, which is a bigger
    /// moment. Showing both would be saying the same thing twice.
    func testHundredPercentReportsCityCompleteAndNotAlsoPercent() {
        let before = snapshot(blocks: 999, totalBlocks: 1_000, fraction: 0.999)
        let after = snapshot(blocks: 1_000, totalBlocks: 1_000, fraction: 1.0)
        let kinds = detector.milestones(from: before, to: after).map(\.kind)
        XCTAssertFalse(kinds.contains(.cityPercent(100)))
        XCTAssertTrue(kinds.contains(.cityComplete(name: "Testville")))
    }

    func testCityCompleteDoesNotRefire() {
        let done = snapshot(blocks: 1_000, totalBlocks: 1_000, fraction: 1.0)
        XCTAssertTrue(detector.milestones(from: done, to: done).isEmpty)
    }

    /// A city with no pack loaded has no blocks, and must not read as finished.
    func testEmptyCityIsNotComplete() {
        let before = snapshot(blocks: 0, totalBlocks: 0)
        let after = snapshot(blocks: 0, totalBlocks: 0)
        XCTAssertTrue(detector.milestones(from: before, to: after).isEmpty)
    }

    // MARK: - Districts

    func testFinishingADistrictFires() {
        let before = snapshot(districts: ["Le Marais"])
        let after = snapshot(districts: ["Le Marais", "Montmartre"])
        XCTAssertEqual(
            detector.milestones(from: before, to: after).map(\.kind),
            [.districtComplete(name: "Montmartre")]
        )
    }

    func testSeveralDistrictsFinishedAtOnceAreAllReportedInOrder() {
        let before = snapshot()
        let after = snapshot(districts: ["Montmartre", "Le Marais"])
        XCTAssertEqual(
            detector.milestones(from: before, to: after).map(\.kind),
            [.districtComplete(name: "Le Marais"), .districtComplete(name: "Montmartre")]
        )
    }

    /// Coverage can fall when a pack is replaced and rebuilt. That must not be
    /// treated as an achievement, and must not crash.
    func testCoverageGoingBackwardsProducesNothing() {
        let before = snapshot(blocks: 500, metres: 200_000, fraction: 0.5, districts: ["A", "B"])
        let after = snapshot(blocks: 120, metres: 40_000, fraction: 0.12, districts: ["A"])
        XCTAssertTrue(detector.milestones(from: before, to: after).isEmpty)
    }

    // MARK: - Ordering and identity

    /// The screen shows the last one most prominently, so finishing the city
    /// must not be buried behind a block count crossed in the same walk.
    func testMostSignificantMilestoneComesLast() {
        let before = snapshot(blocks: 900, totalBlocks: 1_000, fraction: 0.9)
        let after = snapshot(blocks: 1_000, totalBlocks: 1_000, fraction: 1.0, districts: ["A"])
        let kinds = detector.milestones(from: before, to: after).map(\.kind)
        XCTAssertEqual(kinds.last, .cityComplete(name: "Testville"))
    }

    func testIdentifiersAreStableAndDistinct() {
        let before = snapshot(blocks: 8, metres: 9_000, fraction: 0.004, walks: 0)
        let after = snapshot(blocks: 60, metres: 30_000, fraction: 0.06, districts: ["A"])
        let milestones = detector.milestones(from: before, to: after)
        XCTAssertFalse(milestones.isEmpty)
        XCTAssertEqual(Set(milestones.map(\.id)).count, milestones.count)
        for milestone in milestones {
            XCTAssertFalse(milestone.title.isEmpty)
            XCTAssertFalse(milestone.detail.isEmpty)
        }
    }
}
