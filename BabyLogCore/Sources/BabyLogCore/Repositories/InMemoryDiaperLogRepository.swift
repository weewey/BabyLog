import Foundation

public actor InMemoryDiaperLogRepository: DiaperLogRepository {

    private var logs: [DiaperLog] = []

    public init() {}

    public func save(_ log: DiaperLog) async throws {
        logs.append(log)
    }

    public func all() async throws -> [DiaperLog] {
        logs.sorted { $0.loggedAt > $1.loggedAt }
    }

    public func delete(id: UUID) async throws {
        logs.removeAll { $0.id == id }
    }
}
