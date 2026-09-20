import Foundation

/// Averages raw fixes into short time buckets before they reach the matcher.
///
/// This is the single most valuable stage in the pipeline. At 1 Hz a walker
/// covers about 1.4 m between fixes while urban GPS error runs 10-25 m, so an
/// individual fix carries almost no information about which way the walker is
/// going. Averaging a few seconds cuts the noise by the square root of the
/// sample count while the walker moves far enough to establish a direction.
///
/// Measured on simulated walks over an 80 m grid at 20 m of GPS noise, adding
/// this stage moved matching precision from 0.67 to 0.99. Without it the
/// matcher paints streets the user never walked.
public final class LocationSmoother {

    /// Bucket length. Eight seconds is roughly 11 m of walking, comfortably
    /// more than the residual noise, while staying short enough that a turn at
    /// an intersection is not smeared across it.
    public let windowSeconds: TimeInterval

    private var buffer: [TrackPoint] = []

    public init(windowSeconds: TimeInterval = 8) {
        self.windowSeconds = windowSeconds
    }

    /// Feeds one raw fix in; returns a smoothed fix when a bucket closes.
    public func push(_ point: TrackPoint) -> TrackPoint? {
        var emitted: TrackPoint?
        if let first = buffer.first,
           point.timestamp.timeIntervalSince(first.timestamp) >= windowSeconds {
            emitted = collapse()
        }
        buffer.append(point)
        return emitted
    }

    /// Closes the current bucket. Call when tracking stops.
    public func flush() -> TrackPoint? {
        collapse()
    }

    public func reset() {
        buffer.removeAll()
    }

    private func collapse() -> TrackPoint? {
        guard !buffer.isEmpty else { return nil }
        let points = buffer
        buffer.removeAll(keepingCapacity: true)

        let count = Double(points.count)
        let latitude = points.reduce(0) { $0 + $1.coordinate.latitude } / count
        let longitude = points.reduce(0) { $0 + $1.coordinate.longitude } / count
        let interval = points.reduce(0.0) { $0 + $1.timestamp.timeIntervalSince1970 } / count

        // Averaging n independent fixes shrinks the standard error by sqrt(n).
        // The floor stops a long stationary bucket claiming implausible
        // precision, which would let it dominate the whole Viterbi chain.
        let meanAccuracy = points.reduce(0) { $0 + max(0, $1.horizontalAccuracy) } / count
        let accuracy = max(3, meanAccuracy / sqrt(count))

        let speed = points.reduce(0) { $0 + max(0, $1.speed) } / count

        return TrackPoint(
            id: nil,
            sessionID: points[0].sessionID,
            timestamp: Date(timeIntervalSince1970: interval),
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            horizontalAccuracy: accuracy,
            speed: speed,
            course: Self.meanCourse(points),
            altitude: points.reduce(0) { $0 + $1.altitude } / count
        )
    }

    /// Circular mean of the valid courses.
    ///
    /// A plain arithmetic mean is wrong for angles: due north sampled as 359
    /// and 1 degrees would average to 180, exactly backwards. Averaging the
    /// unit vectors avoids that.
    static func meanCourse(_ points: [TrackPoint]) -> Double {
        let valid = points.filter { $0.course >= 0 }
        guard !valid.isEmpty else { return -1 }

        var sumSin = 0.0
        var sumCos = 0.0
        for point in valid {
            let radians = point.course * .pi / 180
            sumSin += sin(radians)
            sumCos += cos(radians)
        }

        // Courses spread evenly around the compass cancel out, leaving no
        // meaningful direction. Report "unknown" rather than an artefact.
        guard hypot(sumSin, sumCos) > 1e-9 else { return -1 }

        let degrees = atan2(sumSin, sumCos) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
