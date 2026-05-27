import Foundation

/// Tool wrapping `FeedLogRepository` to patch an existing feed entry.
/// The entry can be identified three ways (in priority order):
///   1. `id` — explicit UUID (most precise)
///   2. `mostRecent: true` — the most recently logged feed
///   3. `time` — time string like "09:30" or "9:30am"; picks the entry closest to that time today
public struct UpdateFeedLogTool: ChatTool {

    public let name = "updateFeedLog"
    public let description = """
        Update an existing feed log. Identify the entry with ONE of: \
        'id' (UUID), 'mostRecent: true' (the last feed logged), or 'time' (e.g. "09:30" / "9:30am" \
        — picks the entry closest to that time today). Only fields supplied are changed; omitted fields are left as-is.
        """
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the feed log to update. Omit if using mostRecent or time.")),
            ("mostRecent", .init(type: .boolean, description: "Set true to update the most recently logged feed (e.g. 'the last feed', 'the previous one').")),
            ("time", .init(type: .string, description: "Time of the feed to update, e.g. \"09:30\" or \"9:30am\". Picks the entry closest to that time today.")),
            ("volumeMl", .init(type: .integer, description: "New volume in millilitres (1–500).")),
            ("loggedAt", .init(type: .dateTime, description: "Updated date-time.")),
        ],
        required: []
    )

    private let repository: any FeedLogRepository
    private let reminder: (any FeedReminderNotifying)?
    private let reminderThreshold: TimeInterval

    public init(
        repository: any FeedLogRepository,
        reminder: (any FeedReminderNotifying)? = nil,
        reminderThreshold: TimeInterval = 3 * 3600
    ) {
        self.repository = repository
        self.reminder = reminder
        self.reminderThreshold = reminderThreshold
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let all = try await repository.all()
        let existing = try Self.resolveEntry(from: arguments, all: all)
        let id = existing.id

        let newVolume = try arguments.optionalInt("volumeMl") ?? existing.volumeMl
        let newLoggedAt = try arguments.optionalDate("loggedAt") ?? existing.loggedAt

        try await repository.delete(id: id)
        let updated = try FeedLog(
            id: id,
            volumeMl: newVolume,
            loggedAt: newLoggedAt,
            source: existing.source,
            notes: existing.notes
        )
        try await repository.save(updated)
        if let reminder {
            let all = try await repository.all()
            await reminder.rescheduleFeedReminder(feeds: all, threshold: reminderThreshold)
        }

        return ToolResult(content: "Updated feed log \(id.uuidString).")
    }

    // MARK: - Entry resolution

    private static func resolveEntry(from arguments: ToolArguments, all entries: [FeedLog]) throws -> FeedLog {
        // 1. Explicit UUID
        if let idString = try arguments.optionalString("id") {
            guard let id = UUID(uuidString: idString) else {
                throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
            }
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw ChatToolError.executionFailed("No feed log found with id \(idString).")
            }
            return entry
        }

        // 2. mostRecent
        if (try arguments.optionalBool("mostRecent")) == true {
            guard let entry = entries.max(by: { $0.loggedAt < $1.loggedAt }) else {
                throw ChatToolError.executionFailed("No feed logs found.")
            }
            return entry
        }

        // 3. time string — find closest to that time today
        if let timeString = try arguments.optionalString("time") {
            guard let target = parseTimeToday(timeString) else {
                throw ChatToolError.executionFailed("Could not parse time '\(timeString)'. Use a format like \"09:30\" or \"9:30am\".")
            }
            guard let entry = entries.min(by: {
                abs($0.loggedAt.timeIntervalSince(target)) < abs($1.loggedAt.timeIntervalSince(target))
            }) else {
                throw ChatToolError.executionFailed("No feed logs found near \(timeString).")
            }
            return entry
        }

        throw ChatToolError.executionFailed(
            "Provide one of 'id' (UUID), 'mostRecent: true', or 'time' (e.g. \"09:30\") to identify the feed."
        )
    }

    /// Parses a time-only string and returns a Date set to today at that hour+minute.
    private static func parseTimeToday(_ timeString: String) -> Date? {
        let trimmed = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        for (format, locale) in timeFormats {
            fmt.dateFormat = format
            fmt.locale = locale
            if let parsed = fmt.date(from: trimmed) {
                let cal = Calendar.current
                let comps = cal.dateComponents([.hour, .minute, .second], from: parsed)
                return cal.date(bySettingHour: comps.hour ?? 0,
                                minute: comps.minute ?? 0,
                                second: comps.second ?? 0,
                                of: Date())
            }
        }
        return nil
    }

    private static let timeFormats: [(String, Locale)] = [
        ("HH:mm:ss", Locale(identifier: "en_US_POSIX")),
        ("HH:mm",    Locale(identifier: "en_US_POSIX")),
        ("h:mm a",   .current),
        ("h:mma",    .current),
        ("h:mm",     .current),
    ]
}
