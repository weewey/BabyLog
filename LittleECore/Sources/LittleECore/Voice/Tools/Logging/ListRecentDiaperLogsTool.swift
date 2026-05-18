import Foundation

/// Tool wrapping `DiaperLogRepository.all` so the chat model can read
/// back the most recent diaper-change events.
public struct ListRecentDiaperLogsTool: ChatTool {

    public let name = "listRecentDiaperLogs"
    public let description = "List the most recent diaper log entries, newest first. Use this when the user refers to an existing diaper event such as 'the diaper from an hour ago'."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("limit", .init(type: .integer, description: "How many entries to return. Defaults to 5. Pass a larger number when the user asks about longer history (e.g. 'today', 'this week').")),
        ],
        required: []
    )

    private let repository: any DiaperLogRepository

    public init(repository: any DiaperLogRepository) {
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
            return ToolResult(content: "No diaper logs yet.")
        }

        let lines = entries.map { entry in
            "id=\(entry.id.uuidString) | \(entry.type.rawValue) | \(ListRecentToolHelpers.formatTimestamp(entry.loggedAt))"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
