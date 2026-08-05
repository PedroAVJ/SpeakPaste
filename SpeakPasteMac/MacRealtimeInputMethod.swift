import AppKit
import Carbon
import Foundation

/// UTF-16 geometry retained only for the read-only caret marker. Realtime text
/// mutation itself belongs to InputMethodKit marked composition, not AX.
struct MacRealtimeTextRange: Equatable, Sendable {
    let location: Int
    let length: Int

    var upperBound: Int { location + length }
    var asNSRange: NSRange { NSRange(location: location, length: length) }
    var asCFRange: CFRange { CFRange(location: location, length: length) }
}

enum MacRealtimeInputMethodAction: String, Sendable {
    case probe
    case begin
    case update
    case finish
    case cancel
}

struct MacRealtimeInputMethodReceipt: Equatable, Sendable {
    let action: String
    let result: String
    let requestID: String?
    let sessionID: String?
    let clientBundleID: String?
    let revision: UInt64
    let controllerGeneration: UInt64
}

enum MacRealtimeCompositionCommitResult: Equatable, Sendable {
    case verified
    case unverified
    case failed
}

enum MacRealtimeInputMethodReceiptPolicy {
    static func acceptsAttachment(
        _ receipt: MacRealtimeInputMethodReceipt?,
        sessionID: String,
        targetBundleID: String
    ) -> Bool {
        receipt?.action == MacRealtimeInputMethodAction.begin.rawValue
            && receipt?.result == "ready"
            && receipt?.sessionID == sessionID
            && receipt?.clientBundleID == targetBundleID
    }

    static func acceptsUpdate(
        _ receipt: MacRealtimeInputMethodReceipt?,
        sessionID: String,
        revision: UInt64
    ) -> Bool {
        receipt?.action == MacRealtimeInputMethodAction.update.rawValue
            && receipt?.result == "applied"
            && receipt?.sessionID == sessionID
            && receipt?.revision == revision
    }

    static func commitResult(
        _ receipt: MacRealtimeInputMethodReceipt?,
        sessionID: String,
        revision: UInt64
    ) -> MacRealtimeCompositionCommitResult {
        // Once the command is posted, a missing receipt is an ambiguous external
        // side effect. Preserve recovery and never attempt another insertion.
        guard let receipt else { return .unverified }
        guard
            receipt.action == MacRealtimeInputMethodAction.finish.rawValue,
            receipt.sessionID == sessionID,
            receipt.revision == revision
        else {
            return .failed
        }
        return switch receipt.result {
        case "committed": .verified
        case "committed_unverified": .unverified
        default: .failed
        }
    }
}

enum MacRealtimeInputMethodError: LocalizedError {
    case helperMissing
    case installFailed(String)
    case registrationFailed(OSStatus)
    case sourceMissing
    case enableFailed(OSStatus)
    case activationFailed(OSStatus)
    case keyboardSourceChanged
    case unsupportedTarget
    case attachmentTimedOut

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "The bundled realtime input-method helper is missing."
        case let .installFailed(message):
            "The realtime input-method helper could not be installed: \(message)"
        case let .registrationFailed(status):
            "macOS could not register the realtime input method (\(status))."
        case .sourceMissing:
            "macOS did not expose the registered realtime input method."
        case let .enableFailed(status):
            "macOS did not enable the realtime input method (\(status))."
        case let .activationFailed(status):
            "macOS did not attach the realtime input method (\(status))."
        case .keyboardSourceChanged:
            "Realtime was stopped because the active keyboard source changed."
        case .unsupportedTarget:
            "This text field did not expose a compatible input-method client."
        case .attachmentTimedOut:
            "The realtime input method did not attach before recording began."
        }
    }
}

/// Installs the signed helper under the location required by Text Input Sources,
/// registers and enables it, then selects it as an additive palette. The user's
/// actual keyboard source must remain byte-for-byte identical throughout.
@MainActor
final class MacRealtimeInputMethodInstaller {
    static let shared = MacRealtimeInputMethodInstaller()

