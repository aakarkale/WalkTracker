//
//  GPXImporterTests.swift
//
//  Covers GPXImporter: turning an exported GPX file into tracks.
//
//  The file is untrusted input. It arrives from a share sheet or a file
//  picker, so the behaviour pinned down here is that valid files parse in the
//  shapes real tools actually emit, and that broken ones are skipped and
//  counted rather than taking the whole import down with them. Someone
//  importing five years of history should not lose all of it to one bad point.
//

import Foundation
import XCTest
@testable import WalkTracker

final class GPXImporterTests: XCTestCase {

    private func gpx(_ body: String, namespaced: Bool = true) -> Data {
        let open = namespaced
            ? #"<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">"#
            : #"<gpx version="1.1">"#
        return Data((#"<?xml version="1.0" encoding="UTF-8"?>"# + open + body + "</gpx>").utf8)
    }

    /// A run of points five seconds apart, walking north east.
    private func segment(count: Int, startMinute: Int = 0) -> String {
        (0..<count).map { i in
            let seconds = startMinute * 60 + i * 5
            let stamp = Self.stamp(seconds)
            let lat = 40.7500 + Double(i) * 0.0001
            let lon = -73.9800 + Double(i) * 0.0001
            return #"<trkpt lat="\#(lat)" lon="\#(lon)"><ele>12.0</ele><time>\#(stamp)</time></trkpt>"#
        }.joined()
    }

    private static func stamp(_ secondsAfterNoon: Int) -> String {
        let base = Date(timeIntervalSince1970: 1_714_564_800)   // 2024-05-01T12:00:00Z
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: base.addingTimeInterval(TimeInterval(secondsAfterNoon)))
    }

    // MARK: - Shapes real tools emit

    func testNamespacedFileParses() throws {
        let tracks = try GPXImporter().tracks(from: gpx("<trk><name>Morning</name><trkseg>\(segment(count: 20))</trkseg></trk>"))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 20)
        XCTAssertEqual(tracks[0].name, "Morning")
    }

