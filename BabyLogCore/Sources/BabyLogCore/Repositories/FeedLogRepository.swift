import Foundation

public protocol FeedLogRepository: Sendable {
    func save(_ feed: FeedLog) async throws
    func all() async throws -> [FeedLog]
    func delete(id: UUID) async throws
}
