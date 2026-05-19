import Foundation

/// An immutable record of a single diaper-change event.
///
/// Construction always requires a concrete `DiaperType` value; a second
/// raw-value initialiser validates the string at build time and throws
/// `DiaperLogError.invalidType` when the value is unrecognised.
public struct DiaperLog: Sendable, Identifiable, Hashable, Codable {

    public let id: UUID
    public let type: DiaperType
    public let loggedAt: Date
    public let notes: String?

    // MARK: - Initialisers

    /// Designated initialiser. Caller supplies a fully typed `DiaperType`
    /// — always succeeds, no throws needed.
    public init(
        id: UUID,
        type: DiaperType,
        loggedAt: Date,
        notes: String? = nil
    ) {
        self.id = id
        self.type = type
        self.loggedAt = loggedAt
        self.notes = notes
    }

    /// Raw-value initialiser. Validates `typeRawValue` against the known
    /// `DiaperType` cases; throws `DiaperLogError.invalidType` on failure.
    public init(
        id: UUID,
        typeRawValue: String,
        loggedAt: Date,
        notes: String? = nil
    ) throws(DiaperLogError) {
        guard let resolvedType = DiaperType(rawValue: typeRawValue) else {
            throw DiaperLogError.invalidType(typeRawValue)
        }
        self.id = id
        self.type = resolvedType
        self.loggedAt = loggedAt
        self.notes = notes
    }
}
