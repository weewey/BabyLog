import Foundation
import LittleECore

/// Production `ChatSessionFactory` that returns real backend adapters.
///
/// - `.apple` → `AppleFMChatSession` (Apple Foundation Models, on-device).
///   Throws `AppleFMChatSessionError.unavailable` on simulators or
///   pre-iOS-26 hardware.
/// - `.claude` → `ClaudeChatSession` (SSE over HTTPS). Reads the API key
///   from `ClaudeAPIKeyStore` at stream start; surfaces
///   `ChatSessionError.apiKeyMissing` if absent so the UI can prompt.
/// - `.gemma` → `Gemma4MLXChatSession` (Gemma 4 E2B via MLX Swift).
///   Simulator throws `.unavailable`; on device, the first turn downloads
///   ~1 GB of quantised weights before the first token arrives.
struct LiveChatSessionFactory: ChatSessionFactory {

    func makeSession(for backend: ChatBackend) throws -> any ChatSession {
        switch backend {
        case .apple:
            #if canImport(FoundationModels)
            return try AppleFMChatSession()
            #else
            throw AppleFMChatSessionError.unavailable
            #endif
        case .claude:
            return ClaudeChatSession()
        case .gemma:
            return try Gemma4MLXChatSession()
        case .qwen:
            // llama.cpp-backed Qwen 2.5 1.5B-Instruct. Scaffolding only —
            // the real backend is guarded behind `canImport(LlamaSwift)` until
            // the owner adds the llama.cpp SPM dependency to the Xcode
            // project. Until then, `QwenLlamaCppChatSession()` throws
            // `.unsupportedDevice` on every call so the UI can surface a
            // "not configured" alert instead of hanging.
            return try QwenLlamaCppChatSession(loader: LiveQwenModelLoader())
        }
    }
}
