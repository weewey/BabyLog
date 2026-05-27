import Foundation

/// Tool wrapping `PumpingSessionRepository.update` to patch an existing pumping session.
/// The session can be identified three ways (in priority order):
///   1. `id` — explicit UUID (most precise)
///   2. `mostRecent: true` — the most recently logged session
///   3. `time` — time string like "09:30" or "9:30am"; picks the session closest to that time today
/// Only fields supplied in arguments are changed; omitted fields are left as-is.
public struct UpdatePumpingSessionTool: ChatTool {

    public let name = "updatePumpingSession"
    public let description = """
        Update an existing pumping session. Identify the session with ONE of: \
        'id' (UUID), 'mostRecent: true' (the last session logged), or 'time' (e.g. "09:30" / "9:30am" \
        — picks the session closest to that time today). Only fields supplied are changed; omitted fields are left as-is.
        """
    public let requiresConfirmation = false

    public let inputSchema = ToolInputSchema(
        properties: [
            ("id", .init(type: .string, description: "UUID of the pumping session to update. Omit if using mostRecent or time.")),
            ("mostRecent", .init(type: .boolean, description: "Set true to update the most recently logged session (e.g. 'the last pump', 'the previous one').")),
            ("time", .init(type: .string, description: "Time of the session to update, e.g. \"09:30\" or \"9:30am\". Picks the session closest to that time today.")),
            ("startedAt", .init(type: .dateTime, description: "Updated date-time.")),
            ("durationMinutes", .init(type: .integer, description: "New duration in minutes (1–120).")),
            ("side", .init(type: .string, description: "New side.", enumValues: PumpingSide.allCases.map(\.rawValue))),
            ("milkVolumeMl", .init(type: .integer, description: "New milk volume in millilitres (0–500).")),
            ("notes", .init(type: .string, description: "New notes, max 500 characters.")),
        ],
        required: []
    )

    private let repository: any PumpingSessionRepository

    public init(repository: any PumpingSessionRepository) {
        self.repository = repository
    }

    public func execute(arguments: ToolArguments) async throws -> ToolResult {
        let all = try await repository.all()
        let existing = try Self.resolveEntry(from: arguments, all: all)
        let id = existing.id

        let newStartedAt = try arguments.optionalDate("startedAt") ?? existing.startedAt
        let newDuration = try arguments.optionalInt("durationMinutes") ?? existing.durationMinutes
        let sideRaw = try arguments.optionalString("side")
        let newSide: PumpingSide? = sideRaw.flatMap { PumpingSide(rawValue: $0) } ?? existing.side
        let newVolume = try arguments.optionalInt("milkVolumeMl") ?? existing.milkVolumeMl
        let newNotes = try arguments.optionalString("notes") ?? existing.notes

        let updated = try PumpingSession(
            id: id,
            startedAt: newStartedAt,
            durationMinutes: newDuration,
            side: newSide,
            milkVolumeMl: newVolume,
            pumpBrand: existing.pumpBrand,
            scheduleSlotId: existing.scheduleSlotId,
            notes: newNotes
        )
        try await repository.update(updated)

        return ToolResult(content: "Updated pumping session \(id.uuidString).")
    }

    // MARK: - Entry resolution

    private static func resolveEntry(from arguments: ToolArguments, all sessions: [PumpingSession]) throws -> PumpingSession {
        // 1. Explicit UUID
        if let idString = try arguments.optionalString("id") {
            guard let id = UUID(uuidString: idString) else {
                throw ChatToolError.executionFailed("Argument 'id' is not a valid UUID: \(idString)")
            }
            guard let session = sessions.first(where: { $0.id == id }) else {
                throw ChatToolError.executionFailed("No pumping session found with id \(idString).")
            }
            return session
        }

        // 2. mostRecent
        if (try arguments.optionalBool("mostRecent")) == true {
            guard let session = sessions.max(by: { $0.startedAt < $1.startedAt }) else {
                throw ChatToolError.executionFailed("No pumping sessions found.")
            }
            return session
        }

        // 3. time string — find closest to that time today
        if let timeString = try arguments.optionalString("time") {
            guard let target = parseTimeToday(timeString) else {
                throw ChatToolError.executionFailed("Could not parse time '\(timeString)'. Use a format like \"09:30\" or \"9:30am\".")
            }
            guard let session = sessions.min(by: {
                abs($0.startedAt.timeIntervalSince(target)) < abs($1.startedAt.timeIntervalSince(target))
            }) else {
                throw ChatToolError.executionFailed("No pumping sessions found near \(timeString).")
            }
            return session
        }

        throw ChatToolError.executionFailed(
            "Provide one of 'id' (UUID), 'mostRecent: true', or 'time' (e.g. \"09:30\") to identify the session."
        )
    }

    /// Parses a time-only string and returns a Date set to today at that hour+minute.
    private static func parseTimeToday(_ timeString: String) -> Date? {
        let trimmed = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        for (format, locale) in timeFormats {
            fmt.dateFormat = format
            fmt.locale = locale
            if let parsed = fmt.date(from: trimmed) {
                let cal = Calendar.current
                let comps = cal.dateComponents([.hour, .minute, .second], from: parsed)
                return cal.date(bySettingHour: comps.hour ?? 0,
                                minute: comps.minute ?? 0,
                                second: comps.second ?? 0,
                                of: Date())
            }
        }
        return nil
    }

    private static let timeFormats: [(String, Locale)] = [
        ("HH:mm:ss", Locale(identifier: "en_US_POSIX")),
        ("HH:mm",    Locale(identifier: "en_US_POSIX")),
        ("h:mm a",   .current),
        ("h:mma",    .current),
        ("h:mm",     .current),
    ]
}
