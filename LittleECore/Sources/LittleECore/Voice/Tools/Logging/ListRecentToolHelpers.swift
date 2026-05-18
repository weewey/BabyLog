import Foundation

/// Shared formatting + limit clamping used by the `listRecent*` tools.
/// Kept internal — the public surface is the individual tools.
enum ListRecentToolHelpers {

    static let defaultLimit = 5

    /// Return the caller-supplied limit when positive, otherwise fall
    /// back to `defaultLimit`. No upper clamp — the chat model decides
    /// how much history it needs to answer the user's question.
    static func resolveLimit(_ raw: Int?) -> Int {
        guard let raw, raw > 0 else { return defaultLimit }
        return raw
    }

    /// ISO8601 internet date-time (no fractional seconds) in UTC. Matches
    /// the format `ToolArguments.parseISO8601` round-trips cleanly.
    static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }}
