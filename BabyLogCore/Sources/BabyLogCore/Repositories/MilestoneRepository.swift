import Foundation

public protocol MilestoneRepository: Sendable {
    func save(_ milestone: Milestone) async throws
    func all() async throws -> [Milestone]
    func delete(id: UUID) async throws
}

public actor InMemoryMilestoneRepository: MilestoneRepository {
    private var storage: [Milestone] = []
    public init() {}

    public func save(_ m: Milestone) async throws {
        if let i = storage.firstIndex(where: { $0.id == m.id }) {
            storage[i] = m
        } else {
            storage.append(m)
        }
    }

    public func all() async throws -> [Milestone] {
        storage.sorted { $0.achievedAt > $1.achievedAt }
    }

    public func delete(id: UUID) async throws {
        storage.removeAll { $0.id == id }
    }
}