    static let bundleIdentifier = "com.pedro.SpeakPasteInputMethod"
    private let helperName = "SpeakPasteInputMethod.app"
    private var selectedSource: TISInputSource?

    private init() {}

    func prepareAndSelect() async throws {
        try await installBundledHelperIfNeeded()
        let installedURL = try installedHelperURL()
        let registration = TISRegisterInputSource(installedURL as CFURL)
        guard registration == noErr else {
            throw MacRealtimeInputMethodError.registrationFailed(registration)
        }
        guard var source = inputSource() else {
            throw MacRealtimeInputMethodError.sourceMissing
        }
        if !boolProperty(source, key: kTISPropertyInputSourceIsEnabled) {
            let enabled = TISEnableInputSource(source)
            guard enabled == noErr else {
                throw MacRealtimeInputMethodError.enableFailed(enabled)
            }
            var observedEnabled = false
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(25))
                if let refreshed = inputSource(),
                   boolProperty(
                       refreshed,
                       key: kTISPropertyInputSourceIsEnabled
                   ) {
                    source = refreshed
                    observedEnabled = true
                    break
                }
            }
            guard observedEnabled else {
                throw MacRealtimeInputMethodError.enableFailed(OSStatus(paramErr))
            }
        }

        let keyboardBefore = currentKeyboardSourceID()
        // Apple's Dictation palette deliberately reacquires the current client
        // by deselecting, waiting one beat, and selecting again.
        _ = TISDeselectInputSource(source)
        try? await Task.sleep(for: .milliseconds(50))
        let selected = TISSelectInputSource(source)
        guard selected == noErr else {
            throw MacRealtimeInputMethodError.activationFailed(selected)
        }
        try? await Task.sleep(for: .milliseconds(100))
        guard currentKeyboardSourceID() == keyboardBefore else {
            _ = TISDeselectInputSource(source)
            throw MacRealtimeInputMethodError.keyboardSourceChanged
        }
        selectedSource = source
    }

    func deselect() {
        guard let selectedSource else { return }
        _ = TISDeselectInputSource(selectedSource)
        self.selectedSource = nil
    }

    private func installBundledHelperIfNeeded() async throws {
        let fileManager = FileManager.default
        let installedURL = try installedHelperURL()
        let bundledURL = Bundle.main.url(
            forResource: "SpeakPasteInputMethod",
            withExtension: "app"
        )
        guard let bundledURL else {
            // Development logic tests and an already-installed production app
            // can use the registered copy. A shipping app with neither copy is
            // an explicit batch fallback, never a partial install guess.
            guard fileManager.fileExists(atPath: installedURL.path) else {
                throw MacRealtimeInputMethodError.helperMissing
            }
            return
        }
        if fileManager.fileExists(atPath: installedURL.path),
           helperContentsMatch(installedURL, bundledURL) {
            return
        }

        try await stopRunningHelper()

        let parent = installedURL.deletingLastPathComponent()
        let stagingURL = parent.appendingPathComponent(
            ".SpeakPasteInputMethod.installing-\(UUID().uuidString).app",
            isDirectory: true
        )
        let backupURL = parent.appendingPathComponent(
            ".SpeakPasteInputMethod.previous.app",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: bundledURL, to: stagingURL)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            if fileManager.fileExists(atPath: installedURL.path) {
                try fileManager.moveItem(at: installedURL, to: backupURL)
            }
            do {
                try fileManager.moveItem(at: stagingURL, to: installedURL)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
            } catch {
                if fileManager.fileExists(atPath: backupURL.path),
                   !fileManager.fileExists(atPath: installedURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: installedURL)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw MacRealtimeInputMethodError.installFailed(
                error.localizedDescription
            )
        }
    }

    private func installedHelperURL() throws -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(helperName, isDirectory: true)
    }

    private func inputSource() -> TISInputSource? {
        let filter = [
            kTISPropertyInputSourceID as String: Self.bundleIdentifier,
        ] as CFDictionary
        guard let values = TISCreateInputSourceList(filter, true)?
            .takeRetainedValue() as? [TISInputSource]
        else {
            return nil
        }
        return values.first
    }

    private func currentKeyboardSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue()
        else {
            return nil
        }
        return stringProperty(source, key: kTISPropertyInputSourceID)
    }

    private func stringProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw)
            .takeUnretainedValue() as String
    }

    private func boolProperty(
        _ source: TISInputSource,
        key: CFString
    ) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else {
            return false
        }
        return CFBooleanGetValue(
            Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        )
    }

    private func bundleVersion(at url: URL) -> String? {
        Bundle(url: url)?.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String
    }

    /// Version metadata is useful for diagnostics, but it is not an install
    /// proof. Compare the signed executable and metadata so a same-version code
    /// fix can never leave an older helper running from `~/Library/Input Methods`.
    private func helperContentsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard bundleVersion(at: lhs) == bundleVersion(at: rhs),
              let lhsExecutable = Bundle(url: lhs)?.executableURL,
              let rhsExecutable = Bundle(url: rhs)?.executableURL
        else {
            return false
        }
        let fileManager = FileManager.default
        let relativeFiles = [
            "Contents/Info.plist",
            "Contents/_CodeSignature/CodeResources",
        ]
        guard fileManager.contentsEqual(
            atPath: lhsExecutable.path,
            andPath: rhsExecutable.path
        ) else {
            return false
        }
        return relativeFiles.allSatisfy { relativePath in
            let lhsPath = lhs.appendingPathComponent(relativePath).path
            let rhsPath = rhs.appendingPathComponent(relativePath).path
            let lhsExists = fileManager.fileExists(atPath: lhsPath)
            let rhsExists = fileManager.fileExists(atPath: rhsPath)
            if !lhsExists, !rhsExists { return true }
            guard lhsExists == rhsExists else { return false }
            return fileManager.contentsEqual(atPath: lhsPath, andPath: rhsPath)
        }
    }

    private func stopRunningHelper() async throws {
        var running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
        for application in running {
            _ = application.terminate()
        }
        for _ in 0..<40 {
            if NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.bundleIdentifier
            ).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
        for application in running {
            _ = application.forceTerminate()
        }
        for _ in 0..<20 {
            if NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.bundleIdentifier
            ).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw MacRealtimeInputMethodError.installFailed(
            "the previous helper process did not exit"
        )
    }
}

