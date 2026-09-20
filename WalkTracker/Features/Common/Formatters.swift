import Foundation

/// Locale-aware formatting for the few quantities this app puts on screen.
///
/// Everything inside the app is metres and seconds. Only this file knows about
/// miles and feet, and it decides from the locale rather than from a setting:
/// someone whose phone is already in US units expects miles without being
/// asked, and one more toggle in Settings is not a feature.
enum WalkFormat {

    /// Whether to show metric road distances.
    ///
    /// The UK deliberately does not count as metric here. Road and walking
    /// distances there are still miles, even though almost everything else in
    /// the locale is metric.
    static var usesMetricDistance: Bool {
        Locale.current.measurementSystem == .metric
    }

    // MARK: - Distance

    /// A walked distance, in the units the locale expects.
    static func distance(metres: Double) -> String {
        let safe = max(0, metres)

        if usesMetricDistance {
            if safe < 1_000 {
                let value = Int(safe.rounded()).formatted()
                return String(localized: "\(value) m")
            }
            let kilometres = safe / 1_000
            let value = kilometres.formatted(.number.precision(.fractionLength(kilometres < 10 ? 2 : 1)))
            return String(localized: "\(value) km")
        }

        let feet = safe * 3.280_839_895
        // Below about a tenth of a mile, miles stop being a useful unit.
        if feet < 528 {
            let value = Int(feet.rounded()).formatted()
            return String(localized: "\(value) ft")
        }
        let miles = safe / 1_609.344
        let value = miles.formatted(.number.precision(.fractionLength(miles < 10 ? 2 : 1)))
        return String(localized: "\(value) mi")
    }

    // MARK: - Duration

    /// A running clock for the walk in progress, such as 12:04 or 1:12:04.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        let duration = Duration.seconds(seconds)
        return seconds >= 3_600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// A spelled-out duration for history rows, such as "1 hr 5 min".
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds) ?? clock(seconds)
    }

    // MARK: - Percentages

    /// Formats a 0...100 completion percentage.
    ///
    /// - Parameter startedButBelowResolution: true when the user has walked
    ///   something but the floored percentage rounds to zero. Showing a flat
    ///   "0%" after a real walk reads as a bug, and rounding it up would be a
    ///   lie, so it becomes "less than 0.1%".
    static func percentage(_ percent: Double, startedButBelowResolution: Bool = false) -> String {
        if startedButBelowResolution && percent <= 0 {
            let floorValue = (0.001).formatted(.percent.precision(.fractionLength(1)))
            return String(localized: "less than \(floorValue)")
        }
        let fraction = min(1, max(0, percent / 100))
        return fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    /// A whole-number percentage for compact places such as list rows.
    static func compactPercentage(fraction: Double) -> String {
        min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Counts and sizes

    static func blocks(completed: Int, total: Int) -> String {
        let done = completed.formatted()
        let all = total.formatted()
        return String(localized: "\(done) of \(all) blocks")
    }

    static func downloadSize(bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    static func segmentCount(_ count: Int) -> String {
        let value = count.formatted()
        return String(localized: "\(value) blocks")
    }

    // MARK: - Dates

    static func sessionDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
