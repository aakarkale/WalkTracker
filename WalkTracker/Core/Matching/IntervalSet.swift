import Foundation

/// A normalised, non-overlapping set of closed intervals within `0...1`.
///
/// This is how partial coverage of a street block is recorded: walking the
/// north half of a block yields `[0.0, 0.5]`, walking the rest later merges
/// into the single interval `[0.0, 1.0]`. Keeping intervals instead of a bare
/// boolean is what makes the reported percentage honest on long blocks.
public struct IntervalSet: Equatable, Codable, Sendable {

    public struct Interval: Equatable, Codable, Sendable, Comparable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            let lo = min(start, end)
            let hi = max(start, end)
            self.start = min(1, max(0, lo))
            self.end = min(1, max(0, hi))
        }

        public var length: Double { end - start }

        public static func < (lhs: Interval, rhs: Interval) -> Bool {
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
    }

    /// Sorted, disjoint, non-touching intervals.
    public private(set) var intervals: [Interval]

    /// Intervals closer together than this (as a fraction) are fused. At a
    /// typical 80 m block this is 8 cm, far below GPS resolution, so it only
    /// removes float noise rather than real gaps.
    private static let epsilon: Double = 1e-3

    public init() {
        self.intervals = []
    }

    public init(intervals: [Interval]) {
        self.intervals = []
        for interval in intervals {
            insert(interval)
        }
    }

    /// Total covered fraction of the parent segment, 0...1.
    public var coverage: Double {
        intervals.reduce(0) { $0 + $1.length }
    }

    public var isEmpty: Bool { intervals.isEmpty }

    public mutating func insert(from: Double, to: Double) {
        insert(Interval(start: from, end: to))
    }

    /// Adds an interval, merging it with any it overlaps or nearly touches.
    public mutating func insert(_ new: Interval) {
        // A zero-length interval is a single GPS fix, not walked distance.
        guard new.length > 0 else { return }

        var merged = new
        var result: [Interval] = []
        result.reserveCapacity(intervals.count + 1)
        var inserted = false

        for existing in intervals {
            if existing.end + Self.epsilon < merged.start {
                // Entirely before the new interval.
                result.append(existing)
            } else if merged.end + Self.epsilon < existing.start {
                // Entirely after: the new interval's final position is known.
                if !inserted {
                    result.append(merged)
                    inserted = true
                }
                result.append(existing)
            } else {
                // Overlapping or touching: absorb.
                merged = Interval(
                    start: min(merged.start, existing.start),
                    end: max(merged.end, existing.end)
                )
            }
        }

        if !inserted {
            result.append(merged)
        }

        result.sort()
        intervals = result
    }

    public mutating func formUnion(_ other: IntervalSet) {
        for interval in other.intervals {
            insert(interval)
        }
    }

    public func union(_ other: IntervalSet) -> IntervalSet {
        var copy = self
        copy.formUnion(other)
        return copy
    }

    /// The complement within `0...1`: the parts still unwalked.
    public var gaps: [Interval] {
        guard !intervals.isEmpty else { return [Interval(start: 0, end: 1)] }
        var result: [Interval] = []
        var cursor: Double = 0
        for interval in intervals {
            if interval.start - cursor > Self.epsilon {
                result.append(Interval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if 1 - cursor > Self.epsilon {
            result.append(Interval(start: cursor, end: 1))
        }
        return result
    }
}

// MARK: - Compact storage

extension IntervalSet {
    /// Encodes to a compact `start:end,start:end` string for SQLite storage.
    /// Chosen over JSON because coverage rows are the hottest table in the
    /// database and this halves their size.
    public var storageString: String {
        intervals
            .map { "\(Self.format($0.start)):\(Self.format($0.end))" }
            .joined(separator: ",")
    }

    public init(storageString: String) {
        let trimmed = storageString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.init()
            return
        }
        var parsed: [Interval] = []
        for pair in trimmed.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2,
                  let start = Double(parts[0]),
                  let end = Double(parts[1]),
                  start.isFinite, end.isFinite else { continue }
            parsed.append(Interval(start: start, end: end))
        }
        self.init(intervals: parsed)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.5f", value)
    }
}
