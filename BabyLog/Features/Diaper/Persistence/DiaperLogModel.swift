import Foundation
import SwiftData

/// SwiftData persistence model for a single diaper-change event.
///
/// **CloudKit compatibility rules (CLAUDE.md CloudKit):**
/// - Every property must have a compile-time default OR be `Optional`.
/// - No required relationships.
/// - Field names are final once shipped — add new fields rather than rename.
@Model
final class DiaperLogModel {

    // MARK: - Stored properties (all CloudKit-safe)

    /// Stable identity that mirrors `DiaperLog.id`.
    var id: UUID = UUID()

    /// When the diaper change was logged.
    var loggedAt: Date = Date.distantPast

    /// `DiaperType` persisted as a `String` for CloudKit scalar safety.
    /// Unrecognised values are treated as `"wet"` during decoding.
    var typeValue: String = "wet"

    /// Optional free-text notes about the diaper change.
    var notes: String?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        loggedAt: Date = .distantPast,
        typeValue: String = "wet",
        notes: String? = nil
    ) {
        self.id = id
        self.loggedAt = loggedAt
        self.typeValue = typeValue
        self.notes = notes
    }
}
