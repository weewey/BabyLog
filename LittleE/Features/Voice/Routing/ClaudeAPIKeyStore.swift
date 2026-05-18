import Foundation
import Security

/// Typed error surface for `ClaudeAPIKeyStore`. Callers switch on these to
/// decide whether to prompt for a new key, retry, or bail.
enum ClaudeAPIKeyStoreError: Error, Equatable {
    /// Keychain returned a status code we did not expect. The raw `OSStatus`
    /// is carried for logging.
    case unexpectedStatus(OSStatus)
    /// Keychain had no matching item for our service/account pair.
    case notFound
    /// Keychain returned a blob that could not be decoded as UTF-8.
    case invalidData
}

/// Reads/writes the Anthropic API key from the iOS Keychain.
/// On first launch, falls back to a `BuildConfig.plist` (gitignored) and
/// migrates the key into the Keychain.
enum ClaudeAPIKeyStore {

    private static let service = "ai.littlee.voice"
    private static let account = "anthropic_api_key"

    /// Best-effort read used at app startup. Swallows errors on purpose — if
    /// the Keychain is unavailable or the key is missing, we simply return
    /// `nil` and let the voice flow surface `apiKeyMissing` to the user.
    static func load() -> String? {
        if let fromKeychain = try? readKeychain() { return fromKeychain }
        if let fromPlist = readBuildConfig() {
            try? writeKeychain(fromPlist)
            return fromPlist
        }
        #if DEBUG
        if let fromEnv = ProcessInfo.processInfo.environment["LITTLEE_CLAUDE_API_KEY"],
           !fromEnv.isEmpty {
            try? writeKeychain(fromEnv)
            return fromEnv
        }
        #endif
        return nil
    }

    /// Strict read used by settings UI / migrations. Throws on every failure
    /// mode so callers can distinguish "not configured" from "keychain broken".
    static func loadStrict() throws(ClaudeAPIKeyStoreError) -> String {
        try readKeychain()
    }

    static func writeKeychain(_ key: String) throws(ClaudeAPIKeyStoreError) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        // CLAUDE.md spec: the key must be unreadable while the device is
        // locked. `WhenUnlockedThisDeviceOnly` is stricter than
        // `AfterFirstUnlockThisDeviceOnly` (which stays readable until
        // reboot) and does not migrate to new devices via backups.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .unexpectedStatus(status)
        }
    }

    static func deleteKeychain() throws(ClaudeAPIKeyStoreError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .unexpectedStatus(status)
        }
    }

    private static func readKeychain() throws(ClaudeAPIKeyStoreError) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    private static func readBuildConfig() -> String? {
        guard let url = Bundle.main.url(forResource: "BuildConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["AnthropicAPIKey"] as? String,
              !key.isEmpty,
              key != "REPLACE_ME"
        else { return nil }
        return key
    }
}
