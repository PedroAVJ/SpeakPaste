import Darwin
import Foundation
import Security

enum SpeakPasteInputMethodIPCAction: String, Codable, Sendable {
    case probe
    case begin
    case update
    case finish
    case cancel
}

struct SpeakPasteInputMethodIPCCommand: Codable, Sendable {
    let action: SpeakPasteInputMethodIPCAction
    let requestID: String
    let sessionID: String
    let targetBundleID: String?
    let revision: UInt64
    let text: String?
}

struct SpeakPasteInputMethodIPCReceipt: Codable, Sendable {
    let action: String
    let result: String
    let requestID: String?
    let sessionID: String?
    let clientBundleID: String?
    let revision: UInt64
    let controllerGeneration: UInt64
    let markedLocation: Int?
    let markedLength: Int?
}

/// Private local IPC for realtime composition. The socket permissions prevent
/// other users from opening it, and every accepted peer is independently
/// checked against its live code signature before any transcript is decoded.
enum SpeakPasteInputMethodIPCTransport {
    static let mainBundleIdentifier = "com.pedro.SpeakPasteMac"
    static let helperBundleIdentifier = "com.pedro.SpeakPasteInputMethod"

    private static let maximumFrameBytes = 4 * 1_024 * 1_024

    static var commandSocketPath: String {
        "/tmp/com.pedro.SpeakPaste.\(getuid()).input-method.sock"
    }

    static var receiptSocketPath: String {
        "/tmp/com.pedro.SpeakPaste.\(getuid()).main.sock"
    }

    static func request(
        _ command: SpeakPasteInputMethodIPCCommand,
        expectedPeerIdentifier: String,
        timeoutSeconds: Double
    ) -> SpeakPasteInputMethodIPCReceipt? {
        guard let result = openRequest(
            command,
            expectedPeerIdentifier: expectedPeerIdentifier,
            timeoutSeconds: timeoutSeconds
        ) else { return nil }
        result.lease.close()
        return result.receipt
    }

