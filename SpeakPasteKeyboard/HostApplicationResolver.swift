import Darwin
import ObjectiveC.runtime
import UIKit

struct HostApplicationResolution: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: Int32?
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

@MainActor
final class HostApplicationResolver {
    private struct Appearance: Equatable {
        let identifier: UUID
        let processIdentifier: Int32?
        let baselineGeneration: UInt64
        let previousIdentity: HostApplicationIdentity?
    }

    private static var processHasEstablishedAppearance = false
    private static var cleanBoundaryGeneration: UInt64?

    private let identityCache: HostApplicationIdentityCache
    private let arbiterRetryCount: Int
    private let arbiterRetryDelay: Duration
    private var appearance: Appearance?
    private var lastAcceptedIdentity: HostApplicationIdentity?

    init(
        identityCache: HostApplicationIdentityCache =
            HostApplicationIdentityCache(),
        arbiterRetryCount: Int = 20,
        arbiterRetryDelay: Duration = .milliseconds(75)
    ) {
        self.identityCache = identityCache
        self.arbiterRetryCount = max(1, arbiterRetryCount)
        self.arbiterRetryDelay = arbiterRetryDelay
        lastAcceptedIdentity = identityCache.load()
    }

    /// Establishes a trust boundary for this visible keyboard. The first
    /// appearance in an extension process preserves the callback captured by
    /// the Objective-C +load hook. Later appearances begin after the previous
    /// invalidation boundary and quarantine that host's bundle on a new PID.
    func beginAppearance(for controller: UIInputViewController) {
        let generation = SPHostApplicationCaptureGeneration()
        let cleanBoundaryGeneration = Self.cleanBoundaryGeneration
        let baselineGeneration = HostApplicationCapturePolicy.baselineGeneration(
            currentGeneration: generation,
            cleanBoundaryGeneration: cleanBoundaryGeneration,
            processHasEstablishedAppearance: Self.processHasEstablishedAppearance
        )
        if cleanBoundaryGeneration != nil {
            // Preserve a callback for the next host that arrived after the
            // prior controller cleanly invalidated its own host.
            Self.cleanBoundaryGeneration = nil
        }
        // The first process-load callback belongs to this first host. A
        // restart inside one appearance has no clean handoff, so its current
        // generation becomes the new boundary and UIKit is pinged again.
        Self.processHasEstablishedAppearance = true
        appearance = Appearance(
            identifier: UUID(),
            processIdentifier: hostProcessIdentifier(for: controller),
            baselineGeneration: baselineGeneration,
            previousIdentity: lastAcceptedIdentity
        )
    }

    func endAppearance() {
        appearance = nil
        Self.cleanBoundaryGeneration = SPHostApplicationCaptureInvalidate()
    }

    /// Warm the iOS 26.4+ arbiter only after the controller is visible. The
    /// shared client is lazy on a cold extension process, so one early ping in
    /// `viewWillAppear` is not sufficient.
    func prewarm(for controller: UIInputViewController) async -> Bool {
        while !Task.isCancelled {
            let currentAppearance = ensureAppearance(for: controller)
            if await prewarm(currentAppearance, for: controller) {
                return true
            }
            guard !Task.isCancelled else { return false }
            // The PID or lifecycle token changed while UIKit initialized the
            // arbiter. Establish a new boundary and run the full window again.
            beginAppearance(for: controller)
        }
        return false
    }

