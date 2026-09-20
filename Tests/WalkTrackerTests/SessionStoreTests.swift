//
//  SessionStoreTests.swift
//
//  Covers SessionStore against a real UserDatabase in a temporary directory:
//  the session lifecycle (start, end, totals, recovery of a session left open
//  by a crash), the raw point trace, and deletion.
//
//  The cascade test is the important one. Raw fixes are the most sensitive
//  data this app holds, so "delete this walk" has to mean the coordinates go
//  with it. That relies on the foreign key on point.session_id and on
//  PRAGMA foreign_keys being on for the connection, which is easy to lose in
//  a refactor and silent when it happens.
//

import Foundation
import XCTest
@testable import WalkTracker

final class SessionStoreTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private var userDatabase: UserDatabase!
    private var store: SessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Fixture.makeTemporaryDirectory()
        databaseURL = directory.appendingPathComponent("user.sqlite")
        userDatabase = try UserDatabase(fileURL: databaseURL)
        store = SessionStore(database: userDatabase.database)
    }

    override func tearDownWithError() throws {
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

    private func point(_ sessionID: Int64, seconds: TimeInterval, latitude: Double = 48.8566) -> TrackPoint {
        Fixture.point(
            seconds: seconds,
            coordinate: Coordinate(latitude: latitude, longitude: 2.3522),
            accuracy: 8,
            speed: 1.4,
            course: 90,
            altitude: 35,
            sessionID: sessionID
        )
    }

    private func rowCount(_ table: String) throws -> Int {
        // Table name is a literal from this file, never user input.
        try userDatabase.database.query("SELECT COUNT(*) FROM \(table)") { Int($0.int(0)) }.first ?? -1
    }

    // MARK: - Session lifecycle

    func testStartSessionCreatesAnActiveSession() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))

        XCTAssertGreaterThan(session.id, 0)
        XCTAssertEqual(session.cityID, "paris")
        XCTAssertEqual(session.startedAt.timeIntervalSince1970, Fixture.date(0).timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertNil(session.endedAt)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.distanceMetres, 0)
        XCTAssertEqual(session.newCoverageMetres, 0)
        XCTAssertEqual(session.pointCount, 0)
    }

    func testSessionIdsAreDistinct() throws {
        let first = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let second = try store.startSession(cityID: "paris", at: Fixture.date(10))
        XCTAssertNotEqual(first.id, second.id)
    }

    func testEndSessionRecordsTheEndTime() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.endSession(id: session.id, at: Fixture.date(1_800))

        let stored = try XCTUnwrap(try store.recentSessions(cityID: "paris").first)
        XCTAssertEqual(
            stored.endedAt?.timeIntervalSince1970 ?? 0,
            Fixture.date(1_800).timeIntervalSince1970,
            accuracy: 1e-6
        )
        XCTAssertFalse(stored.isActive)
        XCTAssertEqual(stored.duration, 1_800, accuracy: 1e-6)
    }

    func testEndSessionDoesNotMoveAnAlreadyClosedSession() throws {
        // Stopping a walk twice, or a recovery pass running after a normal
        // stop, must not rewrite the end time.
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.endSession(id: session.id, at: Fixture.date(600))
        try store.endSession(id: session.id, at: Fixture.date(9_999))

        let stored = try XCTUnwrap(try store.recentSessions(cityID: "paris").first)
        XCTAssertEqual(
            stored.endedAt?.timeIntervalSince1970 ?? 0,
            Fixture.date(600).timeIntervalSince1970,
            accuracy: 1e-6
        )
    }

    func testUpdateTotalsIsPersisted() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.updateTotals(id: session.id, distanceMetres: 4_321.5, newCoverageMetres: 1_234.25, pointCount: 987)

        let stored = try XCTUnwrap(try store.recentSessions(cityID: "paris").first)
        XCTAssertEqual(stored.distanceMetres, 4_321.5, accuracy: 1e-9)
        XCTAssertEqual(stored.newCoverageMetres, 1_234.25, accuracy: 1e-9)
        XCTAssertEqual(stored.pointCount, 987)
    }

    func testOpenSessionFindsTheUnfinishedWalk() throws {
        // What a crash during background tracking leaves behind.
        let finished = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.endSession(id: finished.id, at: Fixture.date(600))
        let unfinished = try store.startSession(cityID: "paris", at: Fixture.date(1_200))

        let open = try XCTUnwrap(try store.openSession())
        XCTAssertEqual(open.id, unfinished.id)

        try store.endSession(id: unfinished.id, at: Fixture.date(1_800))
        XCTAssertNil(try store.openSession())
    }

    func testRecentSessionsAreNewestFirstAndScopedToTheCity() throws {
        let older = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let newer = try store.startSession(cityID: "paris", at: Fixture.date(10_000))
        let elsewhere = try store.startSession(cityID: "berlin", at: Fixture.date(5_000))

        let paris = try store.recentSessions(cityID: "paris")
        XCTAssertEqual(paris.map(\.id), [newer.id, older.id])

        let all = try store.recentSessions(cityID: nil)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.id, newer.id)
        XCTAssertTrue(all.contains { $0.id == elsewhere.id })
    }

    func testRecentSessionsRespectsTheLimit() throws {
        for index in 0..<5 {
            _ = try store.startSession(cityID: "paris", at: Fixture.date(TimeInterval(index * 100)))
        }
        XCTAssertEqual(try store.recentSessions(cityID: "paris", limit: 2).count, 2)
        XCTAssertEqual(try store.recentSessions(cityID: nil, limit: 3).count, 3)
    }

    // MARK: - Points

    func testAppendedPointsRoundTrip() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let written = [
            point(session.id, seconds: 0, latitude: 48.8566),
            point(session.id, seconds: 5, latitude: 48.8570),
            point(session.id, seconds: 10, latitude: 48.8574)
        ]
        try store.appendPoints(written)

        let read = try store.points(sessionID: session.id)
        XCTAssertEqual(read.count, 3)

        for (expected, actual) in zip(written, read) {
            XCTAssertNotNil(actual.id, "a stored fix should carry its row id")
            XCTAssertEqual(actual.sessionID, session.id)
            XCTAssertEqual(
                actual.timestamp.timeIntervalSince1970,
                expected.timestamp.timeIntervalSince1970,
                accuracy: 1e-6
            )
            XCTAssertEqual(actual.coordinate.latitude, expected.coordinate.latitude, accuracy: 1e-9)
            XCTAssertEqual(actual.coordinate.longitude, expected.coordinate.longitude, accuracy: 1e-9)
            XCTAssertEqual(actual.horizontalAccuracy, expected.horizontalAccuracy, accuracy: 1e-9)
            XCTAssertEqual(actual.speed, expected.speed, accuracy: 1e-9)
            XCTAssertEqual(actual.course, expected.course, accuracy: 1e-9)
            XCTAssertEqual(actual.altitude, expected.altitude, accuracy: 1e-9)
        }
    }

    func testPointsComeBackInTimeOrderEvenIfWrittenOutOfOrder() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.appendPoints([
            point(session.id, seconds: 30),
            point(session.id, seconds: 10),
            point(session.id, seconds: 20)
        ])

        let seconds = try store.points(sessionID: session.id)
            .map { $0.timestamp.timeIntervalSince(Fixture.epoch) }
        XCTAssertEqual(seconds, [10, 20, 30])
    }

    func testAppendingAnEmptyBatchIsANoOp() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.appendPoints([])
        XCTAssertTrue(try store.points(sessionID: session.id).isEmpty)
    }

    func testPointsAreScopedToTheirSession() throws {
        let first = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let second = try store.startSession(cityID: "paris", at: Fixture.date(1_000))
        try store.appendPoints([point(first.id, seconds: 0), point(first.id, seconds: 5)])
        try store.appendPoints([point(second.id, seconds: 1_000)])

        XCTAssertEqual(try store.points(sessionID: first.id).count, 2)
        XCTAssertEqual(try store.points(sessionID: second.id).count, 1)
    }

    func testAllPointsForACityIsScopedAndOrdered() throws {
        let paris = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let parisAgain = try store.startSession(cityID: "paris", at: Fixture.date(1_000))
        let berlin = try store.startSession(cityID: "berlin", at: Fixture.date(2_000))

        try store.appendPoints([point(paris.id, seconds: 10), point(paris.id, seconds: 0)])
        try store.appendPoints([point(parisAgain.id, seconds: 1_000)])
        try store.appendPoints([point(berlin.id, seconds: 2_000)])

        let all = try store.allPoints(cityID: "paris")

        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.sessionID), [paris.id, paris.id, parisAgain.id])
        // Ordered by session, then by time within the session.
        XCTAssertEqual(
            all.map { $0.timestamp.timeIntervalSince(Fixture.epoch) },
            [0, 10, 1_000]
        )
    }

    // MARK: - Deletion

    func testDeletingASessionCascadesToItsPoints() throws {
        let doomed = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let kept = try store.startSession(cityID: "paris", at: Fixture.date(1_000))
        try store.appendPoints([point(doomed.id, seconds: 0), point(doomed.id, seconds: 5)])
        try store.appendPoints([point(kept.id, seconds: 1_000)])
        XCTAssertEqual(try rowCount("point"), 3)

        try store.deleteSession(id: doomed.id)

        XCTAssertTrue(try store.points(sessionID: doomed.id).isEmpty)
        XCTAssertEqual(try rowCount("point"), 1, "the cascade should have taken exactly the deleted session's fixes")
        XCTAssertEqual(try rowCount("session"), 1)
        XCTAssertEqual(try store.points(sessionID: kept.id).count, 1)
    }

    func testDeletingAnUnknownSessionIsHarmless() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.appendPoints([point(session.id, seconds: 0)])

        try store.deleteSession(id: 9_999)

        XCTAssertEqual(try rowCount("session"), 1)
        XCTAssertEqual(try rowCount("point"), 1)
    }

    func testDeletingEverythingLeavesNoTrace() throws {
        // The Settings "delete all my data" path. Anything less than empty
        // tables here is a broken promise.
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.appendPoints([point(session.id, seconds: 0), point(session.id, seconds: 5)])
        let coverage = CoverageStore(database: userDatabase.database)
        _ = try coverage.apply(
            [CoverageClaim(segmentID: 1, from: 0, to: 1, timestamp: Fixture.date(0))],
            cityID: "paris"
        ) { _ in 100 }

        try userDatabase.deleteAllUserData()

        XCTAssertEqual(try rowCount("point"), 0)
        XCTAssertEqual(try rowCount("session"), 0)
        XCTAssertEqual(try rowCount("coverage"), 0)
    }

    func testDeletingOneCityLeavesTheOthersAlone() throws {
        let paris = try store.startSession(cityID: "paris", at: Fixture.date(0))
        let berlin = try store.startSession(cityID: "berlin", at: Fixture.date(1_000))
        try store.appendPoints([point(paris.id, seconds: 0)])
        try store.appendPoints([point(berlin.id, seconds: 1_000)])

        try userDatabase.deleteData(forCity: "paris")

        XCTAssertTrue(try store.recentSessions(cityID: "paris").isEmpty)
        XCTAssertEqual(try store.recentSessions(cityID: "berlin").count, 1)
        XCTAssertEqual(try rowCount("point"), 1)
    }

    // MARK: - Durability

    func testSessionsAndPointsSurviveReopeningTheDatabase() throws {
        let session = try store.startSession(cityID: "paris", at: Fixture.date(0))
        try store.appendPoints([point(session.id, seconds: 0), point(session.id, seconds: 5)])
        try store.endSession(id: session.id, at: Fixture.date(600))

        store = nil
        userDatabase = nil

        userDatabase = try UserDatabase(fileURL: databaseURL)
        store = SessionStore(database: userDatabase.database)

        let stored = try XCTUnwrap(try store.recentSessions(cityID: "paris").first)
        XCTAssertEqual(stored.id, session.id)
        XCTAssertEqual(try store.points(sessionID: session.id).count, 2)
    }
}
