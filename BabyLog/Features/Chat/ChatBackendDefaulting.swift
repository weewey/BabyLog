import Foundation
import BabyLogCore

/// Resolves the chat tab's default backend and performs a one-time migration
/// of existing Gemma/Qwen users onto Apple Foundation Models when it's
/// available.
///
/// The MLX (Gemma/Qwen) backends run Metal in-process and can crash
/// uncatchably if the device locks mid-generation (iOS 26 GPU revoke). Apple
/// FM runs out-of-process and only ever throws, so it's the safe default on
/// any Apple-Intelligence-capable device. Gemma stays selectable in the
/// picker for anyone who explicitly wants it.
enum ChatBackendDefaulting {

    static let selectedBackendKey = "chat.selectedBackend"
    /// Bumping the version re-runs the migration once for existing installs.
    static let migrationKey = "chat.appleDefaultMigration.v1"

    /// Returns the backend to use when no explicit selection is stored, and —
    /// once per install, when Apple FM is available — moves any stored
    /// non-Apple selection onto Apple FM.
    @discardableResult
    static func resolveDefault(
        store: any ChatBackendPreferenceStore,
        appleAvailable: Bool
    ) -> ChatBackend {
        if appleAvailable, store.string(forKey: migrationKey) == nil {
            if let stored = store.string(forKey: selectedBackendKey),
               stored != ChatBackend.apple.rawValue {
                // Existing Gemma/Qwen user → switch to crash-immune Apple FM.
                store.set(ChatBackend.apple.rawValue, forKey: selectedBackendKey)
            }
            store.set("done", forKey: migrationKey)
        }
        return appleAvailable ? .apple : .gemma
    }
}
