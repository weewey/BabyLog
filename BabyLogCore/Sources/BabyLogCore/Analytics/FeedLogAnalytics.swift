import Foundation

public enum FeedLogAnalytics {

    public struct DailyTotal: Equatable, Sendable {
        public let volumeMl: Int
        public let count: Int

        public init(volumeMl: Int, count: Int) {
            self.volumeMl = volumeMl
            self.count = count
        }
    }

    /// Seconds since the most recent feed, or nil if there are none.
    public static func timeSinceLast(_ feeds: [FeedLog], now: Date) -> TimeInterval? {
        guard let latest = feeds.map(\.loggedAt).max() else { return nil }
        return now.timeIntervalSince(latest)
    }

    /// Gaps (in seconds) between consecutive feeds, sorted chronologically.
    /// Returns an empty array for fewer than two feeds.
    public static func intervalsBetween(_ feeds: [FeedLog]) -> [TimeInterval] {
        let sorted = feeds.sorted { $0.loggedAt < $1.loggedAt }
        guard sorted.count >= 2 else { return [] }
        return zip(sorted, sorted.dropFirst()).map { $1.loggedAt.timeIntervalSince($0.loggedAt) }
    }

    /// Mean gap between feeds in seconds, or nil if fewer than two feeds.
    public static func averageInterval(_ feeds: [FeedLog]) -> TimeInterval? {
        let gaps = intervalsBetween(feeds)
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    public struct DailyVolume: Equatable, Sendable {
        public let date: Date
        public let volumeMl: Int
        public let count: Int

        public init(date: Date, volumeMl: Int, count: Int) {
            self.date = date
            self.volumeMl = volumeMl
            self.count = count
        }
    }

    /// Returns one bucket per day for the `days`-day window ending on the calendar day
    /// containing `endingOn`, in ascending chronological order. Empty days produce
    /// zero-valued buckets; feeds outside the window are ignored.
    public static func dailyVolumes(
        _ feeds: [FeedLog],
        endingOn: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [DailyVolume] {
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

        var totals: [Date: (volume: Int, count: Int)] = [:]
        for feed in feeds {
            let dayStart = calendar.startOfDay(for: feed.loggedAt)
            guard dayStart >= windowStart, dayStart <= endStart else { continue }
            let current = totals[dayStart] ?? (0, 0)
            totals[dayStart] = (current.volume + feed.volumeMl, current.count + 1)
        }

        return dayStarts.map { start in
            let entry = totals[start] ?? (0, 0)
            return DailyVolume(date: start, volumeMl: entry.volume, count: entry.count)
        }
    }

    /// 7×24 grid of feed counts bucketed by weekday (rows) and hour-of-day (columns).
    public static func clusterHeatmap(
        feeds: [FeedLog],
        range: Range<Date>,
        calendar: Calendar
    ) -> [[Int]] {
        var grid: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let firstWeekday = calendar.firstWeekday
        for feed in feeds {
            let t = feed.loggedAt
            guard range.contains(t) else { continue }
            let comps = calendar.dateComponents([.weekday, .hour], from: t)
            guard let weekday = comps.weekday, let hour = comps.hour else { continue }
            let row = ((weekday - firstWeekday) % 7 + 7) % 7
            guard (0..<24).contains(hour) else { continue }
            grid[row][hour] += 1
        }
        return grid
    }

    /// Filters feeds to those matching the given weekday-row/hour bucket.
    public static func feedsInBucket(
        _ feeds: [FeedLog],
        row: Int,
        hour: Int,
        calendar: Calendar
    ) -> [FeedLog] {
        let firstWeekday = calendar.firstWeekday
        return feeds.filter { feed in
            let comps = calendar.dateComponents([.weekday, .hour], from: feed.loggedAt)
            guard let weekday = comps.weekday, let feedHour = comps.hour else { return false }
            let feedRow = ((weekday - firstWeekday) % 7 + 7) % 7
            return feedRow == row && feedHour == hour
        }
    }

    public static func totalFor(
        _ feeds: [FeedLog],
        on day: Date,
        calendar: Calendar = .current
    ) -> DailyTotal {
        let startOfDay = calendar.startOfDay(for: day)
        let feedsOnDay = feeds.filter {
            calendar.startOfDay(for: $0.loggedAt) == startOfDay
        }
        let total = feedsOnDay.reduce(0) { $0 + $1.volumeMl }
        return DailyTotal(volumeMl: total, count: feedsOnDay.count)
    }

    // MARK: - Pump milk percentage

    /// Percentage of feed volume that came from pumping.
    /// Returns 0 when feedVolumeMl is zero. Result is clamped to 0...100.
    public static func pumpMilkPercentage(feedVolumeMl: Int, pumpVolumeMl: Int) -> Int {
        guard feedVolumeMl > 0 else { return 0 }
        return min(100, (pumpVolumeMl * 100) / feedVolumeMl)
    }

    /// Daily pump volumes keyed by start-of-day, mirroring `dailyVolumes`
    /// window logic. Returns a dictionary for O(1) lookup per day.
    public static func dailyPumpVolumes(
        _ sessions: [PumpingSession],
        endingOn: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [Date: Int] {
        guard days > 0 else { return [:] }
        let endStart = calendar.startOfDay(for: endingOn)
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: endStart)
        else { return [:] }

        var totals: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            guard day >= windowStart, day <= endStart else { continue }
            totals[day, default: 0] += session.milkVolumeMl ?? 0
        }
        return totals
    }

    // MARK: - Night vs Day

    /// Night window 22:00–06:59 (local), day 07:00–21:59.
    public static func isNightHour(_ hour: Int) -> Bool {
        hour >= 22 || hour < 7
    }

    public struct NightDaySplit: Equatable, Sendable {
        public let night: DailyTotal
        public let day: DailyTotal
        public init(night: DailyTotal, day: DailyTotal) {
            self.night = night
            self.day = day
        }
    }

    public static func nightDaySplit(
        feeds: [FeedLog],
        on day: Date,
        calendar: Calendar = .current
    ) -> NightDaySplit {
        let start = calendar.startOfDay(for: day)
        var nightVol = 0, nightCount = 0, dayVol = 0, dayCount = 0
        for feed in feeds {
            guard calendar.startOfDay(for: feed.loggedAt) == start else { continue }
            let hour = calendar.component(.hour, from: feed.loggedAt)
            if isNightHour(hour) {
                nightVol += feed.volumeMl
                nightCount += 1
            } else {
                dayVol += feed.volumeMl
                dayCount += 1
            }
        }
        return NightDaySplit(
            night: DailyTotal(volumeMl: nightVol, count: nightCount),
            day: DailyTotal(volumeMl: dayVol, count: dayCount)
        )
    }

    /// Night cluster = ≥3 night feeds on `day` with median gap ≤ 90 minutes.
    public static func detectNightCluster(
        feeds: [FeedLog],
        on day: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let start = calendar.startOfDay(for: day)
        let nightFeeds = feeds
            .filter {
                calendar.startOfDay(for: $0.loggedAt) == start
                    && isNightHour(calendar.component(.hour, from: $0.loggedAt))
            }
            .sorted { $0.loggedAt < $1.loggedAt }
        guard nightFeeds.count >= 3 else { return false }
        let gaps = zip(nightFeeds, nightFeeds.dropFirst())
            .map { $1.loggedAt.timeIntervalSince($0.loggedAt) }
            .sorted()
        let mid = gaps.count / 2
        let median: TimeInterval = gaps.count.isMultiple(of: 2)
            ? (gaps[mid - 1] + gaps[mid]) / 2
            : gaps[mid]
        return median <= 90 * 60
    }

    // MARK: - Hourly heatmap + peak hours (rolling window)

    /// Length-24 array of feed counts bucketed by hour-of-day over a
    /// rolling `days`-day window ending on the calendar day of `endingOn`.
    public static func hourlyHeatmap(
        feeds: [FeedLog],
        endingOn: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        var grid = Array(repeating: 0, count: 24)
        guard days > 0 else { return grid }
        let endStart = calendar.startOfDay(for: endingOn)
        guard
            let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: endStart),
            let windowEnd = calendar.date(byAdding: .day, value: 1, to: endStart)
        else { return grid }
        for feed in feeds {
            guard feed.loggedAt >= windowStart, feed.loggedAt < windowEnd else { continue }
            let hour = calendar.component(.hour, from: feed.loggedAt)
            guard (0..<24).contains(hour) else { continue }
            grid[hour] += 1
        }
        return grid
    }