    private func prewarm(
        _ currentAppearance: Appearance,
        for controller: UIInputViewController
    ) async -> Bool {
        for attempt in 0...arbiterRetryCount {
            guard
                !Task.isCancelled,
                appearanceIsCurrent(currentAppearance, for: controller)
            else {
                return false
            }

            let snapshot = hostCaptureSnapshot()
            if let identifier = freshCapturedIdentifier(
                snapshot,
                for: currentAppearance,
                controller: controller
            ) {
                persistIdentity(
                    identifier,
                    processIdentifier: currentAppearance.processIdentifier
                )
                return true
            }

            guard attempt < arbiterRetryCount else {
                return appearanceIsCurrent(
                    currentAppearance,
                    for: controller
                )
            }
            _ = SPHostApplicationCaptureRefresh()
            do {
                try await Task.sleep(for: arbiterRetryDelay)
            } catch {
                return false
            }
            guard
                !Task.isCancelled,
                appearanceIsCurrent(currentAppearance, for: controller)
            else {
                return false
            }
        }
        return false
    }

    func resolve(
        for controller: UIInputViewController
    ) -> HostApplicationResolution {
        var attempts: [String] = []
        let currentAppearance = ensureAppearance(for: controller)
        var resolvedProcessIdentifier = currentAppearance.processIdentifier
        attempts.append(
            "controller-host-pid:"
                + (resolvedProcessIdentifier.map(String.init) ?? "<nil>")
        )

        // Wispr's iOS 26.4+ shape is an early keyboard-arbiter capture, not a
        // late attempt to reverse-map a PID. The Objective-C +load hook runs
        // before UIKit's first focus callback and caches the callback's
        // `_sourceBundleIdentifier` value.
        attempts.append(
            "arbiter-hook-status:\(SPHostApplicationCaptureStatus())"
        )
        attempts.append(
            "arbiter-hook-baseline:\(currentAppearance.baselineGeneration)"
        )
        var captureSnapshot = hostCaptureSnapshot()
        attempts.append("arbiter-hook-generation:\(captureSnapshot.generation)")
        if let identifier = freshCapturedIdentifier(
            captureSnapshot,
            for: currentAppearance,
            controller: controller
        ) {
            attempts.append("arbiter-hook-cached:\(identifier)")
            return resolution(
                identifier,
                attempts,
                processIdentifier: resolvedProcessIdentifier
            )
        }
        if let identifier = rejectedPreviousHostIdentifier(
            captureSnapshot,
            for: currentAppearance
        ) {
            attempts.append(
                "arbiter-hook-rejected-previous-host:\(identifier)"
            )
        }
        attempts.append("arbiter-hook-cached:<nil-or-stale>")

        let didPing = SPHostApplicationCaptureRefresh()
        attempts.append("arbiter-hook-refresh:\(didPing)")
        captureSnapshot = hostCaptureSnapshot()
        if let identifier = freshCapturedIdentifier(
            captureSnapshot,
            for: currentAppearance,
            controller: controller
        ) {
            attempts.append(
                "arbiter-hook-refreshed:\(identifier);generation=\(captureSnapshot.generation)"
            )
            return resolution(
                identifier,
                attempts,
                processIdentifier: resolvedProcessIdentifier
            )
        }
        if let identifier = rejectedPreviousHostIdentifier(
            captureSnapshot,
            for: currentAppearance
        ) {
            attempts.append(
                "arbiter-hook-rejected-previous-host:\(identifier)"
            )
        }
        attempts.append("arbiter-hook-refreshed:<nil-or-stale>")

        guard appearanceIsCurrent(currentAppearance, for: controller) else {
            attempts.append("keyboard-appearance:changed")
            return resolution(
                nil,
                attempts,
                processIdentifier: nil,
                shouldPersistIdentity: false
            )
        }

        let arbiterResolution = keyboardArbiterResolution(for: controller)
        attempts.append(contentsOf: arbiterResolution.attempts)
        if let identifier = arbiterResolution.bundleIdentifier {
            return resolution(
                identifier,
                attempts,
                processIdentifier: resolvedProcessIdentifier
            )
        }

        let legacyValue = legacyBundleIdentifier(for: controller)
        attempts.append("controller-legacy:\(diagnosticValue(legacyValue))")
        if let identifier = knownBundleIdentifier(exactValue: legacyValue) {
            return resolution(
                identifier,
                attempts,
                processIdentifier: resolvedProcessIdentifier
            )
        }

        if let processID = resolvedProcessIdentifier {
            resolvedProcessIdentifier = processID
            if
                let processValue = bundleIdentifier(forProcessID: processID),
                let identifier = knownBundleIdentifier(exactValue: processValue)
            {
                attempts.append("controller-host-pid:\(processID)=\(identifier)")
                return resolution(
                    identifier,
                    attempts,
                    processIdentifier: processID
                )
            }

            // SpringBoardServices refuses to name the host process from inside
            // a keyboard extension, but its executable path still leads to the
            // host's own bundle. Reading that Info.plist is authoritative
            // rather than a guess, so it does not need the curated allowlist.
            let pathValue = bundleIdentifier(fromExecutablePathFor: processID)
            attempts.append(
                "controller-host-path:\(processID)=\(diagnosticValue(pathValue))"
            )
            if let identifier = plausibleBundleIdentifier(pathValue) {
                return resolution(
                    identifier,
                    attempts,
                    processIdentifier: processID
                )
            }
        } else {
            attempts.append("controller-host-path:<nil>")
        }

        let environment = ProcessInfo.processInfo.environment
        let environmentValue = environment["XPCExtensionHostBundleIdentifier"]
        attempts.append("environment-host:\(diagnosticValue(environmentValue))")
        if let identifier = knownBundleIdentifier(exactValue: environmentValue) {
            return resolution(
                identifier,
                attempts,
                processIdentifier: resolvedProcessIdentifier
            )
        }

        let environmentPID = environment["XPCExtensionHostPID"].flatMap(Int32.init)
        if resolvedProcessIdentifier == nil {
            resolvedProcessIdentifier = environmentPID
        }
        if
            let environmentPID,
            currentAppearance.processIdentifier == nil
                || currentAppearance.processIdentifier == environmentPID,
            let processValue = bundleIdentifier(forProcessID: environmentPID),
            let identifier = knownBundleIdentifier(exactValue: processValue)
        {
            attempts.append("environment-pid:\(environmentPID)=\(identifier)")
            return resolution(
                identifier,
                attempts,
                processIdentifier: environmentPID
            )
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
                    return resolution(
                        identifier,
                        attempts,
                        processIdentifier: resolvedProcessIdentifier
                    )
                }
            }

