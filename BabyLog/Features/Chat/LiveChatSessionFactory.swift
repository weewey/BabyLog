import Foundation
import BabyLogCore

/// Production `ChatSessionFactory` that returns real backend adapters.
///
/// - `.apple` → `AppleFMChatSession` (Apple Foundation Models, on-device).
///   Throws `AppleFMChatSessionError.unavailable` on simulators or
///   pre-iOS-26 hardware.
/// - `.gemma` → `Gemma4MLXChatSession` (Gemma 4 E2B via MLX Swift, ~1.5 GB).
///   Simulator throws `.unavailable`.
/// - `.qwen` → `QwenMLXChatSession` (Qwen 3.5 9B via MLX Swift, ~5 GB).
///   Simulator throws `.unsupportedDevice`.
struct LiveChatSessionFactory: ChatSessionFactory {

    func makeSession(for backend: ChatBackend) throws -> any ChatSession {
        switch backend {
        case .apple:
            #if canImport(FoundationModels)
            return try AppleFMChatSession()
            #else
            throw AppleFMChatSessionError.unavailable
            #endif
        case .gemma:
            return try Gemma4MLXChatSession()
        case .qwen:
            return try QwenMLXChatSession()
        }
    }
}
