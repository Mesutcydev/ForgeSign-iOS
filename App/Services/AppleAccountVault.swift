import Foundation
import Security

/// The Apple Account email lives in the Keychain, not in plain preferences that
/// device backups include (audit N7). The password is never stored.
enum AppleAccountVault {
    private static let service = "com.forgesign.mobile.apple-account"
    private static let account = "apple-id"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the value, or removes it when it is empty.
    static func store(_ value: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !value.isEmpty else { return }
        var query = match
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Moves the value an earlier build kept in preferences into the Keychain, once.
    static func migrateLegacyPreference(key: String = "altServerAppleID") -> String? {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: key), !legacy.isEmpty else { return nil }
        store(legacy)
        defaults.removeObject(forKey: key)
        return legacy
    }
}
