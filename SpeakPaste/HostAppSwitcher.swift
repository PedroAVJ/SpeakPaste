import ObjectiveC.runtime
import UIKit

struct KeyboardReturnPrompt: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String?
    let appName: String
}

struct HostAppSwitchOutcome: Equatable, Sendable {
    let didOpen: Bool
    let attempts: [String]
}

@MainActor
private final class ApplicationBackgroundWaiter: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var isObserving = false
    private var timeoutTask: Task<Void, Never>?

    func sendAndWait(
        scene: UIScene,
        _ send: () -> Bool
    ) async -> (didSend: Bool, didEnterBackground: Bool) {
        var didSend = false
        let didEnterBackground = await withCheckedContinuation { continuation in
            self.continuation = continuation
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDidEnterBackground),
                name: UIScene.didEnterBackgroundNotification,
                object: scene
            )
            isObserving = true

            didSend = send()

            // A lifecycle notification may theoretically arrive while the
            // private response method is still on the stack.
            guard self.continuation != nil else { return }
            guard didSend else {
                finish(didEnterBackground: false)
                return
            }

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.finish(didEnterBackground: false)
            }
        }
        return (didSend, didEnterBackground)
    }

    @objc private func sceneDidEnterBackground() {
        finish(didEnterBackground: true)
    }

    private func finish(didEnterBackground: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if isObserving {
            NotificationCenter.default.removeObserver(
                self,
                name: UIScene.didEnterBackgroundNotification,
                object: nil
            )
            isObserving = false
        }
        continuation.resume(returning: didEnterBackground)
    }
}

@MainActor
enum HostAppSwitcher {
    private final class WeakSystemNavigationAction {
        weak var action: AnyObject?

        init(_ action: AnyObject) {
            self.action = action
        }
    }

    private struct SystemNavigationInspection {
        let action: AnyObject?
        let isValid: Bool
        let canSendResponse: Bool
        let destinations: Set<UInt>
        /// The application destination `0` actually resolves to, when SpringBoard
        /// identifies one. A live action whose primary destination names no
        /// application returns the phone to the Home Screen.
        let primaryDestinationBundleIdentifier: String?
        let attempts: [String]

        var hasLivePrimaryDestination: Bool {
            action != nil
                && isValid
                && canSendResponse
                && destinations.contains(HostAppSwitcher.primaryDestination)
        }

        /// The one-shot BaseBoard response cannot be undone or inspected after
        /// the fact, so the destination must be confirmed before it is sent.
        func confirmsReturn(to expectedBundleIdentifier: String?) -> Bool {
            guard
                hasLivePrimaryDestination,
                let resolved = primaryDestinationBundleIdentifier
            else {
                return false
            }
            guard let expectedBundleIdentifier else { return true }
            return resolved.caseInsensitiveCompare(expectedBundleIdentifier)
                == .orderedSame
        }
    }

    /// SpringBoard's primary/back destination, constructed from the previous
    /// application scene.
    private nonisolated static let primaryDestination: UInt = 0

    private static let actionChangedNotification = Notification.Name(
        "UIApplicationSystemNavigationActionChangedNotification"
    )
    private static var attemptedSystemNavigationActions: [WeakSystemNavigationAction] = []
    private static var systemNavigationProbeHistory: [String] = []

    static var systemNavigationActionChangedNotification: Notification.Name {
        actionChangedNotification
    }

    static func beginReturnSession(probeRoute: String) {
        systemNavigationProbeHistory = []
        probeSystemNavigationAction(route: probeRoute)
    }

    static func probeSystemNavigationAction(route: String) {
        let inspection = inspectSystemNavigationAction()
        systemNavigationProbeHistory.append("system-navigation-probe:\(route)")
        systemNavigationProbeHistory.append(contentsOf: inspection.attempts)
        systemNavigationProbeHistory = bounded(systemNavigationProbeHistory)
    }

