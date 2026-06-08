import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device Apple Foundation Models chat backend can actually run
/// on this device right now. Used to default the chat to the crash-immune
/// Apple FM backend (out-of-process, catchable errors) instead of the MLX
/// Gemma backend, which can `SIGABRT` uncatchably if the screen locks
/// mid-generation. See [[mlx-ios26-gpu-revoke-crash]].
enum AppleFMAvailability {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        return false
        #else
        return false
        #endif
    }
}
