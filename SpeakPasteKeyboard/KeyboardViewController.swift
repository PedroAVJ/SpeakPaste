import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let hostResolver = HostApplicationResolver()
    private var hostingController: UIHostingController<KeyboardView>?

    private lazy var model = KeyboardModel(
        resolveHostBundleIdentifier: { [weak self] in
            guard let self else { return nil }
            return self.hostResolver.bundleIdentifier(for: self)
        },
        openContainingApp: { [weak self] url in
            guard let self else { return false }
            return await self.open(url: url)
        },
        insertTranscript: { [weak self] transcript in
            self?.insert(transcript: transcript)
        },
        advanceToNextKeyboard: { [weak self] in
            self?.advanceToNextInputMode()
        }
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        let keyboardView = KeyboardView(model: model)
        let hostingController = UIHostingController(rootView: keyboardView)
        hostingController.view.backgroundColor = .clear
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController

        let height = view.heightAnchor.constraint(equalToConstant: 272)
        height.priority = .init(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        model.startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        model.stopPolling()
        super.viewWillDisappear(animated)
    }

    @MainActor
    private func open(url: URL) async -> Bool {
        if let extensionContext {
            let didOpen = await withCheckedContinuation { continuation in
                extensionContext.open(url) { success in
                    continuation.resume(returning: success)
                }
            }
            if didOpen { return true }
        }

        // Keyboard extensions are not consistently permitted to use
        // NSExtensionContext.open. The responder-chain fallback is the same
        // sideload-only handoff used by microphone keyboard utilities.
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func insert(transcript: String) {
        var text = transcript
        if
            let previousCharacter = textDocumentProxy.documentContextBeforeInput?.last,
            !previousCharacter.isWhitespace,
            !previousCharacter.isNewline,
            let firstCharacter = transcript.first,
            !firstCharacter.isPunctuation
        {
            text = " " + text
        }
        textDocumentProxy.insertText(text)
        UIDevice.current.playInputClick()
    }
}
