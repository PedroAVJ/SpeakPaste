import Darwin
import Foundation
import XCTest
@testable import SpeakPaste

final class MacDeliveryPolicyStoreFailClosedTests: XCTestCase {
    private nonisolated static var safePolicy: MacDeliveryPolicy {
        MacDeliveryPolicy(
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            deliveryMethod: .menuPaste,
            typeOutFallback: true,
            autoSend: false,
            contextKeyterms: true
        )
    }

    func testMalformedAndUnknownFieldDocumentsBlockEveryWritingMutation() async throws {
        let fixtures: [(String, Data)] = [
            (
                "malformed",
                Data(#"{"schemaVersion":1,"policiesByBundleIdentifier":{"#.utf8)
            ),
            (
                "malformed schema type",
                Data(#"{"schemaVersion":true,"policiesByBundleIdentifier":{}}"#.utf8)
            ),
            (
                "unknown document field",
                Data(#"{"schemaVersion":1,"policiesByBundleIdentifier":{},"futureBehavior":true}"#.utf8)
            ),
            (
                "unknown policy field",
                Data(#"{"schemaVersion":1,"policiesByBundleIdentifier":{"com.example.chat":{"bundleIdentifier":"com.example.chat","deliveryMethod":"automatic","autoSend":false,"contextKeyterms":false,"futureBehavior":true}}}"#.utf8)
            ),
        ]

        for (label, fixture) in fixtures {
            try await MainActor.run {
                let scratch = try Self.makeScratchDirectory()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let fileURL = scratch.appendingPathComponent("delivery-policies.json")
                try fixture.write(to: fileURL)

                let store = MacDeliveryPolicyStore(directory: scratch)
                XCTAssertTrue(store.policies.isEmpty, label)
                XCTAssertNotNil(store.lastPersistenceError, label)

                XCTAssertFalse(store.upsert(Self.safePolicy), label)
                XCTAssertFalse(store.replaceAll(with: [Self.safePolicy]), label)
                XCTAssertFalse(store.removeAll(), label)
                XCTAssertEqual(try Data(contentsOf: fileURL), fixture, label)
            }
        }
    }

    func testUnreadableDocumentIsNotMadeReadableOrOverwritten() async throws {
        try await MainActor.run {
            let scratch = try Self.makeScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let fileURL = scratch.appendingPathComponent("delivery-policies.json")
            let fixture = Data(#"{"schemaVersion":1,"policiesByBundleIdentifier":{}}"#.utf8)
            try fixture.write(to: fileURL)
            XCTAssertEqual(Darwin.chmod(fileURL.path, 0o000), 0)
            defer { _ = Darwin.chmod(fileURL.path, 0o600) }

            let store = MacDeliveryPolicyStore(directory: scratch)
            XCTAssertTrue(store.policies.isEmpty)
            XCTAssertNotNil(store.lastPersistenceError)
            XCTAssertFalse(store.upsert(Self.safePolicy))
            XCTAssertFalse(store.replaceAll(with: [Self.safePolicy]))
            XCTAssertFalse(store.removeAll())

            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue, 0o000)
            XCTAssertEqual(Darwin.chmod(fileURL.path, 0o600), 0)
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    func testBlockedDocumentCanBeReplacedOnlyAfterItIsMovedAway() async throws {
        try await MainActor.run {
            let scratch = try Self.makeScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let fileURL = scratch.appendingPathComponent("delivery-policies.json")
            let backupURL = scratch.appendingPathComponent("delivery-policies.invalid.json")
            let fixture = Data(#"{"schemaVersion":99,"policiesByBundleIdentifier":{}}"#.utf8)
            try fixture.write(to: fileURL)

            let store = MacDeliveryPolicyStore(directory: scratch)
            XCTAssertFalse(store.upsert(Self.safePolicy))
            XCTAssertEqual(try Data(contentsOf: fileURL), fixture)

            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            XCTAssertTrue(store.upsert(Self.safePolicy))
            XCTAssertEqual(
                store.configuredPolicy(for: Self.safePolicy.bundleIdentifier),
                Self.safePolicy
            )
            XCTAssertEqual(try Data(contentsOf: backupURL), fixture)
            XCTAssertNotEqual(try Data(contentsOf: fileURL), fixture)
        }
    }

    private nonisolated static func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakPaste-policy-fail-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
