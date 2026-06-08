import Foundation

/// A deterministic, point-in-time digest of everything BabyLog recorded over a
/// window — built for the "prep for the pediatrician visit" flow. All figures
/// are computed from logged data (`VisitSummaryBuilder`); the on-device LLM
/// only ever *narrates* this struct, it never invents the numbers.
public struct VisitSummary: Equatable, Sendable {

    public let childName: String
    /// Compact age label (e.g. "8w 3d") at the end of the window, or "" when
    /// no profile is available.
    public let ageLabel: String
    public let since: Date
    public let until: Date
    /// Inclusive calendar-day span of the window (always ≥ 1).
    public let dayCount: Int
    public let nextAppointment: AppointmentRef?
    public let feeds: FeedsSection
    public let diapers: DiapersSection
    public let growth: GrowthSection
    public let pumping: PumpingSection
    public let milestones: [MilestoneRef]

    public init(
        childName: String,
        ageLabel: String,
        since: Date,
        until: Date,
        dayCount: Int,
        nextAppointment: AppointmentRef?,
        feeds: FeedsSection,
        diapers: DiapersSection,
        growth: GrowthSection,
        pumping: PumpingSection,
        milestones: [MilestoneRef]
    ) {
        self.childName = childName
        self.ageLabel = ageLabel
        self.since = since
        self.until = until
        self.dayCount = dayCount
        self.nextAppointment = nextAppointment
        self.feeds = feeds
        self.diapers = diapers
        self.growth = growth
        self.pumping = pumping
        self.milestones = milestones
    }

    public struct AppointmentRef: Equatable, Sendable {
        public let title: String
        public let date: Date
        public init(title: String, date: Date) {
            self.title = title
            self.date = date
        }
    }

    public struct FeedsSection: Equatable, Sendable {
        public let count: Int
        public let totalMl: Int
        public let avgMlPerDay: Int
        public let feedsPerDay: Double
        public let nightFeeds: Int
        public let avgIntervalSeconds: Double?
        public init(count: Int, totalMl: Int, avgMlPerDay: Int, feedsPerDay: Double, nightFeeds: Int, avgIntervalSeconds: Double?) {
            self.count = count
            self.totalMl = totalMl
            self.avgMlPerDay = avgMlPerDay
            self.feedsPerDay = feedsPerDay
            self.nightFeeds = nightFeeds
            self.avgIntervalSeconds = avgIntervalSeconds
        }
    }

    public struct DiaperCount: Equatable, Sendable {
        public let label: String
        public let count: Int
        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    public struct DiapersSection: Equatable, Sendable {
        public let count: Int
        public let avgPerDay: Double
        /// Per-type counts, in `DiaperType` order, with zero-count types omitted.
        public let byType: [DiaperCount]
        public init(count: Int, avgPerDay: Double, byType: [DiaperCount]) {
            self.count = count
            self.avgPerDay = avgPerDay
            self.byType = byType
        }
    }

    public struct GrowthSection: Equatable, Sendable {
        public let latestWeightGrams: Int?
        public let latestHeightCm: Double?
        public let latestHeadCm: Double?
        /// Weight change across the window (latest minus earliest in-window
        /// weight), or `nil` when fewer than two in-window weights exist.
        public let weightDeltaGrams: Int?
        public init(latestWeightGrams: Int?, latestHeightCm: Double?, latestHeadCm: Double?, weightDeltaGrams: Int?) {
            self.latestWeightGrams = latestWeightGrams
            self.latestHeightCm = latestHeightCm
            self.latestHeadCm = latestHeadCm
            self.weightDeltaGrams = weightDeltaGrams
        }
    }

    public struct PumpingSection: Equatable, Sendable {
        public let count: Int
        public let totalMl: Int
        public init(count: Int, totalMl: Int) {
            self.count = count
            self.totalMl = totalMl
        }
    }

    public struct MilestoneRef: Equatable, Sendable {
        public let title: String
        public let date: Date
        public init(title: String, date: Date) {
            self.title = title
            self.date = date
        }
    }
}

// MARK: - Plain-text rendering (share payload + LLM-failure fallback)

extension VisitSummary {

