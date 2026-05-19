import Foundation

public actor InMemoryFeedLogRepository: FeedLogRepository {
    private var storage: [FeedLog] = []

    public init() {}

    public func save(_ feed: FeedLog) async throws {
        storage.append(feed)
    }

    public func all() async throws -> [FeedLog] {
        storage.sorted { $0.loggedAt > $1.loggedAt }
    }

    public func delete(id: UUID) async throws {
        storage.removeAll { $0.id == id }
    }
}