    static func requestWithLease(
        _ command: SpeakPasteInputMethodIPCCommand,
        expectedPeerIdentifier: String,
        timeoutSeconds: Double
    ) -> (receipt: SpeakPasteInputMethodIPCReceipt, lease: SpeakPasteInputMethodIPCLease)? {
        openRequest(
            command,
            expectedPeerIdentifier: expectedPeerIdentifier,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func openRequest(
        _ command: SpeakPasteInputMethodIPCCommand,
        expectedPeerIdentifier: String,
        timeoutSeconds: Double
    ) -> (receipt: SpeakPasteInputMethodIPCReceipt, lease: SpeakPasteInputMethodIPCLease)? {
        guard let teamIdentifier = currentTeamIdentifier() else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        configureDescriptor(descriptor)
        var closeOnFailure = true
        defer {
            if closeOnFailure { Darwin.close(descriptor) }
        }
        configureTimeout(descriptor, seconds: timeoutSeconds)
        guard connect(descriptor, path: commandSocketPath) else { return nil }
        guard validatePeer(
            descriptor,
            expectedIdentifier: expectedPeerIdentifier,
            expectedTeamIdentifier: teamIdentifier
        ) else {
            return nil
        }
        guard writeFrame(command, to: descriptor) else { return nil }
        guard let receipt = readFrame(
            SpeakPasteInputMethodIPCReceipt.self,
            from: descriptor
        ) else { return nil }
        // A successful begin request keeps this descriptor open as the
        // composition lease. Request/response timeouts must not turn that
        // lease monitor into a polling loop.
        clearTimeout(descriptor)
        closeOnFailure = false
        return (receipt, SpeakPasteInputMethodIPCLease(descriptor: descriptor))
    }

    static func sendOutOfBandReceipt(
        _ receipt: SpeakPasteInputMethodIPCReceipt,
        expectedPeerIdentifier: String
    ) {
        guard let teamIdentifier = currentTeamIdentifier() else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        configureDescriptor(descriptor)
        defer { Darwin.close(descriptor) }
        configureTimeout(descriptor, seconds: 0.5)
        guard connect(descriptor, path: receiptSocketPath) else { return }
        guard validatePeer(
            descriptor,
            expectedIdentifier: expectedPeerIdentifier,
            expectedTeamIdentifier: teamIdentifier
        ) else {
            return
        }
        _ = writeFrame(receipt, to: descriptor)
    }

    static func makeListeningSocket(path: String) -> Int32? {
        guard path.utf8CString.count <= pathCapacity else { return nil }
        guard removeOwnedSocketIfPresent(path: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        configureDescriptor(descriptor)
        var closeOnFailure = true
        defer {
            if closeOnFailure { Darwin.close(descriptor) }
        }
        guard bind(descriptor, path: path), chmod(path, 0o600) == 0 else {
            return nil
        }
        guard Darwin.listen(descriptor, 8) == 0 else { return nil }
        closeOnFailure = false
        return descriptor
    }

    static func acceptPeer(
        on listener: Int32,
        expectedIdentifier: String
    ) -> Int32? {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return nil }
        configureDescriptor(descriptor)
        configureTimeout(descriptor, seconds: 1.0)
        // Authentication happens before a command or receipt frame is read.
        // The connected side performs the symmetric check before writing.
        guard let teamIdentifier = currentTeamIdentifier(), validatePeer(
            descriptor,
            expectedIdentifier: expectedIdentifier,
            expectedTeamIdentifier: teamIdentifier
        ) else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    static func readCommand(from descriptor: Int32) -> SpeakPasteInputMethodIPCCommand? {
        readFrame(SpeakPasteInputMethodIPCCommand.self, from: descriptor)
    }

    static func readReceipt(from descriptor: Int32) -> SpeakPasteInputMethodIPCReceipt? {
        readFrame(SpeakPasteInputMethodIPCReceipt.self, from: descriptor)
    }

    static func writeReceipt(
        _ receipt: SpeakPasteInputMethodIPCReceipt,
        to descriptor: Int32
    ) -> Bool {
        writeFrame(receipt, to: descriptor)
    }

    static func close(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }

    static func clearRequestTimeoutForLease(_ descriptor: Int32) {
        clearTimeout(descriptor)
    }

    static func unlinkSocket(path: String) {
        _ = removeOwnedSocketIfPresent(path: path)
    }

    private static var pathCapacity: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    private static func connect(_ descriptor: Int32, path: String) -> Bool {
        withSocketAddress(path: path) { pointer, length in
            Darwin.connect(descriptor, pointer, length) == 0
        } ?? false
    }

    private static func bind(_ descriptor: Int32, path: String) -> Bool {
        withSocketAddress(path: path) { pointer, length in
            Darwin.bind(descriptor, pointer, length) == 0
        } ?? false
    }

    private static func withSocketAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T? {
        let bytes = path.utf8CString
        guard bytes.count <= pathCapacity else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(
            MemoryLayout.size(ofValue: address.sun_len)
                + MemoryLayout.size(ofValue: address.sun_family)
                + bytes.count
        )
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let addressLength = socklen_t(address.sun_len)
        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, addressLength)
            }
        }
    }

    private static func configureDescriptor(_ descriptor: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    private static func configureTimeout(_ descriptor: Int32, seconds: Double) {
        let wholeSeconds = Int(seconds)
        let microseconds = Int32((seconds - Double(wholeSeconds)) * 1_000_000)
        var timeout = timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func clearTimeout(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func writeFrame<T: Encodable>(_ value: T, to descriptor: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        guard data.count <= maximumFrameBytes else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func readFrame<T: Decodable>(_ type: T.Type, from descriptor: Int32) -> T? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                    guard data.count + newline <= maximumFrameBytes else {
                        return nil
                    }
                    data.append(contentsOf: buffer[..<newline])
                    return try? JSONDecoder().decode(type, from: data)
                }
                guard data.count + count <= maximumFrameBytes else { return nil }
                data.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    private static func peerPID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else {
            return nil
        }
        return pid
    }

    private static func peerUserID(_ descriptor: Int32) -> uid_t? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            &credentials,
            &length
        ) == 0, credentials.cr_version == XUCRED_VERSION else {
            return nil
        }
        return credentials.cr_uid
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        return signingIdentity(for: staticCode)?.teamIdentifier
    }

