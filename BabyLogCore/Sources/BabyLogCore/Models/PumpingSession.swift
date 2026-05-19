import Foundation

public enum PumpingSide: String, Sendable, Codable, CaseIterable, Equatable {
    case left
    case right
    case both
}

public enum PumpingSessionError: Error, Equatable, Sendable {
    case durationOutOfRange
    case volumeOutOfRange
    case notesTooLong
    case brandEmpty
}

public struct PumpingSession: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let durationMinutes: Int
    public let side: PumpingSide?
    public let milkVolumeMl: Int?
    public let pumpBrand: String
    public let scheduleSlotId: String?
    public let notes: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        durationMinutes: Int,
        side: PumpingSide? = nil,
        milkVolumeMl: Int? = nil,
        pumpBrand: String = "Medela",
        scheduleSlotId: String? = nil,
        notes: String? = nil
    ) throws(PumpingSessionError) {
        guard (1...120).contains(durationMinutes) else {
            throw PumpingSessionError.durationOutOfRange
        }
        if let milkVolumeMl {
            guard (0...500).contains(milkVolumeMl) else {
                throw PumpingSessionError.volumeOutOfRange
            }
        }
        let trimmedBrand = pumpBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBrand.isEmpty else {
            throw PumpingSessionError.brandEmpty
        }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes: String? = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        if let normalizedNotes, normalizedNotes.count > 500 {
            throw PumpingSessionError.notesTooLong
        }

        self.id = id
        self.startedAt = startedAt
        self.durationMinutes = durationMinutes
        self.side = side
        self.milkVolumeMl = milkVolumeMl
        self.pumpBrand = trimmedBrand
        self.scheduleSlotId = scheduleSlotId
        self.notes = normalizedNotes
    }
}
