import Foundation

/// Tool wrapping `DiaperLogRepository.delete` so the chat model can remove
/// a previously-logged diaper by id.
public struct DeleteDiaperLogTool: ChatTool {

    public let name = "deleteDiaperLog"
    public let description = "Delete a previously-logged diaper by id."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the diaper log to delete.")),
        ],
        required: ["id"]
    )

    private let repository: any DiaperLogRepository

    public init(repository: any DiaperLogRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let idString = try arguments.string("id")
        guard let id = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }

        let exists = try await repository.all().contains(where: { $0.id == id })
        guard exists else {
            throw ChatToolError.executionFailed("No diaper log found with id \(idString).")
        }

        try await repository.delete(id: id)
        return ToolResult(content: "Deleted diaper log \(idString).")
    }
}
