import Foundation

protocol MacRealtimeScribeSessionProtocol: Sendable {
    func connect(
        configuration: MacRealtimeScribeConfiguration,
        onUpdate: @escaping @Sendable (MacRealtimeTranscriptUpdate) -> Void
    ) async throws
    func sendAudio(_ data: Data) async throws
    func finish() async throws -> TranscriptionResult
    func cancel() async
}

protocol MacRealtimeScribeSessionFactory: Sendable {
    func makeSession() -> any MacRealtimeScribeSessionProtocol
}

struct MacRealtimeScribeLiveFactory: MacRealtimeScribeSessionFactory {
    func makeSession() -> any MacRealtimeScribeSessionProtocol {
        MacRealtimeScribeSession()
    }
}

actor MacRealtimeScribeSession: MacRealtimeScribeSessionProtocol {
    private let endpoint: URL
    private let redirectDelegate = ElevenLabsNoRedirectDelegate()
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var assembler = MacRealtimeTranscriptAssembler()
    private var terminalError: Error?
    private var updateHandler: (@Sendable (MacRealtimeTranscriptUpdate) -> Void)?
    private var requestedLanguageCode: String?
    private var isClosing = false
    private var updateRevision: UInt64 = 0
    private var audioBytesSinceLastCommit = 0
    private var manualCommitRequestsSent = 0

    init(endpoint: URL = MacRealtimeScribeRequestBuilder.endpoint) {
        self.endpoint = endpoint
    }

    func connect(
        configuration: MacRealtimeScribeConfiguration,
        onUpdate: @escaping @Sendable (MacRealtimeTranscriptUpdate) -> Void
    ) async throws {
        guard socket == nil else { throw MacRealtimeScribeError.invalidResponse }
        let request = try MacRealtimeScribeRequestBuilder.request(
            configuration: configuration,
            endpoint: endpoint
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        let socket = session.webSocketTask(with: request)
        urlSession = session
        self.socket = socket
        updateHandler = onUpdate
        requestedLanguageCode = configuration.languageCode
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            try await waitForSessionStart()
        } catch {
            close()
            throw error
        }
    }

    func sendAudio(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }
        try throwTerminalErrorIfPresent()
        guard assembler.sessionStarted, let socket, !isClosing else {
            throw MacRealtimeScribeError.socketClosed
        }
        let shouldCommit = MacRealtimeCommitCadence.shouldCommit(
            bytesSinceLastCommit: audioBytesSinceLastCommit,
            nextChunkByteCount: data.count
        )
        let message = try MacRealtimeScribeRequestBuilder.audioMessage(
            data: data,
            commit: shouldCommit
        )
        do {
            try await socket.send(.string(message))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        if shouldCommit {
            manualCommitRequestsSent += 1
            audioBytesSinceLastCommit = 0
        } else {
            audioBytesSinceLastCommit += data.count
        }
        try throwTerminalErrorIfPresent()
    }

    func finish() async throws -> TranscriptionResult {
        try Task.checkCancellation()
        try throwTerminalErrorIfPresent()
        guard assembler.sessionStarted, let socket, !isClosing else {
            throw MacRealtimeScribeError.socketClosed
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))

        // A 25-second audio chunk can carry a periodic commit. Drain every
        // outstanding periodic response before sending the final tail commit,
        // so an earlier response cannot be mistaken for finalization.
        try await waitForCommitCount(
            manualCommitRequestsSent,
            clock: clock,
            deadline: deadline
        )
        if audioBytesSinceLastCommit > 0 || manualCommitRequestsSent == 0 {
            let countBeforeFinalCommit = assembler.commitEventCount
            let message = try MacRealtimeScribeRequestBuilder.audioMessage(
                data: Data(),
                commit: true
            )
            try await socket.send(.string(message))
            manualCommitRequestsSent += 1
            audioBytesSinceLastCommit = 0
            try await waitForCommitAfter(
                countBeforeFinalCommit,
                clock: clock,
                deadline: deadline
            )
        }

        let text = assembler.snapshot.committedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            close()
            throw ElevenLabsClientError.emptyTranscript
        }
        let result = TranscriptionResult(
            text: text,
            languageCode: requestedLanguageCode,
            languageProbability: nil
        )
        close()
        return result
    }

    func cancel() {
        close()
    }

    private func waitForSessionStart() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !assembler.sessionStarted {
            try Task.checkCancellation()
            try throwTerminalErrorIfPresent()
            guard clock.now < deadline else {
                throw MacRealtimeScribeError.handshakeTimedOut
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForCommitCount(
        _ expectedCount: Int,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        while assembler.commitEventCount < expectedCount {
            try await waitForNextCommitPoll(clock: clock, deadline: deadline)
        }
    }

    private func waitForCommitAfter(
        _ previousCount: Int,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        while assembler.commitEventCount <= previousCount {
            try await waitForNextCommitPoll(clock: clock, deadline: deadline)
        }
    }

    private func waitForNextCommitPoll(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        try Task.checkCancellation()
        try throwTerminalErrorIfPresent()
        guard clock.now < deadline else {
            close()
            throw MacRealtimeScribeError.commitTimedOut
        }
        try await Task.sleep(for: .milliseconds(25))
    }

    private func receiveLoop() async {
        do {
            while !isClosing {
                guard let socket else { throw MacRealtimeScribeError.socketClosed }
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .string(string):
                    guard let encoded = string.data(using: .utf8) else {
                        throw MacRealtimeScribeError.invalidResponse
                    }
                    data = encoded
                case let .data(received):
                    data = received
                @unknown default:
                    throw MacRealtimeScribeError.invalidResponse
                }
                let effect = try assembler.consume(data)
                switch effect {
                case let .textChanged(snapshot), let .committed(snapshot):
                    updateRevision &+= 1
                    updateHandler?(
                        MacRealtimeTranscriptUpdate(
                            revision: updateRevision,
                            snapshot: snapshot
                        )
                    )
                case .sessionStarted, .metadata:
                    break
                }
            }
        } catch {
            guard !isClosing else { return }
            terminalError = error
        }
    }

    private func throwTerminalErrorIfPresent() throws {
        if let terminalError { throw terminalError }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        updateHandler = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
}

/// Thread-safe ordered bridge from AVCapture's serial sample queue to the
/// actor-owned WebSocket. A bounded buffer fails the experiment instead of
/// silently dropping/reordering speech or growing without limit.
final class MacRealtimeAudioPump: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?
        private var storedSentByteCount = 0

        func record(_ error: Error) {
            lock.lock()
            storedError = storedError ?? error
            lock.unlock()
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func recordSent(byteCount: Int) {
            lock.lock()
            storedSentByteCount += max(0, byteCount)
            lock.unlock()
        }

        var sentByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedSentByteCount
        }
    }

    private let continuation: AsyncStream<Data>.Continuation
    private let sender: Task<Void, Never>
    private let state: State

    init(session: any MacRealtimeScribeSessionProtocol) {
        let state = State()
        self.state = state
        var capturedContinuation: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(128)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
        sender = Task {
            do {
                for await chunk in stream {
                    try Task.checkCancellation()
                    try await session.sendAudio(chunk)
                    state.recordSent(byteCount: chunk.count)
                }
            } catch {
                state.record(error)
            }
        }
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty, state.error == nil else { return }
        switch continuation.yield(data) {
        case .enqueued:
            break
        case .dropped:
            state.record(MacRealtimeScribeError.audioBackpressure)
            continuation.finish()
        case .terminated:
            break
        @unknown default:
            state.record(MacRealtimeScribeError.audioBackpressure)
            continuation.finish()
        }
    }

    func finish() async throws -> Int {
        continuation.finish()
        await sender.value
        if let error = state.error { throw error }
        return state.sentByteCount
    }

    func cancel() {
        continuation.finish()
        sender.cancel()
    }
}
