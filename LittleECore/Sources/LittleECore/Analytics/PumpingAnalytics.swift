import Foundation

public struct PumpingAnalytics: Sendable, Equatable {
    public let sessionsLoggedToday: Int
    public let targetSessionsPerDay: Int
    public let averageDurationMinutes: Double
    public let totalMinutesToday: Int
    public let totalVolumeMlToday: Int
    public let completionRatio: Double
    public let nextRecommendedSlot: PumpingScheduleSlot?
    public let overnightGapHours: Double

    public init(
        sessionsLoggedToday: Int,
        targetSessionsPerDay: Int,
        averageDurationMinutes: Double,
        totalMinutesToday: Int,
        totalVolumeMlToday: Int,
        completionRatio: Double,
        nextRecommendedSlot: PumpingScheduleSlot?,
        overnightGapHours: Double
    ) {
        self.sessionsLoggedToday = sessionsLoggedToday
        self.targetSessionsPerDay = targetSessionsPerDay
        self.averageDurationMinutes = averageDurationMinutes
        self.totalMinutesToday = totalMinutesToday
        self.totalVolumeMlToday = totalVolumeMlToday
        self.completionRatio = completionRatio
        self.nextRecommendedSlot = nextRecommendedSlot
        self.overnightGapHours = overnightGapHours
    }

    public static func summarize(
        sessions: [PumpingSession],
        template: PumpingScheduleTemplate,
        now: Date,
        calendar: Calendar = .current
    ) -> PumpingAnalytics {
        let startOfToday = calendar.startOfDay(for: now)
        let todays = sessions.filter { $0.startedAt >= startOfToday && $0.startedAt <= now }

        let count = todays.count
        let totalMinutes = todays.reduce(0) { $0 + $1.durationMinutes }
        let totalVolumeMl = todays.reduce(0) { $0 + ($1.milkVolumeMl ?? 0) }
        let avg: Double = count == 0 ? 0 : Double(totalMinutes) / Double(count)
        let target = max(template.targetSessionsPerDay, 1)
        let ratio = min(Double(count) / Double(target), 1.0)

        // Next recommended slot: first slot whose start minute-of-day > now's
        // minute-of-day AND no session falls within ±30min of the slot start.
        let nowComps = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinuteOfDay = (nowComps.hour ?? 0) * 60 + (nowComps.minute ?? 0)

        let nextSlot: PumpingScheduleSlot? = template.slots.first { slot in
            guard slot.startMinuteOfDay > nowMinuteOfDay else { return false }
            return !sessionWithin30Min(of: slot, on: startOfToday, sessions: todays, calendar: calendar)
        }

        let overnightGap = overnightGapHours(
            sessions: sessions,
            template: template,
            now: now,
            calendar: calendar
        )

        return PumpingAnalytics(
            sessionsLoggedToday: count,
            targetSessionsPerDay: template.targetSessionsPerDay,
            averageDurationMinutes: avg,
            totalMinutesToday: totalMinutes,
            totalVolumeMlToday: totalVolumeMl,
            completionRatio: ratio,
            nextRecommendedSlot: nextSlot,
            overnightGapHours: overnightGap
        )
    }

    private static func sessionWithin30Min(
        of slot: PumpingScheduleSlot,
        on startOfDay: Date,
        sessions: [PumpingSession],
        calendar: Calendar
    ) -> Bool {
        guard let slotDate = calendar.date(
            byAdding: .minute,
            value: slot.startMinuteOfDay,
            to: startOfDay
        ) else { return false }
        for session in sessions {
            let delta = abs(session.startedAt.timeIntervalSince(slotDate))
            if delta <= 30 * 60 { return true }
        }
        return false
    }

