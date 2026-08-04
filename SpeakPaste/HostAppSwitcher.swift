import UIKit

struct KeyboardReturnPrompt: Identifiable, Equatable {
    let id: UUID
    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let appName: String
}

struct HostAppSwitchOutcome: Equatable, Sendable {
    let didOpen: Bool
    let attempts: [String]
}

struct HostAppInfo: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let launchURL: URL
}

/// Wispr-style switchback: identify the keyboard host before leaving the
/// extension, then reopen that exact app through a curated URL scheme. There
/// is deliberately no generic "previous app" or bundle-activation fallback.
@MainActor
enum HostAppSwitcher {
    struct ReturnTargetResolution: Equatable, Sendable {
        let bundleIdentifier: String?
        let attempts: [String]
    }

    static func isValidReturnBundleIdentifier(_ value: String?) -> Bool {
        validBundleIdentifier(value) != nil
    }

    static func appInfo(for bundleIdentifier: String?) -> HostAppInfo? {
        guard let bundleIdentifier = validBundleIdentifier(bundleIdentifier) else {
            return nil
        }
        return appsByBundleIdentifier[bundleIdentifier.lowercased()]
    }

    static func supportsAutomaticReturn(
        to bundleIdentifier: String?
    ) -> Bool {
        appInfo(for: bundleIdentifier) != nil
    }

    static func displayName(for bundleIdentifier: String?) -> String {
        appInfo(for: bundleIdentifier)?.displayName ?? "your previous app"
    }

