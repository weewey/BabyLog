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
    /// for the Apple Foundation Models backend. Kept minimal since Apple FM
    /// doesn't support tool calling — just identity + baby context.
    private func appleInstructions(profile: ChildProfile?) -> String? {
        guard let profile else {
            return "You are the BabyLog Assistant, a helpful baby tracking assistant. Be warm and brief."
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dob = fmt.string(from: profile.dateOfBirth)
        return "You are the BabyLog Assistant helping track baby \(profile.name) (born \(dob)). Be warm and brief."
    }
}
