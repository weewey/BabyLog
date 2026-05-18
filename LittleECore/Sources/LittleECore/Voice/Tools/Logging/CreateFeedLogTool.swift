import Foundation

/// Tool wrapping `FeedLogRepository.save` so a chat model can record a
/// new feed when the parent says "she had 120 ml from the bottle."
public struct CreateFeedLogTool: ChatTool {

    public let name = "createFeedLog"
    public let description = "Record a new feed for the baby with volume in millilitres. Use the current time if the parent does not specify when."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("volumeMl", .init(type: .integer, description: "Volume of the feed in millilitres (1–500).")),
            ("loggedAt", .init(type: .string, description: "Local time as yyyy-MM-ddTHH:mm:ss (no Z suffix). Defaults to now if omitted.")),
        ],
        required: ["volumeMl"]
    )

    private let repository: any FeedLogRepository
    private let clock: any Clock
    private let reminder: (any FeedReminderNotifying)?
    private let reminderThreshold: TimeInterval

    public init(
        repository: any FeedLogRepository,
        clock: any Clock,
        reminder: (any FeedReminderNotifying)? = nil,
        reminderThreshold: TimeInterval = 3 * 3600
    ) {
        self.repository = repository
        self.clock = clock
        self.reminder = reminder
        self.reminderThreshold = reminderThreshold
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let volumeMl = try arguments.int("volumeMl")
        let loggedAt = try arguments.optionalDate("loggedAt") ?? clock.now()

        let feed = try FeedLog(volumeMl: volumeMl, loggedAt: loggedAt, source: .bottle)
        try await repository.save(feed)
        let all = try await repository.all()
        if let reminder {
            await reminder.rescheduleFeedReminder(feeds: all, threshold: reminderThreshold)
        }

        let summary = Self.summarizeForModel(
            justSaved: feed,
            all: all,
            now: clock.now()
        )
        return ToolResult(content: summary)
    }

    /// Build the tool-result text the chat model sees after a successful
    /// save. The numbers in here are what the model should use in its
    /// confirmation reply — without them it has no grounding for a
    /// useful response.
    static func summarizeForModel(
        justSaved: FeedLog,
        all: [FeedLog],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let todayFeeds = all
            .filter { calendar.isDate($0.loggedAt, inSameDayAs: now) }
            .sorted { $0.loggedAt < $1.loggedAt }
        let todayCount = todayFeeds.count
        let todayTotal = todayFeeds.reduce(0) { $0 + $1.volumeMl }
        let timeFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            return f
        }()

        var parts: [String] = []
        parts.append("Logged \(justSaved.volumeMl) ml feed at \(timeFmt.string(from: justSaved.loggedAt)).")
        parts.append("Today: \(todayCount) feed\(todayCount == 1 ? "" : "s"), \(todayTotal) ml total.")

        // Gap from the feed immediately before the one we just saved.
        let ordered = all.sorted { $0.loggedAt < $1.loggedAt }
        if let idx = ordered.firstIndex(where: { $0.id == justSaved.id }), idx > 0 {
            let prev = ordered[idx - 1]
            let gap = justSaved.loggedAt.timeIntervalSince(prev.loggedAt)
            if gap > 0 {
                parts.append("Gap from previous: \(formatGap(gap)).")
            }
        }

        parts.append("id=\(justSaved.id.uuidString)")
        return parts.joined(separator: " ")
    }

    private static func formatGap(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }
}
