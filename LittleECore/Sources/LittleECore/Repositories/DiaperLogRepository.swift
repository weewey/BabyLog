import Foundation

/// Persistence abstraction for diaper-change entries.
public protocol DiaperLogRepository: Sendable {

    func save(_ log: DiaperLog) async throws

    func all() async throws -> [DiaperLog]

    func delete(id: UUID) async throws
}
