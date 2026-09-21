//
//  BackupServiceTests.swift
//
//  Covers BackupService: exporting the walk database and restoring it.
//
//  Backups are the answer to a data-loss problem, so the behaviour that
//  matters most here is the failure path. A restore replaces everything the
//  user has. If it half succeeds it can leave them with neither their old data
//  nor their new data, which is worse than refusing outright, so the rollback
//  is tested as carefully as the happy path.
//

import Foundation
import XCTest
@testable import WalkTracker

final class BackupServiceTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private var database: UserDatabase!
    private let service = BackupService()

    override func setUpWithError() throws {
        directory = try Fixture.makeTemporaryDirectory()
        databaseURL = directory.appendingPathComponent("walks.sqlite")
        database = try UserDatabase(fileURL: databaseURL)
    }

    override func tearDownWithError() throws {
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func seed(sessions: Int, pointsEach: Int, cityID: String = "paris") throws {
        let store = SessionStore(database: database.database)
        for index in 0..<sessions {
            let session = try store.startSession(
                cityID: cityID,
                at: Fixture.date(TimeInterval(index) * 3_600)
            )
            let points = (0..<pointsEach).map { step in
                Fixture.point(
                    seconds: TimeInterval(index) * 3_600 + TimeInterval(step),
                    coordinate: Coordinate(
                        latitude: 48.8566 + Double(step) * 0.0001,
                        longitude: 2.3522 + Double(step) * 0.0001
                    ),
                    sessionID: session.id
                )
            }
            try store.appendPoints(points)
            try store.endSession(id: session.id)
        }
    }

    // MARK: - Export and inspect

    func testExportedBackupCanBeInspected() throws {
        try seed(sessions: 3, pointsEach: 10)

        let url = try service.export(database: database, to: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let (info, data) = try service.inspect(fileAt: url)
        XCTAssertEqual(info.sessionCount, 3)
        XCTAssertEqual(info.pointCount, 30)
        XCTAssertEqual(info.cityIDs, ["paris"])
        XCTAssertNotNil(info.createdAt)
        XCTAssertEqual(info.schemaVersion, UserDatabase.currentSchemaVersion)
        XCTAssertFalse(data.isEmpty)
    }

    func testExportIsCompressed() throws {
        try seed(sessions: 5, pointsEach: 200)
        let url = try service.export(database: database, to: directory)

        // Compared against the snapshot's own uncompressed size, not against
        // the live database file on disk. While the database is open its main
        // file does not hold everything: recent pages live in the write-ahead
        // log, so its byte count understates the real contents and would make
        // this assertion meaningless.
        let compressed = try Data(contentsOf: url).count
        let uncompressed = try service.inspect(fileAt: url).info.uncompressedBytes
        XCTAssertLessThan(compressed, uncompressed, "a backup should compress")
    }

    /// Recent writes live in the write-ahead log until it is folded back in.
    /// Without the checkpoint the copy is silently stale and the user loses
    /// exactly the walks they just took.
    func testExportIncludesWritesStillInTheWriteAheadLog() throws {
        try seed(sessions: 1, pointsEach: 5)
        let url = try service.export(database: database, to: directory)
        XCTAssertEqual(try service.inspect(fileAt: url).info.sessionCount, 1)

        try seed(sessions: 1, pointsEach: 5, cityID: "berlin")
        let second = try service.export(database: database, to: directory.appendingPathComponent("second"))
        let info = try service.inspect(fileAt: second).info
        XCTAssertEqual(info.sessionCount, 2)
        XCTAssertEqual(info.cityIDs, ["berlin", "paris"])
    }

    func testEmptyDatabaseBacksUpAndRestores() throws {
        let url = try service.export(database: database, to: directory)
        let (info, data) = try service.inspect(fileAt: url)
        XCTAssertEqual(info.sessionCount, 0)
        XCTAssertEqual(info.pointCount, 0)
        XCTAssertTrue(info.cityIDs.isEmpty)

        database = nil
        try service.restore(decompressed: data, to: databaseURL)
        database = try UserDatabase(fileURL: databaseURL)
        XCTAssertNil(try SessionStore(database: database.database).openSession())
    }

    // MARK: - Rejecting things that are not backups

    /// A plain SQLite file is the most likely wrong pick, since the user is
    /// choosing from a file browser. It has no marker, so it is refused.
    func testPlainDatabaseWithoutTheMarkerIsRefused() throws {
        let other = directory.appendingPathComponent("other.sqlite")
        _ = try UserDatabase(fileURL: other)

        XCTAssertThrowsError(try service.inspect(fileAt: other)) { error in
            guard case BackupService.BackupError.notABackup = error else {
                return XCTFail("expected notABackup, got \(error)")
            }
        }
    }

    func testRandomBytesAreRefused() throws {
        let junk = directory.appendingPathComponent("junk.sqlite.gz")
        try Data((0..<4_096).map { _ in UInt8.random(in: 0...255) }).write(to: junk)
        XCTAssertThrowsError(try service.inspect(fileAt: junk))
    }

    func testEmptyFileIsRefused() throws {
        let empty = directory.appendingPathComponent("empty.sqlite.gz")
        try Data().write(to: empty)
        XCTAssertThrowsError(try service.inspect(fileAt: empty))
    }

    /// A backup from a future version of the app describes a schema this build
    /// does not understand. Opening it on a guess would misread the user's
    /// history, so it is refused with a message that explains why.
    func testBackupFromANewerSchemaIsRefused() throws {
        try seed(sessions: 1, pointsEach: 5)
        let url = try service.export(database: database, to: directory)
        let (_, data) = try service.inspect(fileAt: url)

        let future = directory.appendingPathComponent("future.sqlite")
        try data.write(to: future)
        let raised = try SQLiteDatabase(path: future.path, readOnly: false)
        try raised.execute("PRAGMA user_version = \(UserDatabase.currentSchemaVersion + 5)")
        try raised.checkpoint()

        XCTAssertThrowsError(try service.inspect(fileAt: future)) { error in
            guard case BackupService.BackupError.unsupportedSchema = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
        }
    }

    // MARK: - Restore

    func testRestoreReplacesCurrentData() throws {
        try seed(sessions: 2, pointsEach: 10, cityID: "paris")
        let url = try service.export(database: database, to: directory)
        let (_, backup) = try service.inspect(fileAt: url)

        // Move on: more walks, a different city.
        try seed(sessions: 4, pointsEach: 10, cityID: "tokyo")
        XCTAssertEqual(try SessionStore(database: database.database).recentSessions(cityID: nil).count, 6)

        database = nil
        try service.restore(decompressed: backup, to: databaseURL)
        database = try UserDatabase(fileURL: databaseURL)

        let sessions = try SessionStore(database: database.database).recentSessions(cityID: nil)
        XCTAssertEqual(sessions.count, 2, "restore should replace, not merge")
        XCTAssertTrue(sessions.allSatisfy { $0.cityID == "paris" })
    }

    func testRestoredDatabaseIsWritable() throws {
        try seed(sessions: 1, pointsEach: 5)
        let (_, backup) = try service.inspect(fileAt: try service.export(database: database, to: directory))

        database = nil
        try service.restore(decompressed: backup, to: databaseURL)
        database = try UserDatabase(fileURL: databaseURL)

        let store = SessionStore(database: database.database)
        let session = try store.startSession(cityID: "lisbon")
        XCTAssertEqual(try store.recentSessions(cityID: "lisbon").count, 1)
        try store.endSession(id: session.id)
    }

    /// The sidecar log belongs to the database being replaced. Left in place,
    /// SQLite would replay those writes over the restored data.
    func testStaleWriteAheadLogIsRemovedOnRestore() throws {
        try seed(sessions: 1, pointsEach: 5)
        let (_, backup) = try service.inspect(fileAt: try service.export(database: database, to: directory))

        database = nil
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        try Data("stale".utf8).write(to: wal)

        try service.restore(decompressed: backup, to: databaseURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path))
    }

    /// The point of the rollback: a failed restore must leave the original
    /// database exactly as it was, not a half-written file.
    func testFailedRestoreLeavesTheOriginalIntact() throws {
        try seed(sessions: 3, pointsEach: 10, cityID: "vienna")
        database = nil

        XCTAssertThrowsError(
            try service.restore(decompressed: Data("not a database at all".utf8), to: databaseURL)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        database = try UserDatabase(fileURL: databaseURL)
        let sessions = try SessionStore(database: database.database).recentSessions(cityID: nil)
        XCTAssertEqual(sessions.count, 3, "the original data should survive a failed restore")
        // Asserted on the data rather than the file size. Closing the database
        // folds the write-ahead log back into the main file, so its byte count
        // legitimately changes across this test and proves nothing either way.
        XCTAssertTrue(sessions.allSatisfy { $0.cityID == "vienna" })
    }

    func testFailedRestoreLeavesNoStrayFilesBehind() throws {
        try seed(sessions: 1, pointsEach: 5)
        database = nil
        XCTAssertThrowsError(try service.restore(decompressed: Data("junk".utf8), to: databaseURL))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("restore-") || $0.hasPrefix("rollback-") }
        XCTAssertTrue(leftovers.isEmpty, "found \(leftovers)")
    }

    func testSuggestedFilenameIsStableAndSafe() {
        let name = BackupService.suggestedFilename(date: Fixture.epoch)
        XCTAssertTrue(name.hasSuffix(".sqlite.gz"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertEqual(name, BackupService.suggestedFilename(date: Fixture.epoch))
    }
}
