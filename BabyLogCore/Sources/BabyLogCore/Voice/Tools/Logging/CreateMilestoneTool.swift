import Foundation

/// Tool wrapping `MilestoneRepository.save` so the chat model can record
/// developmental milestones ("first smile", "rolled over").
public struct CreateMilestoneTool: ChatTool {

    public let name = "createMilestone"
    public let description = "Record a developmental milestone with a short title and optional notes."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("title", .init(type: .string, description: "Short title for the milestone.")),
            ("notes", .init(type: .string, description: "Optional free-text notes.")),
            ("achievedAt", .init(type: .string, description: "Local time as yyyy-MM-ddTHH:mm:ss (no Z suffix). Defaults to now.")),
        ],
        required: ["title"]
    )

    private let repository: any MilestoneRepository
    private let clock: any Clock
    private let birthDate: Date?

    public init(
        repository: any MilestoneRepository,
        clock: any Clock,
        birthDate: Date? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.birthDate = birthDate
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let title = try arguments.string("title")
        let notes = try arguments.optionalString("notes")
        let achievedAt = try arguments.optionalDate("achievedAt") ?? clock.now()

        let milestone = try Milestone(
            title: title,
            achievedAt: achievedAt,
            notes: notes
        )
        try await repository.save(milestone)
        let all = try await repository.all()

        let summary = Self.summarizeForModel(
            justSaved: milestone,
            all: all,
            birthDate: birthDate
        )
        return ToolResult(content: summary)
    }

    static func summarizeForModel(
        justSaved: Milestone,
        all: [Milestone],
        birthDate: Date?
    ) -> String {
        var parts: [String] = []
        parts.append("Logged milestone: \(justSaved.title).")
        let total = all.count
        parts.append("\(total) milestone\(total == 1 ? "" : "s") total.")

        let prior = all
            .filter { $0.id != justSaved.id && $0.achievedAt < justSaved.achievedAt }
            .sorted { $0.achievedAt > $1.achievedAt }
        if let last = prior.first {
            let days = Int(justSaved.achievedAt.timeIntervalSince(last.achievedAt) / 86400)
            if days >= 1 {
                parts.append("\(days) day\(days == 1 ? "" : "s") since the last one (\(last.title)).")
            }
        }
        if let birth = birthDate {
            let ageDays = Int(justSaved.achievedAt.timeIntervalSince(birth) / 86400)
            if ageDays >= 0 {
                parts.append("Baby is \(ageDays) day\(ageDays == 1 ? "" : "s") old.")
            }
        }
        parts.append("id=\(justSaved.id.uuidString)")
        return parts.joined(separator: " ")
    }
}
