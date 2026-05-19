import Foundation

/// Tool wrapping `GrowthMeasurementRepository.delete` so the chat model can
/// remove a previously-logged growth measurement by id.
public struct DeleteGrowthMeasurementTool: ChatTool {

    public let name = "deleteGrowthMeasurement"
    public let description = "Delete a previously-logged growth measurement by id."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the growth measurement to delete.")),
        ],
        required: ["id"]
    )

    private let repository: any GrowthMeasurementRepository

    public init(repository: any GrowthMeasurementRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let idString = try arguments.string("id")
        guard let id = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }

        let exists = try await repository.all().contains(where: { $0.id.value == id })
        guard exists else {
            throw ChatToolError.executionFailed("No growth measurement found with id \(idString).")
        }

        try await repository.delete(id: id)
        return ToolResult(content: "Deleted growth measurement \(idString).")
    }
}
