import Foundation

/// Pure analytics functions for diaper-change data.
///
/// Every function is a pure transformation: it takes values in and returns
/// values out, with no I/O or global state.
public enum DiaperLogAnalytics {

    /// Groups an array of `DiaperLog` entries by calendar day.
    ///
    /// - Parameters:
    ///   - logs:     Entries to group (any input order).
    ///   - calendar: Calendar used to compute `startOfDay` boundaries.
    ///               Pass a fixed `Calendar` with a known `timeZone` in tests.
    /// - Returns:    `[(startOfDay, entries)]` pairs, newest group first.
    ///               Entries within each group are also ordered newest first.
    public static func groupByDay(
        _ logs: [DiaperLog],
        calendar: Calendar
    ) -> [(Date, [DiaperLog])] {

        // Sort all entries newest-first; insertion order then preserves the
        // invariant inside each group without a second pass.
        let sorted = logs.sorted { $0.loggedAt > $1.loggedAt }

        var indexForDay: [Date: Int] = [:]
        var groups: [(Date, [DiaperLog])] = []

        for log in sorted {
            let day = calendar.startOfDay(for: log.loggedAt)
            if let idx = indexForDay[day] {
                groups[idx].1.append(log)
            } else {
                indexForDay[day] = groups.count
                groups.append((day, [log]))
            }
        }

        return groups
    }

    public struct DailyCounts: Equatable, Sendable {
        public let wet: Int
        public let dirty: Int
        public let both: Int

        public var total: Int { wet + dirty + both }

        public init(wet: Int, dirty: Int, both: Int) {
            self.wet = wet
            self.dirty = dirty
            self.both = both
        }
    }

    public struct DailyCountsPoint: Equatable, Sendable {
        public let date: Date
        public let wet: Int
        public let dirty: Int
        public let both: Int

        public init(date: Date, wet: Int, dirty: Int, both: Int) {
            self.date = date
            self.wet = wet
            self.dirty = dirty
            self.both = both
        }
    }

    /// Returns one bucket per day for the `days`-day window ending on the
    /// calendar day containing `endingOn`, in ascending chronological order.
    /// Empty days produce zero-valued buckets; logs outside the window are
    /// ignored. `days <= 0` returns an empty array.
    public static func dailyCounts(
        _ logs: [DiaperLog],
        endingOn: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [DailyCountsPoint] {
        guard days > 0 else { return [] }
        let endStart = calendar.startOfDay(for: endingOn)
        var dayStarts: [Date] = []
        dayStarts.reserveCapacity(days)
        for offset in (0..<days).reversed() {
            if let d = calendar.date(byAdding: .day, value: -offset, to: endStart) {
                dayStarts.append(calendar.startOfDay(for: d))
            }
        }
        guard let windowStart = dayStarts.first else { return [] }

        var totals: [Date: (wet: Int, dirty: Int, both: Int)] = [:]
        for log in logs {
            let dayStart = calendar.startOfDay(for: log.loggedAt)
            guard dayStart >= windowStart, dayStart <= endStart else { continue }
            var current = totals[dayStart] ?? (0, 0, 0)
            switch log.type {
            case .wet: current.wet += 1
            case .dirty: current.dirty += 1
            case .both: current.both += 1
            }
            totals[dayStart] = current
        }

        return dayStarts.map { start in
            let entry = totals[start] ?? (0, 0, 0)
            return DailyCountsPoint(
                date: start,
                wet: entry.wet,
                dirty: entry.dirty,
                both: entry.both
            )
        }
    }

    public static func countsFor(
        _ logs: [DiaperLog],
        on day: Date,
        calendar: Calendar = .current
    ) -> DailyCounts {
        let startOfDay = calendar.startOfDay(for: day)
        let onDay = logs.filter {
            calendar.startOfDay(for: $0.loggedAt) == startOfDay
        }
        var wet = 0, dirty = 0, both = 0
        for log in onDay {
            switch log.type {
            case .wet: wet += 1
            case .dirty: dirty += 1
            case .both: both += 1
            }
        }
        return DailyCounts(wet: wet, dirty: dirty, both: both)
    }
}
