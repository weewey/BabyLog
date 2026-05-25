import Foundation

/// Tool wrapping `FeedLogRepository` to patch an existing feed entry.
public struct UpdateFeedLogTool: ChatTool {

    public let name = "updateFeedLog"
    public let description = "Update an existing feed log by id. Only fields supplied in the arguments are changed; omitted fields are left as-is."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the feed log to update.")),
            ("volumeMl", .init(type: .integer, description: "New volume in millilitres (1–500).")),
            ("loggedAt", .init(type: .dateTime, description: "Updated date-time.")),
        ],
        required: ["id"]
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
        let idString = try arguments.string("id")
        guard let id = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }

        let existing = try await repository.all().first(where: { $0.id == id })
        guard let existing else {
            throw ChatToolError.executionFailed("No feed log found with id \(idString).")
        }

        let newVolume = try arguments.optionalInt("volumeMl") ?? existing.volumeMl
        let newLoggedAt = try arguments.optionalDate("loggedAt") ?? existing.loggedAt

        // Replace the existing entry. The InMemory repo's save appends,
        // so delete-then-save preserves the public contract while
        // keeping the same id.
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

        return ToolResult(content: "Updated feed log \(idString).")
    }
}