private final class MacWeakRealtimeCompositionSession {
    weak var value: MacRealtimeCompositionSession?

    init(_ value: MacRealtimeCompositionSession) {
        self.value = value
    }
}

/// One process-wide command/receipt bridge. Text never enters diagnostic logs;
/// request IDs, revision numbers, target identity, and explicit state receipts
/// are the only observability surface.
@MainActor
final class MacRealtimeInputMethodClient {
    static let shared = MacRealtimeInputMethodClient()

    private let installer = MacRealtimeInputMethodInstaller.shared
    private lazy var receiptServer = SpeakPasteInputMethodReceiptServer {
        [weak self] receipt in
        Task { @MainActor in
            self?.handleReceipt(Self.convert(receipt))
        }
    }
    private var sessions: [String: MacWeakRealtimeCompositionSession] = [:]
    private var leases: [String: SpeakPasteInputMethodIPCLease] = [:]

    private init() {
        receiptServer.start()
    }

    func attach(
        sessionID: UUID,
        targetBundleID: String
    ) async throws -> MacRealtimeCompositionSession {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == targetBundleID else {
            throw MacRealtimeInputMethodError.unsupportedTarget
        }
        try await installer.prepareAndSelect()

        for attempt in 0..<8 {
            if attempt == 4 {
                try await installer.prepareAndSelect()
            }
            let result = await sendBegin(
                sessionID: sessionID.uuidString,
                targetBundleID: targetBundleID,
                timeout: .milliseconds(225)
            )
            let receipt = result?.receipt
            if MacRealtimeInputMethodReceiptPolicy.acceptsAttachment(
                receipt,
                sessionID: sessionID.uuidString,
                targetBundleID: targetBundleID
            ) {
                leases[sessionID.uuidString] = result?.lease
                let session = MacRealtimeCompositionSession(
                    id: sessionID,
                    targetBundleID: targetBundleID,
                    client: self
                )
                sessions[sessionID.uuidString] = MacWeakRealtimeCompositionSession(
                    session
                )
                return session
            }
            result?.lease.close()
            if let failure = receipt?.result,
               [
                   "noncollapsed_selection",
                   "unsupported_client",
                   "foreign_composition",
                   "busy",
               ].contains(failure) {
                break
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == targetBundleID else { break }
            try? await Task.sleep(for: .milliseconds(75))
        }
        installer.deselect()
        throw MacRealtimeInputMethodError.attachmentTimedOut
    }

    func send(
        action: MacRealtimeInputMethodAction,
        sessionID: String,
        targetBundleID: String? = nil,
        revision: UInt64,
        text: String?,
        timeout: Duration = .milliseconds(500)
    ) async -> MacRealtimeInputMethodReceipt? {
        let requestID = UUID().uuidString
        let command = SpeakPasteInputMethodIPCCommand(
            action: SpeakPasteInputMethodIPCAction(rawValue: action.rawValue)!,
            requestID: requestID,
            sessionID: sessionID,
            targetBundleID: targetBundleID,
            revision: revision,
            text: text
        )
        let seconds = Self.seconds(timeout)
        return await Task.detached {
            SpeakPasteInputMethodIPCTransport.request(
                command,
                expectedPeerIdentifier: SpeakPasteInputMethodIPCTransport.helperBundleIdentifier,
                timeoutSeconds: seconds
            )
        }.value.map(Self.convert)
    }

    func cancelImmediately(sessionID: String, revision: UInt64) {
        leases.removeValue(forKey: sessionID)?.close()
        let command = SpeakPasteInputMethodIPCCommand(
            action: .cancel,
            requestID: UUID().uuidString,
            sessionID: sessionID,
            targetBundleID: nil,
            revision: revision,
            text: nil
        )
        Task.detached {
            _ = SpeakPasteInputMethodIPCTransport.request(
                command,
                expectedPeerIdentifier: SpeakPasteInputMethodIPCTransport.helperBundleIdentifier,
                timeoutSeconds: 0.5
            )
        }
        sessions[sessionID] = nil
        installer.deselect()
    }

    func close(sessionID: String) {
        leases.removeValue(forKey: sessionID)?.close()
        sessions[sessionID] = nil
        installer.deselect()
    }

    nonisolated private static func convert(
        _ receipt: SpeakPasteInputMethodIPCReceipt
    ) -> MacRealtimeInputMethodReceipt {
        return MacRealtimeInputMethodReceipt(
            action: receipt.action,
            result: receipt.result,
            requestID: receipt.requestID,
            sessionID: receipt.sessionID,
            clientBundleID: receipt.clientBundleID,
            revision: receipt.revision,
            controllerGeneration: receipt.controllerGeneration
        )
    }

    private func sendBegin(
        sessionID: String,
        targetBundleID: String,
        timeout: Duration
    ) async -> (
        receipt: MacRealtimeInputMethodReceipt,
        lease: SpeakPasteInputMethodIPCLease
    )? {
        let command = SpeakPasteInputMethodIPCCommand(
            action: .begin,
            requestID: UUID().uuidString,
            sessionID: sessionID,
            targetBundleID: targetBundleID,
            revision: 0,
            text: nil
        )
        let seconds = Self.seconds(timeout)
        return await Task.detached {
            SpeakPasteInputMethodIPCTransport.requestWithLease(
                command,
                expectedPeerIdentifier: SpeakPasteInputMethodIPCTransport.helperBundleIdentifier,
                timeoutSeconds: seconds
            )
        }.value.map { (Self.convert($0.receipt), $0.lease) }
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func handleReceipt(_ receipt: MacRealtimeInputMethodReceipt) {
        if receipt.action == "detached", let sessionID = receipt.sessionID {
            sessions[sessionID]?.value?.markDetached(reason: receipt.result)
        }
    }
}

/// Session-scoped ownership of one marked composition. Any target/focus/client
/// loss detaches permanently; final insertion is attempted at most once and a
/// missing receipt never permits a second paste.
@MainActor
final class MacRealtimeCompositionSession {
    let id: UUID
    let targetBundleID: String

    private let client: MacRealtimeInputMethodClient
    private(set) var latestRevision: UInt64 = 0
    private(set) var isDetached = false
    private(set) var isClosed = false
    var onDetach: ((String) -> Void)?

    init(
        id: UUID,
        targetBundleID: String,
        client: MacRealtimeInputMethodClient
    ) {
        self.id = id
        self.targetBundleID = targetBundleID
        self.client = client
    }

    @discardableResult
    func update(revision: UInt64, text: String) async -> Bool {
        guard !isDetached, !isClosed, revision > latestRevision else {
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == targetBundleID else {
            markDetached(reason: "frontmost_changed")
            return false
        }
        let receipt = await client.send(
            action: .update,
            sessionID: id.uuidString,
            targetBundleID: targetBundleID,
            revision: revision,
            text: text
        )
        guard MacRealtimeInputMethodReceiptPolicy.acceptsUpdate(
            receipt,
            sessionID: id.uuidString,
            revision: revision
        ) else {
            markDetached(reason: receipt?.result ?? "receipt_timeout")
            return false
        }
        latestRevision = revision
        return true
    }

    func finish(text: String) async -> MacRealtimeCompositionCommitResult {
        guard !isDetached, !isClosed else { return .failed }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == targetBundleID else {
            markDetached(reason: "frontmost_changed")
            return .failed
        }
        // Mark closed before the side effect. A timeout is ambiguous and must
        // never allow this session to issue the insertion a second time.
        isClosed = true
        let receipt = await client.send(
            action: .finish,
            sessionID: id.uuidString,
            targetBundleID: targetBundleID,
            revision: latestRevision,
            text: text,
            timeout: .milliseconds(900)
        )
        client.close(sessionID: id.uuidString)
        return MacRealtimeInputMethodReceiptPolicy.commitResult(
            receipt,
            sessionID: id.uuidString,
            revision: latestRevision
        )
    }

    @discardableResult
    func cancel() async -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        let receipt = await client.send(
            action: .cancel,
            sessionID: id.uuidString,
            targetBundleID: targetBundleID,
            revision: latestRevision,
            text: nil
        )
        client.close(sessionID: id.uuidString)
        return receipt?.result == "cancelled"
            || receipt?.result == "cancelled_unverified"
    }

    func cancelImmediately() {
        guard !isClosed else { return }
        isClosed = true
        client.cancelImmediately(
            sessionID: id.uuidString,
            revision: latestRevision
        )
    }

    func markDetached(reason: String) {
        guard !isDetached else { return }
        isDetached = true
        if !isClosed {
            isClosed = true
            // A failed/ambiguous update may already have created marked text.
            // Closing the authenticated lease makes helper-side cleanup
            // mandatory even when this request's receipt was lost.
            client.cancelImmediately(
                sessionID: id.uuidString,
                revision: latestRevision
            )
        }
        MacRealtimeTrace.event("composition_detached reason=\(reason)")
        onDetach?(reason)
    }
}
