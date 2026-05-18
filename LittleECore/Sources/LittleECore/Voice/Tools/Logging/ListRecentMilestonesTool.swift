import Foundation

/// Tool wrapping `MilestoneRepository.all` so the chat model can read
/// back the most recent milestones.
public struct ListRecentMilestonesTool: ChatTool {

    public let name = "listRecentMilestones"
    public let description = "List the most recent developmental milestones, newest first. Use this when the user refers to a previous milestone such as 'the one I logged yesterday'."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("limit", .init(type: .integer, description: "How many entries to return. Defaults to 5. Pass a larger number when the user asks about longer history.")),
        ],
        required: []
    )

    private let repository: any MilestoneRepository

    public init(repository: any MilestoneRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let rawLimit = (try? arguments.optionalInt("limit")) ?? nil
        let limit = ListRecentToolHelpers.resolveLimit(rawLimit)

        let all = try await repository.all()
        let entries = all
            .sorted { $0.achievedAt > $1.achievedAt }
            .prefix(limit)

        if entries.isEmpty {
            return ToolResult(content: "No milestones yet.")
        }

        let lines = entries.map { milestone in
            "id=\(milestone.id.uuidString) | \(milestone.title) | \(ListRecentToolHelpers.formatTimestamp(milestone.achievedAt))"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
