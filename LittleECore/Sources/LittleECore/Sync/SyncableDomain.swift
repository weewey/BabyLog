import Foundation

/// A domain type that can be stored in the append-only event log and
/// synced across devices.
///
/// Each conforming type supplies:
/// - a `Wire` shape (plain `Codable` struct) used on the wire and in storage
/// - a `kind` tag so the projection can filter the shared log
/// - a `schemaVersion` for forward/backward compatibility
/// - a `syncID` — the stable record identifier used as `DomainEvent.recordID`
/// - a `toWire` / `fromWire` pair that converts between the domain type and
///   its wire shape. `fromWire` returns `nil` when the payload fails domain
///   validation so the projection can drop corrupt events without crashing.
public protocol SyncableDomain: Sendable, Hashable {
    associatedtype Wire: Codable & Hashable & Sendable

    static var kind: DomainEventKind { get }
    static var schemaVersion: Int { get }
    /// Optional migration hook. Given a wire payload from an older schema
    /// version, return the same payload upgraded to `schemaVersion`. Default
    /// is an identity passthrough — domains only override this when they
    /// have a non-additive schema change.
    static func migrate(payload: Data, fromVersion: Int) -> Data?

    var syncID: String { get }
    func toWire() -> Wire
    static func fromWire(_ wire: Wire) -> Self?
}

public extension SyncableDomain {
    static func migrate(payload: Data, fromVersion: Int) -> Data? {
        // No migration needed by default — the payload is already at the
        // current schema, or the difference is purely additive and the
        // decoder will handle missing/optional fields.
        payload
    }
}

/// JSON codec shared by every `SyncableDomain`. Domains don't roll their
/// own encoder/decoder — they just describe their `Wire` shape and this
/// enum handles the bytes.
public enum SyncableDomainCodec {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<D: SyncableDomain>(_ domain: D) throws -> Data {
        try encoder.encode(domain.toWire())
    }

    public static func decode<D: SyncableDomain>(
        _ type: D.Type,
        from data: Data,
        schemaVersion: Int
    ) -> D? {
        let upgraded: Data
        if schemaVersion == D.schemaVersion {
            upgraded = data
        } else {
            guard let migrated = D.migrate(payload: data, fromVersion: schemaVersion) else {
                return nil
            }
            upgraded = migrated
        }
        guard let wire = try? decoder.decode(D.Wire.self, from: upgraded) else {
            return nil
        }
        return D.fromWire(wire)
    }
}