    private static func overnightGapHours(
        sessions: [PumpingSession],
        template: PumpingScheduleTemplate,
        now: Date,
        calendar: Calendar
    ) -> Double {
        let startOfToday = calendar.startOfDay(for: now)
        guard let sixAM = calendar.date(byAdding: .hour, value: 6, to: startOfToday) else {
            return templateOvernightGapHours(template)
        }

        let beforeSix = sessions
            .filter { $0.startedAt < sixAM }
            .sorted { $0.startedAt < $1.startedAt }
            .last
        let afterSix = sessions
            .filter { $0.startedAt >= sixAM && $0.startedAt <= now }
            .sorted { $0.startedAt < $1.startedAt }
            .first

        if let beforeSix, let afterSix {
            return afterSix.startedAt.timeIntervalSince(beforeSix.startedAt) / 3600
        }
        return templateOvernightGapHours(template)
    }

    private static func templateOvernightGapHours(_ template: PumpingScheduleTemplate) -> Double {
        let pre = template.slots.first { $0.id == "pre-sleep" }
        let morning = template.slots.first { $0.id == "morning-rise" }
        guard let pre, let morning else { return 0 }
        let preMin = pre.startMinuteOfDay
        let morningMin = morning.startMinuteOfDay
        // pre-sleep is in the evening; morning-rise is next day.
        let minutes = (24 * 60 - preMin) + morningMin
        return Double(minutes) / 60.0
    }

    // MARK: - History grouping + trend series

    public static func dailyHistory(
        sessions: [PumpingSession],
        now: Date,
        calendar: Calendar = .current
    ) -> [DailyPumpingSummary] {
        let startOfToday = calendar.startOfDay(for: now)
        let eligible = sessions.filter { $0.startedAt <= now }

        var bucket: [Date: [PumpingSession]] = [:]
        for s in eligible {
            let day = calendar.startOfDay(for: s.startedAt)
            // Skip anything that somehow lives in the future.
            if day > startOfToday { continue }
            bucket[day, default: []].append(s)
        }

        return bucket
            .map { (day, daySessions) in
                let sorted = daySessions.sorted { $0.startedAt > $1.startedAt }
                let totalVol = sorted.reduce(0) { $0 + ($1.milkVolumeMl ?? 0) }
                let totalMin = sorted.reduce(0) { $0 + $1.durationMinutes }
                return DailyPumpingSummary(
                    day: day,
                    sessions: sorted,
                    totalVolumeMl: totalVol,
                    totalMinutes: totalMin
                )
            }
            .sorted { $0.day > $1.day }
    }

    public static func dailyVolumeSeries(
        sessions: [PumpingSession],
        days: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [DailyVolumePoint] {
        let n = max(days, 0)
        guard n > 0 else { return [] }

        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(n - 1), to: today)
        else { return [] }

        var totals: [Date: Int] = [:]
        for s in sessions {
            let day = calendar.startOfDay(for: s.startedAt)
            if day < windowStart || day > today { continue }
            totals[day, default: 0] += s.milkVolumeMl ?? 0
        }

        var out: [DailyVolumePoint] = []
        out.reserveCapacity(n)
        for offset in 0..<n {
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart)
            else { continue }
            out.append(DailyVolumePoint(day: day, totalVolumeMl: totals[day] ?? 0))
        }
        return out
    }
}

// MARK: - Value types

public struct DailyPumpingSummary: Sendable, Equatable {
    public let day: Date
    public let sessions: [PumpingSession]
    public let totalVolumeMl: Int
    public let totalMinutes: Int

    public init(day: Date, sessions: [PumpingSession], totalVolumeMl: Int, totalMinutes: Int) {
        self.day = day
        self.sessions = sessions
        self.totalVolumeMl = totalVolumeMl
        self.totalMinutes = totalMinutes
    }
}

public struct DailyVolumePoint: Sendable, Equatable {
    public let day: Date
    public let totalVolumeMl: Int

    public init(day: Date, totalVolumeMl: Int) {
        self.day = day
        self.totalVolumeMl = totalVolumeMl
    }
}
