import Foundation

/// Snapshot the chat empty-state view renders when there are no messages.
/// All derivation is here so the view is a pure projection and the logic
/// is test-covered on Linux.
public struct ChatEmptyStateSummary: Sendable, Equatable {

    public struct LastFeed: Sendable, Equatable {
        public let volumeMl: Int
        public let loggedAt: Date
    }

    public let lastFeed: LastFeed?
    public let todayFeedCount: Int
    public let todayFeedVolumeMl: Int
    public let todayDiaperCount: Int
    /// `true` when the last feed is ≥ 4h old — the empty-state card tints
    /// amber to gently nudge the parent. 4h matches the typical upper
    /// bound between newborn feeds; beyond that the app earns its keep.
    public let isLastFeedStale: Bool
    /// Context-aware chip list, already ordered for display.
    public let suggestions: [ChatSuggestion]
    /// ml logged per hour of today (24 elements, index = hour 0–23).
    public let todayFeedsByHour: [Int]

    public static let staleFeedThreshold: TimeInterval = 4 * 3600

    public init(
        lastFeed: LastFeed?,
        todayFeedCount: Int,
        todayFeedVolumeMl: Int,
        todayDiaperCount: Int,
        isLastFeedStale: Bool,
        suggestions: [ChatSuggestion],
        todayFeedsByHour: [Int] = Array(repeating: 0, count: 24)
    ) {
        self.lastFeed = lastFeed
        self.todayFeedCount = todayFeedCount
        self.todayFeedVolumeMl = todayFeedVolumeMl
        self.todayDiaperCount = todayDiaperCount
        self.isLastFeedStale = isLastFeedStale
        self.suggestions = suggestions
        self.todayFeedsByHour = todayFeedsByHour.count == 24 ? todayFeedsByHour : Array(repeating: 0, count: 24)
    }

    public static func summarize(
        feeds: [FeedLog],
        diapers: [DiaperLog],
        now: Date,
        calendar: Calendar = .current,
        diapersEnabled: Bool = true
    ) -> Self {
        let startOfToday = calendar.startOfDay(for: now)
        let todayFeeds = feeds.filter { $0.loggedAt >= startOfToday && $0.loggedAt <= now }
        let todayDiapers = diapers.filter { $0.loggedAt >= startOfToday && $0.loggedAt <= now }

        let sortedFeeds = feeds.sorted { $0.loggedAt > $1.loggedAt }
        let last = sortedFeeds.first.map {
            LastFeed(volumeMl: $0.volumeMl, loggedAt: $0.loggedAt)
        }

        let todayVolume = todayFeeds.reduce(0) { $0 + $1.volumeMl }
        var hourly = Array(repeating: 0, count: 24)
        for feed in todayFeeds {
            let h = calendar.component(.hour, from: feed.loggedAt)
            if (0..<24).contains(h) { hourly[h] += feed.volumeMl }
        }
        let stale = last.map { now.timeIntervalSince($0.loggedAt) >= staleFeedThreshold } ?? false
        let suggestions = defaultSuggestions(
            now: now,
            calendar: calendar,
            todayFeedCount: todayFeeds.count,
            lastFeed: last,
            diapersEnabled: diapersEnabled
        )
        return Self(
            lastFeed: last,
            todayFeedCount: todayFeeds.count,
            todayFeedVolumeMl: todayVolume,
            todayDiaperCount: diapersEnabled ? todayDiapers.count : 0,
            isLastFeedStale: stale,
            suggestions: suggestions,
            todayFeedsByHour: hourly
        )
    }

    /// Build the four-chip strip the empty state shows. Three static
    /// write-intent chips are always present so parents can one-tap the
    /// common logs; the trailing auto-send chip varies with the clock and
    /// what's already been logged today.
    public static func defaultSuggestions(
        now: Date,
        calendar: Calendar,
        todayFeedCount: Int,
        lastFeed: LastFeed?,
        diapersEnabled: Bool = true
    ) -> [ChatSuggestion] {
        _ = calendar
        _ = lastFeed
        _ = todayFeedCount

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = .current
        let at = timeFmt.string(from: now)

        var chips: [ChatSuggestion] = [
            .init(text: "60 ml feed at \(at)", slug: "feed60", autoSend: false),
            .init(text: "20 min pump at \(at)", slug: "pump20", autoSend: false),
        ]
        if diapersEnabled {
            chips += [
                .init(text: "Dirty diaper at \(at)", slug: "diaperDirty", autoSend: false),
                .init(text: "Wet diaper at \(at)", slug: "diaperWet", autoSend: false),
            ]
        }
        chips.append(.init(text: "Today's total", slug: "feedTotal", autoSend: true))
        return chips
    }
}

public struct ChatSuggestion: Sendable, Hashable {
    public let text: String
    public let slug: String
    /// Write-intent chips populate the composer for review; read-only
    /// chips auto-send on tap.
    public let autoSend: Bool

    public init(text: String, slug: String, autoSend: Bool) {
        self.text = text
        self.slug = slug
        self.autoSend = autoSend
    }
}
