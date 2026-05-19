import Foundation
import SwiftData

/// SwiftData persistence model for a single pumping session.
///
/// **CloudKit compatibility rules (CLAUDE.md CloudKit):**
/// - Every property must have a compile-time default OR be `Optional`.
/// - No required relationships.
/// - Field names are final once shipped — add new fields rather than rename.
@Model
final class PumpingSessionModel {

    // MARK: - Stored properties (all CloudKit-safe)

    /// Stable identity that mirrors `PumpingSession.id`.
    var id: UUID = UUID()

    /// When the session started.
    var startedAt: Date = Date.distantPast

    /// Duration in minutes (Core domain enforces 1...120 on decode).
    var durationMinutes: Int = 0

    /// `PumpingSide` persisted as raw `String` (nil = unspecified).
    var sideValue: String? = nil

    /// Milk volume in millilitres. `nil` means not recorded.
    var milkVolumeMl: Int? = nil

    /// Free-form pump brand label; defaults to "Medela" matching the template.
    var pumpBrand: String = "Medela"

    /// Optional id of the schedule slot this session satisfies.
    var scheduleSlotId: String? = nil

    /// Optional free-form notes.
    var notes: String? = nil

    // MARK: - Init

    init(
        id: UUID = UUID(),
        startedAt: Date = .distantPast,
        durationMinutes: Int = 0,
        sideValue: String? = nil,
        milkVolumeMl: Int? = nil,
        pumpBrand: String = "Medela",
        scheduleSlotId: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationMinutes = durationMinutes
        self.sideValue = sideValue
        self.milkVolumeMl = milkVolumeMl
        self.pumpBrand = pumpBrand
        self.scheduleSlotId = scheduleSlotId
        self.notes = notes
    }
}
