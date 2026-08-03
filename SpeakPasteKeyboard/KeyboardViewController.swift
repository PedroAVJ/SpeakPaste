import ObjectiveC.runtime
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let hostResolver = HostApplicationResolver()
    private var hostingController: UIHostingController<KeyboardView>?

    private lazy var model = KeyboardModel(
        resolveHostApplication: { [weak self] in
            guard let self else {
                return HostApplicationResolution(
                    bundleIdentifier: nil,
                    attempts: ["controller-deallocated"]
                )
            }
            return self.hostResolver.resolve(for: self)
        },
        openContainingApp: { [weak self] url in
            guard let self else { return .failed(attempts: ["controller-deallocated"]) }
            return await self.open(url: url)
        },
        insertTranscript: { [weak self] transcript in
            self?.insert(transcript: transcript)
        },
        insertText: { [weak self] text in
            self?.textDocumentProxy.insertText(text)
            UIDevice.current.playInputClick()
        },
        deleteBackward: { [weak self] in
            self?.textDocumentProxy.deleteBackward()
            UIDevice.current.playInputClick()
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
        applyKeyboardAppearance()
        model.hasFullAccess = hasFullAccess
        model.startPolling()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyKeyboardAppearance()
    }

    /// Most hosts leave this `.default`, and the system appearance already
    /// reaches the trait collection. A host that asks for a specific keyboard
    /// appearance overrides that, so honor it too.
    private func applyKeyboardAppearance() {
        switch textDocumentProxy.keyboardAppearance {
        case .dark:
            overrideUserInterfaceStyle = .dark
        case .light:
            overrideUserInterfaceStyle = .light
        default:
            overrideUserInterfaceStyle = .unspecified
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        model.stopPolling()
        super.viewWillDisappear(animated)
    }

    @MainActor
    private func open(url: URL) async -> KeyboardAppLaunchOutcome {
        var attempts: [String] = []

        // A keyboard's responder chain belongs to the host presentation. On
        // current iOS versions the URL-capable responder is normally UIScene,
        // not UIApplication. These APIs take different option types, so they
        // must be invoked as their real classes instead of through one dynamic
        // Objective-C signature.
        if let result = await openUsingResponderChain(url) {
            attempts.append("responder-\(result.route):\(result.didOpen)")
            if result.didOpen {
                return .opened(route: result.route, attempts: attempts)
            }
        }

        // Apple doesn't consistently honor NSExtensionContext.open for custom
        // keyboards, but keep the supported extension API as a fallback.
        if let extensionContext {
            let didOpen = await withCheckedContinuation { continuation in
                extensionContext.open(url) { success in
                    continuation.resume(returning: success)
                }
            }
            attempts.append("extension-context:\(didOpen)")
            if didOpen {
                return .opened(route: "extension-context", attempts: attempts)
            }
        }

        // This personal sideload can still fall back to opening its bundle.
        // App activation consumes the pending shared launch request even when
        // the custom deep link itself isn't delivered.
        let didOpenBundle = openContainingBundle()
        attempts.append("workspace-bundle:\(didOpenBundle)")
        if didOpenBundle {
            return .opened(route: "workspace-bundle", attempts: attempts)
        }

        return .failed(attempts: attempts)
    }

    private func openUsingResponderChain(
        _ url: URL
    ) async -> (didOpen: Bool, route: String)? {
        var responder: UIResponder? = self
        while let current = responder {
            if let scene = current as? UIScene {
                let didOpen = await scene.open(url, options: nil)
                return (didOpen, "scene")
            }
            if let application = current as? UIApplication {
                let didOpen = await application.open(url, options: [:])
                return (didOpen, "application")
            }
            responder = current.next
        }
        return nil
    }

    private func openContainingBundle() -> Bool {
        guard
            let extensionBundleIdentifier = Bundle.main.bundleIdentifier,
            extensionBundleIdentifier.hasSuffix(".Keyboard")
        else {
            return false
        }
        let containingBundleIdentifier = String(
            extensionBundleIdentifier.dropLast(".Keyboard".count)
        )

        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard
            let defaultMethod = class_getClassMethod(
                workspaceClass,
                defaultSelector
            ),
            let defaultEncoding = method_getTypeEncoding(defaultMethod),
            String(cString: defaultEncoding) == "@16@0:8"
        else {
            return false
        }
        typealias DefaultWorkspaceFunction = @convention(c) (
            AnyClass,
            Selector
        ) -> Unmanaged<AnyObject>?
        let defaultWorkspace = unsafeBitCast(
            method_getImplementation(defaultMethod),
            to: DefaultWorkspaceFunction.self
        )
        guard
            let workspace = defaultWorkspace(
                workspaceClass,
                defaultSelector
            )?.takeUnretainedValue()
        else {
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard
            let openMethod = class_getInstanceMethod(workspaceClass, openSelector),
            let openEncoding = method_getTypeEncoding(openMethod),
            String(cString: openEncoding) == "B24@0:8@16"
        else {
            return false
        }
        typealias OpenApplicationFunction = @convention(c) (
            AnyObject,
            Selector,
            NSString
        ) -> Bool
        let openApplication = unsafeBitCast(
            method_getImplementation(openMethod),
            to: OpenApplicationFunction.self
        )
        return openApplication(
            workspace,
            openSelector,
            containingBundleIdentifier as NSString
        )
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
