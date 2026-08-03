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
        return true
    }

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
