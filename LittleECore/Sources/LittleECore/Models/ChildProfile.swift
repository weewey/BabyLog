import Foundation

public enum ChildProfileError: Error, Equatable {
    case emptyName
    case futureDateOfBirth
}

/// Identity and demographic info for the tracked child.
/// Always a single record per device; higher layers decide how to store it.
public struct ChildProfile: Sendable, Hashable, Codable {

    public let name: String
    public let dateOfBirth: Date

    public init(name: String, dateOfBirth: Date, now: Date = Date()) throws(ChildProfileError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard dateOfBirth <= now else { throw .futureDateOfBirth }
        self.name = trimmed
        self.dateOfBirth = dateOfBirth
    }
}

/// Pure functions for age rendering — no Date() calls, no I/O.
public enum ChildAge {

    /// Compact label like "3d", "2w 1d", "5mo 2w", "1y 3mo" used in header chips.
    public static func shortLabel(dateOfBirth: Date, now: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .weekOfMonth, .day], from: dateOfBirth, to: now)
        let y = components.year ?? 0
        let mo = components.month ?? 0
        if y >= 1 {
            return mo > 0 ? "\(y)y \(mo)mo" : "\(y)y"
        }
        if mo >= 1 {
            let extraWeeks = (components.weekOfMonth ?? 0)
            return extraWeeks > 0 ? "\(mo)mo \(extraWeeks)w" : "\(mo)mo"
        }
        let totalDays = calendar.dateComponents([.day], from: dateOfBirth, to: now).day ?? 0
        if totalDays >= 7 {
            let weeks = totalDays / 7
            let days = totalDays % 7
            return days > 0 ? "\(weeks)w \(days)d" : "\(weeks)w"
        }
        return "\(max(totalDays, 0))d"
    }
}
