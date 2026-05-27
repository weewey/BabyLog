import Foundation

enum RelativeTime {

    /// Section-header label for a day bucket in a history list.
    ///
    /// - "Today"     — same calendar day as `reference`
    /// - "Yesterday" — the day before
    /// - "Monday"    — within the past 7 days (weekday name)
    /// - "May 26"    — older, same year as `reference`
    /// - "May 26, 2024" — different year
    static func sectionLabel(
        for date: Date,
        reference: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let startOfRef = calendar.startOfDay(for: reference)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDay, to: startOfRef).day ?? 0

        let fmt = DateFormatter()
        fmt.locale = .current
        if days < 7 {
            fmt.dateFormat = "EEEE" // "Monday"
        } else {
            let yearRef = calendar.component(.year, from: reference)
            let yearDay = calendar.component(.year, from: date)
            fmt.dateFormat = yearRef == yearDay ? "MMM d" : "MMM d, yyyy"
        }
        return fmt.string(from: date)
    }

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
