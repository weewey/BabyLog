import Foundation

/// Errors thrown when projecting `JSONValue` arguments into typed
/// accessors. The chat layer surfaces these to the model as a tool error
/// so it can retry with corrected arguments.
public enum ToolArgumentsError: Error, Equatable, Sendable {
    case missing(key: String)
    case typeMismatch(key: String, expected: String)
}

/// A thin wrapper over a decoded `[String: JSONValue]` that throws when
/// a caller asks for a missing or wrong-typed argument. Tools use this
/// to declaratively pull required and optional values out of the
/// argument blob a chat model produces.
public struct ToolArguments: Sendable, Equatable {

    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    // MARK: - Required accessors

    public func string(_ key: String) throws(ToolArgumentsError) -> String {
        guard let raw = values[key] else { throw .missing(key: key) }
        if case let .string(s) = raw { return s }
        throw .typeMismatch(key: key, expected: "string")
    }

    public func int(_ key: String) throws(ToolArgumentsError) -> Int {
        guard let raw = values[key] else { throw .missing(key: key) }
        switch raw {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && d <= Double(Int.max) && d >= Double(Int.min):
            return Int(d)
        default:
            throw .typeMismatch(key: key, expected: "integer")
        }
    }

    public func double(_ key: String) throws(ToolArgumentsError) -> Double {
        guard let raw = values[key] else { throw .missing(key: key) }
        switch raw {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default:
            throw .typeMismatch(key: key, expected: "number")
        }
    }

    public func bool(_ key: String) throws(ToolArgumentsError) -> Bool {
        guard let raw = values[key] else { throw .missing(key: key) }
        if case let .bool(b) = raw { return b }
        throw .typeMismatch(key: key, expected: "boolean")
    }

    public func date(_ key: String) throws(ToolArgumentsError) -> Date {
        let s = try string(key)
        guard let date = ToolArguments.parseISO8601(s) else {
            throw .typeMismatch(key: key, expected: "ISO8601 date string")
        }
        return date
    }

    // MARK: - Optional accessors

    public func optionalString(_ key: String) throws(ToolArgumentsError) -> String? {
        guard let raw = values[key] else { return nil }
        if case .null = raw { return nil }
        if case let .string(s) = raw { return s }
        throw .typeMismatch(key: key, expected: "string")
    }

    public func optionalInt(_ key: String) throws(ToolArgumentsError) -> Int? {
        guard let raw = values[key] else { return nil }
        if case .null = raw { return nil }
        return try int(key)
    }

    public func optionalDouble(_ key: String) throws(ToolArgumentsError) -> Double? {
        guard let raw = values[key] else { return nil }
        if case .null = raw { return nil }
        return try double(key)
    }

    public func optionalBool(_ key: String) throws(ToolArgumentsError) -> Bool? {
        guard let raw = values[key] else { return nil }
        if case .null = raw { return nil }
        return try bool(key)
    }

    public func optionalDate(_ key: String) throws(ToolArgumentsError) -> Date? {
        guard let raw = values[key] else { return nil }
        if case .null = raw { return nil }
        return try date(key)
    }

    // MARK: - ISO8601 helpers

    /// Parses an ISO8601 string with or without fractional seconds.
    /// Allocated per-call to keep the type Sendable without static
    /// `ISO8601DateFormatter` instances (which aren't Sendable).
    static func parseISO8601(_ string: String) -> Date? {
        // Resolve JavaScript/dynamic "now" expressions that models emit when
        // they mean the current time but forget they're not in a JS runtime.
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact "now" keywords.
        let nowKeywords: Set<String> = ["now", "NOW"]
        if nowKeywords.contains(trimmed) { return Date() }
        // Any JS Date runtime expression — covers new Date(), Date.now(),
        // new Date().toISOString(), new Date().toISOString().replace(...), etc.
        let jsDatePatterns = ["new Date(", "Date.now(", ".toISOString("]
        if jsDatePatterns.contains(where: { trimmed.contains($0) }) { return Date() }

        // All datetime args in this app are local times (the AI is explicitly
        // told to use the device's local time in the system prompt). If the
        // model appends a timezone specifier ("Z" or "+HH:MM") anyway — a
        // common LLM habit — strip it and interpret the value as local time
        // BEFORE falling through to the strict UTC parsers. This prevents a
        // feed logged at "9:31 AM local" from being stored as "9:31 AM UTC"
        // (which would be displayed as 5:31 PM local on a UTC+8 device and
        // grouped under the wrong calendar day).
        let naiveCandidate: String
        if trimmed.hasSuffix("Z") {
            naiveCandidate = String(trimmed.dropLast())
        } else if let plusIdx = trimmed.range(of: "+", options: .backwards),
                  trimmed.distance(from: plusIdx.lowerBound, to: trimmed.endIndex) <= 6 {
            naiveCandidate = String(trimmed[..<plusIdx.lowerBound])
        } else {
            naiveCandidate = trimmed
        }

        let naive = DateFormatter()
        naive.calendar = Calendar(identifier: .gregorian)
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = .current

        // Try the stripped candidate (or the original if nothing was stripped).
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd"
        ] {
            naive.dateFormat = format
            if let d = naive.date(from: naiveCandidate) { return d }
        }

        // Last resort: strict UTC ISO8601 (handles any legitimate Z-suffixed
        // string that didn't match the naive formats above).
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: string) { return d }

        return nil
    }
}
