import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The API key could not be encoded."
        case let .unexpectedStatus(status):
            "The API key could not be saved securely (\(status))."
        }
    }
}

struct KeychainStore {
    private let service = "com.example.speakpaste"
    private let account = "elevenlabs-api-key"

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
#if os(macOS)
        // The modern per-app keychain avoids legacy login-keychain ACL prompts
        // when a locally signed development build is replaced.
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    func save(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStoreError.encodingFailed
        }

        let query = query
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func load() -> String? {
        var query = query
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
