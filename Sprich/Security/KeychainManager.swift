import Foundation
import Security

/// Secure storage for API keys using macOS Data Protection Keychain.
/// Keys are never stored in UserDefaults or plaintext on disk.
/// Uses kSecUseDataProtectionKeychain to avoid the legacy login-keychain
/// password prompt entirely — access is scoped by code-signing identity.
enum KeychainManager {

    private static let service = "com.niconuscheler.sprich"

    /// Store a value securely in the Data Protection Keychain.
    @discardableResult
    static func store(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a value from the Data Protection Keychain.
    static func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Delete a value from the Data Protection Keychain.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists in the Keychain.
    static func exists(key: String) -> Bool {
        return retrieve(key: key) != nil
    }

    // MARK: - Legacy Keychain Migration

    private static let migrationFlag = "sprich.keychainMigrationDone"

    private static let allKnownKeys = [
        "sprich.api.groq",
        "sprich.api.openai",
        "sprich.api.deepgram",
        "sprich.api.anthropic",
        "sprich.api.google",
    ]

    /// Migrate API keys from the legacy login keychain to the Data Protection
    /// Keychain. Call once at app launch, before any other keychain access.
    /// Runs only once — guarded by a UserDefaults flag.
    static func migrateFromLegacyKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return }

        for key in allKnownKeys {
            if let value = legacyRetrieve(key: key) {
                store(key: key, value: value)
                legacyDelete(key: key)
            }
        }

        UserDefaults.standard.set(true, forKey: migrationFlag)
    }

    // MARK: - Legacy helpers (no kSecUseDataProtectionKeychain)

    private static func legacyRetrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private static func legacyDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
