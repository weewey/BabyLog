import Foundation
import BabyLogCore

/// Production `ChatSessionFactory` that returns real backend adapters.
///
/// - `.apple` → `AppleFMChatSession` (Apple Foundation Models, on-device).
///   Throws `AppleFMChatSessionError.unavailable` on simulators or
///   pre-iOS-26 hardware.
/// - `.gemma` → `Gemma4MLXChatSession` (Gemma 4 E2B via MLX Swift, ~1.5 GB).
///   Simulator throws `.unavailable`.
/// - `.qwen` → `QwenMLXChatSession` (Qwen 3 4B via MLX Swift, ~2.3 GB).
///   Simulator throws `.unsupportedDevice`.
///
/// `profileLoader` is called on every `makeSession` call so each new
/// session sees the latest saved `ChildProfile` without requiring the
/// factory to be recreated when the user updates the child's name or DOB.
struct LiveChatSessionFactory: ChatSessionFactory {

    /// Returns the current child profile. Called synchronously on each
    /// `makeSession(for:)` call — keep it fast (in-memory SwiftData fetch).
    var profileLoader: @Sendable () -> ChildProfile? = { nil }

    func makeSession(for backend: ChatBackend) throws -> any ChatSession {
        let profile = profileLoader()
        switch backend {
        case .apple:
            #if canImport(FoundationModels)
            let instructions = appleInstructions(profile: profile)
            return try AppleFMChatSession(instructions: instructions)
            #else
            throw AppleFMChatSessionError.unavailable
            #endif
        case .gemma:
            return try Gemma4MLXChatSession(childProfile: profile)
        case .qwen:
            return try QwenMLXChatSession(childProfile: profile)
        }
    }

    /// Build the instructions string injected into `LanguageModelSession`
    /// for the Apple Foundation Models backend. Apple FM runs the logging
    /// tools itself, so the instructions cover identity, baby context, the
    /// local-time rule, and tool-use etiquette — kept compact because the
    /// on-device model has a tight (~4k token) context window.
    private func appleInstructions(profile: ChildProfile?) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        let now = fmt.string(from: Date())

        let who: String
        if let profile {
            let dobFmt = DateFormatter()
            dobFmt.dateFormat = "yyyy-MM-dd"
            dobFmt.locale = Locale(identifier: "en_US_POSIX")
            who = "You help track baby \(profile.name) (born \(dobFmt.string(from: profile.dateOfBirth)))."
        } else {
            who = "You help track a baby."
        }

        return """
        You are the BabyLog Assistant. \(who)
        The current local date and time is \(now); use local time for any dates \
        you pass to tools (no timezone suffix) and assume the time is now unless \
        the parent gives a specific time.
        Use the provided tools to log feeds, diapers, growth, milestones, \
        appointments, and pumping sessions, and to answer questions about them.
        Act immediately with sensible defaults — never ask the parent a \
        clarifying question for a routine log. A bare "dirty", "poo", "bm", or \
        "soiled" means a dirty diaper; "wet" means a wet diaper; assume now for \
        the time.
        If the parent mentions more than one thing (for example a diaper and a \
        feed), call a separate tool for each one.
        After logging, confirm what you did in one warm, brief sentence. Never \
        show internal record ids to the user.
        """
    }
}
