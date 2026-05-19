import Foundation

public enum MedicalAppointmentError: Error, Equatable {
    case emptyTitle
}

public struct MedicalAppointment: Sendable, Identifiable, Hashable, Codable {

    public let id: UUID
    public let title: String
    public let scheduledAt: Date
    public let location: String?
    public let notes: String?

    public init(
        id: UUID = UUID(),
        title: String,
        scheduledAt: Date,
        location: String? = nil,
        notes: String? = nil
    ) throws(MedicalAppointmentError) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        self.id = id
        self.title = trimmed
        self.scheduledAt = scheduledAt
        self.location = location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
