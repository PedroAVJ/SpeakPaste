import Darwin
import ObjectiveC.runtime
import UIKit

struct HostApplicationResolution: Equatable, Sendable {
    let bundleIdentifier: String?
    let attempts: [String]
}

private struct KeyboardSceneCandidate {
    let labels: [String]
    let object: UIScene
}

private struct KeyboardArbiterResolution {
    let bundleIdentifier: String?
    let attempts: [String]
}

struct HostApplicationResolver {
    @MainActor
    func resolve(for controller: UIInputViewController) -> HostApplicationResolution {
        var attempts: [String] = []

        let arbiterResolution = keyboardArbiterResolution(for: controller)
        attempts.append(contentsOf: arbiterResolution.attempts)
        if let identifier = arbiterResolution.bundleIdentifier {
            return resolution(identifier, attempts)
        }

        let legacyValue = legacyBundleIdentifier(for: controller)
        attempts.append("controller-legacy:\(diagnosticValue(legacyValue))")
        if let identifier = knownBundleIdentifier(exactValue: legacyValue) {
            return resolution(identifier, attempts)
        }

        if
            let processID = hostProcessIdentifier(for: controller),
            let processValue = bundleIdentifier(forProcessID: processID),
            let identifier = knownBundleIdentifier(exactValue: processValue)
        {
            attempts.append("controller-host-pid:\(processID)=\(identifier)")
            return resolution(identifier, attempts)
        }
        attempts.append("controller-host-pid:<nil>")

        let environment = ProcessInfo.processInfo.environment
        let environmentValue = environment["XPCExtensionHostBundleIdentifier"]
        attempts.append("environment-host:\(diagnosticValue(environmentValue))")
        if let identifier = knownBundleIdentifier(exactValue: environmentValue) {
            return resolution(identifier, attempts)
        }

        let environmentPID = environment["XPCExtensionHostPID"].flatMap(Int32.init)
        if
            let environmentPID,
            let processValue = bundleIdentifier(forProcessID: environmentPID),
            let identifier = knownBundleIdentifier(exactValue: processValue)
        {
            attempts.append("environment-pid:\(environmentPID)=\(identifier)")
            return resolution(identifier, attempts)
        }
        attempts.append(
            "environment-pid:\(environmentPID.map(String.init) ?? "<nil>")"
        )

        for candidate in hostCandidates(for: controller) {
            attempts.append("candidate:\(candidate.label)=\(className(candidate.object))")
            for selectorName in Self.hostIdentifierSelectors {
                guard
                    let value = objectValue(
                        selectorName: selectorName,
                        from: candidate.object
                    )
                else {
                    continue
                }
                attempts.append(
                    "\(candidate.label).\(selectorName):\(diagnosticValue(value))"
                )
                if let identifier = knownBundleIdentifier(exactValue: value) {
                    return resolution(identifier, attempts)
                }
            }

            for selectorName in Self.hostProcessSelectors {
                guard
                    let processID = integerValue(
                        selectorName: selectorName,
                        from: candidate.object
                    ),
                    processID > 0
                else {
                    continue
                }
                let processValue = bundleIdentifier(forProcessID: processID)
                attempts.append(
                    "\(candidate.label).\(selectorName):\(processID)=\(diagnosticValue(processValue))"
                )
                if let identifier = knownBundleIdentifier(exactValue: processValue) {
                    return resolution(identifier, attempts)
                }
            }
        }

        let frontmostValue = frontmostBundleIdentifier()
        attempts.append("springboard-frontmost:\(diagnosticValue(frontmostValue))")
        return resolution(
            knownBundleIdentifier(exactValue: frontmostValue),
            attempts
        )
    }

