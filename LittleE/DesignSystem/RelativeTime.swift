import Foundation

enum RelativeTime {

    /// Short, compact relative label e.g. "just now", "5m ago", "2h 15m ago", "3d ago".
    /// Falls back to absolute time if older than 7 days.
    static func shortLabel(for date: Date, reference: Date = Date()) -> String {
        let interval = reference.timeIntervalSince(date)
        if interval < 0 {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        let seconds = Int(interval)
        if seconds < 45 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remMins = minutes % 60
        if hours < 24 {
            return remMins == 0 ? "\(hours)h ago" : "\(hours)h \(remMins)m ago"
        }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
