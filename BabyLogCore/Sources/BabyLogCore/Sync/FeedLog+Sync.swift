import Foundation

// MARK: - Wire shape

/// Codable projection of a `FeedLog` used as the on-wire event payload.
///
/// Kept separate from the domain type because `FeedLog`'s initialiser
/// validates (e.g. rejects volumes > 500 ml). Corrupt peer data must
/// decode cleanly so we can reject it at `fromWire` time rather than
/// crashing the decoder.
public struct FeedLogWire: Codable, Hashable, Sendable {
    public let id: UUID
    public let volumeMl: Int
    public let loggedAt: Date
    public let source: FeedSource
    public let notes: String?
}

// MARK: - SyncableDomain conformance

extension FeedLog: SyncableDomain {

    public static var kind: DomainEventKind { .feedLog }
    public static var schemaVersion: Int { 1 }

    public var syncID: String { id.uuidString }

    public func toWire() -> FeedLogWire {
        FeedLogWire(
            id: id,
            volumeMl: volumeMl,
            loggedAt: loggedAt,
            source: source,
            notes: notes
        )
    }

    public static func fromWire(_ wire: FeedLogWire) -> FeedLog? {
        try? FeedLog(
            id: wire.id,
            volumeMl: wire.volumeMl,
            loggedAt: wire.loggedAt,
            source: wire.source,
            notes: wire.notes
        )
    }
}

// MARK: - Back-compat codec shim

/// Historical symbol kept so callers that directly encode/decode feed
/// payloads (notably `EventSourcedFeedLogRepositoryTests.mergeAcrossDevices`)
/// keep compiling after the generic refactor. New code should use
/// `SyncableDomainCodec` directly.
public enum FeedLogEventCodec {
    public static func encode(_ feed: FeedLog) throws -> Data {
        try SyncableDomainCodec.encode(feed)
    }

    public static func decode(_ data: Data) -> FeedLog? {
        SyncableDomainCodec.decode(FeedLog.self, from: data, schemaVersion: FeedLog.schemaVersion)
    }
}
