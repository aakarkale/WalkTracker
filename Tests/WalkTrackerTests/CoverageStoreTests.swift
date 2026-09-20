//
//  CoverageStoreTests.swift
//
//  Covers CoverageStore against a real UserDatabase in a temporary directory:
//  schema migration, applying matched claims, and the arithmetic behind the
//  "new metres this walk" figure.
//
//  The claim that matters most here is that re-walking a street is not
//  progress. Only the increase in covered fraction counts toward a session's
//  new coverage, so walking the same block twice reports the block once.
//
//  These tests use the real SQLite file rather than a stub, because the
//  interesting behaviour lives in the read, merge and write cycle inside one
//  transaction, and a stub would only test the parts that were never in doubt.
//

import XCTest
@testable import WalkTracker

final class CoverageStoreTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private var userDatabase: UserDatabase!
    private var store: CoverageStore!

    private let city = "paris"
    private let otherCity = "berlin"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Fixture.makeTemporaryDirectory()
        databaseURL = directory.appendingPathComponent("user.sqlite")
        userDatabase = try UserDatabase(fileURL: databaseURL)
        store = CoverageStore(database: userDatabase.database)
    }

    override func tearDownWithError() throws {
        // Released in dependency order so the SQLite connection is closed
        // before the file is removed.
        store = nil
        userDatabase = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        databaseURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func claim(_ segmentID: Int64, _ from: Double, _ to: Double, at seconds: TimeInterval = 0) -> CoverageClaim {
        CoverageClaim(segmentID: segmentID, from: from, to: to, timestamp: Fixture.date(seconds))
    }

    /// Every block in these tests is 100 m long, so metres and percent of a
    /// block are the same number and the expected values stay readable.
    private let hundredMetreBlocks: (Int64) -> Double? = { _ in 100 }

    // MARK: - Applying claims

    func testApplyingClaimsRecordsCoverageAndReportsNewMetres() throws {
        let gained = try store.apply(
            [claim(1, 0, 0.5)],
            cityID: city,
            lengthForSegment: hundredMetreBlocks
        )

        XCTAssertEqual(gained, 50, accuracy: 1e-9)
        XCTAssertEqual(try store.fractions(forCity: city)[1] ?? 0, 0.5, accuracy: 1e-9)
    }

    func testCoverageAccumulatesAcrossSeparateApplies() throws {
        let first = try store.apply([claim(1, 0, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)
        let second = try store.apply([claim(1, 0.5, 1.0)], cityID: city, lengthForSegment: hundredMetreBlocks)

        XCTAssertEqual(first, 50, accuracy: 1e-9)
        XCTAssertEqual(second, 50, accuracy: 1e-9)
        XCTAssertEqual(try store.fractions(forCity: city)[1] ?? 0, 1.0, accuracy: 1e-9)
    }

    func testReWalkingTheSameBlockReportsNoNewMetres() throws {
        let first = try store.apply([claim(1, 0, 1)], cityID: city, lengthForSegment: hundredMetreBlocks)
        let second = try store.apply([claim(1, 0, 1)], cityID: city, lengthForSegment: hundredMetreBlocks)

        XCTAssertEqual(first, 100, accuracy: 1e-9)
        XCTAssertEqual(second, 0, accuracy: 1e-9)
        // The coverage itself is unchanged, not doubled.
        XCTAssertEqual(try store.fractions(forCity: city)[1] ?? 0, 1.0, accuracy: 1e-9)
    }

    func testOverlappingWalkCountsOnlyTheNewStretch() throws {
        _ = try store.apply([claim(1, 0, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)
        let gained = try store.apply([claim(1, 0.25, 0.75)], cityID: city, lengthForSegment: hundredMetreBlocks)

        // Only 0.5 to 0.75 is new.
        XCTAssertEqual(gained, 25, accuracy: 1e-9)
        XCTAssertEqual(try store.fractions(forCity: city)[1] ?? 0, 0.75, accuracy: 1e-9)
    }

    func testClaimsAcrossSeveralBlocksAreAllApplied() throws {
        let gained = try store.apply(
            [claim(1, 0, 0.5), claim(2, 0, 0.25), claim(3, 0, 1)],
            cityID: city,
            lengthForSegment: hundredMetreBlocks
        )

        XCTAssertEqual(gained, 175, accuracy: 1e-9)

        let fractions = try store.fractions(forCity: city)
        XCTAssertEqual(fractions.count, 3)
        XCTAssertEqual(fractions[1] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fractions[2] ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(fractions[3] ?? 0, 1.0, accuracy: 1e-9)
    }

    func testSeveralClaimsOnOneBlockAreMergedBeforeWriting() throws {
        // A walk down one block arrives as a burst of small claims.
        let gained = try store.apply(
            [claim(1, 0, 0.2), claim(1, 0.2, 0.4), claim(1, 0.4, 0.6)],
            cityID: city,
            lengthForSegment: hundredMetreBlocks
        )

        XCTAssertEqual(gained, 60, accuracy: 1e-6)
        XCTAssertEqual(try store.coverage(forCity: city, segmentID: 1)?.intervals.intervals.count, 1)
    }

    func testEmptyClaimListWritesNothing() throws {
        let gained = try store.apply([], cityID: city, lengthForSegment: hundredMetreBlocks)

        XCTAssertEqual(gained, 0)
        XCTAssertTrue(try store.fractions(forCity: city).isEmpty)
    }

    func testZeroLengthClaimsWriteNothing() throws {
        let gained = try store.apply([claim(1, 0.5, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)

        XCTAssertEqual(gained, 0)
        XCTAssertTrue(try store.fractions(forCity: city).isEmpty)
    }

    func testUnknownBlockLengthStillRecordsCoverage() throws {
        // A coverage row whose block is missing from the pack can happen after
        // a pack update. The metres are unknown, so none are reported, but the
        // coverage is still recorded rather than thrown away.
        let gained = try store.apply([claim(9_999, 0, 1)], cityID: city) { _ in nil }

        XCTAssertEqual(gained, 0)
        XCTAssertEqual(try store.fractions(forCity: city)[9_999] ?? 0, 1.0, accuracy: 1e-9)
    }

    func testNewMetresScaleWithBlockLength() throws {
        let gained = try store.apply([claim(1, 0, 0.4)], cityID: city) { _ in 250 }
        XCTAssertEqual(gained, 100, accuracy: 1e-9)
    }

    // MARK: - Reading back

    func testCoverageForOneBlockCarriesIntervalsAndTimestamps() throws {
        _ = try store.apply(
            [claim(1, 0, 0.5)],
            cityID: city,
            at: Fixture.date(0),
            lengthForSegment: hundredMetreBlocks
        )
        _ = try store.apply(
            [claim(1, 0.6, 0.8)],
            cityID: city,
            at: Fixture.date(3_600),
            lengthForSegment: hundredMetreBlocks
        )

        let coverage = try XCTUnwrap(try store.coverage(forCity: city, segmentID: 1))

        XCTAssertEqual(coverage.segmentID, 1)
        XCTAssertEqual(coverage.intervals.intervals.count, 2)
        XCTAssertEqual(coverage.fraction, 0.7, accuracy: 1e-6)
        // First walked stays at the original walk; last walked moves.
        XCTAssertEqual(
            coverage.firstWalkedAt?.timeIntervalSince1970 ?? 0,
            Fixture.date(0).timeIntervalSince1970,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            coverage.lastWalkedAt?.timeIntervalSince1970 ?? 0,
            Fixture.date(3_600).timeIntervalSince1970,
            accuracy: 1e-6
        )
    }

    func testCoverageForAnUntouchedBlockIsNil() throws {
        XCTAssertNil(try store.coverage(forCity: city, segmentID: 42))
    }

    func testCompletedSegmentsUseTheCompletionThreshold() throws {
        // The threshold is 0.7, set below 1 so GPS trimming at the ends of a
        // block does not leave every street stuck at 97 per cent.
        _ = try store.apply([claim(1, 0, 0.8)], cityID: city, lengthForSegment: hundredMetreBlocks)
        _ = try store.apply([claim(2, 0, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)
        _ = try store.apply([claim(3, 0, 0.7)], cityID: city, lengthForSegment: hundredMetreBlocks)

        let completed = try store.completedSegmentIDs(forCity: city)

        XCTAssertTrue(completed.contains(1))
        XCTAssertFalse(completed.contains(2))
        XCTAssertTrue(completed.contains(3), "exactly at the threshold counts as complete")
    }

    func testCoverageSurvivesReopeningTheDatabase() throws {
        _ = try store.apply([claim(1, 0, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)

        store = nil
        userDatabase = nil

        userDatabase = try UserDatabase(fileURL: databaseURL)
        store = CoverageStore(database: userDatabase.database)

        XCTAssertEqual(try store.fractions(forCity: city)[1] ?? 0, 0.5, accuracy: 1e-9)
    }

    // MARK: - Per city isolation

    func testTheSameBlockIdInTwoCitiesIsTwoRows() throws {
        // Segment ids are pack-local, so id 1 in Paris and id 1 in Berlin are
        // different streets.
        _ = try store.apply([claim(1, 0, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)
        _ = try store.apply([claim(1, 0, 1.0)], cityID: otherCity, lengthForSegment: hundredMetreBlocks)

        XCTAssertEqual(try store.fractions(forCity: city)[1] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(try store.fractions(forCity: otherCity)[1] ?? 0, 1.0, accuracy: 1e-9)
    }

    func testClearCoverageRemovesOnlyTheNamedCity() throws {
        _ = try store.apply([claim(1, 0, 0.5), claim(2, 0, 0.5)], cityID: city, lengthForSegment: hundredMetreBlocks)
        _ = try store.apply([claim(1, 0, 0.5)], cityID: otherCity, lengthForSegment: hundredMetreBlocks)

        try store.clearCoverage(forCity: city)

        XCTAssertTrue(try store.fractions(forCity: city).isEmpty)
        XCTAssertEqual(try store.fractions(forCity: otherCity).count, 1)
    }

    func testCoverageCanBeRebuiltAfterClearing() throws {
        // Clearing is what happens when a pack is replaced. Re-applying the
        // same claims afterwards reports the metres as new again, because from
        // the app's point of view none of it is recorded any more.
        _ = try store.apply([claim(1, 0, 1)], cityID: city, lengthForSegment: hundredMetreBlocks)
        try store.clearCoverage(forCity: city)

        let regained = try store.apply([claim(1, 0, 1)], cityID: city, lengthForSegment: hundredMetreBlocks)
        XCTAssertEqual(regained, 100, accuracy: 1e-9)
    }
}