    static func anticipatedRoute(
        for bundleIdentifier: String?,
        processIdentifier: Int32? = nil
    ) -> String {
        let target = resolveReturnTarget(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        return appInfo(for: target.bundleIdentifier) == nil
            ? "manual-switchback"
            : "host-url"
    }

    static func anticipatedAttempts(
        for bundleIdentifier: String?,
        processIdentifier: Int32? = nil
    ) -> [String] {
        let target = resolveReturnTarget(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        var attempts = target.attempts
        if let app = appInfo(for: target.bundleIdentifier) {
            attempts.append("host-catalog:\(app.bundleIdentifier)")
            attempts.append("host-url:pending")
        } else if target.bundleIdentifier == nil {
            attempts.append("manual-switchback:missing-host")
        } else {
            attempts.append("manual-switchback:unsupported-host")
        }
        return attempts
    }

    /// The keyboard is responsible for resolving the host while it is still
    /// embedded there. A PID cannot be safely or reliably reverse-mapped after
    /// SpeakPaste launches, so it remains diagnostic only.
    static func resolveReturnTarget(
        bundleIdentifier: String?,
        processIdentifier: Int32?
    ) -> ReturnTargetResolution {
        var attempts: [String] = []
        if let bundleIdentifier = validBundleIdentifier(bundleIdentifier) {
            attempts.append("return-target-shared-bundle:\(bundleIdentifier)")
            return ReturnTargetResolution(
                bundleIdentifier: bundleIdentifier,
                attempts: attempts
            )
        }

        attempts.append("return-target-shared-bundle:nil")
        if let processIdentifier, processIdentifier > 1 {
            attempts.append("return-target-host-pid:\(processIdentifier)")
            attempts.append("return-target-pid-unmapped")
        } else {
            attempts.append("return-target-host-pid:nil")
        }
        return ReturnTargetResolution(
            bundleIdentifier: nil,
            attempts: attempts
        )
    }

    static func open(
        bundleIdentifier: String?,
        processIdentifier: Int32? = nil,
        onAttemptsChanged: (([String]) -> Void)? = nil
    ) async -> HostAppSwitchOutcome {
        let target = resolveReturnTarget(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        var attempts = target.attempts
        guard let app = appInfo(for: target.bundleIdentifier) else {
            attempts.append(
                target.bundleIdentifier == nil
                    ? "manual-switchback:missing-host"
                    : "manual-switchback:unsupported-host"
            )
            onAttemptsChanged?(attempts)
            return HostAppSwitchOutcome(didOpen: false, attempts: attempts)
        }

        attempts.append("host-catalog:\(app.bundleIdentifier)")
        let canOpen = UIApplication.shared.canOpenURL(app.launchURL)
        attempts.append("host-url-can-open:\(canOpen)")
        onAttemptsChanged?(attempts)
        guard canOpen else {
            attempts.append("manual-switchback:scheme-unavailable")
            onAttemptsChanged?(attempts)
            return HostAppSwitchOutcome(didOpen: false, attempts: attempts)
        }

        let didOpen = await UIApplication.shared.open(
            app.launchURL,
            options: [:]
        )
        attempts.append("host-url:\(didOpen)")
        if !didOpen {
            attempts.append("manual-switchback:open-failed")
        }
        onAttemptsChanged?(attempts)
        return HostAppSwitchOutcome(didOpen: didOpen, attempts: attempts)
    }

    private static func validBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = identifier.lowercased()
        let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        let keyboardBundleIdentifier = ownBundleIdentifier.map {
            $0 + ".keyboard"
        }
        let liveActivityBundleIdentifier = ownBundleIdentifier.map {
            $0 + ".liveactivity"
        }
        guard
            !identifier.isEmpty,
            (identifier.contains(".") || lowercased == "pinterest"),
            !identifier.contains(" "),
            !["<null>", "(null)", "null", "nil"].contains(lowercased),
            lowercased != "com.apple.springboard",
            lowercased != "com.apple.spotlight",
            lowercased != "com.apple.uikitsystemapp",
            lowercased != ownBundleIdentifier,
            lowercased != keyboardBundleIdentifier,
            lowercased != liveActivityBundleIdentifier
        else {
            return nil
        }
        return identifier
    }

    private static func app(
        _ bundleIdentifier: String,
        _ displayName: String,
        _ launchURL: String
    ) -> HostAppInfo {
        HostAppInfo(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            launchURL: URL(string: launchURL)!
        )
    }

    /// Bundle identifiers come from Apple's App Store catalog; URL schemes are
    /// the exact allowlist shipped in Wispr Flow 1.67/build 1313.
    private static let supportedApps: [HostAppInfo] = [
        app("com.apple.MobileSMS", "Messages", "sms:"),
        app("net.whatsapp.WhatsApp", "WhatsApp", "whatsapp://"),
        app("com.burbn.instagram", "Instagram", "instagram://"),
        app("com.facebook.Messenger", "Messenger", "fb-messenger://"),
        app("com.apple.mobilemail", "Mail", "message://"),
        app("com.atebits.Tweetie2", "X", "twitter://"),
        app("com.linkedin.LinkedIn", "LinkedIn", "linkedin://"),
        app("com.apple.mobilenotes", "Notes", "mobilenotes://"),
        app("com.microsoft.onenote", "OneNote", "onenote://"),
        app("com.google.Keep", "Google Keep", "keep://"),
        app("notion.id", "Notion", "notion://"),
        app("com.evernote.iPhone.Evernote", "Evernote", "evernote://"),
        app("com.openai.chat", "ChatGPT", "chatgpt://"),
        app("com.anthropic.claude", "Claude", "claude://"),
        app("com.google.gemini", "Gemini", "googlegemini://"),
        app("ai.x.GrokApp", "Grok", "com.grokapp://"),
        app("ai.perplexity.app", "Perplexity", "perplexity-app://"),
        app("com.goodnotesapp.x", "Goodnotes", "goodnotes5://"),
        app("com.gingerlabs.Notability", "Notability", "notability://"),
        app("net.shinyfrog.bear-iOS", "Bear", "bear://"),
        app("md.obsidian", "Obsidian", "obsidian://"),
        app("com.google.chrome.ios", "Chrome", "googlechrome://"),
        app("com.google.calendar", "Google Calendar", "googlecalendar://"),
        app("com.google.Docs", "Google Docs", "googledocs://"),
        app("com.google.Drive", "Google Drive", "googledrive://"),
        app("com.google.Maps", "Google Maps", "comgooglemaps://"),
        app("com.google.GoogleMobile", "Google", "googleapp://"),
        app("com.microsoft.msedge", "Microsoft Edge", "microsoft-edge://"),
        app("com.google.ios.youtube", "YouTube", "youtube://"),
        app("com.facebook.Facebook", "Facebook", "fb://"),
        app("com.zhiliaoapp.musically", "TikTok", "tiktok://"),
        app("com.reddit.Reddit", "Reddit", "reddit://"),
        app("com.burbn.barcelona", "Threads", "barcelona://"),
        app("xyz.blueskyweb.app", "Bluesky", "bluesky://"),
        app("pinterest", "Pinterest", "pinterest://"),
        app("org.whispersystems.signal", "Signal", "sgnl://"),
        app("jp.naver.line", "LINE", "line://"),
        app("ph.telegra.Telegraph", "Telegram", "tg://"),
        app("com.tinyspeck.chatlyio", "Slack", "slack://"),
        app("com.hammerandchisel.discord", "Discord", "discord://"),
        app("com.google.Gmail", "Gmail", "googlegmail://"),
        app("com.microsoft.Office.Outlook", "Outlook", "ms-outlook://"),
        app("com.yahoo.Aerogram", "Yahoo Mail", "ymail://"),
        app("com.superhuman.Superhuman", "Superhuman", "superhuman://"),
        app("ch.protonmail.protonmail", "Proton Mail", "protonmail://"),
    ]

    private static let appsByBundleIdentifier: [String: HostAppInfo] =
        Dictionary(
            uniqueKeysWithValues: supportedApps.map {
                ($0.bundleIdentifier.lowercased(), $0)
            }
        )
}
