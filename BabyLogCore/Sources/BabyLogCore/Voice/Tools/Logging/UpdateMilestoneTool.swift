import Foundation

/// Tool wrapping `MilestoneRepository` to patch an existing milestone.
public struct UpdateMilestoneTool: ChatTool {

    public let name = "updateMilestone"
    public let description = "Update an existing milestone by id. Only fields supplied in the arguments are changed; omitted fields are left as-is."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the milestone to update.")),
            ("title", .init(type: .string, description: "New milestone title.")),
            ("achievedAt", .init(type: .dateTime, description: "Updated date-time.")),
            ("notes", .init(type: .string, description: "New free-text notes.")),
        ],
        required: ["id"]
    )

    private let repository: any MilestoneRepository

    public init(repository: any MilestoneRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let idString = try arguments.string("id")
        guard let id = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }

        let existing = try await repository.all().first(where: { $0.id == id })
        guard let existing else {
            throw ChatToolError.executionFailed("No milestone found with id \(idString).")
        }

        let newTitle = try arguments.optionalString("title") ?? existing.title
        let newAchievedAt = try arguments.optionalDate("achievedAt") ?? existing.achievedAt
        let newNotes = try arguments.optionalString("notes") ?? existing.notes

        try await repository.delete(id: id)
        do {
            let updated = try Milestone(
                id: id,
                title: newTitle,
                achievedAt: newAchievedAt,
                notes: newNotes
            )
            try await repository.save(updated)
        } catch {
            throw ChatToolError.executionFailed("Failed to update milestone: \(error)")
        }

        return ToolResult(content: "Updated milestone \(idString).")
    }
}