    @MainActor
    private func keyboardArbiterResolution(
        for controller: UIInputViewController
    ) -> KeyboardArbiterResolution {
        var attempts: [String] = []
        let (candidates, candidateAttempts) = keyboardSceneCandidates(
            for: controller
        )
        attempts.append(contentsOf: candidateAttempts)
        guard !candidates.isEmpty else {
            attempts.append("arbiter-scene:<nil>")
            return KeyboardArbiterResolution(
                bundleIdentifier: nil,
                attempts: attempts
            )
        }

        guard let arbiterClass = NSClassFromString("_UIKeyboardArbiterClient") else {
            attempts.append("arbiter-class:<missing>")
            return KeyboardArbiterResolution(
                bundleIdentifier: nil,
                attempts: attempts
            )
        }
        let selector = NSSelectorFromString(
            "keyboardClientFBSSceneIdentityStringOrIdentifierFromScene:"
        )
        guard let method = class_getClassMethod(arbiterClass, selector) else {
            attempts.append("arbiter-selector:<missing>")
            return KeyboardArbiterResolution(
                bundleIdentifier: nil,
                attempts: attempts
            )
        }

        let encoding = method_getTypeEncoding(method).map {
            String(cString: $0)
        }
        attempts.append("arbiter-signature:\(diagnosticValue(encoding))")
        let returnEncoding = copiedMethodType(method_copyReturnType(method))
        let sceneEncoding = copiedMethodType(
            method_copyArgumentType(method, 2)
        )
        guard
            method_getNumberOfArguments(method) == 3,
            objcBaseType(returnEncoding) == "@",
            objcBaseType(sceneEncoding) == "@"
        else {
            attempts.append(
                "arbiter-signature:<rejected>;return=\(returnEncoding ?? "<nil>");scene=\(sceneEncoding ?? "<nil>")"
            )
            return KeyboardArbiterResolution(
                bundleIdentifier: nil,
                attempts: attempts
            )
        }

        typealias ArbiterFunction = @convention(c) (
            AnyClass,
            Selector,
            AnyObject
        ) -> Unmanaged<AnyObject>?
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: ArbiterFunction.self
        )
        let fbsSelector = NSSelectorFromString("_FBSScene")
        let sceneIdentifierSelector = NSSelectorFromString("_sceneIdentifier")
        var resolvedBundles: Set<String> = []

        for candidate in candidates {
            let label = candidate.labels.joined(separator: "|")
            attempts.append(
                "arbiter-candidate:\(label)=\(className(candidate.object))"
            )
            attempts.append(
                "arbiter-session:\(label)=\(diagnosticValue(candidate.object.session.persistentIdentifier))"
            )

            let hasFBSScene = candidate.object.responds(to: fbsSelector)
            let hasSceneIdentifier = candidate.object.responds(
                to: sceneIdentifierSelector
            )
            attempts.append(
                "arbiter-capabilities:\(label)=fbs:\(hasFBSScene),scene-id:\(hasSceneIdentifier)"
            )
            guard hasFBSScene, hasSceneIdentifier else { continue }

            let processResolution = processIdentityResolution(
                for: candidate.object,
                label: label
            )
            attempts.append(contentsOf: processResolution.attempts)
            resolvedBundles.formUnion(processResolution.bundleIdentifiers)

            guard
                let unmanaged = function(
                    arbiterClass,
                    selector,
                    candidate.object
                )
            else {
                attempts.append("arbiter-result:\(label)=<nil>")
                continue
            }

            let result = unmanaged.takeUnretainedValue()
            guard let value = result as? NSString else {
                let resultClass = (result as? NSObject).map(className) ?? "<unknown>"
                attempts.append(
                    "arbiter-result-class:\(label)=\(resultClass)"
                )
                attempts.append(
                    "arbiter-result-description:\(label)=\(diagnosticValue(String(describing: result)))"
                )
                continue
            }

            let rawValue = value as String
            let decodedValue = rawValue.removingPercentEncoding ?? rawValue
            attempts.append(
                "arbiter-result:\(label)=\(diagnosticValue(rawValue))"
            )
            attempts.append(
                "arbiter-decoded:\(label)=\(diagnosticValue(decodedValue))"
            )
            if
                let match = knownBundleIdentifier(
                    fromSceneIdentity: decodedValue
                )
            {
                attempts.append(
                    "arbiter-scene-match:\(label)=\(match)"
                )
                resolvedBundles.insert(match)
            }
        }

        guard resolvedBundles.count == 1, let identifier = resolvedBundles.first else {
            if resolvedBundles.count > 1 {
                attempts.append(
                    "arbiter-bundle-conflict:\(resolvedBundles.sorted().joined(separator: ","))"
                )
            } else {
                attempts.append("arbiter-bundle:<nil>")
            }
            return KeyboardArbiterResolution(
                bundleIdentifier: nil,
                attempts: attempts
            )
        }

