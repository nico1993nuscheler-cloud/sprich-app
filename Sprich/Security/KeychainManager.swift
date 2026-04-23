import Foundation
import Security

/// Secure storage for API keys using macOS Keychain.
/// Keys are never stored in UserDefaults or plaintext on disk.
enum KeychainManager {

    private static let service = "com.niconuscheler.sprich"

    /// Store a value securely in the Keychain.
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
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a value from the Keychain.
    ///
    /// The real "no prompt on install" behavior (182a558) is that
    /// we never `retrieve()` an item the app didn't `store()` itself,
    /// so on a fresh install there's nothing to prompt about.
    ///
    /// `kSecUseAuthenticationUI = .fail` is a safety net on top of
    /// that: if a Sprich keychain item exists but can only be read
    /// by a different code-signing identity (e.g. stale items left
    /// over from a prior ad-hoc `xcodebuild` in dev, or a future
    /// re-signing with a proper Developer ID), return nil silently
    /// instead of surfacing the ACL "Always Allow / Deny" dialog.
    /// The app then routes the user back into Settings, and
    /// `store()` rewrites the item under the current signature.
    ///
    /// The proper cross-signature solution is the Data Protection
    /// Keychain (tried in 535d9bd, reverted in 182a558) — it requires
    /// the keychain-access-groups entitlement, which needs a paid
    /// Apple Developer ID (P1-INF-01).
    static func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            // errSecInteractionNotAllowed (-25308) = item exists but its
            // ACL would require UI. Treated identically to "not found".
            return nil
        }

        return string
    }

    /// Delete a value from the Keychain.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists in the Keychain.
    static func exists(key: String) -> Bool {
        return retrieve(key: key) != nil
    }
}