    /// A human-readable summary suitable for the share sheet and as the
    /// fallback when LLM narration is unavailable.
    public func plainText(calendar: Calendar = .current) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.locale = Locale.current
        df.dateStyle = .medium
        df.timeStyle = .none

        var lines: [String] = []
        lines.append("\(childName) — visit summary")

        var header = "Period: \(df.string(from: since)) – \(df.string(from: until)) (\(dayCount) day\(dayCount == 1 ? "" : "s"))"
        if !ageLabel.isEmpty { header = "Age \(ageLabel) • " + header }
        lines.append(header)

        if let next = nextAppointment {
            lines.append("Next appointment: \(next.title), \(df.string(from: next.date))")
        }
        lines.append("")

        // Feeds
        lines.append("FEEDS")
        if feeds.count == 0 {
            lines.append("• None logged this period")
        } else {
            lines.append("• \(feeds.count) feeds • avg \(feeds.avgMlPerDay) ml/day across \(Self.oneDecimal(feeds.feedsPerDay)) feeds/day")
            var l2 = "• \(feeds.nightFeeds) night feeds"
            if let iv = feeds.avgIntervalSeconds { l2 += " • avg \(Self.duration(iv)) between feeds" }
            lines.append(l2)
        }
        lines.append("")

        // Diapers
        lines.append("DIAPERS")
        if diapers.count == 0 {
            lines.append("• None logged this period")
        } else {
            let breakdown = diapers.byType.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
            lines.append("• \(diapers.count) changes • avg \(Self.oneDecimal(diapers.avgPerDay))/day (\(breakdown))")
        }
        lines.append("")

        // Growth
        lines.append("GROWTH")
        if growth.latestWeightGrams == nil && growth.latestHeightCm == nil && growth.latestHeadCm == nil {
            lines.append("• None logged")
        } else {
            if let w = growth.latestWeightGrams {
                var wl = "• Weight \(Self.kilograms(w))"
                if let d = growth.weightDeltaGrams { wl += " (\(d >= 0 ? "+" : "")\(d) g this period)" }
                lines.append(wl)
            }
            var measures: [String] = []
            if let h = growth.latestHeightCm { measures.append("Height \(Self.oneDecimal(h)) cm") }
            if let hc = growth.latestHeadCm { measures.append("Head \(Self.oneDecimal(hc)) cm") }
            if !measures.isEmpty { lines.append("• " + measures.joined(separator: " • ")) }
        }
        lines.append("")

        // Pumping (only when used)
        if pumping.count > 0 {
            lines.append("PUMPING")
            lines.append("• \(pumping.count) sessions • \(pumping.totalMl) ml total")
            lines.append("")
        }

        // Milestones
        lines.append("MILESTONES")
        if milestones.isEmpty {
            lines.append("• None this period")
        } else {
            for m in milestones { lines.append("• \(m.title) — \(df.string(from: m.date))") }
        }
        lines.append("")

        lines.append("Logged in BabyLog. Figures reflect what was recorded, not medical advice.")
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    static func kilograms(_ grams: Int) -> String {
        String(format: "%.2f kg", Double(grams) / 1000.0)
    }

    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - LLM narration

extension VisitSummary {

    /// Prompt for the on-device model to turn this digest into a few warm,
    /// plain-language sentences. The model is told explicitly to use only the
    /// numbers given (never invent figures) and to avoid medical judgments —
    /// the deterministic `plainText` remains the source of truth and the
    /// fallback when narration is unavailable.
    public func narrationPrompt(calendar: Calendar = .current) -> String {
        """
        You are helping a parent get ready for their baby's pediatrician visit. \
        Below is a factual summary of what they logged this period. Write 2 to 4 \
        warm, plain-language sentences they could read aloud to the doctor or skim \
        themselves — cover the trends that stand out (feeding, diapers, growth, \
        sleep stretches, milestones). Use ONLY the numbers given; never invent or \
        change a figure. Do not give medical advice or say whether values are \
        healthy. No bullet points or headings — just a short paragraph.

        \(plainText(calendar: calendar))
        """
    }
}
