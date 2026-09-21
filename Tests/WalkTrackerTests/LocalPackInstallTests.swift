//
//  LocalPackInstallTests.swift
//
//  Covers installing a city pack from a file the user picked, rather than
//  downloading one.
//
//  Side-loading is the one path with no published digest to check against, so
//  what is tested here is the set of checks that remain: the file must open as
//  a pack of a schema this build understands, and it must carry the city it
//  was picked for. A pack for the wrong city is the dangerous case, because it
//  would quietly credit streets in one place against a percentage for another,
//  and nothing later in the app would notice.
//

import Foundation
import XCTest
@testable import WalkTracker

final class LocalPackInstallTests: XCTestCase {

    private var directory: URL!
    private var packsDirectory: URL!
    private var downloader: CityPackDownloader!

    override func setUpWithError() throws {
        directory = try Fixture.makeTemporaryDirectory()
        packsDirectory = directory.appendingPathComponent("packs")
        downloader = CityPackDownloader(
            baseURL: URL(string: "https://packs.example.invalid/v1/")!,
            packsDirectory: packsDirectory
        )
    }

    override func tearDownWithError() throws {
        downloader = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixtures

    private func city(id: String, name: String) -> City {
        City(
            id: id,
            name: name,
            country: "Testland",
            countryCode: "TL",
            cameraBounds: BoundingBox(
                minLatitude: 40.70, minLongitude: -74.02,
                maxLatitude: 40.76, maxLongitude: -73.96
            ),
            center: Coordinate(latitude: 40.73, longitude: -73.99),
            pack: nil
        )
    }

    /// Geometry blob in the pack's binary layout: a little-endian point count,
    /// then the latitudes scaled by 1e7, then the longitudes.
    private func geometry(_ coordinates: [Coordinate]) -> Data {
        var data = Data()
        var count = UInt16(coordinates.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for coordinate in coordinates {
            var value = Int32(coordinate.latitude * 1e7).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for coordinate in coordinates {
            var value = Int32(coordinate.longitude * 1e7).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Writes a minimal but genuinely valid pack, so the tests exercise the
    /// real reader rather than a stub.
    @discardableResult
    private func writePack(
        at url: URL,
        cityID: String,
        cityName: String,
        schemaVersion: Int = 1,
        blocks: Int = 3
    ) throws -> URL {
        let database = try SQLiteDatabase(path: url.path, readOnly: false)
        try database.execute("""
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE segment (
            id INTEGER PRIMARY KEY, way_id INTEGER, name TEXT, class TEXT,
            start_node INTEGER, end_node INTEGER, length_m REAL,
            district_id INTEGER, geometry BLOB
        );
        CREATE VIRTUAL TABLE segment_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        CREATE TABLE district (
            id INTEGER PRIMARY KEY, name TEXT,
            min_lat REAL, min_lon REAL, max_lat REAL, max_lon REAL,
            segment_count INTEGER, total_length_m REAL
        );
        """)

        var totalLength: Double = 0
        for index in 0..<blocks {
            let start = Coordinate(latitude: 40.73 + Double(index) * 0.001, longitude: -73.99)
            let end = Coordinate(latitude: 40.73 + Double(index) * 0.001, longitude: -73.988)
            let line = Polyline(coordinates: [start, end])
            totalLength += line.length

            try database.run(
                """
                INSERT INTO segment (id, way_id, name, class, start_node, end_node, length_m, district_id, geometry)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                [
                    .integer(Int64(index + 1)), .integer(100), .text("Test Street"),
                    .text(WayClass.residential.rawValue),
                    .integer(Int64(index)), .integer(Int64(index + 1)),
                    .real(line.length), .blob(geometry([start, end]))
                ]
            )
            try database.run(
                "INSERT INTO segment_rtree (id, min_lon, max_lon, min_lat, max_lat) VALUES (?, ?, ?, ?, ?)",
                [
                    .integer(Int64(index + 1)),
                    .real(min(start.longitude, end.longitude)), .real(max(start.longitude, end.longitude)),
                    .real(min(start.latitude, end.latitude)), .real(max(start.latitude, end.latitude))
                ]
            )
        }

        for (key, value) in [
            ("schema_version", String(schemaVersion)),
            ("city_id", cityID),
            ("city_name", cityName),
            ("built_at", "2026-01-01T00:00:00Z"),
            ("osm_extract", "test fixture"),
            ("segment_count", String(blocks)),
            ("total_length_m", String(format: "%.3f", totalLength)),
            ("min_lat", "40.70"), ("min_lon", "-74.02"),
            ("max_lat", "40.76"), ("max_lon", "-73.96")
        ] {
            try database.run("INSERT INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        }

        // The pipeline ships packs in a rollback journal mode so the file is
        // self-contained. The fixture has to match: a WAL header sends any
        // reader looking for a sidecar log that will not travel with the file,
        // and a read-only reader that cannot find it fails outright.
        try database.checkpoint()
        try database.execute("PRAGMA journal_mode = DELETE")
        return url
    }

    // MARK: - The happy path

    func testInstallsAPackChosenFromAFile() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("testville.sqlite")
        try writePack(at: source, cityID: "testville", cityName: "Testville", blocks: 4)

        let installed = try downloader.installLocalPack(at: source, expecting: target)

        XCTAssertEqual(installed.cityID, "testville")
        XCTAssertEqual(installed.cityName, "Testville")
        XCTAssertEqual(installed.segmentCount, 4)
        XCTAssertGreaterThan(installed.totalLengthMetres, 0)
        XCTAssertEqual(installed.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.installedURL.path))
        XCTAssertTrue(downloader.hasLocalPack(target))
        XCTAssertTrue(downloader.isInstalled(target))
    }

    /// A city with no published descriptor is exactly the case side-loading
    /// exists for, so the installed pack has to be findable without one.
    func testInstalledPackIsFoundForACityWithNoDescriptor() throws {
        let target = city(id: "testville", name: "Testville")
        XCTAssertNil(target.pack)
        XCTAssertNil(downloader.installedURL(for: target))

        let source = directory.appendingPathComponent("testville.sqlite")
        try writePack(at: source, cityID: "testville", cityName: "Testville")
        _ = try downloader.installLocalPack(at: source, expecting: target)

        XCTAssertNotNil(downloader.installedURL(for: target))
    }

    func testInstalledPackOpensAsAReadableStore() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("testville.sqlite")
        try writePack(at: source, cityID: "testville", cityName: "Testville", blocks: 3)

        let installed = try downloader.installLocalPack(at: source, expecting: target)
        let store = try CityPackStore(path: installed.installedURL.path)

        XCTAssertEqual(store.meta.cityID, "testville")
        XCTAssertEqual(store.totals(includeOptional: false).blockCount, 3)
        XCTAssertFalse(store.segments(in: store.meta.bounds).isEmpty)
    }

    func testGzippedPackIsAccepted() throws {
        let target = city(id: "testville", name: "Testville")
        let plain = directory.appendingPathComponent("testville.sqlite")
        try writePack(at: plain, cityID: "testville", cityName: "Testville")

        let gzipped = directory.appendingPathComponent("testville.sqlite.gz")
        try GzipEncoder.compress(try Data(contentsOf: plain)).write(to: gzipped)

        let installed = try downloader.installLocalPack(at: gzipped, expecting: target)
        XCTAssertEqual(installed.cityID, "testville")
        XCTAssertEqual(installed.segmentCount, 3)
    }

    // MARK: - The checks that remain without a digest

    /// The dangerous case. Streets would be credited in one city against a
    /// percentage for another, and nothing downstream would notice.
    func testPackForADifferentCityIsRefused() throws {
        let target = city(id: "paris", name: "Paris")
        let source = directory.appendingPathComponent("wrong.sqlite")
        try writePack(at: source, cityID: "testville", cityName: "Testville")

        XCTAssertThrowsError(try downloader.installLocalPack(at: source, expecting: target)) { error in
            guard case CityPackDownloader.DownloadError.localPackForDifferentCity = error else {
                return XCTFail("expected localPackForDifferentCity, got \(error)")
            }
        }
        XCTAssertFalse(downloader.hasLocalPack(target), "a refused pack must not be installed")
    }

    func testPackFromAnUnsupportedSchemaIsRefused() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("future.sqlite")
        try writePack(at: source, cityID: "testville", cityName: "Testville", schemaVersion: 99)

        XCTAssertThrowsError(try downloader.installLocalPack(at: source, expecting: target))
        XCTAssertFalse(downloader.hasLocalPack(target))
    }

    func testArbitraryBytesAreRefused() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("junk.sqlite")
        try Data((0..<8_192).map { _ in UInt8.random(in: 0...255) }).write(to: source)

        XCTAssertThrowsError(try downloader.installLocalPack(at: source, expecting: target))
        XCTAssertFalse(downloader.hasLocalPack(target))
    }

    func testEmptyFileIsRefused() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("empty.sqlite")
        try Data().write(to: source)

        XCTAssertThrowsError(try downloader.installLocalPack(at: source, expecting: target))
        XCTAssertFalse(downloader.hasLocalPack(target))
    }

    func testRefusedInstallLeavesNoTemporaryFilesBehind() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("junk.sqlite")
        try Data("not a database".utf8).write(to: source)

        XCTAssertThrowsError(try downloader.installLocalPack(at: source, expecting: target))

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: packsDirectory.path))?
            .filter { $0.hasSuffix(".tmp") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "found \(leftovers)")
    }

    // MARK: - Replacement

    /// Digest rather than version, because a side-loaded pack has no version.
    /// This is what makes the coverage rebuild fire when the streets change
    /// underneath the stored segment ids.
    func testReplacingWithADifferentPackChangesTheDigest() throws {
        let target = city(id: "testville", name: "Testville")

        let first = directory.appendingPathComponent("first.sqlite")
        try writePack(at: first, cityID: "testville", cityName: "Testville", blocks: 3)
        let a = try downloader.installLocalPack(at: first, expecting: target)

        let second = directory.appendingPathComponent("second.sqlite")
        try writePack(at: second, cityID: "testville", cityName: "Testville", blocks: 7)
        let b = try downloader.installLocalPack(at: second, expecting: target)

        XCTAssertNotEqual(a.sha256, b.sha256)
        XCTAssertEqual(b.segmentCount, 7, "the newer pack should be the installed one")
        XCTAssertEqual(a.installedURL, b.installedURL, "and it should occupy the same path")
    }

    func testUninstallRemovesASideLoadedPack() throws {
        let target = city(id: "testville", name: "Testville")
        let source = directory.appendingPathComponent("testville.sqlite")
        try writePack(at: source, cityID: "testville", cityName: "Testville")
        _ = try downloader.installLocalPack(at: source, expecting: target)

        XCTAssertTrue(downloader.hasLocalPack(target))
        try downloader.uninstall(target)
        XCTAssertFalse(downloader.hasLocalPack(target))
        XCTAssertNil(downloader.installedURL(for: target))
    }
}