    public struct PeakHour: Equatable, Sendable {
        public let hour: Int
        public let count: Int
        public init(hour: Int, count: Int) {
            self.hour = hour
            self.count = count
        }
    }

    public static func peakHours(
        feeds: [FeedLog],
        endingOn: Date,
        days: Int,
        limit: Int,
        calendar: Calendar = .current
    ) -> [PeakHour] {
        let grid = hourlyHeatmap(
            feeds: feeds,
            endingOn: endingOn,
            days: days,
            calendar: calendar
        )
        let pairs = grid.enumerated()
            .filter { $0.element > 0 }
            .map { PeakHour(hour: $0.offset, count: $0.element) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.hour < $1.hour
            }
        return Array(pairs.prefix(max(0, limit)))
    }

    // MARK: - Longest stretch

    public static func longestStretch(
        feeds: [FeedLog],
        on day: Date,
        calendar: Calendar = .current
    ) -> TimeInterval? {
        let start = calendar.startOfDay(for: day)
        let sorted = feeds
            .filter { calendar.startOfDay(for: $0.loggedAt) == start }
            .sorted { $0.loggedAt < $1.loggedAt }
        guard sorted.count >= 2 else { return nil }
        return zip(sorted, sorted.dropFirst())
            .map { $1.loggedAt.timeIntervalSince($0.loggedAt) }
            .max()
    }
}
