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

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private var dataProtectionQuery: [String: Any] {
        var query = baseQuery
#if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    func save(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStoreError.encodingFailed
        }

        let status = upsert(data, query: dataProtectionQuery, usesDataProtection: true)
        if status == errSecSuccess { return }
#if os(macOS)
        // Local ad-hoc builds have no provisioning profile, so macOS rejects the
        // Data Protection Keychain with errSecMissingEntitlement. Fall back to
        // the traditional per-user Keychain instead of discarding the key.
        if status == errSecMissingEntitlement {
            let fallbackStatus = upsert(data, query: baseQuery, usesDataProtection: false)
            guard fallbackStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(fallbackStatus)
            }
            return
        }
#endif
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func load() -> String? {
        if let value = load(query: dataProtectionQuery) {
            return value
        }
#if os(macOS)
        return load(query: baseQuery)
#else
        return nil
#endif
    }

    func delete() {
        SecItemDelete(dataProtectionQuery as CFDictionary)
#if os(macOS)
        SecItemDelete(baseQuery as CFDictionary)
#endif
    }

    private func load(query base: [String: Any]) -> String? {
        var query = base
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

    private func upsert(
        _ data: Data,
        query: [String: Any],
        usesDataProtection: Bool
    ) -> OSStatus {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if usesDataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil)
    }
}
