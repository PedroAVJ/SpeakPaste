import AppKit
import InputMethodKit

private final class SpeakPasteInputMethodDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        guard
            let connectionName = info["InputMethodConnectionName"] as? String,
            let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            NSApp.terminate(nil)
            return
        }
        server = IMKServer(
            name: connectionName,
            bundleIdentifier: bundleIdentifier
        )
        // The main app may send `begin` immediately after selecting this input
        // source, before InputMethodKit has constructed its first controller.
        // Start the authenticated command socket with the helper process so
        // attach retries receive an explicit `wrong_client` until IMK supplies
        // the focused client instead of timing out on a missing server.
        _ = SpeakPasteInputControllerBroker.shared
    }
}

private let delegate = SpeakPasteInputMethodDelegate()
private let application = NSApplication.shared
application.delegate = delegate
application.run()
