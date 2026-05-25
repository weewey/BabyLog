import Foundation

/// Tool wrapping `DiaperLogRepository.save` for chat-driven diaper logs.
public struct CreateDiaperLogTool: ChatTool {

    public let name = "createDiaperLog"
    public let description = "Record a diaper change. 'wet' is urine only, 'dirty' is stool only, 'both' is both in the same diaper."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("type", .init(type: .string, description: "Diaper contents.", enumValues: ["wet", "dirty", "both"])),
            ("loggedAt", .init(type: .dateTime, description: "When this occurred. Omit to use current time.")),
        ],
        required: ["type"]
    )

    private let repository: any DiaperLogRepository
    private let clock: any Clock

    public init(repository: any DiaperLogRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let typeRaw = try arguments.string("type")
        let loggedAt = try arguments.optionalDate("loggedAt") ?? clock.now()

        let log = try DiaperLog(
            id: UUID(),
            typeRawValue: typeRaw,
            loggedAt: loggedAt
        )
        try await repository.save(log)
        let all = try await repository.all()

        let summary = Self.summarizeForModel(justSaved: log, all: all, now: clock.now())
        return ToolResult(content: summary)
    }

    static func summarizeForModel(
        justSaved: DiaperLog,
        all: [DiaperLog],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let today = all
            .filter { calendar.isDate($0.loggedAt, inSameDayAs: now) }
            .sorted { $0.loggedAt < $1.loggedAt }
        let wet = today.filter { $0.type == .wet }.count
        let dirty = today.filter { $0.type == .dirty }.count
        let both = today.filter { $0.type == .both }.count
        let total = today.count

        var parts: [String] = []
        parts.append("Logged \(justSaved.type.rawValue) diaper.")
        var breakdown: [String] = []
        if wet > 0 { breakdown.append("\(wet) wet") }
        if dirty > 0 { breakdown.append("\(dirty) dirty") }
        if both > 0 { breakdown.append("\(both) both") }
        let bd = breakdown.isEmpty ? "none yet" : breakdown.joined(separator: ", ")
        parts.append("Today: \(total) diaper\(total == 1 ? "" : "s") (\(bd)).")

        let ordered = all.sorted { $0.loggedAt < $1.loggedAt }
        if let idx = ordered.firstIndex(where: { $0.id == justSaved.id }), idx > 0 {
            let prev = ordered[idx - 1]
            let gap = justSaved.loggedAt.timeIntervalSince(prev.loggedAt)
            if gap > 0 {
                parts.append("Gap from previous: \(formatGap(gap)).")
            }
        }

        parts.append("id=\(justSaved.id.uuidString)")
        return parts.joined(separator: " ")
    }

    private static func formatGap(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }
}
