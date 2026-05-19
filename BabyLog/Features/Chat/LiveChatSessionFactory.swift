import Foundation
import LittleECore

/// Production `ChatSessionFactory` that returns real backend adapters.
///
/// - `.apple` → `AppleFMChatSession` (Apple Foundation Models, on-device).
///   Throws `AppleFMChatSessionError.unavailable` on simulators or
///   pre-iOS-26 hardware.
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
        case .gemma:
            return try Gemma4MLXChatSession()
        }
    }
}