        attempts.append("arbiter-bundle:\(identifier)")
        return KeyboardArbiterResolution(
            bundleIdentifier: identifier,
            attempts: attempts
        )
    }

    @MainActor
    private func keyboardSceneCandidates(
        for controller: UIInputViewController
    ) -> ([KeyboardSceneCandidate], [String]) {
        var baseScenes: [(label: String, object: UIScene)] = []
        var baseIdentifiers: Set<ObjectIdentifier> = []

        func appendBase(_ label: String, _ scene: UIScene?) {
            guard let scene else { return }
            let identifier = ObjectIdentifier(scene)
            guard baseIdentifiers.insert(identifier).inserted else { return }
            baseScenes.append((label, scene))
        }

        let loadedView = controller.viewIfLoaded
        let window = loadedView?.window
        appendBase("window-scene", window?.windowScene)

        let responderRoots: [(String, UIResponder?)] = [
            ("controller", controller),
            ("view", loadedView),
            ("window", window),
        ]
        for (rootLabel, root) in responderRoots {
            var responder = root
            var index = 0
            while let current = responder, index < 16 {
                appendBase("\(rootLabel)-responder-\(index)", current as? UIScene)
                if let currentWindow = current as? UIWindow {
                    appendBase(
                        "\(rootLabel)-responder-\(index)-window-scene",
                        currentWindow.windowScene
                    )
                }
                responder = current.next
                index += 1
            }
        }

        var order: [ObjectIdentifier] = []
        var objects: [ObjectIdentifier: UIScene] = [:]
        var labels: [ObjectIdentifier: [String]] = [:]
        var attempts: [String] = []

        func register(_ label: String, _ object: UIScene) {
            let identifier = ObjectIdentifier(object)
            if objects[identifier] == nil {
                objects[identifier] = object
                order.append(identifier)
            }
            labels[identifier, default: []].append(label)
        }

        for base in baseScenes {
            let settingsObject = privateObjectValue(
                selectorName: "_settingsScene",
                from: base.object
            )
            if let settingsScene = settingsObject as? UIScene {
                attempts.append(
                    "arbiter-settings:\(base.label)=\(className(settingsScene))"
                )
                register("\(base.label)._settingsScene", settingsScene)
            } else if let settingsObject {
                attempts.append(
                    "arbiter-settings:\(base.label)=non-scene:\(className(settingsObject))"
                )
            } else {
                attempts.append("arbiter-settings:\(base.label)=<nil>")
            }
            register(base.label, base.object)
        }

        let candidates = order.compactMap { identifier -> KeyboardSceneCandidate? in
            guard let object = objects[identifier] else { return nil }
            return KeyboardSceneCandidate(
                labels: labels[identifier] ?? [],
                object: object
            )
        }
        return (candidates, attempts)
    }

    private func processIdentityResolution(
        for scene: NSObject,
        label: String
    ) -> (bundleIdentifiers: Set<String>, attempts: [String]) {
        var attempts: [String] = []
        var bundleIdentifiers: Set<String> = []
        guard let fbsScene = privateObjectValue(
            selectorName: "_FBSScene",
            from: scene
        ) else {
            attempts.append("arbiter-fbs:\(label)=<nil>")
            return (bundleIdentifiers, attempts)
        }
        attempts.append("arbiter-fbs:\(label)=\(className(fbsScene))")

        for processSelector in ["hostProcess", "clientProcess"] {
            guard
                let process = privateObjectValue(
                    selectorName: processSelector,
                    from: fbsScene
                )
            else {
                attempts.append(
                    "arbiter-\(processSelector):\(label)=<nil>"
                )
                continue
            }
            let processID = integerValue(
                selectorName: "pid",
                from: process
            )
            attempts.append(
                "arbiter-\(processSelector):\(label)=\(className(process)),pid:\(processID.map(String.init) ?? "<nil>")"
            )
            guard
                let identity = privateObjectValue(
                    selectorName: "identity",
                    from: process
                )
            else {
                attempts.append(
                    "arbiter-\(processSelector)-identity:\(label)=<nil>"
                )
                continue
            }

            var identities: [(String, NSObject)] = [("identity", identity)]
            if let hostIdentity = privateObjectValue(
                selectorName: "hostIdentity",
                from: identity
            ) {
                identities.append(("hostIdentity", hostIdentity))
            }
            for (identityLabel, identityObject) in identities {
                let value = objectValue(
                    selectorName: "embeddedApplicationIdentifier",
                    from: identityObject
                )
                attempts.append(
                    "arbiter-\(processSelector)-\(identityLabel):\(label)=\(diagnosticValue(value))"
                )
                if let match = knownBundleIdentifier(exactValue: value) {
                    bundleIdentifiers.insert(match)
                }
            }
        }
        return (bundleIdentifiers, attempts)
    }

    private func privateObjectValue(
        selectorName: String,
        from object: NSObject
    ) -> NSObject? {
        let selector = NSSelectorFromString(selectorName)
        guard
            object.responds(to: selector),
            let method = class_getInstanceMethod(type(of: object), selector),
            method_getNumberOfArguments(method) == 2,
            objcBaseType(copiedMethodType(method_copyReturnType(method))) == "@"
        else {
            return nil
        }
        typealias Getter = @convention(c) (
            AnyObject,
            Selector
        ) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(
            method_getImplementation(method),
            to: Getter.self
        )
        return getter(object, selector)?.takeUnretainedValue() as? NSObject
    }

    private func copiedMethodType(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func objcBaseType(_ encoding: String?) -> Character? {
        guard let encoding else { return nil }
        let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V"]
        return encoding.drop(while: { qualifiers.contains($0) }).first
    }

    private func knownBundleIdentifier(exactValue: String?) -> String? {
        guard let exactValue else { return nil }
        let value = exactValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Self.knownHostBundleIdentifiers.first {
            $0.lowercased() == value
        }
    }

    private func knownBundleIdentifier(
        fromSceneIdentity value: String
    ) -> String? {
        var separators = CharacterSet(charactersIn: "/:|?&#=,;")
        separators.formUnion(.whitespacesAndNewlines)
        let components = value
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        for bundleIdentifier in Self.knownHostBundleIdentifiers {
            let bundle = bundleIdentifier.lowercased()
            if components.contains(where: {
                $0 == bundle || $0.hasPrefix(bundle + "-")
            }) {
                return bundleIdentifier
            }
        }
        return nil
    }

    private static let knownHostBundleIdentifiers = [
        "com.apple.MobileSMS",
        "com.apple.mobilenotes",
        "com.apple.mobilemail",
        "com.openai.chat",
        "com.anthropic.claude",
        "net.whatsapp.WhatsApp",
        "com.tinyspeck.chatlyio",
        "com.google.Gmail",
        "com.linkedin.LinkedIn",
    ]

    private func legacyBundleIdentifier(
        for controller: UIInputViewController
    ) -> String? {
        let selector = NSSelectorFromString("_hostApplicationBundleIdentifier")
        guard controller.responds(to: selector) else { return nil }
        return controller.perform(selector)?.takeUnretainedValue() as? String
    }

    private func hostProcessIdentifier(
        for controller: UIInputViewController
    ) -> Int32? {
        let selector = NSSelectorFromString("_hostProcessIdentifier")
        guard controller.responds(to: selector) else { return nil }
        typealias ProcessIdentifierFunction = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = controller.method(for: selector)
        let function = unsafeBitCast(
            implementation,
            to: ProcessIdentifierFunction.self
        )
        let processID = function(controller, selector)
        return processID > 0 ? processID : nil
    }

    private static let hostIdentifierSelectors = [
        "_hostApplicationBundleIdentifier",
        "hostApplicationBundleIdentifier",
        "__hostBundleIdentifier",
        "_hostBundleIdentifier",
        "hostBundleIdentifier",
        "_hostBundleID",
        "hostBundleID",
        "_hostBundleId",
        "hostBundleId",
    ]

    private static let hostProcessSelectors = [
        "_hostProcessIdentifier",
        "hostProcessIdentifier",
        "_hostPID",
        "hostPID",
    ]

    @MainActor
    private func hostCandidates(
        for controller: UIInputViewController
    ) -> [(label: String, object: NSObject)] {
        var candidates: [(String, NSObject)] = []
        var identifiers: Set<ObjectIdentifier> = []

        func append(_ label: String, _ object: NSObject?) {
            guard let object else { return }
            let identifier = ObjectIdentifier(object)
            guard identifiers.insert(identifier).inserted else { return }
            candidates.append((label, object))
        }

        append("controller", controller)
        append("extension-context", controller.extensionContext)
        append("view", controller.viewIfLoaded)
        append("window", controller.viewIfLoaded?.window)
        append("scene", controller.viewIfLoaded?.window?.windowScene)
        append("scene-session", controller.viewIfLoaded?.window?.windowScene?.session)

        var responder = controller.next
        var responderIndex = 0
        while let current = responder, responderIndex < 12 {
            append("responder-\(responderIndex)", current)
            responder = current.next
            responderIndex += 1
        }

        var parent = controller.parent
        var parentIndex = 0
        while let current = parent, parentIndex < 8 {
            append("parent-\(parentIndex)", current)
            parent = current.parent
            parentIndex += 1
        }

        return candidates
    }

    private func objectValue(
        selectorName: String,
        from object: NSObject
    ) -> String? {
        let selector = NSSelectorFromString(selectorName)
        guard
            object.responds(to: selector),
            let method = class_getInstanceMethod(type(of: object), selector)
        else {
            return nil
        }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard returnType.pointee == Int8(UInt8(ascii: "@")) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func integerValue(
        selectorName: String,
        from object: NSObject
    ) -> Int32? {
        let selector = NSSelectorFromString(selectorName)
        guard
            object.responds(to: selector),
            let method = class_getInstanceMethod(type(of: object), selector)
        else {
            return nil
        }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }

        let implementation = method_getImplementation(method)
        switch UnicodeScalar(UInt8(bitPattern: returnType.pointee)) {
        case "i":
            typealias Function = @convention(c) (AnyObject, Selector) -> Int32
            return unsafeBitCast(implementation, to: Function.self)(object, selector)
        case "I":
            typealias Function = @convention(c) (AnyObject, Selector) -> UInt32
            let value = unsafeBitCast(implementation, to: Function.self)(object, selector)
            return value <= Int32.max ? Int32(value) : nil
        case "q":
            typealias Function = @convention(c) (AnyObject, Selector) -> Int64
            let value = unsafeBitCast(implementation, to: Function.self)(object, selector)
            return Int32(exactly: value)
        case "Q":
            typealias Function = @convention(c) (AnyObject, Selector) -> UInt64
            let value = unsafeBitCast(implementation, to: Function.self)(object, selector)
            return Int32(exactly: value)
        default:
            return nil
        }
    }

    private func resolution(
        _ bundleIdentifier: String?,
        _ attempts: [String]
    ) -> HostApplicationResolution {
        let boundedAttempts: [String]
        if attempts.count <= 160 {
            boundedAttempts = attempts
        } else {
            let omitted = attempts.count - 160
            boundedAttempts = Array(attempts.prefix(80))
                + ["diagnostics-omitted:\(omitted)"]
                + Array(attempts.suffix(80))
        }
        return HostApplicationResolution(
            bundleIdentifier: bundleIdentifier,
            attempts: boundedAttempts
        )
    }

    private func diagnosticValue(_ value: String?) -> String {
        guard let value else { return "<nil>" }
        let sanitized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(sanitized.prefix(480))
    }

    private func className(_ object: NSObject) -> String {
        NSStringFromClass(type(of: object))
    }

    private func bundleIdentifier(forProcessID processID: Int32) -> String? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SBSCopyDisplayIdentifierForProcessID") else {
            return nil
        }

        typealias BundleIdentifierFunction = @convention(c) (Int32) -> Unmanaged<CFString>?
        let function = unsafeBitCast(symbol, to: BundleIdentifierFunction.self)
        guard let identifier = function(processID)?.takeRetainedValue() else {
            return nil
        }
        return identifier as String
    }

    private func frontmostBundleIdentifier() -> String? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard
            let symbol = dlsym(
                handle,
                "SBSCopyFrontmostApplicationDisplayIdentifier"
            )
        else {
            return nil
        }

        typealias FrontmostIdentifierFunction = @convention(c) () -> Unmanaged<CFString>?
        let function = unsafeBitCast(symbol, to: FrontmostIdentifierFunction.self)
        guard let identifier = function()?.takeRetainedValue() else { return nil }
        return identifier as String
    }
}
