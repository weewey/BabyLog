import Foundation

/// Tool wrapping `MedicalAppointmentRepository.delete` so the chat model
/// can cancel a previously-scheduled appointment by id.
public struct DeleteMedicalAppointmentTool: ChatTool {

    public let name = "deleteMedicalAppointment"
    public let description = "Delete a previously-scheduled medical appointment by id."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the appointment to delete.")),
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

        let exists = try await repository.all().contains(where: { $0.id == id })
        guard exists else {
            throw ChatToolError.executionFailed("No medical appointment found with id \(idString).")
        }

        try await repository.delete(id: id)
        await calendar?.remove(appointmentId: id)
        return ToolResult(content: "Deleted medical appointment \(idString).")
    }
}
