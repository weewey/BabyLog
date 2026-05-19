import Foundation

/// Returns a pre-computed summary of today's feeds (count, total ml,
/// last feed time). Designed for small on-device models that struggle
/// to sum and filter raw feed lists accurately — the model only needs
/// to relay the result verbatim.
public struct GetTodayFeedSummaryTool: ChatTool {

    public let name = "getTodayFeedSummary"
    public let description = "Get today's feed summary: total number of feeds, total volume in ml, and last feed time. Use this when the user asks about today's total, how much the baby has eaten today, or how many feeds."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(properties: [], required: [])

    private let repository: any FeedLogRepository
    private let clock: any Clock

    public init(repository: any FeedLogRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let now = clock.now()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        let all = try await repository.all()
        let todayFeeds = all
            .filter { $0.loggedAt >= startOfToday && $0.loggedAt <= now }
            .sorted { $0.loggedAt > $1.loggedAt }

        let count = todayFeeds.count
        let totalMl = todayFeeds.reduce(0) { $0 + $1.volumeMl }

        if count == 0 {
            return ToolResult(content: "Today: 0 feeds, 0 ml total. No feeds logged yet today.")
        }

        let lastFeedTime = ListRecentToolHelpers.formatTimestamp(todayFeeds[0].loggedAt)
        return ToolResult(
            content: "Today: \(count) feed\(count == 1 ? "" : "s"), \(totalMl) ml total, last feed at \(lastFeedTime)."
        )
    }
}
