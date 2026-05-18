import Foundation

/// The kind of diaper-change event recorded in a `DiaperLog`.
public enum DiaperType: String, Sendable, Codable, Hashable, CaseIterable {
    case wet
    case dirty
    case both
}
