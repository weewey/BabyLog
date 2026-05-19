import Foundation
import Testing
@testable import BabyLogCore

@Suite("GetTodayPumpingSummaryTool")
struct GetTodayPumpingSummaryToolTests {

    private final class FixedClock: Clock, @unchecked Sendable {
        let fixed: Date
        init(_ date: Date) { self.fixed = date }
        func now() -> Date { fixed }
    }

    private func makeNow(hour: Int, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = hour; comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    private func makeSession(
        hour: Int, minute: Int = 0,
        durationMinutes: Int = 20,
        milkVolumeMl: Int? = 100
    ) throws -> PumpingSession {
        try PumpingSession(
            startedAt: makeNow(hour: hour, minute: minute),
            durationMinutes: durationMinutes,
            milkVolumeMl: milkVolumeMl
        )
    }

    @Test("empty returns zero summary")
    func emptyReturnsZero() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let tool = GetTodayPumpingSummaryTool(
            repository: repo,
            clock: FixedClock(makeNow(hour: 14))
        )

        let result = try await tool.execute(arguments: ToolArguments([:]))
        #expect(result.content.contains("0 pumping sessions"))
        #expect(result.content.contains("0 ml total"))
    }

    @Test("sums volume and minutes across today's sessions")
    func sumsToday() async throws {
        let repo = InMemoryPumpingSessionRepository()
        try await repo.save(try makeSession(hour: 8, milkVolumeMl: 80))
        try await repo.save(try makeSession(hour: 11, durationMinutes: 25, milkVolumeMl: 120))

        let tool = GetTodayPumpingSummaryTool(
            repository: repo,
            clock: FixedClock(makeNow(hour: 14))
        )

        let result = try await tool.execute(arguments: ToolArguments([:]))
        #expect(result.content.contains("2 sessions"))
        #expect(result.content.contains("200 ml total"))
        #expect(result.content.contains("45 min"))
    }

    @Test("nil volume treated as zero")
    func nilVolumeIsZero() async throws {
        let repo = InMemoryPumpingSessionRepository()
        try await repo.save(try makeSession(hour: 8, milkVolumeMl: nil))
        try await repo.save(try makeSession(hour: 10, milkVolumeMl: 60))

        let tool = GetTodayPumpingSummaryTool(
            repository: repo,
            clock: FixedClock(makeNow(hour: 14))
        )

        let result = try await tool.execute(arguments: ToolArguments([:]))
        #expect(result.content.contains("60 ml total"))
    }

    @Test("single session uses singular form")
    func singleSession() async throws {
        let repo = InMemoryPumpingSessionRepository()
        try await repo.save(try makeSession(hour: 9, milkVolumeMl: 100))

        let tool = GetTodayPumpingSummaryTool(
            repository: repo,
            clock: FixedClock(makeNow(hour: 14))
        )

        let result = try await tool.execute(arguments: ToolArguments([:]))
        #expect(result.content.contains("1 session,"))
    }
}