    private static func validatePeer(
        _ descriptor: Int32,
        expectedIdentifier: String,
        expectedTeamIdentifier: String
    ) -> Bool {
        guard peerUserID(descriptor) == geteuid(),
              let pid = peerPID(descriptor)
        else {
            return false
        }
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            return false
        }
        let requirementText = "anchor apple generic and identifier \"\(expectedIdentifier)\" and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func signingIdentity(for code: SecStaticCode) -> (
        identifier: String,
        teamIdentifier: String
    )? {
        var information: CFDictionary?
        // The default information set omits `kSecCodeInfoTeamIdentifier` on
        // macOS. Request signing information explicitly; otherwise both sides
        // fail authentication before sending a frame even though their live
        // signatures are valid.
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let identifier = values[kSecCodeInfoIdentifier] as? String,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String
        else {
            return nil
        }
        return (identifier, teamIdentifier)
    }

    private static func removeOwnedSocketIfPresent(path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return errno == ENOENT }
        guard status.st_uid == getuid(), (status.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }
        return unlink(path) == 0
    }
}

final class SpeakPasteInputMethodIPCLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        let descriptor = lock.withLock { () -> Int32 in
            let current = self.descriptor
            self.descriptor = -1
            return current
        }
        if descriptor >= 0 {
            _ = shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    deinit { close() }
}

final class SpeakPasteInputMethodCommandServer: @unchecked Sendable {
    typealias Handler = @Sendable (SpeakPasteInputMethodIPCCommand) -> Void
    typealias LeaseInvalidatedHandler = @Sendable (String, String) -> Void

    private struct PendingResponse {
        let descriptor: Int32
        let command: SpeakPasteInputMethodIPCCommand
    }

