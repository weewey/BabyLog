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

    /// Human-readable date-time in the device's local timezone, e.g.
    /// "May 27, 9:31 AM". Used in tool-result strings the AI reads back
    /// to the user, so local time is always correct and unambiguous.
    /// Note: tool *arguments* (input) still use ISO8601 UTC via
    /// `ToolArguments.parseISO8601` — this is output-only.
    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }}
