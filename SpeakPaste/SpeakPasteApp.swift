import SwiftUI
import UIKit

@main
@MainActor
final class SpeakPasteAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemNavigationActionDidChange(_:)),
            name: HostAppSwitcher.systemNavigationActionChangedNotification,
            object: nil
        )
        HostAppSwitcher.probeSystemNavigationAction(route: "application-launch")
#if DEBUG
        seedAPIKeyFromEnvironmentIfNeeded()
#endif
        return true
    }

#if DEBUG
    /// A Mac cannot write to the device Keychain, so installing a debug build
    /// leaves the app with no key until someone types one. Let a debug launch
    /// seed it once from the environment instead. `scripts/install-iphone.sh`
    /// passes it through `DEVICECTL_CHILD_ELEVENLABS_API_KEY`, so the value
    /// never reaches the source tree, the app bundle, or a command line.
    /// Release builds do not contain this path.
    private func seedAPIKeyFromEnvironmentIfNeeded() {
        guard
            let value = ProcessInfo.processInfo
                .environment["ELEVENLABS_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return
        }
        // Overwrite rather than only filling a gap, so rotating the key on the
        // Mac and re-running the install script keeps the phone in sync.
        let keychain = KeychainStore()
        var saveError: String?
        if keychain.load() != value {
            do {
                try keychain.save(value)
            } catch {
                saveError = error.localizedDescription
            }
        }
        recordKeychainSeedResult(
            storedKey: keychain.load() != nil,
            saveError: saveError
        )
    }

    /// Report only whether a key is present, never the key itself, so an
    /// install can be verified from the Mac without a dictation run.
    private func recordKeychainSeedResult(storedKey: Bool, saveError: String?) {
        guard
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }
        let report: [String: Any] = [
            "hasAPIKey": storedKey,
            "saveError": saveError ?? "none",
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        try? data.write(
            to: directory.appendingPathComponent("last-install-check.json"),
            options: .atomic
        )
    }
#endif

    @objc private func systemNavigationActionDidChange(_ notification: Notification) {
        HostAppSwitcher.probeSystemNavigationAction(route: "action-changed")
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SpeakPasteSceneDelegate.self
        return configuration
    }
}

@MainActor
final class SpeakPasteSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let model = AppModel()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let rootView = ContentView().environmentObject(model)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: rootView)
        self.window = window
        window.makeKeyAndVisible()
        HostAppSwitcher.probeSystemNavigationAction(route: "scene-will-connect")

        for context in connectionOptions.urlContexts {
            handleIncomingURL(
                context.url,
                sourceApplication: context.options.sourceApplication
                    ?? connectionOptions.sourceApplication,
                deliveryRoute: "scene-connection"
            )
        }
        model.handleActivation()
    }

    func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        for context in URLContexts {
            handleIncomingURL(
                context.url,
                sourceApplication: context.options.sourceApplication,
                deliveryRoute: "scene-open-url"
            )
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        HostAppSwitcher.probeSystemNavigationAction(route: "scene-did-become-active")
        model.handleActivation()
    }

    private func handleIncomingURL(
        _ url: URL,
        sourceApplication: String?,
        deliveryRoute: String
    ) {
        if
            url.scheme == "speakpaste",
            url.host == "dictate",
            url.path == "/start"
        {
            HostAppSwitcher.beginReturnSession(probeRoute: deliveryRoute)
        }
        captureReturnApplication(
            from: url,
            sourceApplication: sourceApplication,
            deliveryRoute: deliveryRoute
        )
        model.handleIncomingURL(url)
    }

    private func captureReturnApplication(
        from url: URL,
        sourceApplication: String?,
        deliveryRoute: String
    ) {
        guard
            url.scheme == "speakpaste",
            url.host == "dictate",
            url.path == "/start",
            let sessionValue = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?
                .queryItems?
                .first(where: { $0.name == "session" })?
                .value,
            let sessionID = UUID(uuidString: sessionValue)
        else {
            return
        }

        let sharedStore = SharedDictationStore()
        let snapshot = sharedStore.load()
        guard snapshot.sessionID == sessionID else { return }

        sharedStore.setIncomingURLContext(
            deliveryRoute: deliveryRoute,
            sourceApplication: sourceApplication,
            sessionID: sessionID
        )

        guard
            let sourceApplication,
            HostAppSwitcher.isValidReturnBundleIdentifier(sourceApplication)
        else {
            return
        }
        sharedStore.setReturnBundleIdentifier(
            sourceApplication,
            sessionID: sessionID
        )
    }
}
