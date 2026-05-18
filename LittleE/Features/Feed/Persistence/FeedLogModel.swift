import Foundation
import SwiftData

/// SwiftData persistence model for a single feeding session.
///
/// **CloudKit compatibility rules (CLAUDE.md CloudKit):**
/// - Every property must have a compile-time default OR be `Optional`.
/// - No required relationships.
/// - Field names are final once shipped — add new fields rather than rename.
@Model
final class FeedLogModel {

    // MARK: - Stored properties (all CloudKit-safe)

    /// Stable identity that mirrors `FeedLog.id`.
    var id: UUID = UUID()

    /// When the feed was logged.
    var loggedAt: Date = Date.distantPast

    /// Volume fed in millilitres.
    var volumeMl: Int = 0

    /// `FeedSource` persisted as a `String` for CloudKit scalar safety.
    /// Mapped manually since `FeedSource` is not `RawRepresentable`.
    /// Unrecognised values are treated as `"bottle"` during decoding.
    var sourceValue: String = "bottle"

    /// Optional free-form note; added in MVP pass, CloudKit-safe (Optional).
    var notes: String? = nil

    // MARK: - Init

    init(
        id: UUID = UUID(),
        loggedAt: Date = .distantPast,
        volumeMl: Int = 0,
        sourceValue: String = "bottle",
        notes: String? = nil
    ) {
        self.id = id
        self.loggedAt = loggedAt
        self.volumeMl = volumeMl
        self.sourceValue = sourceValue
        self.notes = notes
    }
}
