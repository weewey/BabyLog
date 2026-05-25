import Foundation

/// Tool wrapping `PumpingSessionRepository.save` so a chat model can
/// record a pumping session when the user says "logged 7:30am, 20 min".
public struct CreatePumpingSessionTool: ChatTool {

    public let name = "createPumpingSession"
    public let description = "Record a new pumping session. Duration in minutes is required. Use the current time if the user does not specify when."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("startedAt", .init(type: .dateTime, description: "When this occurred. Omit to use current time.")),
            ("durationMinutes", .init(type: .integer, description: "Length of the session in minutes (1–120).")),
            ("side", .init(type: .string, description: "Which breast(s) were pumped.", enumValues: PumpingSide.allCases.map(\.rawValue))),
            ("milkVolumeMl", .init(type: .integer, description: "Milk expressed in millilitres (0–500). Optional.")),
            ("notes", .init(type: .string, description: "Freeform notes, max 500 characters.")),
        ],
        required: ["durationMinutes"]
    )

    private let repository: any PumpingSessionRepository
    private let clock: any Clock

    public init(repository: any PumpingSessionRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let duration = try arguments.int("durationMinutes")
        let startedAt = try arguments.optionalDate("startedAt") ?? clock.now()
        let sideRaw = try arguments.optionalString("side")
        let side: PumpingSide? = sideRaw.flatMap { PumpingSide(rawValue: $0) }
        let milkVolumeMl = try arguments.optionalInt("milkVolumeMl")
        let notes = try arguments.optionalString("notes")

        let session = try PumpingSession(
            startedAt: startedAt,
            durationMinutes: duration,
            side: side,
            milkVolumeMl: milkVolumeMl,
            notes: notes
        )
        try await repository.save(session)

        let timeString = ListRecentToolHelpers.formatTimestamp(startedAt)
        return ToolResult(
            content: "Logged pumping session: \(duration) min at \(timeString). id=\(session.id.uuidString)"
        )
    }
}
