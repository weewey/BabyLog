import Foundation

/// Tool wrapping `GrowthMeasurementRepository.all` so the chat model can
/// read back the most recent growth entries.
public struct ListRecentGrowthMeasurementsTool: ChatTool {

    public let name = "listRecentGrowthMeasurements"
    public let description = "List the most recent growth measurements, newest first. Use this when the user refers to a previous weight/height entry."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("limit", .init(type: .integer, description: "How many entries to return. Defaults to 5. Pass a larger number when the user asks about longer history.")),
        ],
        required: []
    )

    private let repository: any GrowthMeasurementRepository

    public init(repository: any GrowthMeasurementRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let rawLimit = (try? arguments.optionalInt("limit")) ?? nil
        let limit = ListRecentToolHelpers.resolveLimit(rawLimit)

        let all = try await repository.all()
        let entries = all
            .sorted { $0.date > $1.date }
            .prefix(limit)

        if entries.isEmpty {
            return ToolResult(content: "No growth measurements yet.")
        }

        let lines = entries.map { measurement in
            "id=\(measurement.id.value.uuidString) | \(Self.summary(for: measurement)) | \(ListRecentToolHelpers.formatTimestamp(measurement.date))"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    private static func summary(for m: GrowthMeasurement) -> String {
        var parts: [String] = []
        if let w = m.weightGrams { parts.append("\(w) g") }
        if let h = m.heightCm { parts.append("\(h) cm") }
        if let hc = m.headCircumferenceCm { parts.append("head \(hc) cm") }
        return parts.isEmpty ? "(no fields)" : parts.joined(separator: ", ")
    }
}
