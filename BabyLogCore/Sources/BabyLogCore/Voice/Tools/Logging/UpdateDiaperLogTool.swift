import Foundation

/// Tool wrapping `DiaperLogRepository` to patch an existing diaper entry.
public struct UpdateDiaperLogTool: ChatTool {

    public let name = "updateDiaperLog"
    public let description = "Update an existing diaper log by id. Only fields supplied in the arguments are changed; omitted fields are left as-is."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the diaper log to update.")),
            ("type", .init(type: .string, description: "New diaper type.", enumValues: ["wet", "dirty", "both"])),
            ("loggedAt", .init(type: .dateTime, description: "Updated date-time.")),
            ("notes", .init(type: .string, description: "New free-text notes.")),
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

        let existing = try await repository.all().first(where: { $0.id == id })
        guard let existing else {
            throw ChatToolError.executionFailed("No diaper log found with id \(idString).")
        }

        let newType: DiaperType
        if let raw = try arguments.optionalString("type") {
            guard let parsed = DiaperType(rawValue: raw) else {
                throw ChatToolError.executionFailed("Unknown diaper type '\(raw)'. Expected 'wet', 'dirty', or 'both'.")
            }
            newType = parsed
        } else {
            newType = existing.type
        }
        let newLoggedAt = try arguments.optionalDate("loggedAt") ?? existing.loggedAt
        let newNotes = try arguments.optionalString("notes") ?? existing.notes

        try await repository.delete(id: id)
        let updated = DiaperLog(
            id: id,
            type: newType,
            loggedAt: newLoggedAt,
            notes: newNotes
        )
        try await repository.save(updated)

        return ToolResult(content: "Updated diaper log \(idString).")
    }
}
