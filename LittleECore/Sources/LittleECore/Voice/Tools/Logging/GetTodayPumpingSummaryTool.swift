import Foundation

public struct GetTodayPumpingSummaryTool: ChatTool {

    public let name = "getTodayPumpingSummary"
    public let description = "Get today's pumping summary: total sessions, total milk volume in ml, total pumping minutes, and last session time. Use this when the user asks about today's pumping total or how much milk they have pumped today."
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(properties: [], required: [])

    private let repository: any PumpingSessionRepository
    private let clock: any Clock

    public init(repository: any PumpingSessionRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let now = clock.now()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        let all = try await repository.all()
        let todays = all
            .filter { $0.startedAt >= startOfToday && $0.startedAt <= now }
            .sorted { $0.startedAt > $1.startedAt }

        let count = todays.count
        let totalMl = todays.reduce(0) { $0 + ($1.milkVolumeMl ?? 0) }
        let totalMinutes = todays.reduce(0) { $0 + $1.durationMinutes }

        if count == 0 {
            return ToolResult(content: "Today: 0 pumping sessions, 0 ml total, 0 minutes. No sessions logged yet today.")
        }

        let lastTime = ListRecentToolHelpers.formatTimestamp(todays[0].startedAt)
        return ToolResult(
            content: "Today: \(count) session\(count == 1 ? "" : "s"), \(totalMl) ml total, \(totalMinutes) min pumping time, last session at \(lastTime)."
        )
    }
}
