//
//  TestSupport.swift
//
//  Small shared fixtures for the test suite: a fixed epoch so timestamps in
//  failure messages are stable and readable, a TrackPoint factory (the real
//  initialiser takes eight arguments, and spelling them out in every test
//  buries the one value the test is actually about), and a temporary
//  directory helper for the store tests.
//
//  Nothing here contains assertions. It exists only so the test files can say
//  what they mean.
//

import Foundation
import XCTest
@testable import WalkTracker

enum Fixture {

    /// 2023-11-14T22:13:20Z. Any fixed instant would do; a real one keeps
    /// failure output easy to read.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func date(_ secondsAfterEpoch: TimeInterval) -> Date {
        epoch.addingTimeInterval(secondsAfterEpoch)
    }

    /// A GPS fix, with defaults that pass every gate in the pipeline: a good
    /// accuracy, a walking speed, and no course (which is what CoreLocation
    /// reports when it cannot determine one).
    static func point(
        seconds: TimeInterval,
        coordinate: Coordinate,
        accuracy: Double = 5,
        speed: Double = 1.4,
        course: Double = -1,
        altitude: Double = 12,
        sessionID: Int64 = 1
    ) -> TrackPoint {
        TrackPoint(
            id: nil,
            sessionID: sessionID,
            timestamp: date(seconds),
            coordinate: coordinate,
            horizontalAccuracy: accuracy,
            speed: speed,
            course: course,
            altitude: altitude
        )
    }

    /// A fresh directory under the system temporary directory. The caller is
    /// responsible for removing it, which the store tests do in tearDown.
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkTrackerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
