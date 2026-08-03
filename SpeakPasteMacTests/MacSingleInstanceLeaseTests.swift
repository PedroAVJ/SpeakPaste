import Foundation
import XCTest
@testable import SpeakPaste

final class MacSingleInstanceLeaseTests: XCTestCase {
    func testSecondLeaseIsRejectedUntilFirstLeaseIsReleased() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakPaste-lease-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: MacSingleInstanceLease.Acquisition? = MacSingleInstanceLease.acquire(
            lockDirectory: directory
        )
        guard case .acquired = first else {
            return XCTFail("The first process lease should be acquired")
        }
        guard case .alreadyHeld = MacSingleInstanceLease.acquire(lockDirectory: directory) else {
            return XCTFail("A second lease must not initialize app state")
        }

        first = nil
        guard case .acquired = MacSingleInstanceLease.acquire(lockDirectory: directory) else {
            return XCTFail("The kernel lease should be released with its owner")
        }
    }

    func testUnsafeTestingIdentifierCannotShapeTheLockPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakPaste-lease-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .unavailable = MacSingleInstanceLease.acquireForIsolatedTesting(
            lockIdentifier: "../outside",
            lockDirectory: directory
        ) else {
            return XCTFail("Path-shaped bundle identifiers must be rejected")
        }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }
}
