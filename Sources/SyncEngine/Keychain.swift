/// Keychain helper for secure credential storage.
///
/// Stores the PLAUD binding token in the macOS Keychain rather than
/// plaintext TOML. Falls back to TOML for CLI compatibility.

import Foundation
import Security

public enum KeychainHelper {
    private static let service = "com.openplaudit.app"

    /// Save a string value to the Keychain.
    public static func save(key: String, value: String) throws {
        let data = Data(value.utf8)

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load a string value from the Keychain. Returns nil if not found.
    public static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain. Throws on failure (except "not found").
    @discardableResult
    public static func delete(key: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainError.deleteFailed(status)
    }
}

public enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Keychain save failed (status=\(s))"
        case .deleteFailed(let s): return "Keychain delete failed (status=\(s))"
        }
    }
}
