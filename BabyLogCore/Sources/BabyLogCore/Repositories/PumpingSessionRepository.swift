import Foundation

public protocol PumpingSessionRepository: Sendable {
    func save(_ session: PumpingSession) async throws
    func update(_ session: PumpingSession) async throws
    func delete(id: UUID) async throws
    func all() async throws -> [PumpingSession]
    func recent(limit: Int) async throws -> [PumpingSession]
}

public actor InMemoryPumpingSessionRepository: PumpingSessionRepository {
    private var storage: [PumpingSession] = []

    public init() {}

    public func save(_ session: PumpingSession) async throws {
        storage.append(session)
    }

    public func update(_ session: PumpingSession) async throws {
        if let idx = storage.firstIndex(where: { $0.id == session.id }) {
            storage[idx] = session
        } else {
            storage.append(session)
        }
    }

    public func delete(id: UUID) async throws {
        storage.removeAll { $0.id == id }
    }

    public func all() async throws -> [PumpingSession] {
        storage.sorted { $0.startedAt > $1.startedAt }
    }

    public func recent(limit: Int) async throws -> [PumpingSession] {
        let sorted = storage.sorted { $0.startedAt > $1.startedAt }
        guard limit > 0 else { return [] }
        return Array(sorted.prefix(limit))
    }
}
