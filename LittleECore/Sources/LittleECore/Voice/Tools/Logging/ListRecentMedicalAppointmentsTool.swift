import Foundation

/// Tool wrapping `MedicalAppointmentRepository.all` so the chat model can
/// read back the most recent medical appointments, newest first.
public struct ListRecentMedicalAppointmentsTool: ChatTool {

    public let name = "listRecentMedicalAppointments"
    public let description = "List the most recent medical appointments, newest first. Use this when the user refers to an existing appointment such as 'the check-up next week'."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("limit", .init(type: .integer, description: "How many entries to return. Defaults to 5. Pass a larger number when the user asks about longer history.")),
        ],
        required: []
    )

    private let repository: any MedicalAppointmentRepository

    public init(repository: any MedicalAppointmentRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let rawLimit = (try? arguments.optionalInt("limit")) ?? nil
        let limit = ListRecentToolHelpers.resolveLimit(rawLimit)

        let all = try await repository.all()
        let entries = all
            .sorted { $0.scheduledAt > $1.scheduledAt }
            .prefix(limit)

        if entries.isEmpty {
            return ToolResult(content: "No medical appointments yet.")
        }

        let lines = entries.map { appointment -> String in
            var line = "id=\(appointment.id.uuidString) | \(appointment.title) | \(ListRecentToolHelpers.formatTimestamp(appointment.scheduledAt))"
            if let location = appointment.location {
                line += " | \(location)"
            }
            return line
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
