/// Errors produced during `DiaperLog` construction.
public enum DiaperLogError: Error, Sendable, Equatable {
    /// The supplied raw value did not match any known `DiaperType` case.
    case invalidType(String)
}
