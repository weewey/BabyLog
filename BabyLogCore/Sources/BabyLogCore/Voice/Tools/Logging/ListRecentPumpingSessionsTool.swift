import Foundation

/// Tool wrapping `PumpingSessionRepository.recent` so the chat model can
/// read back recent pumping sessions.
public struct ListRecentPumpingSessionsTool: ChatTool {

    public let name = "listRecentPumpingSessions"
    public let description = "List the most recent pumping sessions, newest first. Use this when the user refers to an existing session such as 'my last pump'."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("limit", .init(type: .integer, description: "How many entries to return. Defaults to 10.")),
        ],
        required: []
    )

    private let repository: any PumpingSessionRepository

    public init(repository: any PumpingSessionRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let rawLimit = try? arguments.optionalInt("limit")
        let limit = (rawLimit ?? nil).flatMap { $0 > 0 ? $0 : nil } ?? 10

        let entries = try await repository.recent(limit: limit)

        if entries.isEmpty {
            return ToolResult(content: "No pumping sessions yet.")
        }

        let lines = entries.map { entry -> String in
            let volume = entry.milkVolumeMl.map { "\($0) ml" } ?? "—"
            let side = entry.side?.rawValue ?? "—"
            return "id=\(entry.id.uuidString) | \(ListRecentToolHelpers.formatTimestamp(entry.startedAt)) | \(entry.durationMinutes) min | \(volume) | \(side)"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
