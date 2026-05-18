import Foundation
import Security

/// Typed error surface for `GitHubSyncTokenStore`. Callers switch on these
/// to decide whether to prompt for a new token, retry, or bail.
enum GitHubSyncTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case notFound
    case invalidData
}

/// Holds the configuration `GitHubSyncService` needs at runtime: the
/// `<owner>/<repo>` slug and the fine-grained PAT scoped to that repo.
struct GitHubSyncConfig: Equatable, Sendable {
    let repoSlug: String
    let token: String
}

/// Reads/writes the GitHub sync PAT and repo slug from the iOS Keychain.
/// The token is gated by `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so
/// it cannot be exfiltrated while the device is locked and never migrates
/// to a new device via iCloud backup. The repo slug lives in `UserDefaults`
/// since it isn't sensitive.
enum GitHubSyncTokenStore {

    /// Hard-coded private repo that backs the household sync. Both devices
    /// point at the same repo by construction, so the user only ever has
    /// to enter the fine-grained PAT — never a slug.
    static let repoSlug = "weewey/littlee-sync"

    private static let service = "ai.littlee.sync"
    private static let tokenAccount = "github_sync_pat"

    /// Best-effort load used at startup. Returns `nil` if the token is
    /// missing; the sync service then sits in `.idle` until the user
    /// pastes a PAT from Settings.
    ///
    /// In DEBUG builds, falls back to the `LITTLEE_GITHUB_SYNC_PAT` env var
    /// (forwarded via `SIMCTL_CHILD_LITTLEE_GITHUB_SYNC_PAT` from the smoke
    /// script). This sidesteps the simulator's `errSecMissingEntitlement`
    /// failure on Keychain writes for unsigned debug builds.
    static func load() -> GitHubSyncConfig? {
        if let token = try? readToken(), !token.isEmpty {
            return GitHubSyncConfig(repoSlug: repoSlug, token: token)
        }
        #if DEBUG
        if let fromEnv = ProcessInfo.processInfo.environment["LITTLEE_GITHUB_SYNC_PAT"],
           !fromEnv.isEmpty {
            try? writeToken(fromEnv)
            return GitHubSyncConfig(repoSlug: repoSlug, token: fromEnv)
        }
        #endif
        return nil
    }

    static func writeToken(_ token: String) throws(GitHubSyncTokenStoreError) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .unexpectedStatus(status)
        }
    }

    static func deleteAll() throws(GitHubSyncTokenStoreError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .unexpectedStatus(status)
        }
    }

    private static func readToken() throws(GitHubSyncTokenStoreError) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                throw .invalidData
            }
            return str
        case errSecItemNotFound:
            throw .notFound
        default:
            throw .unexpectedStatus(status)
        }
    }
}
