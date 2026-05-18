import Foundation

/// Tool wrapping `GrowthMeasurementRepository` to patch an existing measurement.
public struct UpdateGrowthMeasurementTool: ChatTool {

    public let name = "updateGrowthMeasurement"
    public let description = "Update an existing growth measurement by id. Only fields supplied in the arguments are changed; omitted fields are left as-is."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the growth measurement to update.")),
            ("weightGrams", .init(type: .integer, description: "New weight in grams (500–15000).")),
            ("heightCm", .init(type: .number, description: "New height in centimetres (20.0–120.0).")),
            ("headCircumferenceCm", .init(type: .number, description: "New head circumference in centimetres (20.0–60.0).")),
            ("date", .init(type: .string, description: "New ISO8601 date of the measurement.")),
            ("notes", .init(type: .string, description: "New free-text notes.")),
        ],
        required: ["id"]
    )

    private let repository: any GrowthMeasurementRepository

    public init(repository: any GrowthMeasurementRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let idString = try arguments.string("id")
        guard let uuid = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }
        let typedId = GrowthMeasurementID(uuid)

        let existing = try await repository.all().first(where: { $0.id == typedId })
        guard let existing else {
            throw ChatToolError.executionFailed("No growth measurement found with id \(idString).")
        }

        let newWeight = try arguments.optionalInt("weightGrams") ?? existing.weightGrams
        let newHeight = try arguments.optionalDouble("heightCm") ?? existing.heightCm
        let newHead = try arguments.optionalDouble("headCircumferenceCm") ?? existing.headCircumferenceCm
        let newDate = try arguments.optionalDate("date") ?? existing.date
        let newNotes = try arguments.optionalString("notes") ?? existing.notes

        try await repository.delete(id: uuid)
        do {
            let updated = try GrowthMeasurement(
                id: typedId,
                date: newDate,
                weightGrams: newWeight,
                heightCm: newHeight,
                headCircumferenceCm: newHead,
                notes: newNotes
            )
            try await repository.save(updated)
        } catch {
            throw ChatToolError.executionFailed("Failed to update growth measurement: \(error)")
        }

        return ToolResult(content: "Updated growth measurement \(idString).")
    }
}
