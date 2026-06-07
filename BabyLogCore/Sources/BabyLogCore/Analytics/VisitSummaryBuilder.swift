import Foundation

/// Assembles a `VisitSummary` from already-fetched domain records. Pure and
/// synchronous so it runs in sub-millisecond Linux tests; the app layer does
/// the async repository fetches and passes the arrays in.
public struct VisitSummaryBuilder {

    public init() {}

    /// Build a summary over the window ending at `now`. The window *starts* at
    /// the most recent past appointment (so the summary covers "since the last
    /// visit"); when there's no past appointment it falls back to the last
    /// `defaultWindowDays` days.
    public func build(
        profile: ChildProfile?,
        feeds: [FeedLog],
        diapers: [DiaperLog],
        growth: [GrowthMeasurement],
        pumping: [PumpingSession],
        milestones: [Milestone],
        appointments: [MedicalAppointment],
        now: Date,
        defaultWindowDays: Int = 14,
        calendar: Calendar = .current
    ) -> VisitSummary {
        let until = now
        let pastAppointments = appointments
            .filter { $0.scheduledAt <= now }
            .sorted { $0.scheduledAt > $1.scheduledAt }
        let since = pastAppointments.first?.scheduledAt
            ?? calendar.date(byAdding: .day, value: -defaultWindowDays, to: now)
            ?? now
        let nextAppointment = appointments
            .filter { $0.scheduledAt > now }
            .min { $0.scheduledAt < $1.scheduledAt }
            .map { VisitSummary.AppointmentRef(title: $0.title, date: $0.scheduledAt) }

        let spanDays = (calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: since),
            to: calendar.startOfDay(for: until)
        ).day ?? 0) + 1
        let days = max(spanDays, 1)

        func inWindow(_ date: Date) -> Bool { date >= since && date <= until }

        // Feeds
        let windowFeeds = feeds.filter { inWindow($0.loggedAt) }
        let feedTotal = windowFeeds.reduce(0) { $0 + $1.volumeMl }
        let nightFeeds = windowFeeds.filter {
            FeedLogAnalytics.isNightHour(calendar.component(.hour, from: $0.loggedAt))
        }.count
        let feedsSection = VisitSummary.FeedsSection(
            count: windowFeeds.count,
            totalMl: feedTotal,
            avgMlPerDay: Int((Double(feedTotal) / Double(days)).rounded()),
            feedsPerDay: Double(windowFeeds.count) / Double(days),
            nightFeeds: nightFeeds,
            avgIntervalSeconds: FeedLogAnalytics.averageInterval(windowFeeds)
        )

        // Diapers
        let windowDiapers = diapers.filter { inWindow($0.loggedAt) }
        let byType: [VisitSummary.DiaperCount] = DiaperType.allCases.compactMap { type in
            let n = windowDiapers.filter { $0.type == type }.count
            return n > 0 ? VisitSummary.DiaperCount(label: type.rawValue, count: n) : nil
        }
        let diapersSection = VisitSummary.DiapersSection(
            count: windowDiapers.count,
            avgPerDay: Double(windowDiapers.count) / Double(days),
            byType: byType
        )

        // Growth — latest value per field across all history; delta within window.
        let latestWeight = growth.filter { $0.weightGrams != nil }
            .max { $0.date < $1.date }?.weightGrams
        let latestHeight = growth.filter { $0.heightCm != nil }
            .max { $0.date < $1.date }?.heightCm
        let latestHead = growth.filter { $0.headCircumferenceCm != nil }
            .max { $0.date < $1.date }?.headCircumferenceCm
        let windowWeights = growth
            .filter { inWindow($0.date) && $0.weightGrams != nil }
            .sorted { $0.date < $1.date }
        let weightDelta: Int?
        if windowWeights.count >= 2,
           let first = windowWeights.first?.weightGrams,
           let last = windowWeights.last?.weightGrams {
            weightDelta = last - first
        } else {
            weightDelta = nil
        }
        let growthSection = VisitSummary.GrowthSection(
            latestWeightGrams: latestWeight,
            latestHeightCm: latestHeight,
            latestHeadCm: latestHead,
            weightDeltaGrams: weightDelta
        )

        // Pumping
        let windowPumping = pumping.filter { inWindow($0.startedAt) }
        let pumpingSection = VisitSummary.PumpingSection(
            count: windowPumping.count,
            totalMl: windowPumping.reduce(0) { $0 + ($1.milkVolumeMl ?? 0) }
        )

        // Milestones
        let windowMilestones = milestones
            .filter { inWindow($0.achievedAt) }
            .sorted { $0.achievedAt < $1.achievedAt }
            .map { VisitSummary.MilestoneRef(title: $0.title, date: $0.achievedAt) }

        let ageLabel = profile.map {
            ChildAge.shortLabel(dateOfBirth: $0.dateOfBirth, now: until, calendar: calendar)
        } ?? ""

        return VisitSummary(
            childName: profile?.name ?? "Baby",
            ageLabel: ageLabel,
            since: since,
            until: until,
            dayCount: days,
            nextAppointment: nextAppointment,
            feeds: feedsSection,
            diapers: diapersSection,
            growth: growthSection,
            pumping: pumpingSection,
            milestones: windowMilestones
        )
    }
}