    /// Some exporters omit the namespace. The parser runs with namespace
    /// processing off precisely so both shapes work.
    func testFileWithoutNamespaceParses() throws {
        let tracks = try GPXImporter().tracks(
            from: gpx("<trk><trkseg>\(segment(count: 20))</trkseg></trk>", namespaced: false)
        )
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 20)
    }

    func testSeveralTracksStaySeparate() throws {
        let body = "<trk><trkseg>\(segment(count: 10))</trkseg></trk>"
            + "<trk><trkseg>\(segment(count: 10, startMinute: 200))</trkseg></trk>"
        XCTAssertEqual(try GPXImporter().tracks(from: gpx(body)).count, 2)
    }

    func testElevationIsRead() throws {
        let tracks = try GPXImporter().tracks(from: gpx("<trk><trkseg>\(segment(count: 5))</trkseg></trk>"))
        XCTAssertEqual(tracks[0].points[0].altitude, 12.0, accuracy: 0.001)
    }

    /// GPX carries no accuracy, so a stand-in is supplied. It has to sit inside
    /// the matcher's gate or nothing imported would ever be matched.
    func testSubstitutedAccuracyPassesTheMatcherGate() throws {
        let tracks = try GPXImporter().tracks(from: gpx("<trk><trkseg>\(segment(count: 5))</trkseg></trk>"))
        let accuracy = tracks[0].points[0].horizontalAccuracy
        XCTAssertGreaterThan(accuracy, 0)
        XCTAssertLessThanOrEqual(accuracy, MapMatcher.Configuration().maxHorizontalAccuracy)
    }

    // MARK: - Splitting

    /// Some tools concatenate a whole year into one segment. Treating that as
    /// a single walk would invent a route across every overnight gap.
    func testLongGapSplitsIntoSeparateWalks() throws {
        let body = "<trk><trkseg>\(segment(count: 10))\(segment(count: 10, startMinute: 120))</trkseg></trk>"
        XCTAssertEqual(try GPXImporter().tracks(from: gpx(body)).count, 2)
    }

    func testShortGapStaysOneWalk() throws {
        let body = "<trk><trkseg>\(segment(count: 10))\(segment(count: 10, startMinute: 10))</trkseg></trk>"
        XCTAssertEqual(try GPXImporter().tracks(from: gpx(body)).count, 1)
    }

    func testPointsAreSortedByTime() throws {
        let body = """
        <trk><trkseg>
        <trkpt lat="40.70" lon="-74.0"><time>\(Self.stamp(20))</time></trkpt>
        <trkpt lat="40.71" lon="-74.0"><time>\(Self.stamp(10))</time></trkpt>
        <trkpt lat="40.72" lon="-74.0"><time>\(Self.stamp(15))</time></trkpt>
        </trkseg></trk>
        """
        let points = try GPXImporter().tracks(from: gpx(body))[0].points
        XCTAssertEqual(points.map(\.timestamp), points.map(\.timestamp).sorted())
    }

    // MARK: - Broken input

    func testMalformedPointsAreSkippedNotFatal() throws {
        let body = """
        <trk><trkseg>
        <trkpt lat="40.70" lon="-74.00"><time>\(Self.stamp(0))</time></trkpt>
        <trkpt lat="40.70"><time>\(Self.stamp(5))</time></trkpt>
        <trkpt lat="40.70" lon="-74.00"></trkpt>
        <trkpt lat="91.0" lon="-74.00"><time>\(Self.stamp(15))</time></trkpt>
        <trkpt lat="0" lon="0"><time>\(Self.stamp(20))</time></trkpt>
        <trkpt lat="40.70" lon="-74.00"><time>not a date</time></trkpt>
        <trkpt lat="40.71" lon="-74.01"><time>\(Self.stamp(30))</time></trkpt>
        </trkseg></trk>
        """
        let importer = GPXImporter()
        let tracks = try importer.tracks(from: gpx(body))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].points.count, 2, "only the two good points should survive")
        XCTAssertEqual(importer.lastSkippedPointCount, 5)
    }

    func testFractionalSecondTimestampsParse() throws {
        let body = """
        <trk><trkseg>
        <trkpt lat="40.70" lon="-74.00"><time>2024-05-01T12:00:00.500Z</time></trkpt>
        <trkpt lat="40.71" lon="-74.01"><time>2024-05-01T12:00:05.250Z</time></trkpt>
        </trkseg></trk>
        """
        XCTAssertEqual(try GPXImporter().tracks(from: gpx(body))[0].points.count, 2)
    }

    func testSinglePointTrackIsDropped() {
        let body = "<trk><trkseg>\(segment(count: 1))</trkseg></trk>"
        XCTAssertThrowsError(try GPXImporter().tracks(from: gpx(body)))
    }

    func testEmptyAndNonGPXInputThrow() {
        XCTAssertThrowsError(try GPXImporter().tracks(from: Data()))
        XCTAssertThrowsError(try GPXImporter().tracks(from: Data("not xml at all".utf8)))
        XCTAssertThrowsError(try GPXImporter().tracks(from: gpx("<trk><trkseg></trkseg></trk>")))
    }

    func testOversizedFileIsRefusedBeforeParsing() {
        let huge = Data(count: GPXImporter.maximumBytes + 1)
        XCTAssertThrowsError(try GPXImporter().tracks(from: huge)) { error in
            guard case GPXImporter.ImportError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    /// An XML parser that resolves external entities can be talked into
    /// reading files off the device. Nothing in GPX needs them, and the
    /// importer turns them off; this checks no data escapes through one.
    func testExternalEntitiesAreNotResolved() throws {
        let hostile = Data("""
        <?xml version="1.0"?>
        <!DOCTYPE gpx [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <gpx version="1.1"><trk><name>&xxe;</name><trkseg>
        <trkpt lat="40.70" lon="-74.00"><time>\(Self.stamp(0))</time></trkpt>
        <trkpt lat="40.71" lon="-74.01"><time>\(Self.stamp(5))</time></trkpt>
        </trkseg></trk></gpx>
        """.utf8)

        // Either the parse fails or it succeeds with nothing substituted. What
        // must never happen is file contents appearing in the track name.
        if let tracks = try? GPXImporter().tracks(from: hostile), let name = tracks.first?.name {
            XCTAssertFalse(name.contains("root:"), "external entity was resolved")
            XCTAssertFalse(name.contains("/bin/"), "external entity was resolved")
        }
    }
}
