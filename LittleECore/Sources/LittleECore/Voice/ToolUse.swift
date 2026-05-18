import Foundation

// MARK: - Per-intent draft structs
//
// All slots are optional: the speech model may not have heard everything,
// and the user fills in / corrects the rest in the confirmation sheet.

public struct FeedDraft: Hashable, Sendable {
    public var volumeMl: Int?
    public var loggedAt: Date?
    public var source: FeedSource?
    public var notes: String?

    public init(
        volumeMl: Int? = nil,
        loggedAt: Date? = nil,
        source: FeedSource? = nil,
        notes: String? = nil
    ) {
        self.volumeMl = volumeMl
        self.loggedAt = loggedAt
        self.source = source
        self.notes = notes
    }
}

public struct DiaperDraft: Hashable, Sendable {
    public var type: DiaperType?
    public var loggedAt: Date?
    public var notes: String?

    public init(
        type: DiaperType? = nil,
        loggedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.type = type
        self.loggedAt = loggedAt
        self.notes = notes
    }
}

public struct GrowthDraft: Hashable, Sendable {
    public var date: Date?
    public var weightGrams: Int?
    public var heightCm: Double?
    public var headCircumferenceCm: Double?
    public var notes: String?

    public init(
        date: Date? = nil,
        weightGrams: Int? = nil,
        heightCm: Double? = nil,
        headCircumferenceCm: Double? = nil,
        notes: String? = nil
    ) {
        self.date = date
        self.weightGrams = weightGrams
        self.heightCm = heightCm
        self.headCircumferenceCm = headCircumferenceCm
        self.notes = notes
    }
}

public struct AppointmentDraft: Hashable, Sendable {
    public var title: String?
    public var scheduledAt: Date?
    public var location: String?
    public var notes: String?

    public init(
        title: String? = nil,
        scheduledAt: Date? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.scheduledAt = scheduledAt
        self.location = location
        self.notes = notes
    }
}

public struct MilestoneDraft: Hashable, Sendable {
    public var title: String?
    public var achievedAt: Date?
    public var notes: String?

    public init(
        title: String? = nil,
        achievedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.achievedAt = achievedAt
        self.notes = notes
    }
}

// MARK: - ToolUse

/// One structured logging action the assistant wants to take on the baby log.
/// Corresponds to a single `tool_use` block in the Claude API's message
/// content. The model may return zero, one, or several of these in a turn
/// alongside optional free-text reply content (see `AssistantResponse`).
public enum ToolUse: Hashable, Sendable {
    case feed(FeedDraft)
    case diaper(DiaperDraft)
    case growth(GrowthDraft)
    case appointment(AppointmentDraft)
    case milestone(MilestoneDraft)
    case unknown(reason: String)
}

// MARK: - AssistantResponse

/// A single turn returned by `LittleEAssistant.respond(to:)`. May carry
/// free-text the assistant said to the user, logging actions it wants to
/// perform, or both in one turn (e.g. "logged 120 ml — Ethan's at 450 ml
/// today" alongside a `.feed` tool use).
public struct AssistantResponse: Hashable, Sendable {
    /// Natural-language reply. Empty string when the model called tools
    /// without narrating — callers should treat `""` the same as "no answer".
    public var answer: String
    /// Logging actions the model proposes. Empty when the model only replied
    /// with text. Order matches the model's message content order.
    public var toolUses: [ToolUse]

    public init(answer: String = "", toolUses: [ToolUse] = []) {
        self.answer = answer
        self.toolUses = toolUses
    }

    /// Convenience: a response that contains only free-text and no tool uses.
    public static func answer(_ text: String) -> AssistantResponse {
        AssistantResponse(answer: text, toolUses: [])
    }

    /// Convenience: a response that contains a single tool use and no answer.
    public static func toolUse(_ toolUse: ToolUse) -> AssistantResponse {
        AssistantResponse(answer: "", toolUses: [toolUse])
    }
}

// MARK: - Errors

/// Typed error surface for `LittleEAssistant` implementations. Callers switch on
/// these to render user-facing copy and decide whether to retry.
public enum AssistantError: Error, Equatable, Sendable {
    /// No API key configured (Keychain empty and no BuildConfig fallback).
    case apiKeyMissing
    /// Transient connectivity / HTTP 5xx failure after retries exhausted.
    case network
    /// Request did not complete within its deadline.
    case timeout
    /// HTTP 429 from the upstream service.
    case rateLimited
    /// Response shape did not match what the parser expects.
    case decoding
    /// HTTP 401/403 — the configured key was rejected.
    case unauthenticated
    /// Any other non-2xx response we do not specifically handle.
    case invalidResponse
    /// Catch-all for bugs we did not foresee.
    case unknown
}

// MARK: - Protocol

public protocol LittleEAssistant: Sendable {
    func respond(to transcript: String) async throws(AssistantError) -> AssistantResponse
}
