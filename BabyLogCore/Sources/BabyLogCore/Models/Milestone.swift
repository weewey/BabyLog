import Foundation

public enum MilestoneError: Error, Equatable {
    case emptyTitle
}

public struct Milestone: Sendable, Identifiable, Hashable, Codable {

    public let id: UUID
    public let title: String
    public let achievedAt: Date
    public let notes: String?

    public init(
        id: UUID = UUID(),
        title: String,
        achievedAt: Date,
        notes: String? = nil
    ) throws(MilestoneError) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        self.id = id
        self.title = trimmed
        self.achievedAt = achievedAt
        let tn = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = (tn?.isEmpty ?? true) ? nil : tn
    }
}
