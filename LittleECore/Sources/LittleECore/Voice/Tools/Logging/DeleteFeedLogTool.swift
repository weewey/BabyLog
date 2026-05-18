import Foundation

/// Tool wrapping `FeedLogRepository.delete` so the chat model can remove
/// a previously-logged feed by id ("delete that last feed").
public struct DeleteFeedLogTool: ChatTool {

    public let name = "deleteFeedLog"
    public let description = "Delete a previously-logged feed by id."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the feed log to delete.")),
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

        let exists = try await repository.all().contains(where: { $0.id == id })
        guard exists else {
            throw ChatToolError.executionFailed("No feed log found with id \(idString).")
        }

        try await repository.delete(id: id)
        if let reminder {
            let all = try await repository.all()
            await reminder.rescheduleFeedReminder(feeds: all, threshold: reminderThreshold)
        }
        return ToolResult(content: "Deleted feed log \(idString).")
    }
}