    private let acceptQueue = DispatchQueue(
        label: "com.pedro.SpeakPaste.input-method.ipc.accept"
    )
    private let outboundQueue = DispatchQueue(
        label: "com.pedro.SpeakPaste.input-method.ipc.outbound"
    )
    private let leaseQueue = DispatchQueue(
        label: "com.pedro.SpeakPaste.input-method.lease",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private let handler: Handler
    private let leaseInvalidatedHandler: LeaseInvalidatedHandler
    private var listener: Int32 = -1
    private var responses: [String: PendingResponse] = [:]

    init(
        handler: @escaping Handler,
        leaseInvalidated: @escaping LeaseInvalidatedHandler
    ) {
        self.handler = handler
        leaseInvalidatedHandler = leaseInvalidated
    }

    func start() {
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func reply(_ receipt: SpeakPasteInputMethodIPCReceipt) {
        if let requestID = receipt.requestID {
            guard let pending = lock.withLock({
                responses.removeValue(forKey: requestID)
            }) else {
                // Expiry already closed this command socket. Unsolicited
                // receipts use a nil request ID; a late response must not be
                // transformed into a different IPC conversation.
                return
            }
            let wroteReceipt = SpeakPasteInputMethodIPCTransport.writeReceipt(
                receipt,
                to: pending.descriptor
            )
            if pending.command.action == .begin,
               receipt.result == "ready",
               wroteReceipt {
                monitorLease(
                    descriptor: pending.descriptor,
                    sessionID: pending.command.sessionID,
                    requestID: pending.command.requestID
                )
            } else {
                SpeakPasteInputMethodIPCTransport.close(pending.descriptor)
                if pending.command.action == .begin, receipt.result == "ready" {
                    self.leaseInvalidatedHandler(
                        pending.command.sessionID,
                        pending.command.requestID
                    )
                }
            }
            return
        }
        outboundQueue.async {
            SpeakPasteInputMethodIPCTransport.sendOutOfBandReceipt(
                receipt,
                expectedPeerIdentifier: SpeakPasteInputMethodIPCTransport.mainBundleIdentifier
            )
        }
    }

    private func acceptLoop() {
        guard let listener = SpeakPasteInputMethodIPCTransport.makeListeningSocket(
            path: SpeakPasteInputMethodIPCTransport.commandSocketPath
        ) else { return }
        self.listener = listener
        while true {
            guard let descriptor = SpeakPasteInputMethodIPCTransport.acceptPeer(
                on: listener,
                expectedIdentifier: SpeakPasteInputMethodIPCTransport.mainBundleIdentifier
            ) else { continue }
            guard let command = SpeakPasteInputMethodIPCTransport.readCommand(from: descriptor) else {
                SpeakPasteInputMethodIPCTransport.close(descriptor)
                continue
            }
            let replaced = lock.withLock { () -> PendingResponse? in
                let prior = responses.updateValue(PendingResponse(
                    descriptor: descriptor,
                    command: command
                ), forKey: command.requestID)
                return prior
            }
            if let replaced {
                SpeakPasteInputMethodIPCTransport.close(replaced.descriptor)
            }
            handler(command)
            schedulePendingResponseExpiry(
                requestID: command.requestID,
                descriptor: descriptor
            )
        }
    }

    private func schedulePendingResponseExpiry(
        requestID: String,
        descriptor: Int32
    ) {
        leaseQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let expired = lock.withLock { () -> PendingResponse? in
                guard responses[requestID]?.descriptor == descriptor else {
                    return nil
                }
                return responses.removeValue(forKey: requestID)
            }
            if let expired {
                SpeakPasteInputMethodIPCTransport.close(expired.descriptor)
                if expired.command.action == .begin {
                    // The broker receives commands on the main queue in FIFO
                    // order, so a delayed accepted begin is followed by this
                    // lease invalidation and cannot survive without its peer.
                    leaseInvalidatedHandler(
                        expired.command.sessionID,
                        expired.command.requestID
                    )
                }
            }
        }
    }

    private func monitorLease(
        descriptor: Int32,
        sessionID: String,
        requestID: String
    ) {
        leaseQueue.async { [leaseInvalidatedHandler] in
            SpeakPasteInputMethodIPCTransport.clearRequestTimeoutForLease(
                descriptor
            )
            var byte: UInt8 = 0
            while true {
                let result = Darwin.read(descriptor, &byte, 1)
                if result == 0 { break }
                if result < 0, errno == EINTR { continue }
                if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                if result < 0 { break }
            }
            SpeakPasteInputMethodIPCTransport.close(descriptor)
            leaseInvalidatedHandler(sessionID, requestID)
        }
    }

    deinit {
        if listener >= 0 { SpeakPasteInputMethodIPCTransport.close(listener) }
        let pending = lock.withLock { () -> [PendingResponse] in
            defer { responses.removeAll() }
            return Array(responses.values)
        }
        for response in pending {
            SpeakPasteInputMethodIPCTransport.close(response.descriptor)
        }
        SpeakPasteInputMethodIPCTransport.unlinkSocket(
            path: SpeakPasteInputMethodIPCTransport.commandSocketPath
        )
    }
}

final class SpeakPasteInputMethodReceiptServer: @unchecked Sendable {
    typealias Handler = @Sendable (SpeakPasteInputMethodIPCReceipt) -> Void

    private let queue = DispatchQueue(label: "com.pedro.SpeakPaste.main.ipc")
    private let handler: Handler
    private var listener: Int32 = -1

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        guard let listener = SpeakPasteInputMethodIPCTransport.makeListeningSocket(
            path: SpeakPasteInputMethodIPCTransport.receiptSocketPath
        ) else { return }
        self.listener = listener
        while true {
            guard let descriptor = SpeakPasteInputMethodIPCTransport.acceptPeer(
                on: listener,
                expectedIdentifier: SpeakPasteInputMethodIPCTransport.helperBundleIdentifier
            ) else { continue }
            defer { SpeakPasteInputMethodIPCTransport.close(descriptor) }
            if let receipt = SpeakPasteInputMethodIPCTransport.readReceipt(from: descriptor) {
                handler(receipt)
            }
        }
    }

    deinit {
        if listener >= 0 { SpeakPasteInputMethodIPCTransport.close(listener) }
        SpeakPasteInputMethodIPCTransport.unlinkSocket(
            path: SpeakPasteInputMethodIPCTransport.receiptSocketPath
        )
    }
}
