import Foundation

/// Tool wrapping `MedicalAppointmentRepository` to patch an existing
/// appointment. Only fields supplied in the arguments are changed.
public struct UpdateMedicalAppointmentTool: ChatTool {

    public let name = "updateMedicalAppointment"
    public let description = "Update an existing medical appointment by id. Only fields supplied in the arguments are changed; omitted fields are left as-is."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the appointment to update.")),
            ("title", .init(type: .string, description: "New title.")),
            ("scheduledAt", .init(type: .string, description: "New local time as yyyy-MM-ddTHH:mm:ss (no Z suffix).")),
            ("location", .init(type: .string, description: "New location.")),
            ("notes", .init(type: .string, description: "New notes.")),
        ],
        required: ["id"]
    )

    private let repository: any MedicalAppointmentRepository
    private let calendar: (any CalendarSyncing)?

    public init(
        repository: any MedicalAppointmentRepository,
        calendar: (any CalendarSyncing)? = nil
    ) {
        self.repository = repository
        self.calendar = calendar
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let idString = try arguments.string("id")
        guard let id = UUID(uuidString: idString) else {
            throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
        }

        let existing = try await repository.all().first(where: { $0.id == id })
        guard let existing else {
            throw ChatToolError.executionFailed("No medical appointment found with id \(idString).")
        }

        let newTitle = try arguments.optionalString("title") ?? existing.title
        let newScheduledAt = try arguments.optionalDate("scheduledAt") ?? existing.scheduledAt
        let newLocation: String?
        if let loc = try arguments.optionalString("location") {
            newLocation = loc
        } else {
            newLocation = existing.location
        }
        let newNotes: String?
        if let n = try arguments.optionalString("notes") {
            newNotes = n
        } else {
            newNotes = existing.notes
        }

        // Replace the existing entry. The InMemory repo's save upserts,
        // so a plain save with the same id preserves identity.
        try await repository.delete(id: id)
        let updated = try MedicalAppointment(
            id: id,
            title: newTitle,
            scheduledAt: newScheduledAt,
            location: newLocation,
            notes: newNotes
        )
        try await repository.save(updated)
        await calendar?.upsert(appointment: updated)

        return ToolResult(content: "Updated medical appointment \(idString).")
    }
}