            for selectorName in Self.hostProcessSelectors {
                guard
                    let processID = integerValue(
                        selectorName: selectorName,
                        from: candidate.object
                    ),
                    processID > 0,
                    currentAppearance.processIdentifier == nil
                        || currentAppearance.processIdentifier == processID
                else {
                    continue
                }
                let processValue = bundleIdentifier(forProcessID: processID)
                if resolvedProcessIdentifier == nil {
                    resolvedProcessIdentifier = processID
                }
                attempts.append(
                    "\(candidate.label).\(selectorName):\(processID)=\(diagnosticValue(processValue))"
                )
                if let identifier = knownBundleIdentifier(exactValue: processValue) {
                    return resolution(
                        identifier,
                        attempts,
                        processIdentifier: processID
                    )
                }
            }
        }

        let frontmostValue = frontmostBundleIdentifier()
        attempts.append("springboard-frontmost:\(diagnosticValue(frontmostValue))")
        if let identifier = knownBundleIdentifier(exactValue: frontmostValue) {
            return resolution(
                identifier,
                attempts,
                processIdentifier: resolvedProcessIdentifier
            )
        }

        guard appearanceIsCurrent(currentAppearance, for: controller) else {
            attempts.append("durable-host-cache:appearance-changed")
            return resolution(
                nil,
                attempts,
                processIdentifier: nil,
                shouldPersistIdentity: false
            )
        }

        if
            let cached = identityCache.matchingIdentity(
                processIdentifier: currentAppearance.processIdentifier
            ),
            let identifier = plausibleBundleIdentifier(cached.bundleIdentifier)
        {
            attempts.append(
                "durable-host-cache:\(identifier);pid=\(cached.processIdentifier)"
            )
            return resolution(
                identifier,
                attempts,
                processIdentifier: currentAppearance.processIdentifier,
                shouldPersistIdentity: false
            )
        }

        if let cached = identityCache.load() {
            attempts.append(
                "durable-host-cache:rejected;cached-pid="
                    + String(cached.processIdentifier)
            )
            identityCache.clear()
            lastAcceptedIdentity = nil
        } else {
            attempts.append("durable-host-cache:<nil>")
        }
        return resolution(
            nil,
            attempts,
            processIdentifier: currentAppearance.processIdentifier,
            shouldPersistIdentity: false
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
        "net.whatsapp.WhatsApp",
        "com.burbn.instagram",
        "com.facebook.Messenger",
        "com.atebits.Tweetie2",
        "com.linkedin.LinkedIn",
        "com.microsoft.onenote",
        "com.google.Keep",
        "notion.id",
        "com.evernote.iPhone.Evernote",
        "com.openai.chat",
        "com.anthropic.claude",
        "com.google.gemini",
        "ai.x.GrokApp",
        "ai.perplexity.app",
        "com.goodnotesapp.x",
        "com.gingerlabs.Notability",
        "net.shinyfrog.bear-iOS",
        "md.obsidian",
        "com.google.chrome.ios",
        "com.google.calendar",
        "com.google.Docs",
        "com.google.Drive",
        "com.google.Maps",
        "com.google.GoogleMobile",
        "com.microsoft.msedge",
        "com.google.ios.youtube",
        "com.facebook.Facebook",
        "com.zhiliaoapp.musically",
        "com.reddit.Reddit",
        "com.burbn.barcelona",
        "xyz.blueskyweb.app",
        "pinterest",
        "org.whispersystems.signal",
        "jp.naver.line",
        "ph.telegra.Telegraph",
        "com.tinyspeck.chatlyio",
        "com.hammerandchisel.discord",
        "com.google.Gmail",
        "com.microsoft.Office.Outlook",
        "com.yahoo.Aerogram",
        "com.superhuman.Superhuman",
        "ch.protonmail.protonmail",
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

    private func ensureAppearance(
        for controller: UIInputViewController
    ) -> Appearance {
        let currentProcessIdentifier = hostProcessIdentifier(for: controller)
        if
            let appearance,
            appearance.processIdentifier == currentProcessIdentifier
        {
            return appearance
        }

        beginAppearance(for: controller)
        // `beginAppearance` always installs a token synchronously.
        return appearance!
    }

    private func appearanceIsCurrent(
        _ expected: Appearance,
        for controller: UIInputViewController
    ) -> Bool {
        appearance?.identifier == expected.identifier
            && hostProcessIdentifier(for: controller)
                == expected.processIdentifier
    }

    private func hostCaptureSnapshot() -> (
        bundleIdentifier: String?,
        generation: UInt64
    ) {
        var generation: UInt64 = 0
        let bundleIdentifier = SPHostApplicationCaptureCopySnapshot(&generation)
        return (bundleIdentifier, generation)
    }

    private func freshCapturedIdentifier(
        _ snapshot: (bundleIdentifier: String?, generation: UInt64),
        for expected: Appearance,
        controller: UIInputViewController
    ) -> String? {
        guard
            appearance?.identifier == expected.identifier,
            let identifier = plausibleBundleIdentifier(
                snapshot.bundleIdentifier
            ),
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: identifier,
                captureGeneration: snapshot.generation,
                appearanceBaselineGeneration: expected.baselineGeneration,
                expectedProcessIdentifier: expected.processIdentifier,
                currentProcessIdentifier: hostProcessIdentifier(for: controller),
                previousIdentity: expected.previousIdentity
            )
        else {
            return nil
        }
        return identifier
    }

    private func rejectedPreviousHostIdentifier(
        _ snapshot: (bundleIdentifier: String?, generation: UInt64),
        for expected: Appearance
    ) -> String? {
        guard
            let processIdentifier = expected.processIdentifier,
            let identifier = plausibleBundleIdentifier(
                snapshot.bundleIdentifier
            ),
            HostApplicationCapturePolicy.rejectsPreviousHost(
                candidateBundleIdentifier: identifier,
                expectedProcessIdentifier: processIdentifier,
                previousIdentity: expected.previousIdentity
            )
        else {
            return nil
        }
        return identifier
    }

    private func resolution(
        _ bundleIdentifier: String?,
        _ attempts: [String],
        processIdentifier: Int32? = nil,
        shouldPersistIdentity: Bool = true
    ) -> HostApplicationResolution {
        if shouldPersistIdentity, let bundleIdentifier {
            persistIdentity(
                bundleIdentifier,
                processIdentifier: processIdentifier
            )
        }
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
            processIdentifier: processIdentifier,
            attempts: boundedAttempts
        )
    }

    private func persistIdentity(
        _ bundleIdentifier: String,
        processIdentifier: Int32?
    ) {
        guard
            let processIdentifier,
            processIdentifier > 1,
            let identifier = plausibleBundleIdentifier(bundleIdentifier)
        else {
            return
        }
        let capturedAt = Date()
        lastAcceptedIdentity = HostApplicationIdentity(
            bundleIdentifier: identifier,
            processIdentifier: processIdentifier,
            capturedAt: capturedAt
        )
        identityCache.save(
            bundleIdentifier: identifier,
            processIdentifier: processIdentifier,
            capturedAt: capturedAt
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

    /// Walk a running process's executable path up to its `.app` wrapper and
    /// read the identifier the bundle declares about itself.
    private func bundleIdentifier(fromExecutablePathFor processID: Int32) -> String? {
        // libproc is not surfaced by the iOS SDK, so bind the symbol the same
        // way this file reaches SpringBoardServices.
        typealias ProcessPathFunction = @convention(c) (
            Int32,
            UnsafeMutableRawPointer?,
            UInt32
        ) -> Int32
        guard
            let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                "proc_pidpath"
            )
        else {
            return nil
        }
        let processPath = unsafeBitCast(symbol, to: ProcessPathFunction.self)

        var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw in
            processPath(processID, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return nil }

        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        var directory = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
        while directory.pathExtension != "app", directory.path != "/" {
            directory = directory.deletingLastPathComponent()
        }
        guard directory.pathExtension == "app" else { return nil }

        let infoPlist = directory.appendingPathComponent("Info.plist")
        guard
            let contents = NSDictionary(contentsOf: infoPlist),
            let identifier = contents["CFBundleIdentifier"] as? String
        else {
            return nil
        }
        return identifier
    }

    /// Accept an identifier resolved from a bundle rather than inferred, as
    /// long as it is well formed and is not SpeakPaste itself.
    private func plausibleBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = identifier.lowercased()
        let hasBundleShape = identifier.contains(".")
            || identifier.caseInsensitiveCompare("pinterest") == .orderedSame
        guard
            hasBundleShape,
            !identifier.contains(" "),
            !["<null>", "(null)", "null", "nil"].contains(lowercased),
            lowercased != "com.apple.springboard",
            lowercased != "com.apple.spotlight",
            lowercased != "com.apple.uikitsystemapp",
            !lowercased.hasPrefix("com.apple.inputmethod."),
            let ownIdentifier = Bundle.main.bundleIdentifier
        else {
            return nil
        }
        let containingIdentifier = ownIdentifier.hasSuffix(".Keyboard")
            ? String(ownIdentifier.dropLast(".Keyboard".count))
            : ownIdentifier
        guard
            identifier != ownIdentifier,
            identifier != containingIdentifier
        else {
            return nil
        }
        return identifier
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
