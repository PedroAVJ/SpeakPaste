import ObjectiveC.runtime
import UIKit

struct KeyboardReturnPrompt: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String?
    let appName: String
}

@MainActor
enum HostAppSwitcher {
    static func displayName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "your previous app" }
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

    static func open(bundleIdentifier: String?) async -> Bool {
        guard let bundleIdentifier else { return false }

        // SpeakPaste's keyboard is a sideloaded experiment. This dynamic call mirrors
        // the switchback technique used by dictation keyboards, but would not be
        // suitable for App Store distribution because it is not a public API.
        if openUsingWorkspace(bundleIdentifier: bundleIdentifier) {
            return true
        }

        guard let url = fallbackURL(for: bundleIdentifier) else { return false }
        return await UIApplication.shared.open(url)
    }

    private static func openUsingWorkspace(bundleIdentifier: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let classMethod = class_getClassMethod(workspaceClass, defaultSelector) else {
            return false
        }

        typealias DefaultWorkspaceFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let defaultImplementation = method_getImplementation(classMethod)
        let defaultWorkspace = unsafeBitCast(
            defaultImplementation,
            to: DefaultWorkspaceFunction.self
        )
        guard let workspace = defaultWorkspace(workspaceClass, defaultSelector)?.takeUnretainedValue() else {
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard let openMethod = class_getInstanceMethod(workspaceClass, openSelector) else {
            return false
        }
        typealias OpenFunction = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let openImplementation = method_getImplementation(openMethod)
        let open = unsafeBitCast(openImplementation, to: OpenFunction.self)
        return open(workspace, openSelector, bundleIdentifier as NSString)
    }

    private static func fallbackURL(for bundleIdentifier: String) -> URL? {
        let schemes: [String: String] = [
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
        return schemes[bundleIdentifier].flatMap(URL.init(string:))
    }
}
