import Foundation
import Security

enum KeychainStoreError: LocalizedError, Equatable {
    case encodingFailed
    case unexpectedStatus(OSStatus)
    case unexpectedDeleteStatus(OSStatus)
    case deletionVerificationFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The API key could not be encoded."
        case let .unexpectedStatus(status):
            "The API key could not be saved securely (\(status))."
        case let .unexpectedDeleteStatus(status):
            "The API key could not be removed securely (\(status))."
        case .deletionVerificationFailed:
            "The API key is still present after Keychain reported that it was removed."
        }
    }
}

struct KeychainStore {
    struct Access {
        let deleteItem: ([String: Any]) -> OSStatus
        let loadString: ([String: Any]) -> String?
        let upsertData: (Data, [String: Any], Bool) -> OSStatus

        init(
            deleteItem: @escaping ([String: Any]) -> OSStatus,
            loadString: @escaping ([String: Any]) -> String?,
            upsertData: @escaping (Data, [String: Any], Bool) -> OSStatus = Access.liveUpsert
        ) {
            self.deleteItem = deleteItem
            self.loadString = loadString
            self.upsertData = upsertData
        }

        static var live: Access {
            Access(
                deleteItem: { query in
                    SecItemDelete(query as CFDictionary)
                },
                loadString: { base in
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
                },
                upsertData: liveUpsert
            )
        }

        static func liveUpsert(
            _ data: Data,
            _ query: [String: Any],
            _ usesDataProtection: Bool
        ) -> OSStatus {
            var attributes: [String: Any] = [kSecValueData as String: data]
            if usesDataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }

            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            if updateStatus == errSecSuccess { return updateStatus }
            guard updateStatus == errSecItemNotFound else { return updateStatus }

            var insert = query
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private let service = "com.example.speakpaste"
    /// The first signed macOS builds stored the same account under this
    /// service. Retain it as an upgrade fallback so an existing key cannot
    /// disappear merely because the storage label changed.
    private let legacyService = "com.pedro.speakpaste"
    private let account = "elevenlabs-api-key"
    private let access: Access

    init(access: Access = .live) {
        self.access = access
    }

    private var baseQuery: [String: Any] {
        baseQuery(service: service)
    }

    private var legacyBaseQuery: [String: Any] {
        baseQuery(service: legacyService)
    }

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private var dataProtectionQuery: [String: Any] {
        dataProtectionQuery(base: baseQuery)
    }

    private var legacyDataProtectionQuery: [String: Any] {
        dataProtectionQuery(base: legacyBaseQuery)
    }

    private func dataProtectionQuery(base: [String: Any]) -> [String: Any] {
        var query = base
#if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    func save(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStoreError.encodingFailed
        }

#if os(macOS)
        // The traditional per-user Keychain is the macOS source of truth
        // across both signed and ad-hoc builds. Save it first, then synchronize
        // the Data Protection entry when the current signature can access it.
        // A stale DP item can therefore never shadow a newer development key.
        let baseStatus = access.upsertData(data, baseQuery, false)
        guard baseStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(baseStatus)
        }
        _ = access.upsertData(data, dataProtectionQuery, true)
#else
        let status = access.upsertData(data, dataProtectionQuery, true)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
#endif
    }

    func load() -> String? {
#if os(macOS)
        if let value = access.loadString(baseQuery) {
            return value
        }
        if let value = access.loadString(dataProtectionQuery) {
            return value
        }
        if let value = access.loadString(legacyBaseQuery) {
            return value
        }
        return access.loadString(legacyDataProtectionQuery)
#else
        if let value = access.loadString(dataProtectionQuery) {
            return value
        }
        return access.loadString(legacyDataProtectionQuery)
#endif
    }

    func delete() throws {
        var firstFailure: OSStatus?
        for query in deletionQueries {
            let status = access.deleteItem(query)
            if !isSuccessfulDeletion(status, for: query), firstFailure == nil {
                firstFailure = status
            }
        }
        if let firstFailure {
            throw KeychainStoreError.unexpectedDeleteStatus(firstFailure)
        }
        guard load() == nil else {
            throw KeychainStoreError.deletionVerificationFailed
        }
    }

    private func isSuccessfulDeletion(
        _ status: OSStatus,
        for _: [String: Any]
    ) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    private var deletionQueries: [[String: Any]] {
#if os(macOS)
        [dataProtectionQuery, baseQuery, legacyDataProtectionQuery, legacyBaseQuery]
#else
        [dataProtectionQuery, legacyDataProtectionQuery]
#endif
    }
}
