import Foundation

/// Tool wrapping `MedicalAppointmentRepository.save` so the chat model can
/// schedule a new medical appointment ("book Ethan's 6-month check-up on
/// May 1st at 10am").
public struct CreateMedicalAppointmentTool: ChatTool {

    public let name = "createMedicalAppointment"
    public let description = "Schedule a new medical appointment for the baby with a title and local-time timestamp. Optional location and notes may be supplied."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("title", .init(type: .string, description: "Short title for the appointment, e.g. '6-month check-up'.")),
            ("scheduledAt", .init(type: .string, description: "Local time as yyyy-MM-ddTHH:mm:ss (no Z suffix) for when the appointment is scheduled.")),
            ("location", .init(type: .string, description: "Optional location, e.g. 'Dr Tan's clinic'.")),
            ("notes", .init(type: .string, description: "Optional free-text notes.")),
        ],
        required: ["title", "scheduledAt"]
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
        let title = try arguments.string("title")
        let scheduledAt = try arguments.date("scheduledAt")
        let location = try arguments.optionalString("location")
        let notes = try arguments.optionalString("notes")

        let appointment = try MedicalAppointment(
            title: title,
            scheduledAt: scheduledAt,
            location: location,
            notes: notes
        )
        try await repository.save(appointment)
        await calendar?.upsert(appointment: appointment)

        return ToolResult(content: "Scheduled appointment: \(appointment.title). id=\(appointment.id.uuidString)")
    }
}
