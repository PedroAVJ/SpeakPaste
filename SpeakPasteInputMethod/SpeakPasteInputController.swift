import AppKit
import InputMethodKit

/// InputMethodKit creates one controller for each client input session. Commands
/// therefore belong to a single process-wide broker, never to every controller
/// receiving the same authenticated command stream. The most recently activated
/// controller is the only controller allowed to claim a SpeakPaste session.
final class SpeakPasteInputControllerBroker: @unchecked Sendable {
    static let shared = SpeakPasteInputControllerBroker()

    private lazy var commandServer = SpeakPasteInputMethodCommandServer(
        handler: { [weak self] command in
            DispatchQueue.main.async { self?.handle(command) }
        },
        leaseInvalidated: { [weak self] sessionID, requestID in
            DispatchQueue.main.async {
                self?.leaseInvalidated(
                    sessionID: sessionID,
                    requestID: requestID
                )
            }
        }
    )
    private weak var activeController: SpeakPasteInputController?
    private var activeGeneration: UInt64 = 0

    private init() {
        commandServer.start()
    }

    func activate(_ controller: SpeakPasteInputController) {
        if let previous = activeController, previous !== controller {
            previous.detach(reason: "controller_replaced")
        }
        activeGeneration &+= 1
        activeController = controller
        controller.assign(generation: activeGeneration)
        controller.postReceipt(action: "activated", result: "ready")
    }

    func deactivate(_ controller: SpeakPasteInputController) {
        guard activeController === controller else {
            controller.detach(reason: "client_deactivated")
            return
        }
        controller.detach(reason: "client_deactivated")
        activeController = nil
    }

    func clientRequestedCommit(_ controller: SpeakPasteInputController) {
        guard activeController === controller else { return }
        // InputMethodKit may ask an idle palette controller to commit before a
        // SpeakPaste session begins. That is not a deactivation signal.
        guard controller.hasOwnedSession else { return }
        // A click outside marked text asks an input method to commit by default.
        // Provisional speech must never become final through that implicit path.
        controller.detach(reason: "client_commit_requested")
    }

    func clientTyped(_ controller: SpeakPasteInputController) {
        guard activeController === controller else { return }
        guard controller.hasOwnedSession else { return }
        controller.detach(reason: "keyboard_input")
    }

    func controllerWillClose(_ controller: SpeakPasteInputController) {
        controller.detach(reason: "controller_closed")
        if activeController === controller {
            activeController = nil
        }
    }

    private func handle(_ command: SpeakPasteInputMethodIPCCommand) {
        guard let controller = activeController else {
            send(
                SpeakPasteInputMethodIPCReceipt(
                    action: command.action.rawValue,
                    result: "input_client_unavailable",
                    requestID: command.requestID,
                    sessionID: command.sessionID,
                    clientBundleID: nil,
                    revision: command.revision,
                    controllerGeneration: activeGeneration,
                    markedLocation: nil,
                    markedLength: nil
                )
            )
            return
        }
        controller.handle(
            command: command,
            generation: activeGeneration
        )
    }

    private func leaseInvalidated(sessionID: String, requestID: String) {
        guard let controller = activeController,
              controller.ownsLease(
                  sessionID: sessionID,
                  requestID: requestID
              ) else { return }
        controller.detach(reason: "command_peer_disconnected")
    }

    func send(_ receipt: SpeakPasteInputMethodIPCReceipt) {
        commandServer.reply(receipt)
    }
}

/// A hidden palette input method matching the public architecture used by
/// macOS Dictation: every cumulative hypothesis is one marked composition, and
/// the final post-processed transcript commits that composition exactly once.
/// Recording, recognition, History, and recovery stay in the containing app.
@objc(SpeakPasteInputController)
final class SpeakPasteInputController: IMKInputController {
    private enum ClientMutation {
        case idle
        case settingMarkedText
        case insertingText
    }

    private enum MarkReadback {
        case none
        case marked(NSRange)
        case unavailable
    }

    private enum CancellationResult {
        case verified
        case bestEffort
        case failed
    }

