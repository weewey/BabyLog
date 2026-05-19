import Foundation

// MARK: - Repository protocol

public protocol GrowthMeasurementRepository: Sendable {
    /// Persist (or overwrite) a measurement keyed by its ID.
    func save(_ measurement: GrowthMeasurement) async throws

    /// Return every stored measurement in insertion-stable order.
    func all() async throws -> [GrowthMeasurement]

    /// Remove the measurement whose underlying UUID matches. No-op if absent.
    func delete(id: UUID) async throws
}

// MARK: - In-memory implementation

public actor InMemoryGrowthMeasurementRepository: GrowthMeasurementRepository {
    private var store: [GrowthMeasurementID: GrowthMeasurement] = [:]
    /// Tracks insertion order so `all()` is deterministic.
    private var insertionOrder: [GrowthMeasurementID] = []

    public init() {}

    public func save(_ measurement: GrowthMeasurement) async throws {
        if store[measurement.id] == nil {
            insertionOrder.append(measurement.id)
        }
        store[measurement.id] = measurement
    }

    public func all() async throws -> [GrowthMeasurement] {
        insertionOrder.compactMap { store[$0] }
    }

    public func delete(id: UUID) async throws {
        let key = GrowthMeasurementID(id)
        store.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }
}
