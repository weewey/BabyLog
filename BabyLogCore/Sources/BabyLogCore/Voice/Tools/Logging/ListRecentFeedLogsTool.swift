import Foundation

/// Tool wrapping `FeedLogRepository.all` so the chat model can read back
/// the most recent feed entries. Gives the model enough context to act
/// on phrases like "my last feed" or "the bottle from an hour ago".
public struct ListRecentFeedLogsTool: ChatTool {

    public let name = "listRecentFeedLogs"
    public let description = "List the most recent feed log entries, newest first. Use this when the user refers to an existing feed such as 'my last feed'."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("limit", .init(type: .integer, description: "How many entries to return. Defaults to 5. Pass a larger number when the user asks about longer history (e.g. 'today', 'this week').")),
        ],
        required: []
    )

    private let repository: any FeedLogRepository

    public init(repository: any FeedLogRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let rawLimit = (try? arguments.optionalInt("limit")) ?? nil
        let limit = ListRecentToolHelpers.resolveLimit(rawLimit)

        let all = try await repository.all()
        let entries = all
            .sorted { $0.loggedAt > $1.loggedAt }
            .prefix(limit)

        if entries.isEmpty {
            return ToolResult(content: "No feed logs yet.")
        }

        let lines = entries.map { entry in
            "id=\(entry.id.uuidString) | \(entry.volumeMl) ml | \(ListRecentToolHelpers.formatTimestamp(entry.loggedAt))"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