    private var isActive = false
    private var generation: UInt64 = 0
    private var sessionID: String?
    private var leaseRequestID: String?
    private var latestRevision: UInt64 = 0
    private var hasMarkedText = false
    private var initialSelection: NSRange?
    private var ownedMarkedRange: NSRange?
    private var markedTextUTF16Count = 0
    private var clientMutation = ClientMutation.idle

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        isActive = true
        SpeakPasteInputControllerBroker.shared.activate(self)
    }

    override func deactivateServer(_ sender: Any!) {
        SpeakPasteInputControllerBroker.shared.deactivate(self)
        isActive = false
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        guard clientMutation == .idle else { return }
        SpeakPasteInputControllerBroker.shared.clientRequestedCommit(self)
    }

    override func cancelComposition() {
        guard clientMutation == .idle else { return }
        if sessionID != nil {
            detach(reason: "client_cancel_requested")
        }
    }

    override func inputControllerWillClose() {
        SpeakPasteInputControllerBroker.shared.controllerWillClose(self)
        super.inputControllerWillClose()
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        if sessionID != nil, clientMutation == .idle {
            SpeakPasteInputControllerBroker.shared.clientTyped(self)
        }
        // A palette is additive. Ordinary keyboard input must always continue
        // through the user's current keyboard source unchanged.
        return false
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if sessionID != nil,
           clientMutation == .idle,
           event?.type == .keyDown {
            SpeakPasteInputControllerBroker.shared.clientTyped(self)
        }
        return false
    }

    override func didCommand(
        by aSelector: Selector!,
        client sender: Any!
    ) -> Bool {
        if sessionID != nil, clientMutation == .idle {
            SpeakPasteInputControllerBroker.shared.clientTyped(self)
        }
        return false
    }

    func assign(generation: UInt64) {
        self.generation = generation
    }

    fileprivate func handle(
        command: SpeakPasteInputMethodIPCCommand,
        generation expectedGeneration: UInt64
    ) {
        guard isActive, generation == expectedGeneration else { return }
        let action = command.action
        let requestID = command.requestID
        let requestedSessionID: String? = command.sessionID
        let revision = command.revision

        switch action {
        case .probe:
            postReceipt(
                action: action.rawValue,
                result: "ready",
                requestID: requestID,
                requestedSessionID: requestedSessionID,
                revision: revision
            )

        case .begin:
            guard
                let requestedSessionID,
                let inputClient = client(),
                targetMatches(command.targetBundleID, inputClient: inputClient)
            else {
                postReceipt(
                    action: action.rawValue,
                    result: "wrong_client",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }

            // A retry on the authenticated lease is idempotent while the
            // caret/composition remains ours.
            if sessionID == requestedSessionID {
                let result = sessionStateStillOwned(inputClient)
                    ? "ready"
                    : "stale_or_detached"
                if result == "ready" {
                    // Transfer the lease to this retry before replying. Closing
                    // the older begin connection can no longer detach it.
                    leaseRequestID = requestID
                }
                postReceipt(
                    action: action.rawValue,
                    result: result,
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                if result != "ready" {
                    detach(reason: result)
                }
                return
            }

            guard sessionID == nil else {
                postReceipt(
                    action: action.rawValue,
                    result: "busy",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }

            let selection = inputClient.selectedRange()
            guard selection.location != NSNotFound else {
                postReceipt(
                    action: action.rawValue,
                    result: "unsupported_client",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }
            guard selection.length == 0 else {
                postReceipt(
                    action: action.rawValue,
                    result: "noncollapsed_selection",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }
            // A valid non-empty range is somebody else's live composition.
            // NSNotFound only means this client does not expose readback.
            if case .marked = readMarkedState(inputClient) {
                postReceipt(
                    action: action.rawValue,
                    result: "foreign_composition",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }
            sessionID = requestedSessionID
            leaseRequestID = requestID
            latestRevision = 0
            hasMarkedText = false
            initialSelection = selection
            ownedMarkedRange = nil
            markedTextUTF16Count = 0
            postReceipt(
                action: action.rawValue,
                result: "ready",
                requestID: requestID,
                requestedSessionID: requestedSessionID,
                revision: revision
            )

        case .update:
            guard
                owns(requestedSessionID, revision: revision),
                let text = command.text,
                let inputClient = client(),
                sessionStateStillOwned(inputClient)
            else {
                postReceipt(
                    action: action.rawValue,
                    result: "stale_or_detached",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }
            let textLength = text.utf16.count
            clientMutation = .settingMarkedText
            inputClient.setMarkedText(
                text,
                selectionRange: NSRange(location: textLength, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
            )
            clientMutation = .idle
            latestRevision = revision
            let markedRange = inputClient.markedRange()
            let expectedLocation = ownedMarkedRange?.location
                ?? initialSelection?.location
            let result: String
            if text.isEmpty {
                switch readMarkedState(inputClient) {
                case .none:
                    hasMarkedText = false
                    ownedMarkedRange = nil
                    markedTextUTF16Count = 0
                    result = "applied"
                case .unavailable:
                    hasMarkedText = false
                    ownedMarkedRange = nil
                    markedTextUTF16Count = 0
                    result = "applied"
                case let .marked(range):
                    // setMarkedText produced this range synchronously. It is
                    // safe to clear on detach only when it stayed at our anchor.
                    if expectedLocation == nil || range.location == expectedLocation {
                        hasMarkedText = true
                        ownedMarkedRange = range
                        markedTextUTF16Count = range.length
                    } else {
                        hasMarkedText = false
                        ownedMarkedRange = nil
                        markedTextUTF16Count = 0
                    }
                    result = "range_mismatch"
                }
            } else {
                switch readMarkedState(inputClient) {
                case let .marked(range):
                    if range.length == textLength,
                       expectedLocation == nil || range.location == expectedLocation {
                        hasMarkedText = true
                        ownedMarkedRange = range
                        markedTextUTF16Count = textLength
                        result = "applied"
                    } else {
                        if expectedLocation == nil || range.location == expectedLocation {
                            hasMarkedText = true
                            ownedMarkedRange = range
                            markedTextUTF16Count = range.length
                        } else {
                            hasMarkedText = false
                            ownedMarkedRange = nil
                            markedTextUTF16Count = 0
                        }
                        result = "range_mismatch"
                    }
                case .unavailable:
                    // Electron clients can accept the mutation while refusing
                    // marked-range readback. That is best effort, not failure.
                    hasMarkedText = true
                    ownedMarkedRange = nil
                    markedTextUTF16Count = textLength
                    result = "applied"
                case .none:
                    hasMarkedText = false
                    ownedMarkedRange = nil
                    markedTextUTF16Count = 0
                    result = "range_mismatch"
                }
            }
            if result != "applied" {
                detach(reason: result)
            }
            postReceipt(
                action: action.rawValue,
                result: result,
                requestID: requestID,
                requestedSessionID: requestedSessionID,
                revision: revision,
                markedRange: markedRange
            )

        case .finish:
            guard
                owns(
                    requestedSessionID,
                    revision: revision,
                    allowingEqualRevision: true
                ),
                let text = command.text,
                let inputClient = client(),
                sessionStateStillOwned(inputClient)
            else {
                postReceipt(
                    action: action.rawValue,
                    result: "stale_or_detached",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }

            let markedRangeBefore = inputClient.markedRange()
            if text.isEmpty {
                _ = cancelOwnedComposition(inputClient)
            } else {
                clientMutation = .insertingText
                inputClient.insertText(
                    text,
                    replacementRange: NSRange(
                        location: NSNotFound,
                        length: NSNotFound
                    )
                )
                clientMutation = .idle
            }
            let markedRangeAfter = inputClient.markedRange()
            let exactReadback = text.isEmpty || finalTextMatches(
                text,
                priorMarkedRange: markedRangeBefore,
                inputClient: inputClient
            )
            let compositionEnded: Bool
            switch readMarkedState(inputClient) {
            case .none:
                compositionEnded = true
            case .marked, .unavailable:
                compositionEnded = false
            }
            let result: String
            if compositionEnded, exactReadback {
                result = "committed"
            } else {
                // insertText was attempted exactly once. A surviving mark or
                // missing readback is ambiguous external state, never a
                // definite failure eligible for another paste.
                result = "committed_unverified"
            }
            resetSession()
            postReceipt(
                action: action.rawValue,
                result: result,
                requestID: requestID,
                requestedSessionID: requestedSessionID,
                revision: revision,
                markedRange: markedRangeAfter
            )

        case .cancel:
            guard sessionID == requestedSessionID else {
                postReceipt(
                    action: action.rawValue,
                    result: "stale_or_detached",
                    requestID: requestID,
                    requestedSessionID: requestedSessionID,
                    revision: revision
                )
                return
            }
            let cancellation = cancelOwnedComposition()
            resetSession()
            let result = switch cancellation {
            case .verified: "cancelled"
            case .bestEffort: "cancelled_unverified"
            case .failed: "cancel_failed"
            }
            postReceipt(
                action: action.rawValue,
                result: result,
                requestID: requestID,
                requestedSessionID: requestedSessionID,
                revision: revision
            )
        }
    }

    func detach(reason: String) {
        guard sessionID != nil else {
            resetSession()
            return
        }
        let detachedSessionID = sessionID
        _ = cancelOwnedComposition()
        resetSession()
        postReceipt(
            action: "detached",
            result: reason,
            requestedSessionID: detachedSessionID
        )
    }

    private func owns(
        _ requestedSessionID: String?,
        revision: UInt64,
        allowingEqualRevision: Bool = false
    ) -> Bool {
        guard let requestedSessionID, requestedSessionID == sessionID else {
            return false
        }
        return allowingEqualRevision
            ? revision >= latestRevision
            : revision > latestRevision
    }

    fileprivate func ownsLease(sessionID: String, requestID: String) -> Bool {
        self.sessionID == sessionID && leaseRequestID == requestID
    }

    fileprivate var hasOwnedSession: Bool {
        sessionID != nil
    }

    private func targetMatches(
        _ expectedBundleID: String?,
        inputClient: IMKTextInput
    ) -> Bool {
        guard let expectedBundleID else { return false }
        return inputClient.bundleIdentifier() == expectedBundleID
    }

    private func sessionStateStillOwned(_ inputClient: IMKTextInput) -> Bool {
        if !hasMarkedText {
            guard let initialSelection else { return false }
            return NSEqualRanges(inputClient.selectedRange(), initialSelection)
        }

        switch readMarkedState(inputClient) {
        case .unavailable:
            return true
        case .none:
            return false
        case let .marked(range):
            let expectedLocation = ownedMarkedRange?.location
                ?? initialSelection?.location
            return range.length == markedTextUTF16Count
                && (expectedLocation == nil || range.location == expectedLocation)
        }
    }

    private func readMarkedState(_ inputClient: IMKTextInput) -> MarkReadback {
        let range = inputClient.markedRange()
        if range.location == NSNotFound {
            return .unavailable
        }
        return range.length == 0 ? .none : .marked(range)
    }

    private func cancelOwnedComposition(
        _ knownClient: IMKTextInput? = nil
    ) -> CancellationResult {
        guard let inputClient = knownClient ?? client() else {
            return .bestEffort
        }

        if hasMarkedText {
            switch readMarkedState(inputClient) {
            case let .marked(range):
                let expectedLocation = ownedMarkedRange?.location
                    ?? initialSelection?.location
                guard range.length == markedTextUTF16Count,
                      expectedLocation == nil || range.location == expectedLocation
                else {
                    // This is a valid mark, but it is no longer ours.
                    return .failed
                }
            case .none:
                return .verified
            case .unavailable:
                break
            }
        } else {
            // No SpeakPaste mark was created. Never clear a valid foreign mark
            // merely because the controller is detaching.
            switch readMarkedState(inputClient) {
            case .none:
                return .verified
            case .unavailable:
                return .bestEffort
            case .marked:
                return .failed
            }
        }

        clientMutation = .settingMarkedText
        inputClient.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        clientMutation = .idle
        hasMarkedText = false
        ownedMarkedRange = nil
        markedTextUTF16Count = 0

        return switch readMarkedState(inputClient) {
        case .none: .verified
        case .unavailable: .bestEffort
        case .marked: .failed
        }
    }

    private func finalTextMatches(
        _ text: String,
        priorMarkedRange: NSRange,
        inputClient: IMKTextInput
    ) -> Bool {
        let length = text.utf16.count
        let selection = inputClient.selectedRange()
        let location: Int
        // The pre-insert marked range is the strongest anchor. Selection can
        // legitimately move as a side effect of insertText.
        if priorMarkedRange.location != NSNotFound {
            location = priorMarkedRange.location
        } else if let initialSelection {
            location = initialSelection.location
        } else if selection.location != NSNotFound, selection.location >= length {
            location = selection.location - length
        } else {
            return false
        }
        guard let observed = inputClient.attributedSubstring(
            from: NSRange(location: location, length: length)
        ) else {
            return false
        }
        return observed.string == text
    }

    private func resetSession() {
        sessionID = nil
        leaseRequestID = nil
        latestRevision = 0
        hasMarkedText = false
        initialSelection = nil
        ownedMarkedRange = nil
        markedTextUTF16Count = 0
        clientMutation = .idle
    }

    func postReceipt(
        action: String,
        result: String,
        requestID: String? = nil,
        requestedSessionID: String? = nil,
        revision: UInt64 = 0,
        markedRange: NSRange? = nil
    ) {
        SpeakPasteInputControllerBroker.shared.send(
            SpeakPasteInputMethodIPCReceipt(
                action: action,
                result: result,
                requestID: requestID,
                sessionID: requestedSessionID ?? sessionID,
                clientBundleID: client()?.bundleIdentifier(),
                revision: revision,
                controllerGeneration: generation,
                markedLocation: markedRange?.location,
                markedLength: markedRange?.length
            )
        )
    }
}
