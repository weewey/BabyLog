import Foundation

public struct PumpingScheduleSlot: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let emoji: String
    public let startHour: Int
    public let startMinute: Int
    public let endHour: Int
    public let endMinute: Int

    public init(
        id: String,
        label: String,
        emoji: String,
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int
    ) {
        self.id = id
        self.label = label
        self.emoji = emoji
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    public var isNight: Bool { FeedLogAnalytics.isNightHour(startHour) }

    /// Minute-of-day of the slot start (0...1439).
    public var startMinuteOfDay: Int { startHour * 60 + startMinute }
}

public struct PumpingScheduleTemplate: Equatable, Sendable {
    public let id: String
    public let name: String
    public let pumpBrand: String
    public let targetSessionsPerDay: Int
    public let averageDurationMinutes: Int
    public let slots: [PumpingScheduleSlot]

    public init(
        id: String,
        name: String,
        pumpBrand: String,
        targetSessionsPerDay: Int,
        averageDurationMinutes: Int,
        slots: [PumpingScheduleSlot]
    ) {
        self.id = id
        self.name = name
        self.pumpBrand = pumpBrand
        self.targetSessionsPerDay = targetSessionsPerDay
        self.averageDurationMinutes = averageDurationMinutes
        self.slots = slots
    }

    public static let medelaEightSessionNewborn = PumpingScheduleTemplate(
        id: "medela-8-newborn",
        name: "Medela · 8 sessions · newborn",
        pumpBrand: "Medela",
        targetSessionsPerDay: 8,
        averageDurationMinutes: 20,
        slots: [
            PumpingScheduleSlot(id: "night",         label: "Night session", emoji: "⭐", startHour: 3,  startMinute: 0,  endHour: 4,  endMinute: 0),
            PumpingScheduleSlot(id: "morning-rise",  label: "Morning rise",  emoji: "🌅", startHour: 8,  startMinute: 30, endHour: 9,  endMinute: 30),
            PumpingScheduleSlot(id: "midday",        label: "Midday",        emoji: "⛅", startHour: 11, startMinute: 30, endHour: 12, endMinute: 30),
            PumpingScheduleSlot(id: "afternoon",     label: "Afternoon",     emoji: "🌼", startHour: 14, startMinute: 30, endHour: 15, endMinute: 30),
            PumpingScheduleSlot(id: "early-evening", label: "Early evening", emoji: "🌇", startHour: 17, startMinute: 0,  endHour: 18, endMinute: 0),
            PumpingScheduleSlot(id: "evening",       label: "Evening",       emoji: "🌙", startHour: 19, startMinute: 30, endHour: 20, endMinute: 30),
            PumpingScheduleSlot(id: "late-evening",  label: "Late evening",  emoji: "🌘", startHour: 21, startMinute: 30, endHour: 22, endMinute: 30),
            PumpingScheduleSlot(id: "pre-sleep",     label: "Pre-sleep",     emoji: "💤", startHour: 23, startMinute: 0,  endHour: 0,  endMinute: 0),
        ]
    )

    public static let tipsRotation: [String] = [
        "Prolactin peaks 1–5 AM — the night session really matters.",
        "Double pumping cuts session time and boosts yield.",
        "Hands-on compressions can add 50 ml to a session.",
        "Stay hydrated — aim for a full glass of water each session.",
        "Warm compresses before pumping can speed let-down.",
        "A photo of your baby while pumping can help let-down.",
    ]

    public static func tipOfDay(for date: Date, calendar: Calendar = .current) -> String {
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let index = abs(dayOfYear.hashValue) % tipsRotation.count
        return tipsRotation[index]
    }
}