    static func anticipatedRoute(for bundleIdentifier: String?) -> String {
        let host = validBundleIdentifier(bundleIdentifier)
        if inspectSystemNavigationAction().confirmsReturn(to: host) {
            return "system-navigation-response"
        }
        return anticipatedFallbackRoute(for: bundleIdentifier)
    }

    static func anticipatedAttempts(for bundleIdentifier: String?) -> [String] {
        let inspection = inspectSystemNavigationAction()
        let host = validBundleIdentifier(bundleIdentifier)
        var attempts = systemNavigationProbeHistory
        attempts.append("system-navigation-probe:preflight")
        attempts.append(contentsOf: inspection.attempts)
        if inspection.confirmsReturn(to: host) {
            attempts.append("system-navigation-response:pending")
        } else {
            attempts.append(anticipatedFallbackRoute(for: bundleIdentifier))
        }
        return bounded(attempts)
    }

    static func isValidReturnBundleIdentifier(_ value: String?) -> Bool {
        validBundleIdentifier(value) != nil
    }

    static func displayName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier = validBundleIdentifier(bundleIdentifier) else {
            return "your previous app"
        }
        let names: [String: String] = [
            "com.apple.MobileSMS": "Messages",
            "com.apple.mobilenotes": "Notes",
            "com.apple.mobilemail": "Mail",
            "com.openai.chat": "ChatGPT",
            "com.anthropic.claude": "Claude",
            "net.whatsapp.WhatsApp": "WhatsApp",
            "com.tinyspeck.chatlyio": "Slack",
            "com.google.Gmail": "Gmail",
            "com.linkedin.LinkedIn": "LinkedIn",
        ]
        return names[bundleIdentifier] ?? "your previous app"
    }

    static func open(
        bundleIdentifier: String?,
        onAttemptsChanged: (([String]) -> Void)? = nil
    ) async -> HostAppSwitchOutcome {
        var attempts = systemNavigationProbeHistory
        let inspection = inspectSystemNavigationAction()
        let host = validBundleIdentifier(bundleIdentifier)
        attempts.append("system-navigation-probe:return")
        attempts.append(contentsOf: inspection.attempts)
        attempts = bounded(attempts)
        onAttemptsChanged?(attempts)

        if
            inspection.confirmsReturn(to: host),
            let action = inspection.action,
            let activeScene = UIApplication.shared.connectedScenes.first(where: {
                $0.activationState == .foregroundActive
            }),
            !hasAttemptedSystemNavigationAction(action)
        {
            // BaseBoard responses are strict one-shot values. Mark this action
            // consumed before entering the IMP so overlapping UI tasks cannot
            // issue it twice.
            markSystemNavigationActionAttempted(action)

            let waiter = ApplicationBackgroundWaiter()
            let response = await waiter.sendAndWait(scene: activeScene) {
                let didSend = sendPrimarySystemNavigationResponse(action: action)
                attempts.append("system-navigation-response:\(didSend)")
                var postResponseAttempts: [String] = []
                let isStillValid = invokeBooleanNoArgument(
                    receiver: action,
                    selectorName: "isValid",
                    encoding: "B16@0:8",
                    attempts: &postResponseAttempts
                ) ?? false
                let canStillSend = invokeBooleanNoArgument(
                    receiver: action,
                    selectorName: "canSendResponse",
                    encoding: "B16@0:8",
                    attempts: &postResponseAttempts
                ) ?? false
                attempts.append(contentsOf: postResponseAttempts)
                attempts.append("system-navigation-post-valid:\(isStillValid)")
                attempts.append("system-navigation-post-can-send:\(canStillSend)")
                attempts = bounded(attempts)
                onAttemptsChanged?(attempts)
                return didSend
            }
            attempts.append(
                "system-navigation-backgrounded:\(response.didEnterBackground)"
            )
            attempts = bounded(attempts)
            onAttemptsChanged?(attempts)

            if response.didSend && response.didEnterBackground {
                return HostAppSwitchOutcome(didOpen: true, attempts: attempts)
            }
        } else if
            inspection.hasLivePrimaryDestination,
            !inspection.confirmsReturn(to: host)
        {
            // A live action whose primary destination names no application, or
            // names one other than the host, suspends SpeakPaste to the Home
            // Screen. Leave the one-shot response unsent and use a route whose
            // destination is known.
            attempts.append(
                "system-navigation-destination-unconfirmed:resolved="
                    + diagnosticValue(inspection.primaryDestinationBundleIdentifier)
                    + ";expected=" + diagnosticValue(host)
            )
            attempts = bounded(attempts)
            onAttemptsChanged?(attempts)
        } else if
            let action = inspection.action,
            hasAttemptedSystemNavigationAction(action)
        {
            attempts.append("system-navigation-response:already-attempted")
            attempts = bounded(attempts)
            onAttemptsChanged?(attempts)
        } else if
            inspection.confirmsReturn(to: host),
            !UIApplication.shared.connectedScenes.contains(where: {
                $0.activationState == .foregroundActive
            })
        {
            attempts.append("system-navigation-active-scene:missing")
            attempts = bounded(attempts)
            onAttemptsChanged?(attempts)
        }

        guard let bundleIdentifier = host else {
            attempts.append("missing-host")
            attempts = bounded(attempts)
            onAttemptsChanged?(attempts)
            return HostAppSwitchOutcome(didOpen: false, attempts: attempts)
        }

        // If SpringBoard did not provide a live breadcrumb action, use the
        // host's public URL scheme. iOS owns the transition and any one-time
        // confirmation for this fallback.
        if let url = fallbackURL(for: bundleIdentifier) {
            let didOpen = await UIApplication.shared.open(url)
            attempts.append("host-url:\(didOpen)")
            attempts = bounded(attempts)
            onAttemptsChanged?(attempts)
            if didOpen {
                return HostAppSwitchOutcome(didOpen: true, attempts: attempts)
            }
        }

        // SpeakPaste is a private sideload. Keep bundle activation only as a
        // last resort for hosts without a known URL; this is not a public API.
        let didOpen = openUsingWorkspace(bundleIdentifier: bundleIdentifier)
        attempts.append("workspace-bundle:\(didOpen)")
        attempts = bounded(attempts)
        onAttemptsChanged?(attempts)
        return HostAppSwitchOutcome(didOpen: didOpen, attempts: attempts)
    }

    private static func anticipatedFallbackRoute(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier = validBundleIdentifier(bundleIdentifier) else {
            return "missing-host"
        }
        return fallbackURL(for: bundleIdentifier) == nil
            ? "workspace-bundle"
            : "host-url"
    }

    private static func inspectSystemNavigationAction() -> SystemNavigationInspection {
        var attempts: [String] = []
        let actionSelector = NSSelectorFromString("_systemNavigationAction")
        guard
            let method = exactMethod(
                on: UIApplication.self,
                selector: actionSelector,
                encoding: "@16@0:8"
            )
        else {
            attempts.append(
                selectorDiagnostic(
                    on: UIApplication.self,
                    selector: actionSelector,
                    label: "action"
                )
            )
            return SystemNavigationInspection(
                action: nil,
                isValid: false,
                canSendResponse: false,
                destinations: [],
                primaryDestinationBundleIdentifier: nil,
                attempts: attempts
            )
        }

        typealias ObjectNoArgument =
            @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let getAction = unsafeBitCast(
            implementation,
            to: ObjectNoArgument.self
        )
        guard
            let unmanagedAction = getAction(UIApplication.shared, actionSelector)
        else {
            attempts.append("system-navigation-action:nil")
            return SystemNavigationInspection(
                action: nil,
                isValid: false,
                canSendResponse: false,
                destinations: [],
                primaryDestinationBundleIdentifier: nil,
                attempts: attempts
            )
        }

        let action = unmanagedAction.takeUnretainedValue()
        guard
            let expectedClass = NSClassFromString("UISystemNavigationAction"),
            let object = action as? NSObject,
            object.isKind(of: expectedClass),
            let actionClass = object_getClass(action)
        else {
            attempts.append("system-navigation-action:unexpected-class")
            return SystemNavigationInspection(
                action: nil,
                isValid: false,
                canSendResponse: false,
                destinations: [],
                primaryDestinationBundleIdentifier: nil,
                attempts: attempts
            )
        }

        attempts.append(
            "system-navigation-action:\(String(cString: class_getName(actionClass)))"
        )
        attempts.append(
            "system-navigation-identity:\(String(describing: ObjectIdentifier(action)))"
        )
        let isValid = invokeBooleanNoArgument(
            receiver: action,
            selectorName: "isValid",
            encoding: "B16@0:8",
            attempts: &attempts
        ) ?? false
        let canSendResponse = invokeBooleanNoArgument(
            receiver: action,
            selectorName: "canSendResponse",
            encoding: "B16@0:8",
            attempts: &attempts
        ) ?? false
        let destinations = navigationDestinations(
            action: action,
            attempts: &attempts
        )

        attempts.append("system-navigation-valid:\(isValid)")
        attempts.append("system-navigation-can-send:\(canSendResponse)")
        attempts.append(
            "system-navigation-destinations:"
                + (destinations.isEmpty
                    ? "none"
                    : destinations.sorted().map(String.init).joined(separator: ","))
        )

        for destination in destinations.sorted() {
            attempts.append(
                destinationDiagnostic(action: action, destination: destination)
            )
        }

        let primaryBundleIdentifier = destinations.contains(primaryDestination)
            ? resolvedBundleIdentifier(
                action: action,
                destination: primaryDestination
            )
            : nil
        attempts.append(
            "system-navigation-primary-bundle:"
                + diagnosticValue(primaryBundleIdentifier)
        )

        return SystemNavigationInspection(
            action: action,
            isValid: isValid,
            canSendResponse: canSendResponse,
            destinations: destinations,
            primaryDestinationBundleIdentifier: primaryBundleIdentifier,
            attempts: attempts
        )
    }

    /// The application a destination leads to, taken from SpringBoard's own
    /// metadata. Falls back to the destination URL's scheme because a
    /// breadcrumb may expose a launch URL without a bundle identifier.
    private static func resolvedBundleIdentifier(
        action: AnyObject,
        destination: UInt
    ) -> String? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        if
            let bundle = destinationString(
                action: action,
                selectorName: "bundleIdForDestination:",
                destination: destination
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundle.isEmpty,
            bundle.caseInsensitiveCompare(ownBundleIdentifier ?? "") != .orderedSame
        {
            return bundle
        }
        guard
            let scheme = destinationURL(
                action: action,
                destination: destination
            )?.scheme
        else {
            return nil
        }
        return bundleIdentifier(forScheme: scheme)
    }

    private static func navigationDestinations(
        action: AnyObject,
        attempts: inout [String]
    ) -> Set<UInt> {
        let selector = NSSelectorFromString("destinations")
        guard
            let actionClass = object_getClass(action),
            let method = exactMethod(
                on: actionClass,
                selector: selector,
                encoding: "@16@0:8"
            )
        else {
            if let actionClass = object_getClass(action) {
                attempts.append(
                    selectorDiagnostic(
                        on: actionClass,
                        selector: selector,
                        label: "destinations"
                    )
                )
            }
            return []
        }

        typealias ObjectNoArgument =
            @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let getDestinations = unsafeBitCast(
            implementation,
            to: ObjectNoArgument.self
        )
        guard
            let value = getDestinations(action, selector)?.takeUnretainedValue(),
            let array = value as? NSArray
        else {
            attempts.append("system-navigation-destinations:unexpected-value")
            return []
        }

        return Set(array.compactMap { ($0 as? NSNumber)?.uintValue })
    }

    private static func destinationDiagnostic(
        action: AnyObject,
        destination: UInt
    ) -> String {
        let title = destinationString(
            action: action,
            selectorName: "titleForDestination:",
            destination: destination
        )
        let bundle = destinationString(
            action: action,
            selectorName: "bundleIdForDestination:",
            destination: destination
        )
        let scene = destinationString(
            action: action,
            selectorName: "sceneIdentifierForDestination:",
            destination: destination
        )
        let urlScheme = destinationURL(
            action: action,
            destination: destination
        )?.scheme

        return [
            "system-navigation-destination:\(destination)",
            "title=\(diagnosticValue(title))",
            "bundle=\(diagnosticValue(bundle))",
            "scene=\(scene == nil ? "nil" : "present")",
            "url-scheme=\(diagnosticValue(urlScheme))",
        ].joined(separator: ";")
    }

    private static func destinationString(
        action: AnyObject,
        selectorName: String,
        destination: UInt
    ) -> String? {
        guard
            let value = invokeDestinationObject(
                receiver: action,
                selectorName: selectorName,
                destination: destination
            )
        else {
            return nil
        }
        if let string = value as? NSString {
            return String(string)
        }
        return nil
    }

    private static func destinationURL(
        action: AnyObject,
        destination: UInt
    ) -> URL? {
        invokeDestinationObject(
            receiver: action,
            selectorName: "URLForDestination:",
            destination: destination
        ) as? URL
    }

    private static func invokeDestinationObject(
        receiver: AnyObject,
        selectorName: String,
        destination: UInt
    ) -> AnyObject? {
        guard let receiverClass = object_getClass(receiver) else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard
            let method = exactMethod(
                on: receiverClass,
                selector: selector,
                encoding: "@24@0:8Q16"
            )
        else {
            return nil
        }

        typealias ObjectDestination =
            @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let invoke = unsafeBitCast(
            implementation,
            to: ObjectDestination.self
        )
        return invoke(receiver, selector, destination)?.takeUnretainedValue()
    }

    private static func invokeBooleanNoArgument(
        receiver: AnyObject,
        selectorName: String,
        encoding: String,
        attempts: inout [String]
    ) -> Bool? {
        guard let receiverClass = object_getClass(receiver) else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard
            let method = exactMethod(
                on: receiverClass,
                selector: selector,
                encoding: encoding
            )
        else {
            attempts.append(
                selectorDiagnostic(
                    on: receiverClass,
                    selector: selector,
                    label: selectorName
                )
            )
            return nil
        }

        typealias BooleanNoArgument =
            @convention(c) (AnyObject, Selector) -> Bool
        let implementation = method_getImplementation(method)
        let invoke = unsafeBitCast(
            implementation,
            to: BooleanNoArgument.self
        )
        return invoke(receiver, selector)
    }

    private static func sendPrimarySystemNavigationResponse(
        action: AnyObject
    ) -> Bool {
        guard let actionClass = object_getClass(action) else { return false }

        // Recheck the one-shot gates immediately before sending. The response
        // method itself does not perform these checks.
        var ignoredAttempts: [String] = []
        guard
            invokeBooleanNoArgument(
                receiver: action,
                selectorName: "isValid",
                encoding: "B16@0:8",
                attempts: &ignoredAttempts
            ) == true,
            invokeBooleanNoArgument(
                receiver: action,
                selectorName: "canSendResponse",
                encoding: "B16@0:8",
                attempts: &ignoredAttempts
            ) == true
        else {
            return false
        }

        let selector = NSSelectorFromString("sendResponseForDestination:")
        guard
            let method = exactMethod(
                on: actionClass,
                selector: selector,
                encoding: "B24@0:8Q16"
            )
        else {
            return false
        }

        typealias BooleanDestination =
            @convention(c) (AnyObject, Selector, UInt) -> Bool
        let implementation = method_getImplementation(method)
        let send = unsafeBitCast(
            implementation,
            to: BooleanDestination.self
        )
        return send(action, selector, primaryDestination)
    }

    private static func hasAttemptedSystemNavigationAction(
        _ action: AnyObject
    ) -> Bool {
        attemptedSystemNavigationActions.removeAll { $0.action == nil }
        return attemptedSystemNavigationActions.contains { $0.action === action }
    }

    private static func markSystemNavigationActionAttempted(
        _ action: AnyObject
    ) {
        attemptedSystemNavigationActions.removeAll { $0.action == nil }
        attemptedSystemNavigationActions.append(WeakSystemNavigationAction(action))
    }

    private static func exactMethod(
        on receiverClass: AnyClass,
        selector: Selector,
        encoding: String
    ) -> Method? {
        guard
            let method = class_getInstanceMethod(receiverClass, selector),
            let typeEncoding = method_getTypeEncoding(method),
            String(cString: typeEncoding) == encoding
        else {
            return nil
        }
        return method
    }

    private static func selectorDiagnostic(
        on receiverClass: AnyClass,
        selector: Selector,
        label: String
    ) -> String {
        guard
            let method = class_getInstanceMethod(receiverClass, selector),
            let typeEncoding = method_getTypeEncoding(method)
        else {
            return "system-navigation-selector:\(label):missing"
        }
        return "system-navigation-selector:\(label):encoding="
            + String(cString: typeEncoding)
    }

    private static func diagnosticValue(_ value: String?) -> String {
        guard let value else { return "nil" }
        let cleaned = value
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\n", with: " ")
        return String(cleaned.prefix(80))
    }

    private static func bounded(_ attempts: [String]) -> [String] {
        let limit = 120
        guard attempts.count > limit else { return attempts }
        let headCount = limit / 2
        let tailCount = limit - headCount
        return Array(attempts.prefix(headCount))
            + ["... \(attempts.count - limit) earlier diagnostics omitted ..."]
            + Array(attempts.suffix(tailCount))
    }

    private static func validBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidValues: Set<String> = ["", "<null>", "(null)", "null", "nil"]
        let ownBundleIdentifiers = Set(
            [
                Bundle.main.bundleIdentifier,
                Bundle.main.bundleIdentifier.map { $0 + ".Keyboard" },
            ].compactMap { $0 }
        )
        // The keyboard resolves the host by reading that app's own bundle
        // rather than inferring it, so any well-formed identifier is usable.
        // Hosts outside the curated list simply have no URL scheme and fall
        // through to bundle activation.
        guard
            !invalidValues.contains(identifier.lowercased()),
            !ownBundleIdentifiers.contains(identifier),
            identifier.contains("."),
            !identifier.contains(" ")
        else {
            return nil
        }
        return identifier
    }

    private static func openUsingWorkspace(bundleIdentifier: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard
            let classMethod = class_getClassMethod(
                workspaceClass,
                defaultSelector
            ),
            let defaultEncoding = method_getTypeEncoding(classMethod),
            String(cString: defaultEncoding) == "@16@0:8"
        else {
            return false
        }

        typealias DefaultWorkspaceFunction =
            @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let defaultImplementation = method_getImplementation(classMethod)
        let defaultWorkspace = unsafeBitCast(
            defaultImplementation,
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
        typealias OpenFunction =
            @convention(c) (AnyObject, Selector, NSString) -> Bool
        let openImplementation = method_getImplementation(openMethod)
        let open = unsafeBitCast(openImplementation, to: OpenFunction.self)
        return open(workspace, openSelector, bundleIdentifier as NSString)
    }

    private static let fallbackURLStrings: [String: String] = [
        "com.apple.MobileSMS": "sms:",
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.mobilemail": "message://",
        "com.openai.chat": "chatgpt://",
        "com.anthropic.claude": "claude://",
        "net.whatsapp.WhatsApp": "whatsapp://",
        "com.tinyspeck.chatlyio": "slack://",
        "com.google.Gmail": "googlegmail://",
        "com.linkedin.LinkedIn": "linkedin://",
    ]

    private static func fallbackURL(for bundleIdentifier: String) -> URL? {
        fallbackURLStrings[bundleIdentifier].flatMap(URL.init(string:))
    }

    private static func bundleIdentifier(forScheme scheme: String) -> String? {
        fallbackURLStrings.first { _, value in
            URL(string: value)?.scheme?.caseInsensitiveCompare(scheme)
                == .orderedSame
        }?.key
    }
}
