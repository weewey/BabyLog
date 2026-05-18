import Foundation

public struct FeedLog: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let volumeMl: Int
    public let loggedAt: Date
    public let source: FeedSource
    public let notes: String?

    public init(
        id: UUID = UUID(),
        volumeMl: Int,
        loggedAt: Date,
        source: FeedSource,
        notes: String? = nil
    ) throws(FeedLogError) {
        guard (1...500).contains(volumeMl) else {
            throw FeedLogError.volumeOutOfRange
        }
        self.id = id
        self.volumeMl = volumeMl
        self.loggedAt = loggedAt
        self.source = source
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
