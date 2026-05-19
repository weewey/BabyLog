import Foundation

/// Tool wrapping `PumpingSessionRepository.delete` so the chat model can
/// remove a previously-logged pumping session by id.
public struct DeletePumpingSessionTool: ChatTool {

    public let name = "deletePumpingSession"
    public let description = "Delete a previously-logged pumping session by id."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the pumping session to delete.")),
        ],
        required: ["id"]
    )

    private let repository: any PumpingSessionRepository

    public init(repository: any PumpingSessionRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let idString = try arguments.string("id")
        guard let id = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }

        let exists = try await repository.all().contains(where: { $0.id == id })
        guard exists else {
            throw ChatToolError.executionFailed("No pumping session found with id \(idString).")
        }

        try await repository.delete(id: id)
        return ToolResult(content: "Deleted pumping session \(idString).")
    }
}
