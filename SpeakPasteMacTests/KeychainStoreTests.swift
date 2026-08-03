import Security
import XCTest
@testable import SpeakPasteKeychain

final class KeychainStoreTests: XCTestCase {
    func testSaveMakesTraditionalMacStoreAuthoritativeAndSynchronizesDataProtection() throws {
        var writes: [Bool] = []
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { _ in nil },
                upsertData: { _, query, _ in
                    writes.append(usesDataProtectionKeychain(query))
                    return errSecSuccess
                }
            )
        )

        try store.save("new-key")

        XCTAssertEqual(writes, [false, true])
    }

    func testSaveStillSucceedsWhenAdHocBuildCannotSynchronizeDataProtection() throws {
        var baseValue: String?
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { query in
                    usesDataProtectionKeychain(query) ? "stale-signed-key" : baseValue
                },
                upsertData: { data, query, _ in
                    if usesDataProtectionKeychain(query) { return errSecMissingEntitlement }
                    baseValue = String(data: data, encoding: .utf8)
                    return errSecSuccess
                }
            )
        )

        try store.save("current-dev-key")

        XCTAssertEqual(store.load(), "current-dev-key")
    }

    func testLoadPrefersTraditionalStoreOverStaleDataProtectionValue() {
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { query in
                    usesDataProtectionKeychain(query) ? "stale-key" : "current-key"
                }
            )
        )

        XCTAssertEqual(store.load(), "current-key")
    }

    func testLoadFallsBackToOriginalSignedServiceWithoutExposingOrReplacingItsKey() {
        var reads: [String] = []
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { query in
                    let service = keychainService(query)
                    reads.append("\(service):\(usesDataProtectionKeychain(query))")
                    if service == "com.pedro.speakpaste",
                       !usesDataProtectionKeychain(query) {
                        return "original-signed-key"
                    }
                    return nil
                }
            )
        )

        XCTAssertEqual(store.load(), "original-signed-key")
        XCTAssertEqual(
            reads,
            [
                "com.example.speakpaste:false",
                "com.example.speakpaste:true",
                "com.pedro.speakpaste:false",
            ]
        )
    }

    func testDeleteAcceptsSuccessAndAlreadyMissingThenVerifiesEveryStoreIsEmpty() throws {
        var deletedDataProtectionStore = false
        var deletedFallbackStore = false
        var loadedDataProtectionStore = false
        var loadedFallbackStore = false
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    if usesDataProtectionKeychain(query) {
                        deletedDataProtectionStore = true
                        return errSecSuccess
                    }
                    deletedFallbackStore = true
                    return errSecItemNotFound
                },
                loadString: { query in
                    if usesDataProtectionKeychain(query) {
                        loadedDataProtectionStore = true
                    } else {
                        loadedFallbackStore = true
                    }
                    return nil
                }
            )
        )

        try store.delete()

        XCTAssertTrue(deletedDataProtectionStore)
        XCTAssertTrue(deletedFallbackStore)
        XCTAssertTrue(loadedDataProtectionStore)
        XCTAssertTrue(loadedFallbackStore)
    }

    func testDeleteAttemptsEveryStoreAndThrowsWhenEitherDeletionFails() {
        var fallbackDeleteAttempted = false
        var verificationAttempted = false
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    if usesDataProtectionKeychain(query) {
                        return errSecAuthFailed
                    }
                    fallbackDeleteAttempted = true
                    return errSecSuccess
                },
                loadString: { _ in
                    verificationAttempted = true
                    return nil
                }
            )
        )

        XCTAssertThrowsError(try store.delete()) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .unexpectedDeleteStatus(errSecAuthFailed)
            )
        }
        XCTAssertTrue(fallbackDeleteAttempted)
        XCTAssertFalse(verificationAttempted)
    }

    func testDeleteReportsUnverifiableDataProtectionStoreButStillDeletesFallback() {
        var fallbackDeleteAttempted = false
        var verificationAttempted = false
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    if usesDataProtectionKeychain(query) {
                        return errSecMissingEntitlement
                    }
                    fallbackDeleteAttempted = true
                    return errSecSuccess
                },
                loadString: { _ in
                    verificationAttempted = true
                    return nil
                }
            )
        )

        XCTAssertThrowsError(try store.delete()) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .unexpectedDeleteStatus(errSecMissingEntitlement)
            )
        }

        XCTAssertTrue(fallbackDeleteAttempted)
        XCTAssertFalse(verificationAttempted)
    }

    func testDeleteThrowsWhenKeyRemainsAfterSuccessfulStatuses() {
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecSuccess },
                loadString: { query in
                    usesDataProtectionKeychain(query) ? "still-present" : nil
                }
            )
        )

        XCTAssertThrowsError(try store.delete()) { error in
            XCTAssertEqual(error as? KeychainStoreError, .deletionVerificationFailed)
        }
    }

    func testDeleteCoversCurrentAndOriginalServiceBackends() throws {
        var deleted: [String] = []
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    deleted.append(
                        "\(keychainService(query)):\(usesDataProtectionKeychain(query))"
                    )
                    return errSecItemNotFound
                },
                loadString: { _ in nil }
            )
        )

        try store.delete()

        XCTAssertEqual(
            Set(deleted),
            Set([
                "com.example.speakpaste:true",
                "com.example.speakpaste:false",
                "com.pedro.speakpaste:true",
                "com.pedro.speakpaste:false",
            ])
        )
    }
}

private func usesDataProtectionKeychain(_ query: [String: Any]) -> Bool {
    query[kSecUseDataProtectionKeychain as String] as? Bool == true
}

private func keychainService(_ query: [String: Any]) -> String {
    query[kSecAttrService as String] as? String ?? ""
}
