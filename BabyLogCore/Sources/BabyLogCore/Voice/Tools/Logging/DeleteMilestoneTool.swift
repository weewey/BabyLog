import Foundation

/// Tool wrapping `MilestoneRepository.delete` so the chat model can remove
/// a previously-logged milestone by id.
public struct DeleteMilestoneTool: ChatTool {

    public let name = "deleteMilestone"
    public let description = "Delete a previously-logged milestone by id."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the milestone to delete.")),
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

        let exists = try await repository.all().contains(where: { $0.id == id })
        guard exists else {
            throw ChatToolError.executionFailed("No milestone found with id \(idString).")
        }

        try await repository.delete(id: id)
        return ToolResult(content: "Deleted milestone \(idString).")
    }
}
