import Foundation

/// Tool wrapping `PumpingSessionRepository.update` to patch an existing
/// pumping session by id. Only fields supplied in arguments are changed.
public struct UpdatePumpingSessionTool: ChatTool {

    public let name = "updatePumpingSession"
    public let description = "Update an existing pumping session by id. Only fields supplied in the arguments are changed; omitted fields are left as-is."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the pumping session to update.")),
            ("startedAt", .init(type: .string, description: "New ISO8601 start timestamp.")),
            ("durationMinutes", .init(type: .integer, description: "New duration in minutes (1–120).")),
            ("side", .init(type: .string, description: "New side.", enumValues: PumpingSide.allCases.map(\.rawValue))),
            ("milkVolumeMl", .init(type: .integer, description: "New milk volume in millilitres (0–500).")),
            ("notes", .init(type: .string, description: "New notes, max 500 characters.")),
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

        let existing = try await repository.all().first(where: { $0.id == id })
        guard let existing else {
            throw ChatToolError.executionFailed("No pumping session found with id \(idString).")
        }

        let newStartedAt = try arguments.optionalDate("startedAt") ?? existing.startedAt
        let newDuration = try arguments.optionalInt("durationMinutes") ?? existing.durationMinutes
        let sideRaw = try arguments.optionalString("side")
        let newSide: PumpingSide? = sideRaw.flatMap { PumpingSide(rawValue: $0) } ?? existing.side
        let newVolume = try arguments.optionalInt("milkVolumeMl") ?? existing.milkVolumeMl
        let newNotes = try arguments.optionalString("notes") ?? existing.notes

        let updated = try PumpingSession(
            id: id,
            startedAt: newStartedAt,
            durationMinutes: newDuration,
            side: newSide,
            milkVolumeMl: newVolume,
            pumpBrand: existing.pumpBrand,
            scheduleSlotId: existing.scheduleSlotId,
            notes: newNotes
        )
        try await repository.update(updated)

        return ToolResult(content: "Updated pumping session \(idString).")
    }
}
