# macOS feature parity: SpeakPaste vs superwhisper and Wispr Flow

Derived from a survey of superwhisper 2.17.0 and Wispr Flow 1.5.433 (marketing
sites, docs, changelogs, and forensic inspection of both apps installed on this
Mac), Apple's platform expectations for menu-bar utilities, and the ElevenLabs
Scribe batch API. 446 features were inventoried across those sources and diffed
against this repository.

## Standing constraints

- ElevenLabs Scribe is the only transcription backend. No model pickers, no
  second provider, no local Whisper.
- Batch, not realtime. Quality before latency.
- macOS target only.
- Existing invariants hold: Continuity reliability gating, right-Command toggle,
  the held-transcript queue, and no silent fallbacks.

## Table stakes (31)

### Custom vocabulary sent to Scribe as keyterm biasing

*context · medium · seen in: superwhisper (vocabulary + keyterms[] in binary), Wispr Flow (custom dictionary), ElevenLabs Scribe API (keyterms)*

A user-managed list of names, jargon, product names, acronyms and code identifiers, uploaded with every transcription request as repeated multipart `keyterms[]` fields so Scribe biases recognition toward them.

**Why it matters.** This is the single highest-leverage feature available under the Scribe-only constraint, and the one thing every competitor has that SpeakPaste has none of. Today every proper noun Pedro says is a coin flip, and there is no mechanism at all to fix a recurring mis-transcription. Batch Scribe allows 1000 terms of up to 50 chars each (realtime allows only 50x20), so the entire personal glossary can be sent unconditionally — and because keyterms are context-aware rather than forced string injection, a large always-on list does not corrupt ordinary dictation.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/ElevenLabsClient.swift` builds the multipart body in `multipartBody(boundary:audioData:filename:audioContentType:languageCode:cleanSpeech:)` (lines 89-122) and sends only model_id/no_verbatim/tag_audio_events/language_code. Add a `keyterms: [String]` parameter to `ElevenLabsClientProtocol.transcribe` (line 3-10) and emit one `appendField(name: "keyterms[]", value: term)` per term — this is exactly the field superwhisper's binary emits (`Content-Disposition: form-data; name="keyterms[]"`). Store the list in a new `SpeakPasteMac/MacVocabularyStore.swift` modelled on `MacReliabilityStore.swift` (JSON in UserDefaults, or Application Support via `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` so it is hand-editable). Surface an add/edit/delete list plus CSV import in the new Settings scene. Enforce the documented limits client-side (<=1000 terms, <50 chars, <=5 words). Note the billing tripwire: requests with more than 100 keyterms have a 20-second minimum billable unit, so a 6s dictation bills as 20s — still ~$0.0015, economically irrelevant, but worth a one-line note in the UI rather than a surprise.

### Permission status dashboard with live re-checking and System Settings deep links

*privacy · medium · seen in: superwhisper (permission onboarding + Reset Permission), Wispr Flow (sequential permission cards), macOS platform expectations (TCC)*

A standing surface listing Microphone, Accessibility, Input Monitoring and Login Item status, each with a live-read state and an 'Open System Settings' button, plus re-checking of Accessibility while the app runs rather than only on app activation.

**Why it matters.** All four grants can be revoked at any time from System Settings, and today none of them is visible anywhere in SpeakPaste. Worse: `MacGlobalHotKey.refreshMonitor()` only re-runs on `NSApplication.didBecomeActiveNotification`, so a user who grants Accessibility in System Settings and then returns to their editor (not to SpeakPaste) leaves the CGEventTap uninstalled — the global hotkey stays dead with zero explanation, and the NSEvent fallback only fires while SpeakPaste itself is frontmost. This is the exact silent-fallback failure the product's own principle forbids.

**Implementation.** In `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacGlobalHotKey.swift:177-186`, add a `DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"))` observer plus a low-frequency poll so `refreshMonitor()` runs when the grant changes out-of-band. Add `SpeakPasteMac/MacPermissionsModel.swift` reading `AVCaptureDevice.authorizationStatus(for: .audio)`, `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`, `CGPreflightPostEventAccess()` and `SMAppService.mainApp.status`. Deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`, `?Privacy_Accessibility`, `?Privacy_ListenEvent`, and `SMAppService.openSystemSettingsLoginItems()`. Render it in the new Settings scene and add a compact 'hotkey inactive' state to `MacStatusHUD.swift` so the dead-shortcut case is visible rather than mysterious. Use `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` only from an explicit button, never at launch (the existing comment at MacGlobalHotKey.swift:97-98 is right to avoid a launch-time dialog).

### Secure Event Input detection, with refusal to deliver into a secure context

*reliability · medium · seen in: macOS platform expectations (TN2150)*

Polling `IsSecureEventInputEnabled()` so the app knows when a password field, Terminal's Secure Keyboard Entry, or a password manager has captured the keyboard — and both surfacing that state and routing the transcript to the held queue instead of attempting a paste.

**Why it matters.** While secure event input is held, the CGEventTap stops receiving flagsChanged events and synthetic ⌘V is blocked by the WindowServer. Today both the right-Command toggle and auto-paste simply stop working with no message at all — the app reports `.pasted` from `sendPasteKeystroke()` because `CGEvent.post` returns nothing to check. This is the highest-value reliability addition for a hotkey-driven tool, and the held-transcript queue is already the correct destination for the text.

**Implementation.** `IsSecureEventInputEnabled()` from Carbon/HIToolbox (import Carbon). Check it in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacPasteController.swift` before `sendPasteKeystroke()` (line 75) and return a new `.heldSecureInput` case in `MacPasteResult` (line 5-22) so `MacAppModel.deliver(_:)` (line 403-458) calls `hold(_:for:)` instead. Also poll it from `MacGlobalHotKey` while the tap is installed and publish a 'a password field is capturing the keyboard — the shortcut is paused' banner into `MacStatusHUD.swift`'s display-state switch (line 213-286). `kCGSSessionSecureInputPID` from the session dictionary (`CGSessionCopyCurrentDictionary()`) identifies the holding process if you want to name it.

### Keyboard-layout-correct paste keystroke

*delivery · medium · seen in: superwhisper (all-layout paste fix), macOS platform expectations*

Resolving the virtual keycode that actually produces "v" on the current keyboard layout (or using the target app's Paste menu item via AX) instead of hardcoding keycode 0x09.

**Why it matters.** `sendPasteKeystroke()` posts virtualKey 0x09 with maskCommand. On QWERTY that is V; on Dvorak, Colemak and several European layouts keycode 0x09 is a different character, so the app sends ⌘K (or worse) into the user's editor instead of pasting. It reports success either way. Superwhisper shipped an explicit fix for this ('Automatic paste on all keyboard layouts', v1.22.4). The same hardcoded 0x09 appears in the ⌥⌘V release-chord recognizer.

**Implementation.** In `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacPasteController.swift:75-88`, replace the literal `0x09` with a cached lookup: `TISCopyCurrentKeyboardLayoutInputSource()` -> `TISGetInputSourceProperty(kTISPropertyUnicodeKeyLayoutData)` -> `UCKeyTranslate` over keycodes 0...127 to find the one yielding "v", refreshed on `kTISNotifySelectedKeyboardInputSourceChanged`. Fall back to 0x09 when resolution fails. Apply the same resolution to `macReleaseKeyCode` in `SpeakPasteMac/MacGlobalHotKey.swift:54`. A belt-and-braces alternative for stubborn apps: walk the target's AX menu bar for the Edit > Paste item and `AXUIElementPerformAction(item, kAXPressAction)`.

### Clipboard preservation and restore after paste

*delivery · small · seen in: superwhisper (restoreClipboardEnabled + delay), Wispr Flow (clipboard restore)*

Snapshotting every representation on the general pasteboard before writing the transcript, then restoring the original contents after a configurable delay.

**Why it matters.** `copyToPasteboard(_:)` calls `NSPasteboard.general.clearContents()` and overwrites, and it runs on every single delivery path including the ones that end in `.copied`. Every dictation therefore destroys whatever the user had copied, and pollutes clipboard-manager history with dictation text. Both superwhisper and Wispr Flow treat restore as default behavior.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacPasteController.swift:70-73`. Before clearing, capture `NSPasteboard.general.pasteboardItems` by copying each item's `types` and `data(forType:)` into fresh `NSPasteboardItem`s (the originals are invalidated by `clearContents()`), record `changeCount`, then after `sendPasteKeystroke()` schedule a restore that only fires if `changeCount` still matches what SpeakPaste wrote. Make the delay a setting (superwhisper exposes `restoreClipboardTimeDelay`; 300-600 ms is a sane default because slow Electron targets read the pasteboard late). Add a 'Restore clipboard after pasting' toggle to the new Settings scene, plus superwhisper's stronger 'Bypass clipboard' option once direct AX insertion exists as an alternative path.

### Persistence of user settings across launches

*settings · small · seen in: superwhisper (all settings persisted), Wispr Flow, macOS platform expectations*

Writing `language`, `cleanSpeech` and `autoPaste` to UserDefaults so they survive a relaunch.

**Why it matters.** All three are plain `@Published` properties with hardcoded defaults, so a user who sets Spanish, or turns off auto-paste because they dictate into a terminal, silently gets the defaults back on every launch. The app already persists the chosen device and the reliability log, which makes the omission look like an oversight rather than a decision.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:60-62`. Because `MacAppModel` is an ObservableObject (not a View) `@AppStorage` is awkward; add `didSet` writers to UserDefaults keys (`mac-language`, `mac-clean-speech`, `mac-auto-paste`) and read them in `init` alongside the existing `UserDefaults.standard.removeObject(forKey: Self.autoPersistedDeviceKey)` at line 118. `TranscriptionLanguage` already conforms to `Codable`/`RawRepresentable` so its rawValue stores directly.

### Standard Settings window (⌘,) with a real settings surface

*settings · medium · seen in: superwhisper (four ways to open Settings), Wispr Flow (System/Account split), macOS platform expectations (SwiftUI Settings scene)*

A SwiftUI `Settings` scene giving the standard preferences window, the Settings… menu item and the ⌘, shortcut, with panes for General, Microphone, Shortcuts, Vocabulary, Delivery, Account and Updates.

**Why it matters.** There is no `Settings` scene at all, so ⌘, does nothing and every option lives crammed into a fixed 500x620 non-resizable main window that also hosts the recorder, the transcript and the reliability log. Nearly every gap in this matrix needs somewhere to live, and this is that place. It is also the prerequisite for hiding the main window entirely once the app becomes a menu-bar agent.

**Implementation.** Add a `Settings { MacSettingsView().environmentObject(model) }` scene to `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/SpeakPasteMacApp.swift:14-30` and move `settingsSection` out of `MacContentView.swift:541-580`. Opening it from the MenuBarExtra has a documented sharp edge: `NSApp.sendAction(Selector(("showSettingsWindow:")))` is unreliable and `@Environment(\.openSettings)` needs a live SwiftUI render tree, so inside a `.menu`-style MenuBarExtra use the `SettingsLink { Text("Settings…") }` initializer (macOS 14+) rather than a plain Button. Use a `TabView` with `.tabItem` for the panes.

### Developer ID signing, hardened runtime, notarization, and a real bundle identifier

*reliability · medium · seen in: superwhisper (Developer ID + notarized), macOS platform expectations*

Setting `PRODUCT_BUNDLE_IDENTIFIER` to a real reverse-DNS id, filling `DEVELOPMENT_TEAM`, turning on `ENABLE_HARDENED_RUNTIME`, adding an entitlements file for the Mac target, incrementing `CURRENT_PROJECT_VERSION` per build, and notarizing with `xcrun notarytool` + `xcrun stapler`.

**Why it matters.** TCC grants for Accessibility, Input Monitoring and Microphone are keyed to the code signature. With `DEVELOPMENT_TEAM = ""`, `ENABLE_HARDENED_RUNTIME = NO` and `PRODUCT_BUNDLE_IDENTIFIER = com.example.SpeakPasteMac`, every rebuild produces a new ad-hoc signature and the user re-grants everything — which is also why `KeychainStore` needs its `errSecMissingEntitlement` fallback (KeychainStore.swift:45-56). On macOS 26 the WindowServer additionally distinguishes hardware events from `CGEventPost`-synthesized ones, so an improperly signed binary can find synthetic ⌘V filtered even with Accessibility granted. This is a hard prerequisite for every permission-dependent feature in this list.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste.xcodeproj/project.pbxproj`, configurations `D90000000000000000000001` (Debug) and `D90000000000000000000002` (Release). Change `PRODUCT_BUNDLE_IDENTIFIER` (the memory note records `com.pedro` + team `KC2ZK3BWH7` as the working install recipe), set `ENABLE_HARDENED_RUNTIME = YES`, add `CODE_SIGN_ENTITLEMENTS = SpeakPasteMac/SpeakPasteMac.entitlements` (the Mac target has none today; the iPhone and keyboard targets do), and keep `ENABLE_APP_SANDBOX = NO` — AX writes and CGEventTap do not work sandboxed, which forecloses the Mac App Store and makes Developer ID + Sparkle the only channel. Also update the `service` string in `SpeakPaste/KeychainStore.swift:19` if the bundle id changes, or existing keys become unreachable.

### Launch at login

*settings · small · seen in: superwhisper (LaunchOnLogin), macOS platform expectations (SMAppService)*

An opt-in Settings toggle calling `SMAppService.mainApp.register()` / `.unregister()`, reflecting all four `SMAppService.Status` values honestly.

**Why it matters.** A dictation utility whose whole value is 'the shortcut is always live' does not survive a reboot today — there is no login-item mechanism anywhere in the codebase. The status reflection matters as much as the toggle: if the user disables the login item in System Settings the status becomes `.requiresApproval`, and showing a checked toggle over that is precisely the silent-lie pattern the product forbids.

**Implementation.** `import ServiceManagement` in a new `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacLoginItem.swift`. `SMAppService.mainApp` is the only supported route on macOS 13+ (LSSharedFileList and the `SMLoginItemSetEnabled` helper-bundle route are legacy and need no helper target here). Render `.enabled` / `.requiresApproval` / `.notRegistered` / `.notFound` distinctly, and on `.requiresApproval` show a button wired to `SMAppService.openSystemSettingsLoginItems()`. Never register automatically on first launch.

### Menu-bar agent mode, with a hide-icon control and Quit/Settings in the menu

*platform-integration · medium · seen in: superwhisper (menu bar + Show in Dock toggle), Wispr Flow (Flow Bar), macOS platform expectations (HIG menu bar)*

Running as a background agent (`LSUIElement` / `NSApp.setActivationPolicy(.accessory)`) with no Dock icon and no always-present window, plus a Settings toggle to hide the status item and a complete menu (Open SpeakPaste, Settings…, Check for Updates…, Quit).

**Why it matters.** SpeakPaste declares a `WindowGroup` as its primary scene and never sets `LSUIElement`, so it behaves as a regular Dock app that shows up in ⌘Tab — the main structural divergence from every shipping competitor, all of which are menu-bar agents. The MenuBarExtra menu also has no Quit, no Settings, and no way to reopen the main window, which becomes an outright dead end the moment the Dock icon goes away. HIG additionally says the user, not the app, decides whether a menu bar extra appears, and warns against relying on its presence.

**Implementation.** Add `INFOPLIST_KEY_LSUIElement = YES` to both Mac configurations in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste.xcodeproj/project.pbxproj` (or call `setActivationPolicy(.accessory)` from an AppDelegate so it can be toggled at runtime, which is what superwhisper does — its Info.plist has no LSUIElement key and it flips policy for the settings window). Convert the `WindowGroup` in `SpeakPasteMac/SpeakPasteMacApp.swift:15-21` to a `Window` with an id opened from the menu via `@Environment(\.openWindow)`. Critical detail: `statusHUD.start()` is currently called from `MacContentView.onAppear` (line 18) — move it into `MacAppModel`/an AppDelegate `applicationDidFinishLaunching`, or the HUD never starts when no window is open. Add `Button("Quit SpeakPaste") { NSApplication.shared.terminate(nil) }` and a `SettingsLink` to `MacMenuBarView` (SpeakPasteMacApp.swift:55-108), plus a `MenuBarExtra(isInserted:)` binding for the hide-icon setting — and keep the global hotkey as the guaranteed alternate invocation path when the icon is hidden.

### Configurable keyboard shortcuts with a recorder UI and conflict rejection

*trigger · large · seen in: superwhisper (shortcut recorder + per-mode shortcuts), Wispr Flow (4 bindings per action + validation rules), macOS platform expectations (HIG keyboards)*

A click-to-record shortcut field for the toggle, release, cancel and paste-last actions, with modifier-order normalization, rejection of HIG-reserved combinations, and honest reporting when a shortcut is already claimed.

**Why it matters.** Both shortcuts are hardcoded — bare right-Command in `MacGlobalHotKey` and ⌥⌘V for release — with no way to change either. Right-Command is a genuinely good default but it is also the key many users have bound to input-source switching or a Hyperkey tool, and there is no escape hatch. Every competitor treats rebindable shortcuts as baseline, and HIG explicitly endorses letting people customize key bindings. Fixing this also resolves a live documentation defect: README.md:35-36 still tells users to 'tap either Command (⌘) key', which the right-only code contradicts.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacGlobalHotKey.swift`: promote `MacModifierSide.rightCommand` (line 10) and `macReleaseKeyCode` (line 54) into a persisted `MacShortcutBinding` value type. Keep the CGEventTap exclusively for modifier-only bindings — Carbon `RegisterEventHotKey` structurally cannot express a bare modifier — and route any conventional key+modifier binding (cancel, paste-last) through `RegisterEventHotKey`/`EventHotKeyID` instead, which needs no TCC grant at all and returns `eventHotKeyExistsErr` (-9878) so conflicts can be reported as 'This shortcut is already in use' rather than silently accepted. Apple ships no recorder control, so build one: a focusable NSView/SwiftUI representable capturing flagsChanged+keyDown, rendering the glyph string in Control-Option-Shift-Command order, validated against the HIG reserved table (⌘Space, ⌘Q, ⌘Tab, ⌘H, ⌘W…). Also update README.md:35-36 in the same change.

### Cancel / discard an in-flight recording

*trigger · small · seen in: superwhisper (Cancel Recording + length-aware confirm), Wispr Flow (rebindable cancel)*

A separate shortcut and HUD affordance that aborts the active recording and throws the audio away instead of transcribing it, with length-aware confirmation for long takes.

**Why it matters.** The right-Command toggle is the only control: the second tap always transcribes. There is no way to abandon a dictation you misspoke, said something private in, or started by accident — the audio goes to ElevenLabs regardless. `MacAudioRecorder.disconnect()` already tears down cleanly and deletes the segment file, so the plumbing exists; nothing exposes it.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift`: add `func cancelRecording()` that calls `recorder.disconnect()` (MacAudioRecorder.swift:334-342 — it already stops the output and `failSession` removes `segmentURL` at line 619-621), calls `stopMeter()`, clears `deliveryTarget`, and sets `phase = .ready` without logging a failure attempt. Bind Escape plus a rebindable shortcut in `MacGlobalHotKey` (via the Carbon path once bindings are configurable), add a Cancel button to the recording state in `MacContentView.captureSection` (line 305-325) and to `MacMenuBarView`. Follow superwhisper's rule that recordings under 30 seconds cancel immediately while longer ones confirm first.

### Retry a failed transcription (stop deleting the audio unconditionally)

*reliability · medium · seen in: Wispr Flow (inline retry for failed transcripts), superwhisper (Process Again from history)*

Retaining the recorded WAV when the ElevenLabs request fails, and offering a Retry action that re-uploads it instead of asking the user to speak again.

**Why it matters.** `transcribe(...)` deletes the audio in a `defer` block on every path, including failure. A 429, a dropped Wi-Fi connection, an expired key or a 503 therefore destroys the dictation permanently. The iPhone app already does the right thing here — README.md:139-141 documents that iPhone recordings are 'retained after an API failure so Retry can reuse them' — so macOS is strictly worse than the platform it was ported from, and the reliability log will happily show a failure with nothing recoverable behind it.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:354-357` — make the `defer` delete only on success (or on an explicit discard), and move retained failures into a `pendingRetries: [UUID: (URL, MacDeliveryTarget?, String)]` map surfaced in the failure banner (`MacContentView.swift:440-458`) and in `MacMenuBarView`. Move retained audio out of `FileManager.default.temporaryDirectory` (MacAudioRecorder.swift:269-271) into Application Support so the system does not reap it. Pair with the error taxonomy below so only retryable classes offer Retry, and add a retention cap plus a 'discard all pending audio' control to keep the privacy story honest.

### Structured ElevenLabs error taxonomy with retry and backoff

*reliability · medium · seen in: superwhisper (429 retry/backoff strings), ElevenLabs Scribe API (errors reference)*

Parsing `detail.{type, code, message, status, request_id, param}` and branching on it: exponential backoff on 429/503, a key-entry prompt on 401, an out-of-credits message on 402, a plan message on 403, and a distinct 'that was too short' on 400 audio_too_short.

**Why it matters.** `ElevenLabsClient.errorMessage(from:)` extracts a human string and discards `code`, `param` and `request_id`, so every failure is terminal and indistinguishable. A transient 429 (which SpeakPaste can inflict on itself — see the concurrency gap) is presented as a permanent failure and, today, also destroys the audio. Running out of ElevenLabs credits currently reads as a mystery. superwhisper's binary carries explicit `ElevenLabs rate limited (429), retrying after …` / `Retrying ElevenLabs request (attempt…)` strings — the retry loop is table stakes for this backend.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/ElevenLabsClient.swift:132-153` — decode the envelope into a typed `ElevenLabsAPIError { type, code, message, status, requestID, param }` and extend `ElevenLabsClientError` (line 12-27) with `isRetryable`. Add bounded exponential backoff (3 attempts, jittered) inside `transcribe` for 429 `rate_limit_exceeded` / `concurrent_limit_exceeded` / `system_busy` and 503. Read the `current-concurrent-requests` and `maximum-concurrent-requests` response headers from `httpResponse.allHeaderFields` to size the queue. Include `request_id` in the reliability-log detail string built in `MacAppModel.deliver(_:)` (line 420-428) so a support report is actionable.

### Bounded in-flight transcription concurrency

*reliability · small · seen in: ElevenLabs Scribe API (per-plan concurrency limits)*

A small semaphore or serial queue capping how many Scribe requests run at once, sized to the account's concurrency ceiling.

**Why it matters.** `startTranscription` spawns an unbounded detached `Task` per dictation and the comment at MacAppModel.swift:341 explicitly celebrates that 'Several of these can be in flight at once'. ElevenLabs enforces per-plan concurrency (Free 2, Starter 3, Creator 5, Pro 10), so a burst of rapid dictations — exactly the workflow the mic-freed-immediately design encourages — self-inflicts 429s. Combined with the unconditional audio delete above, that burst silently loses dictations.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:319-339`. Gate the body of `transcribe(...)` behind an `actor TranscriptionGate` holding an async semaphore (default 2-3), configurable in Settings and auto-tuned from the `maximum-concurrent-requests` header once the error work lands. The existing `nextSpeakSequence` / `nextDeliverySequence` ordered-delivery machinery (lines 92-95, 395-401) is unaffected — ordering is already independent of completion order.

### Stop a background transcription failure from killing a live recording

*reliability · small · seen in: SpeakPaste's own code (defect)*

Guarding `recordFailure(_:...)` with the same `!phase.isBusy` check that `deliver(_:)` already applies before it takes over the phase.

**Why it matters.** This is a live defect, not a missing feature. `deliver(_:)` correctly refuses to overwrite an active recording (`guard !phase.isBusy else { return }`, MacAppModel.swift:455). `recordFailure` has no such guard: a background transcription that fails while the user is mid-dictation calls `stopMeter()` and forces `phase = .failed`, so the HUD claims ERROR while `MacAudioRecorder` is still capturing. The user's next right-Command tap then sees `.failed`, tries to start a fresh session, and gets `recorderBusy`. The entire in-flight architecture depends on this separation holding.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:545-562`. Split the function: always prepend the `MacReliabilityAttempt`, but only call `stopMeter()` and set `phase = .failed` when `!phase.isBusy`. When busy, queue the message so it surfaces once the microphone releases (a `pendingFailureMessage` shown on the next transition to `.ready`). Callers at lines 276, 291, 405, 581 and 652 all funnel through here — the disconnect path at 652 legitimately does want to interrupt a live recording, so give it a separate `interruptsRecording: Bool` parameter rather than one blanket rule. This is also the single clearest argument for the Mac-target test coverage gap below: `CommandTapRecognizer` and this phase machine are pure and trivially testable.

### Persistent transcript history

*history · medium · seen in: superwhisper (history + FTS5 search), Wispr Flow (home hub history)*

A searchable list of past dictations (text, timestamp, destination app, delivery route, durations) in its own window, with per-row copy and re-insert.

**Why it matters.** macOS keeps exactly one transcript — `model.transcript`, overwritten by the next dictation. `HistoryStore.swift` and `HistoryView.swift` exist in the repo but are iPhone-only and are not in the Mac target's Sources phase (project.pbxproj build phase `D60000000000000000000001` contains no HistoryStore reference). Anything not pasted and not copied before the next dictation is simply gone, which is a poor match for a tool that deliberately lets several dictations be in flight at once.

**Implementation.** Add `SpeakPasteMac/MacTranscriptHistoryStore.swift` writing JSON (or SQLite via GRDB if search over thousands of rows is wanted — superwhisper uses an FTS5 virtual table) under `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, and record from `MacAppModel.deliver(_:)` at `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:414` where `transcript` is assigned. Present it in a separate `Window("History", id: "history")` scene, not inside the MenuBarExtra (HIG warns against complexity in the extra). Reuse `MacPasteController.pasteAtCurrentFocus(_:)` for the re-insert action. Add a retention setting with a real default (superwhisper ships none for individuals and hands users a crontab recipe, which is a bad model — a 30-day default sweep is better), and keep audio deletion as-is by default so the history is text-only unless the user opts into retention.

### Held transcripts survive quit and crash

*reliability · small · seen in: Wispr Flow (dictation recovery after quit), superwhisper (crash-proof incremental saving)*

Persisting the held-transcript queue to disk so text waiting for a destination is not lost when SpeakPaste quits, and restoring it (or at least surfacing it for manual paste) on next launch.

**Why it matters.** `heldTranscripts` is an in-memory `[MacHeldTranscript]`. The HUD promises 'Nothing is lost' (MacContentView.swift:112) and that promise is false across a quit, a crash, or a logout. The held queue is the product's signature safety mechanism; making it the one piece of state that evaporates undercuts it.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:74, 462-467`. `MacHeldTranscript` (line 18-23) holds a non-Codable `MacDeliveryTarget` containing an `AXUIElement`, so persist a reduced form: text, `createdAt`, target bundle identifier and application name. On relaunch the AXUIElement is meaningless anyway, so restored entries should be releasable via ⌥⌘V and by bundle-identifier match on return, but never auto-delivered on strict element identity. Write on every mutation of `heldTranscripts`; a JSON file next to the reliability log is sufficient. Pair with a Wispr-style 'text recovered from your last session' notice on launch.

### Audio feedback earcons for start, stop, success and failure

*feedback-ui · small · seen in: superwhisper (themed sound effects), Wispr Flow, macOS platform expectations*

Short sounds marking recording start, recording stop, successful delivery, and error — played through the alert device and independently toggleable.

**Why it matters.** There is no `NSSound` or `AudioServices` use anywhere in the codebase. The user is looking at the app they are dictating into, not at the menu bar, so the HUD alone cannot carry the 'do not speak yet -> speak now' transition — and that transition is precisely the one the Continuity liveness gate makes variable-length (up to 15 s). Every competitor ships earcons; superwhisper ships whole switchable themes plus a distinct 'nothing was transcribed' sound.

**Implementation.** New `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacSoundEffects.swift`, driven from the `phase` didSet in `MacAppModel.swift:46-51`. Use `NSSound(named:)` or `AudioServicesPlayAlertSound` so playback honors the user's chosen alert output device and alert volume rather than the default output device (TN2102). Cover at minimum: connecting-complete/'speak now', stop, delivered, held, error. Add a Settings toggle plus volume. Important interaction: do not play the start sound through the Continuity device path in a way that feeds back into the mic — play to the Mac's alert device only.

### Input Monitoring and Post Event permission preflight

*privacy · small · seen in: macOS platform expectations (CGPreflight* APIs)*

Calling `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` before creating the event tap and `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` before synthesizing ⌘V, and declaring `NSInputMonitoringUsageDescription`.

**Why it matters.** macOS splits event permissions into three separate TCC buckets — `kTCCServiceAccessibility`, `kTCCServiceListenEvent` and `kTCCServicePostEvent`. The app only ever checks `AXIsProcessTrusted()` (MacGlobalHotKey.swift:178, MacPasteController.swift:43/54, MacDeliveryTarget.swift:87). That can be true while listen or post access is not granted, in which case `CGEvent.tapCreate` succeeds but delivers nothing, or `sendPasteKeystroke()` returns true while the keystroke is discarded — a silent no-op reported as success.

**Implementation.** Add the preflight calls in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacGlobalHotKey.swift:188-212` (before `CGEvent.tapCreate`) and `SpeakPasteMac/MacPasteController.swift:75` (before posting). Add `INFOPLIST_KEY_NSInputMonitoringUsageDescription` to both Mac build configurations in project.pbxproj alongside the existing `INFOPLIST_KEY_NSMicrophoneUsageDescription`. Feed all three states into the permission dashboard. While hardening the tap, also switch `options: .defaultTap` to `.listenOnly` — SpeakPaste never modifies events (the callback always returns `Unmanaged.passUnretained(event)`), and a listen-only tap is cheaper and less likely to be disabled — and filter events inside `speakPasteEventTapCallback` before the `DispatchQueue.main.async` hop at line 66, which currently bounces every system-wide keyDown and mouse click to the main thread.

### Accessibility messaging timeout so a hung target cannot freeze delivery

*reliability · small · seen in: macOS platform expectations (AXUIElementSetMessagingTimeout)*

Calling `AXUIElementSetMessagingTimeout` (0.5-1.0 s) on the elements SpeakPaste queries.

**Why it matters.** AX calls into a hung or slow application block the caller. `MacAccessibility.systemFocusedElement()` and `focusedElementAcceptsText()` run on the main actor — the former from `MacDeliveryTarget.captureCurrent()` at record start, the latter from a 0.4 s repeating timer while anything is held. A wedged Electron app therefore stalls the UI and the held-transcript watcher on exactly the apps most likely to be dictation targets.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacDeliveryTarget.swift:85-131`. Call `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.75)` once at startup and on any per-application element you create. Consider moving the held-transcript poll (`MacAppModel.startPendingWatcher()`, line 473-480) off the main actor onto a background queue that hops back only to mutate published state.

### Continuity microphone identified by transport type, not by display name

*capture · medium · seen in: SpeakPaste's own code (weakness), macOS platform expectations (CoreAudio transport types)*

Detecting the iPhone microphone through CoreAudio's transport type (`kAudioDeviceTransportTypeContinuityCaptureWired` / `…Wireless`) or `AVCaptureDevice.isContinuityCamera`, with the current name heuristic kept only as a last-resort fallback.

**Why it matters.** `MacAudioInputDevice.isContinuityDevice` is a localized-name substring match on "iPhone" or "Continuity". This single predicate drives device sort order, auto-selection, the entire no-silent-fallback gate, the UI badge and the release-the-phone messaging. A USB interface literally named 'iPhone Mic' would be auto-selected as the Continuity device, and a non-English system locale could stop the auto-selection working at all — turning the product's core promise into a coin flip on a string.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAudioDevice.swift:8-11`. Resolve each `AVCaptureDevice.uniqueID` to its CoreAudio `AudioObjectID` and read `kAudioDevicePropertyTransportType` via `AudioObjectGetPropertyData`; the Continuity constants are `kAudioDeviceTransportTypeContinuityCaptureWired` ('ccwd') and `kAudioDeviceTransportTypeContinuityCaptureWireless` ('ccwl'), both macOS 13+. Also probe `AVCaptureDevice.isContinuityCamera` (macOS 14+) on the discovered device and verify empirically which signal the paired microphone actually reports on the target machine — do not assume. Keep the substring check as a third-tier fallback and log which signal matched into the reliability detail so a misclassification is diagnosable rather than invisible.

### Maximum recording duration guard with pre-expiry warning

*capture · small · seen in: Wispr Flow (20-minute cap + 19-minute warning)*

A configurable ceiling (10-20 minutes) on a single dictation, with a warning shortly before it, that stops cleanly and transcribes what was captured.

**Why it matters.** Nothing bounds recording length. A forgotten stop — easy with a bare-modifier toggle that has no visible pressed state — holds the Continuity session open indefinitely (keeping the iPhone captive, which is the one thing this product refuses to do), grows an uncompressed native-PCM WAV without limit, and eventually uploads it. Wispr caps desktop sessions at 20 minutes with a 19-minute warning for exactly this reason.

**Implementation.** Arm a `DispatchWorkItem` in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAudioRecorder.swift` alongside the existing `scheduleStartTimeout`/`scheduleFinalizationTimeout` pattern (lines 459-506), or drive it from the existing meter timer in `MacAppModel.startMeter()` (line 604-613) which already ticks `elapsed` every 80 ms. On warning, switch the HUD state in `MacStatusHUD.swift` to an explicit 'stopping in 60s' variant; on expiry call the normal `stopAndTranscribe()` path so the audio is preserved rather than discarded.

### Minimum-length guard for accidental taps

*reliability · small · seen in: ElevenLabs Scribe API (100 ms minimum)*

Refusing to upload clips below Scribe's 100 ms floor (and practically, below ~0.5 s), with a distinct 'that was too short' message instead of a network round-trip.

**Why it matters.** A bare right-Command tap is easy to double-fire. Today a start-then-immediately-stop either throws `noActiveRecording` (a confusing message for what the user did) or uploads a sub-100 ms file and gets back an opaque 400 `audio_too_short`. Either way it burns a request and logs a failure in the reliability history that misrepresents the app's actual reliability.

**Implementation.** In `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:280-317`, check `recordingDuration` before calling `startTranscription(...)` and short-circuit to a `.ready` phase with a non-logged toast rather than a `.failed` reliability entry. Optionally debounce the toggle in `MacGlobalHotKey` so a second tap inside ~250 ms of the first is treated as a cancel rather than a stop.

### Silent-microphone warning during recording

*reliability · small · seen in: superwhisper (no-audio-detected warning), Wispr Flow (mic disconnect notification)*

Detecting that the input level has stayed at the noise floor for several seconds while recording and warning, instead of producing an empty transcript at the end.

**Why it matters.** The steady-audio gate proves the stream is flowing before recording starts, but nothing checks that it carries speech. A hardware-muted mic, a muted Continuity session, or a phone that walked out of range mid-take yields buffers of silence, a clean-looking RECORDING state, and then a hard `emptyTranscript` failure after the user has already finished speaking a paragraph. The level data is already computed and published — nothing acts on it.

**Implementation.** `MacAppModel.startMeter()` already samples `recorder.normalizedLevel` every 80 ms at `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:604-613`. Track a rolling max; if it stays below ~0.02 for 3-4 s after recording starts, publish a warning state that `MacStatusHUD.swift` renders as 'NO AUDIO — check the microphone' without stopping the take (the user may simply have paused). superwhisper ships this as 'Microphone audio detection warning'; Wispr ships a mid-session 'Microphone disconnected' notification with an Insert action to salvage what was captured — SpeakPaste already has the salvage half via `handleUnexpectedRecordingFailure`.

### Smart capitalization and spacing at the insertion point

*delivery · medium · seen in: superwhisper (smart capitalization + spacing), Wispr Flow (Smart Formatting)*

Deciding whether to capitalize the first word and whether to insert a leading space, based on the text immediately before the cursor in the destination field.

**Why it matters.** Scribe always returns punctuated, capitalized prose and there is no API parameter to change that — the batch endpoint has no punctuate/smart_format/capitalization knob at all, so this can only be done locally. Dictating a continuation mid-sentence therefore pastes 'And then we should' with a capital A directly against the preceding character. Both competitors treat this as default behavior; superwhisper ships it as `autocapitalizeInsert` plus smart space insertion.

**Implementation.** Read the character preceding the caret before pasting: from the focused element in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacDeliveryTarget.swift`, fetch `kAXValueAttribute` and `kAXSelectedTextRangeAttribute` (an `AXValue` of type `.cfRange`) to locate the insertion index. Apply the transform in `MacPasteController.deliver(_:to:autoPaste:)` before `copyToPasteboard(text)`. Rules: lowercase the first letter when the preceding non-space character is a letter/comma; prepend a space when the preceding character is non-space and the transcript does not already start with punctuation. Fall back to no transform when AX cannot read the field (Electron), and expose an off switch — this must never mangle text when the context read is unreliable.

### Deterministic text replacements

*text-quality · medium · seen in: superwhisper (replacements + symbol/email recipes), Wispr Flow (misspelling replacement rules)*

An ordered list of find/replace pairs applied to the transcript after transcription, with case-insensitive matching, exact-case output, whole-word option and multi-line values.

**Why it matters.** Keyterm biasing fixes recognition; it cannot fix casing, brand styling, or expansions ('at sign' -> @, 'dot com' -> .com, 'my work email' -> the actual address). superwhisper's docs explicitly recommend replacements over vocabulary for persistent mis-transcriptions, and the symbol/email recipes are the documented workaround for the one class of thing speech models reliably fumble. SpeakPaste has no post-processing stage of any kind between the Scribe response and the pasteboard.

**Implementation.** Insert a pure `MacTranscriptPostProcessor` between `client.transcribe(...)` and `completedDictations[sequence] = …` in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:364-377`. Keep it a value type with no dependencies so it is unit-testable (this is the natural first test for the Mac target). Store rules next to the vocabulary list; share one Settings pane with two tabs since users conflate the two concepts. Order matters — apply replacements before capitalization/spacing so the insertion-point transform sees final text.

### Paste-last-transcript-here shortcut

*delivery · small · seen in: Wispr Flow (paste-last / copy-last hotkeys)*

A global shortcut that re-inserts the most recent transcript wherever the caret is now, independent of the held queue.

**Why it matters.** ⌥⌘V only releases *held* transcripts. When a transcript was delivered but landed somewhere wrong — the paste went to a stale field, the app swallowed it, the user clicked away a beat too early — there is no recovery except opening the main window and clicking Copy, then pasting manually. Wispr ships exactly this as ⌘⌃V and it closes the last hole in the delivery story cheaply.

**Implementation.** `MacPasteController.pasteAtCurrentFocus(_:)` already exists and does precisely this (`/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacPasteController.swift:52-56`). Add a `pasteLastTranscript()` action to `MacAppModel` calling it with `transcript`, bind it in `MacGlobalHotKey` (Carbon `RegisterEventHotKey` path — it is a conventional chord and needs no event tap), and add the menu item to `MacMenuBarView` next to the existing 'Copy Last Transcript'.

### Replace or delete the stored API key from the UI

*settings · small · seen in: superwhisper (BYOK management), Wispr Flow (Account settings)*

Making the key section reachable after a key is saved, with Replace and Delete controls.

**Why it matters.** `MacContentView` renders `apiKeySection` only `if !model.hasAPIKey`, so once a key is stored there is no way to change it from the app. `MacAppModel.deleteAPIKey()` exists and is wired to nothing. A rotated or revoked ElevenLabs key currently means editing the Keychain by hand or deleting the app's Keychain item via `security` — for a tool whose only failure-with-a-fix is a bad key, that is a dead end.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacContentView.swift:26-28, 462-481` and `SpeakPasteMac/MacAppModel.swift:210-213`. Move the section into the Settings scene's Account pane, always visible, showing a masked indicator ('Key stored in Keychain') plus Replace and Delete. Also surface whether the active key came from the Keychain or from the `ELEVENLABS_API_KEY` environment variable (`resolvedAPIKey`, line 694-698) — right now a stale env var silently wins over nothing and the user cannot tell which credential is in play.

### First-run onboarding with staged permission requests

*onboarding · medium · seen in: superwhisper (guided onboarding + mic page + try-the-shortcut), Wispr Flow (permission cards + demo window), macOS platform expectations (HIG onboarding/privacy)*

A skippable, replayable first-launch flow: explain the app, request Microphone at first record, request Accessibility and Input Monitoring when the global shortcut is first enabled, pick a microphone with a live level check, record a practice dictation, offer launch-at-login.

**Why it matters.** There is no onboarding at all. A new user sees a window with a disabled record button, an orange 'No microphone' pill and a notice telling them to bring their iPhone nearby, with the global shortcut silently non-functional because Accessibility was never requested. HIG asks for permissions at point of use with a single-button pre-alert screen and no escape route, and for onboarding to be brief, skippable and reachable later from Help or Settings.

**Implementation.** New `SpeakPasteMac/MacOnboardingView.swift` presented as a `Window` scene gated on a `hasCompletedOnboarding` UserDefaults flag, mirroring superwhisper's `completedOnboarding` / `onboardingProgress` pattern. Reuse the existing pieces rather than rebuilding: the device list from `MacAudioDeviceCatalog.availableInputs()`, the live meter (`InputLevelMeter` at `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacContentView.swift:695-720`) for the 'speak and watch the bars react' step, and the permission dashboard for the grant steps. Include a sandboxed practice target (a plain TextEditor in the onboarding window) so the first dictation cannot go wrong in a real app. Add a 'Show onboarding again' item under Help.

### Automated test coverage for the macOS target

*reliability · medium · seen in: SpeakPaste's own code (absent)*

A SpeakPasteMac test target covering the pure, high-risk logic: `CommandTapRecognizer`, the capture phase machine, the ordered delivery queue, held-transcript gating, and the transcript post-processor.

**Why it matters.** `SpeakPasteTests` contains only `ElevenLabsClientTests`, `HistoryStoreTests` and `SharedDictationStoreTests`, all `@testable import SpeakPaste` (the iPhone module) with `TEST_HOST` pointing at SpeakPaste.app. No SpeakPasteMac file has any test. The recorder state machine, hotkey recognizer, delivery gating and ordered queue are the most intricate code in the repo and carry the reliability guarantees the product is built on — and the `recordFailure` phase-clobbering defect above is exactly the class of bug a twenty-line test would have caught. `CommandTapRecognizer` (MacGlobalHotKey.swift:21-52) and `MacDeliveryTarget` are already pure and testable with no refactor.

**Implementation.** Add a `SpeakPasteMacTests` target in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste.xcodeproj/project.pbxproj` with `TEST_HOST` on the Mac app and `SDKROOT = macosx`. `MacAppModel` already takes injectable `recorder`/`client`/`keychain`/`pasteController`/`reliabilityStore`/`globalHotKey` collaborators in its initializer (MacAppModel.swift:102-130), so the ordered-delivery and held-transcript paths are testable with fakes today; `MacAudioRecorder` is the only piece needing a protocol extraction. Also add a shared `SpeakPasteMac.xcscheme` — `SpeakPaste.xcodeproj/xcshareddata/xcschemes/` currently contains only `SpeakPaste.xcscheme`, so the Mac scheme is per-user state and cannot be relied on for CI.

## Differentiators (17)

### Own the audio write path: sample-tap capture with pre-roll and incremental flushing

*capture · large · seen in: superwhisper (crash-proof 10s WAV saving), Wispr Flow*

Replacing `AVCaptureAudioFileOutput` with the existing `AVCaptureAudioDataOutput` tap plus an `AVAudioFile` writer, giving a pre-roll ring buffer of the seconds captured during the WAIT gate, incremental crash-safe flushing, and an offline resample stage.

**Why it matters.** This is the structural unlock behind several other gaps. Today the liveness gate can hold the user in WAIT for up to 15 s and any speech in that window is discarded, because file recording only starts after the gate passes — the very design that fixed AVError -11812 also creates the latency the product cannot otherwise remove. Buffers are already flowing through `captureOutput(_:didOutput:from:)` during the wait and are thrown away after being counted. Owning the write also means a crash mid-dictation stops losing everything (AVCaptureAudioFileOutput only produces a valid file on finalize), and makes 16 kHz mono resampling, local VAD and level metering possible without touching the capture graph.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAudioRecorder.swift`: the tap is already installed at lines 383-389 and `MacSampleFlowCounter` (69-84) is the natural place to grow a bounded ring of `CMSampleBuffer`s. On `startSegment()`, open an `AVAudioFile` in the device's native format, drain the ring (last ~3 s) into it, then continue appending from the delegate, flushing every few seconds. Preserve every existing guarantee: keep `sessionGeneration` matching (line 544-554), the runtime-error latch (49-64), the start/finalization watchdogs (459-506) and the full `stopRunning()` release before transcription (720-742). Do this incrementally behind a flag and validate against the Continuity path before switching the default — the current file-output design is load-bearing and was hard-won.

### Resample to 16 kHz mono PCM before upload and declare file_format=pcm_s16le_16

*capture · medium · seen in: ElevenLabs Scribe API (file_format)*

An offline post-capture conversion of the recorded WAV to 16-bit PCM, 16 kHz, mono, little-endian, uploaded with `file_format=pcm_s16le_16`.

**Why it matters.** `output.audioSettings = nil` deliberately keeps the Continuity session's native PCM to avoid a compressor in the capture graph — a good decision that should stay. But the resulting file can be 32-bit float stereo at 48 kHz, roughly 11 MB for 30 seconds, all of which is uploaded on a synchronous request. Converting *after* the file is finalized touches nothing in the capture graph, cuts upload bytes by roughly 10x, and unlocks the documented lower-latency ingestion path — the only server-side latency knob Scribe offers.

**Implementation.** After `MacAudioRecorder.stop()` returns in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:284-298`, convert with `AVAudioConverter` (or `AVAudioFile` read + `AVAudioPCMBuffer` + `AVAudioFile` write) to `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)`. Then add `appendField(name: "file_format", value: "pcm_s16le_16")` in `SpeakPaste/ElevenLabsClient.swift:109-114`. Measure before/after against the reliability log's `stt` timing — if conversion time exceeds the upload saving on short clips, gate it on file size. Fall back to the untouched WAV (and omit file_format) on any conversion error, never silently upload a mismatched declaration.

### Word-level confidence gating using logprob

*feedback-ui · medium · seen in: ElevenLabs Scribe API (words[].logprob)*

Decoding the `words[]` array and its `logprob` values, and using low overall confidence to withhold auto-paste (routing to the held queue for review) or to flag uncertain words.

**Why it matters.** `TranscriptionResult` decodes only `text`, `language_code` and `language_probability`, discarding the whole words array. Scribe returns per-word log probabilities for free on every request. For a tool built on never-guess, 'this transcript is broadly low-confidence, look at it before it goes into your message' is the most natural extension of the existing hold-instead-of-guess rule, and no competitor exposes it.

**Implementation.** Extend `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/TranscriptionModels.swift:27-37` with a `words: [Word]?` field (`{text, start, end, type, logprob, speaker_id}`), filtering `type == "spacing"` and `type == "audio_event"` out of anything pasted. Compute a mean/percentile confidence in `MacAppModel.transcribe(...)` and, above a configurable threshold of uncertainty, deliver as `.held` with a distinct HUD state rather than pasting. Note `timestamps_granularity` defaults to `word`, so no extra request parameter is needed; setting it to `none` would remove this data, so leave it alone.

### Per-app delivery rules keyed on bundle identifier

*context · medium · seen in: superwhisper (bundled per-app knowledge base), Wispr Flow (per-destination exceptions)*

A table mapping `NSRunningApplication.bundleIdentifier` to a delivery policy: auto-paste, clipboard-only, always-hold, or never-deliver.

**Why it matters.** `autoPaste` is one global boolean. Terminal-class apps, IDEs, remote-desktop windows and password managers each behave differently with synthetic ⌘V, and some destinations should be blocklisted outright. Today the only way to protect one app is to turn auto-paste off everywhere. `MacDeliveryTarget` already captures the process identity at record time — it just does not capture the bundle identifier, and nothing keys off it.

**Implementation.** Add `bundleIdentifier` to `MacDeliveryTarget` in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacDeliveryTarget.swift:23-35` (it is one line: `application.bundleIdentifier`). Consult a persisted rules map in `MacPasteController.deliver(_:to:autoPaste:)` (MacPasteController.swift:36-47) before the `autoPaste` check. Seed sensible defaults (1Password and similar -> never; Terminal/iTerm -> chunked; everything else -> auto) and let the reliability log's existing destination naming (MacAppModel.swift:424-428) drive a 'add a rule for this app' affordance.

### App Intents exposed to Shortcuts and Spotlight

*platform-integration · medium · seen in: superwhisper (Shortcuts/Raycast/Alfred via deep links), macOS platform expectations (App Intents)*

`AppIntent` definitions for Start Dictation, Stop and Transcribe, Cancel, Paste Held Transcripts and Transcribe Audio File (returning `ReturnsValue<String>` so the transcript feeds later Shortcuts steps), registered through an `AppShortcutsProvider`.

**Why it matters.** There is no automation surface of any kind. App Intents give a keyboard-driven invocation path that needs no TCC grant at all — a genuine complement to the event tap, and a real answer for the case where Accessibility is missing or Secure Event Input has the keyboard. On macOS 26 every App Intent is directly runnable from Spotlight, so this is also the cheapest possible 'works even when the hotkey does not' story.

**Implementation.** New `SpeakPasteMac/MacAppIntents.swift`. Intents must reach the `@MainActor MacAppModel` singleton, which today is a `@StateObject` owned by the App struct at `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/SpeakPasteMacApp.swift:5-12` — hoist it into a shared `static let` or an AppDelegate so intents can resolve it. Return `some IntentResult & ReturnsValue<String>` from the transcribe intent. No entitlement is required.

### URL-scheme deep links

*platform-integration · small · seen in: superwhisper (superwhisper:// deep links)*

A registered `speakpaste://` scheme handling record, stop, toggle, paste-held and settings.

**Why it matters.** Cheapest possible automation surface and the one every third-party integration in this space is built on — superwhisper's Raycast extension, Alfred workflow and Macrowhisper all sit on deep links plus the recordings folder. The Mac target generates its Info.plist (`GENERATE_INFOPLIST_FILE = YES`) and declares no URL types; only the iPhone Info.plist has `CFBundleURLTypes`.

**Implementation.** Add `INFOPLIST_KEY_CFBundleURLTypes` is not available as a build-setting key, so either switch the Mac target to a checked-in `Info.plist` (as the iPhone target does at `INFOPLIST_FILE = SpeakPaste/Info.plist`) or add the raw key via `INFOPLIST_PREFIX_HEADER`-style plist merging. Handle with `.onOpenURL` on the main scene or `application(_:open:)` in an AppDelegate, dispatching to the same `MacAppModel` methods the MenuBarExtra calls (`toggleRecording()`, `releaseHeldTranscripts()`). Ship the intents above and the URL scheme together — they are the same routing table.

### Push-to-talk (hold right-Command)

*trigger · medium · seen in: superwhisper (push-to-talk on the main shortcut), Wispr Flow (Fn hold, double-tap to latch)*

Holding the trigger key records and releasing stops, alongside the existing tap-to-toggle, distinguished by hold duration on the same key.

**Why it matters.** Tap-toggle is the right default for long dictation but wrong for a three-word interjection, and it is the interaction most prone to the 'forgot to stop' failure that motivates the max-duration guard. `CommandTapRecognizer` already tracks key-down and key-up precisely and already distinguishes taps from chords, so the state it needs exists — it just discards timing.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacGlobalHotKey.swift:21-52`. Add a timestamp to `modifiersChanged(commandDown:hasOtherModifiers:)`: on key-down start a timer, and if the key is still down past a threshold (~350 ms) fire a `pushToTalkBegan` callback; on key-up fire `pushToTalkEnded` if that fired, otherwise the existing tap. Real complication worth planning for: the Continuity liveness gate can take seconds, so a hold shorter than the connect time must not produce a zero-length recording — treat a release during `.connecting` as a cancel, and say so in the HUD. Keep it opt-in in Settings.

### Apply the user's system Text Replacements and an NSSpellChecker cleanup pass

*text-quality · medium · seen in: macOS platform expectations (NSSpellChecker)*

Running the transcript through `NSSpellChecker.shared.userReplacementsDictionary` (System Settings > Keyboard > Text Replacements) and an on-device `checkString(_:range:types:...)` pass for `.correction` / `.capitalization` / `.spelling`.

**Why it matters.** Platform-native personalization for free: the user's existing shorthand and proper-noun corrections already live in macOS and sync via iCloud, and applying them costs one local call with no second network round-trip and no second AI provider. It is the exact shape of text-quality improvement that is available under the Scribe-only constraint.

**Implementation.** Fold into the same `MacTranscriptPostProcessor` as the replacement rules, invoked from `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:364-377`. `NSSpellChecker.shared.userReplacementsDictionary` (macOS 10.6+) returns the substitution table; the same data is readable as `NSUserDictionaryReplacementItems` in `.GlobalPreferences`. Be conservative with the spell-check pass — apply `.capitalization` and high-confidence `.correction` results only, never bulk-rewrite, and make it individually toggleable, because a spell checker fighting the keyterm list would be worse than either alone.

### Audio ducking or media pause while recording

*capture · medium · seen in: superwhisper (pause music / mute output), Wispr Flow, macOS platform expectations*

Pausing playing media and/or lowering system output volume for the duration of a recording, restoring afterward.

**Why it matters.** Playback bleeding into the microphone is a direct transcription-quality problem, and with a Continuity mic sitting on the desk next to the speakers it is worse than with a headset. Both competitors ship it; superwhisper offers full mute, a 15% duck, and media pause/resume with AirPods fade.

**Implementation.** Simplest safe version: send a media pause/play via `MPRemoteCommandCenter`-adjacent means or post the `NX_KEYTYPE_PLAY` system-defined key event with `CGEvent`, around `MacAppModel.startRecording()` / `stopAndTranscribe()` in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:243-317`. Explicit caveat worth flagging before implementing: macOS 14's `AVAudioInputNode.voiceProcessingOtherAudioDuckingConfiguration` requires `setVoiceProcessingEnabled(true)`, which changes the input node format and adds AEC/AGC — that interacts directly with the Continuity capture path this app has spent its whole reliability budget stabilizing. Do not enable voice processing; use output-side ducking or media pause only, default off, and validate against the Continuity gate.

### Sparkle-based in-app updates

*platform-integration · medium · seen in: superwhisper (Sparkle + public appcast), macOS platform expectations*

An `SPUStandardUpdaterController` with `SUFeedURL` and `SUPublicEDKey` in Info.plist, an EdDSA-signed appcast over HTTPS, and a 'Check for Updates…' menu item.

**Why it matters.** Apple ships no updater outside the Mac App Store, and the App Sandbox requirement rules the store out for this app. Without Sparkle there is no distribution story at all beyond rebuilding in Xcode — and no way to ship any of the fixes in this matrix to a machine other than the one that built them.

**Implementation.** Add Sparkle 2 as an SPM dependency to the Mac target in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste.xcodeproj/project.pbxproj`, add the 'Check for Updates…' item to `MacMenuBarView` in `SpeakPasteMac/SpeakPasteMacApp.swift:55-108`. Critical prerequisite: Sparkle compares `CFBundleVersion`, and both Mac configurations pin `CURRENT_PROJECT_VERSION = 1`, so updates would never be detected — wire it to a monotonically increasing value. Depends on the Developer ID signing gap; an ad-hoc build cannot ship a trustworthy update.

### Capture transcription_id for server-side recovery

*history · small · seen in: ElevenLabs Scribe API (GET /v1/speech-to-text/transcripts/{id})*

Decoding `transcription_id` from every successful response and using `GET /v1/speech-to-text/transcripts/{transcription_id}` to recover a transcript whose HTTP response was lost.

**Why it matters.** The narrow but real case the current design cannot handle: the server finished, the network dropped or the app was killed before the body arrived, and the audio is deleted in the `defer`. The transcript exists on ElevenLabs and is retrievable. Free to capture — it is already in the payload.

**Implementation.** Add `transcriptionID` to `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/TranscriptionModels.swift:27-37`, store it in the history record, and add a `fetchTranscript(id:apiKey:)` method to `ElevenLabsClient`. Caveat to state in the UI: the docs give no retention period, so recovery is best-effort and must not be promised; and it is mutually exclusive with `enable_logging=false`, which is enterprise-only anyway.

### Language-detection confidence warning

*feedback-ui · small · seen in: ElevenLabs Scribe API (language_probability), superwhisper (language detection failure state)*

Acting on the `language_probability` value already decoded but never used: warning when auto-detection landed on an unexpected or low-confidence language instead of pasting silently.

**Why it matters.** `TranscriptionResult.languageProbability` is decoded at TranscriptionModels.swift:30/35 and thrown away. Pedro dictates in both English and Spanish with the picker often on Auto; a Spanish take detected as Portuguese produces plausible-looking garbage that gets pasted with full confidence. This is a no-silent-fallback violation that costs one comparison to fix.

**Implementation.** In `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:364-377`, carry `result.languageCode` and `result.languageProbability` into `MacFinishedDictation` (line 8-15) and into the reliability detail. Below a threshold, or when the detected code is outside a user-configured expected set, deliver as `.held` with 'detected Portuguese — check before pasting'. Both English and Spanish sit in Scribe's Excellent (<=5% WER) tier, so a low probability here is genuinely informative rather than routine noise.

### Chunked delivery for terminal and TUI targets

*delivery · medium · seen in: Wispr Flow (chunked delivery for AI coding CLIs)*

Splitting a long transcript into smaller paste chunks with brief pauses when the destination is a terminal emulator or a coding-agent TUI.

**Why it matters.** A single large ⌘V into Claude Code, Codex or a terminal REPL is routinely truncated or mangled by line-discipline and bracketed-paste handling. Wispr ships this specifically for Claude Code and Codex on Mac. Given Pedro's actual workflow this is one of the higher-value delivery fixes in the list, and it depends on the per-app rules gap for its trigger condition.

**Implementation.** In `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacPasteController.swift`, add a chunked variant of `activateAndPaste(_:)` that writes and pastes ~500-character segments split on sentence boundaries with ~60 ms gaps, selected by the per-app rule for the captured bundle identifier. Never chunk when clipboard restore is pending mid-sequence — restore only after the final chunk.

### Diagnostics export and report-an-issue

*reliability · small · seen in: superwhisper (Report Issue from a recording), Wispr Flow*

A control that packages the reliability log, app version, macOS version, permission states, selected device and its transport type, and the last error's `request_id` into a copyable or saveable report.

**Why it matters.** The reliability log is the product's own instrument for the bug it was built to fix, and it is trapped in a scrollable list with no copy, no export and a hard 20-entry cap. Diagnosing an intermittent Continuity failure across sessions is currently impossible without reading UserDefaults by hand.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacReliabilityStore.swift` — raise the `prefix(20)` cap at line 55 (100-200 is cheap), add `clear()`, and add an export producing JSON or Markdown. Surface Copy Report / Clear buttons in the reliability section header at `SpeakPasteMac/MacContentView.swift:584-598`. Include the device transport type from the Continuity-detection gap so a misidentified microphone is visible in the report.

### Network reachability signalling

*reliability · small · seen in: superwhisper (reachability monitoring with recovery notice)*

An `NWPathMonitor` telling the user when the connection dropped and when it returned, so a failed cloud transcription is attributable.

**Why it matters.** An offline transcription currently fails with a raw `URLError` string in the failure banner and — until the retry gap is fixed — destroys the audio. Distinguishing 'you are offline, this dictation is queued' from 'ElevenLabs rejected your key' is the difference between a queued retry and a lost paragraph.

**Implementation.** Add `NWPathMonitor` to `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift` alongside the existing `observeDeviceChanges()` (line 621-662). When offline, skip the upload entirely, retain the audio, and hold the dictation for automatic retry on reconnect rather than burning a 45-second timeout.

### VoiceOver announcements on phase transitions

*feedback-ui · small · seen in: Wispr Flow (full screen-reader support), macOS platform expectations*

Posting `NSAccessibility.post(element:notification:.announcementRequested)` when the capture phase changes, so 'connecting', 'speak now', 'transcribing', 'done' are spoken without navigating to the status item.

**Why it matters.** The app has good static accessibility labels throughout `MacContentView` and on the MenuBarExtra image, but a static label on a menu bar extra is not announced when it changes. For a hands-free dictation tool whose central instruction is 'do not speak until WAIT becomes SPEAK NOW', a VoiceOver user has no way to know when that transition happened. That is table-stakes accessibility for this specific product, not polish.

**Implementation.** Hook the `phase` didSet in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:46-51` and post `NSAccessibility.post(element: NSApp, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])`. Reuse the strings already written for `menuBarAccessibilityLabel` in `SpeakPasteMac/SpeakPasteMacApp.swift:43-52`. Pair with the earcons so both the audio and the spoken channel carry the same transition.

### HUD placement on the right display, with user control and an off switch

*feedback-ui · medium · seen in: superwhisper (position memory, snap points, headless mode), Wispr Flow (Flow Bar docking), macOS platform expectations (NSScreen)*

Positioning the HUD on the screen holding the destination app rather than `NSScreen.main`, repositioning on display changes, and letting the user move it, dock it, or turn it off entirely.

**Why it matters.** `positionPanelOnActiveScreen()` prefers `NSScreen.main`, which is the keyboard-focus screen — for a non-activating panel reporting on another app that is frequently the wrong display, so on a multi-monitor desk the HUD appears somewhere the user is not looking. It is also fixed top-center, unmovable (`ignoresMouseEvents = true`, `isMovable = false`), and cannot be disabled. superwhisper persists position, snap point and a headless mode; Wispr docks to three edges.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacStatusHUD.swift:119-142`. Choose the screen containing the frontmost window of the captured `MacDeliveryTarget` (or `NSEvent.mouseLocation`) instead of `NSScreen.main`, and observe `NSApplication.didChangeScreenParametersNotification` to reposition on hot-plug and resolution change. For movability, drop `ignoresMouseEvents` only while a modifier is held, or add a drag handle, and persist the anchor. Add 'Show floating status' and a corner picker to Settings; the earcons gap makes a headless mode viable. Note the panel's `collectionBehavior` (line 27-31) already correctly includes `.canJoinAllSpaces` and `.fullScreenAuxiliary` — do not regress that.

## Nice to have (17)

### Keep the screen awake during recording

*reliability · small · seen in: superwhisper (ScreenWakeManager)*

Preventing display and system idle sleep while a dictation is in flight.

**Why it matters.** A long dictation with no keyboard or mouse input is exactly the condition that triggers idle sleep, which kills the Continuity session mid-take. The salvage path would recover the partial file, but the take is still truncated for a reason entirely within the app's control.

**Implementation.** Wrap the recording window in `ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "Recording dictation")` and end it in `stopAndTranscribe()`, in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:243-317`. Balance begin/end across every failure path including `handleUnexpectedRecordingFailure`.

### Transcribe an existing audio or video file

*capture · medium · seen in: superwhisper (three entry points for file transcription)*

Accepting a dropped file, an Open With, or a Services-menu invocation and running it through the same Scribe path.

**Why it matters.** Zero marginal backend cost — Scribe accepts every major audio and video format, up to 10 hours, with no transcoding needed. It turns a dictation utility into a general transcription tool for voice memos and meeting recordings using code that already exists.

**Implementation.** Register `CFBundleDocumentTypes` for `public.audio` and `public.movie` (needs the checked-in-Info.plist change from the URL-scheme gap), handle `application(_:open:)`, and add a drop target to the main window. `ElevenLabsClient.transcribe(audioURL:...)` already takes an arbitrary URL and `audioContentType(for:)` at `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/ElevenLabsClient.swift:124-130` just needs more cases. Route the result to the history window rather than to a paste target. Mind the 45 s request timeout at line 52 — long files need a much larger value.

### Services menu provider

*platform-integration · small · seen in: macOS platform expectations (NSServices)*

An `NSServices` declaration plus `NSApplication.servicesProvider` so 'Transcribe with SpeakPaste' appears in every app's Services menu.

**Why it matters.** Low-cost, very macOS-native integration point that essentially no competitor ships, and it composes with the file-transcription gap for free.

**Implementation.** Add `NSServices` to the Mac Info.plist with `NSSendTypes` of `NSFilenamesPboardType` for the file case, and register a provider object from the AppDelegate. `NSRequiredContext` must be present or the system registers the service and never shows it.

### Full Scribe language list instead of three options

*settings · small · seen in: ElevenLabs Scribe API (90+ languages), Wispr Flow (in-bar language picker)*

Replacing the Auto/English/Spanish enum with the full ISO-639-1 language set Scribe supports.

**Why it matters.** `TranscriptionLanguage` hardcodes three cases. Auto-detect covers the common path and both of Pedro's languages are in Scribe's Excellent tier, so this is low urgency — but an explicit hint measurably improves accuracy when the language is known, and the three-case enum is an arbitrary ceiling with no technical reason behind it.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/TranscriptionModels.swift:3-25` — replace the enum with a struct wrapping an ISO code plus `Locale.current.localizedString(forLanguageCode:)` for display, keeping `nil` as Auto. The segmented picker at `SpeakPasteMac/MacContentView.swift:545-557` becomes a searchable Menu. Keep a short favorites list (Auto/EN/ES) at the top so the common case stays one click.

### Deterministic transcription via temperature and seed

*text-quality · small · seen in: ElevenLabs Scribe API (temperature, seed)*

Sending `temperature=0` and a stable `seed` so repeated requests on the same audio return the same words.

**Why it matters.** Neither parameter is set today, so the server default applies and a retry of the same audio can produce different text. For dictation the user wants the same words every time, and determinism makes the retry path (and the transcript history) predictable rather than surprising.

**Implementation.** Two `appendField` calls in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPaste/ElevenLabsClient.swift:109-114`. Persist a per-dictation seed alongside the retained audio so a retry reuses it. Verify empirically that temperature 0 does not degrade quality on short clips before making it the default.

### Local silence pre-check before upload

*reliability · medium · seen in: superwhisper (Silero VAD gate + silence removal)*

A cheap RMS or VAD check over the recorded buffers that skips the network call entirely when there is no speech, telling the user immediately instead of after a round-trip.

**Why it matters.** An empty transcript is currently discovered only after a full upload and inference — several seconds and a billed request for nothing, ending in a failure the user has to read carefully to understand. superwhisper runs a Silero ONNX VAD locally and skips the request outright with 'No voice detected, skipping transcribe'. Cutting silence also reduces upload size on long takes.

**Implementation.** Cheapest version needs no model: the sample tap in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAudioRecorder.swift:233-239` can accumulate an RMS envelope while recording; if the peak never exceeds a floor, fail fast in `MacAppModel.stopAndTranscribe()` with the same 'did not hear any speech' message `ElevenLabsClientError.emptyTranscript` already provides. This also naturally covers the silent-microphone warning gap. Full silence *removal* before upload is a follow-on that depends on owning the audio write path.

### Per-item held-transcript controls and age-out

*delivery · small · seen in: superwhisper, Wispr Flow*

Release, copy or discard individual held transcripts, and expire ones older than a configurable age.

**Why it matters.** The banner offers only all-or-nothing Copy and Discard and the queue joins everything with a space. Two dictations meant for different fields, or a stale transcript from an hour ago, cannot be separated — and there is no cap, so the queue can grow indefinitely with no cleanup.

**Implementation.** `MacHeldTranscript` already carries `id` and `createdAt` (`/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:18-23`) — the data is there, only the UI and the expiry sweep are missing. Expand `heldBanner` (MacContentView.swift:101-139) into a per-row list with individual actions, and add an age check to the existing 0.4 s `pendingWatchTimer` (MacAppModel.swift:473-480) that moves expired items to the transcript history instead of dropping them.

### Mouse-button and menu-bar-click triggers

*trigger · small · seen in: superwhisper (mouse + menubar click), Wispr Flow (Mouse Flow)*

Binding a non-primary mouse button (middle click, Mouse 4-10) to recording, and optionally making a left click on the menu bar icon start a recording.

**Why it matters.** Cheap alternate triggers for when the hands are on the mouse, and a fallback when the keyboard shortcut is unavailable (Secure Event Input, screen sharing, a conflicting Hyperkey binding). The event tap already receives `otherMouseDown` — it currently uses those events only to cancel a tap candidate.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacGlobalHotKey.swift:164-168` already handles `.otherMouseDown`; read `event.getIntegerValueField(.mouseEventButtonNumber)` and match it against a persisted binding. Never allow left or right click (Wispr rejects both outright). For the menu-bar variant, make it opt-in and keep right-click opening the menu, as superwhisper does.

### Disable-for-this-session kill switch

*trigger · small · seen in: superwhisper (Disable for session)*

A one-click menu item that suppresses the global shortcut until the app is relaunched or the user re-enables it.

**Why it matters.** During a screen share, a game, or while using an app that genuinely needs bare right-Command, the only options today are quitting SpeakPaste or living with the conflict. Cheap to build once the hotkey install/uninstall is already factored (`MacGlobalHotKey.uninstall()` exists).

**Implementation.** Add a published `isShortcutSuspended` to `MacAppModel`, call `globalHotKey.uninstall()` / re-install, and show the state in both the menu bar icon and the HUD so a suspended shortcut is never mistaken for a broken one — `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacGlobalHotKey.swift:112-132` and `SpeakPasteMac/SpeakPasteMacApp.swift:55-108`.

### Trackpad haptic confirmation

*feedback-ui · small · seen in: macOS platform expectations (NSHapticFeedbackManager)*

`NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime:)` on recording start and stop.

**Why it matters.** Silent confirmation for meetings and shared spaces where earcons are not an option, and a natural companion to a bare-modifier toggle that otherwise has no tactile feedback at all — the user cannot feel whether the tap registered.

**Implementation.** One call from the `phase` didSet in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:46-51`, guarded by a Settings toggle. Force Touch trackpads only; degrades to nothing elsewhere.

### Notifications for results the user cannot see

*feedback-ui · small · seen in: Wispr Flow (categorized notifications with a non-mutable Critical bucket), macOS platform expectations*

`UNUserNotificationCenter` alerts strictly for out-of-band events: a transcription that failed after the user moved on, or held text that arrived while the destination was gone.

**Why it matters.** The HUD auto-hides after 4 s on error and the user is by definition looking at another app. A background transcription that fails minutes later currently produces a HUD flash that may be missed entirely, after which the failure exists only in the reliability log.

**Implementation.** Request authorization once from Settings (never at launch), and post only from the background-transcription failure path in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:379-391`. HIG is explicit that foreground state changes belong in the HUD, not in notifications — keep the taxonomy narrow. Requires the stable bundle identifier and proper signing from the signing gap.

### Usage statistics

*history · medium · seen in: superwhisper (WPM, time saved, typing test), Wispr Flow (stats + streaks)*

Words dictated, average words per minute, time saved versus typing, and which apps receive the most dictation.

**Why it matters.** Pure motivation layer, but both competitors ship it prominently and the raw material is nearly free: the reliability log already records recording duration, transcription duration, device and destination per attempt — only word counts and aggregation are missing.

**Implementation.** Derive from the transcript history store once it exists rather than from `MacReliabilityStore`, which is capped and failure-oriented. The per-attempt destination string is already assembled in `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacAppModel.swift:424-428`; storing the bundle identifier instead of a display name (see the per-app rules gap) makes the by-app breakdown reliable.

### British/American spelling normalization

*text-quality · small · seen in: superwhisper (American/British spelling)*

A local post-processing pass forcing output to one spelling convention.

**Why it matters.** Trivial, purely local, and removes a small recurring annoyance for users whose model output drifts between conventions. Both superwhisper and its docs treat it as a formatting transform independent of the voice model, which is exactly what the Scribe-only constraint permits.

**Implementation.** Another rule set in the same `MacTranscriptPostProcessor` as the replacements, driven by a bundled word-pair table. Off by default; one Settings toggle.

### Focus filter integration

*platform-integration · medium · seen in: macOS platform expectations (SetFocusFilterIntent)*

A `SetFocusFilterIntent` so SpeakPaste behavior changes per Focus mode — earcons and notifications suppressed under Do Not Disturb, transcripts routed to the held queue during a Meeting focus.

**Why it matters.** The entitlement-free macOS 13+ route to Focus awareness (the `INFocusStatusCenter` alternative requires the Communication Notifications capability). Composes naturally with the earcons and notifications gaps and prevents an audible dictation tool from being disruptive in exactly the situations where it is most likely to be used quietly.

**Implementation.** Ships with the App Intents work; implement `SetFocusFilterIntent` in the same `SpeakPasteMac/MacAppIntents.swift`, exposing suppress-sounds and always-hold as filter parameters.

### Coding-agent integration hook

*platform-integration · large · seen in: superwhisper (agent-hook, Claude Code/Codex/Grok plugins)*

A hook script installed into Claude Code / Codex that surfaces the SpeakPaste recorder when the agent needs input or finishes a task, so the reply can be spoken without switching to the terminal.

**Why it matters.** superwhisper ships this as a headline feature with a dedicated `agent-hook` binary and a filesystem inbox, and it maps directly onto how this repo is actually worked. It is a large separate surface, but it is also the most distinctive thing in the competitive set and it composes with the URL-scheme and chunked-delivery gaps rather than needing new capture machinery.

**Implementation.** Depends on the URL-scheme gap: the hook only needs to fire `speakpaste://record` with a session identifier and read the resulting transcript back. Model the drop-directory contract on superwhisper's `~/Library/Application Support/superwhisper/agent/inbox/` with a deep-link fallback. Keep the hook script out of the app bundle's critical path — install it on demand from Settings, never automatically.

### Menu bar icon as a template asset, and Liquid Glass adoption for the HUD

*feedback-ui · small · seen in: macOS platform expectations (HIG menu bar, NSGlassEffectView)*

Verifying the phase-driven SF Symbols render as template images that tint correctly on light, dark and selected menu bars, and adopting the macOS 26 system material for the floating HUD.

**Why it matters.** The phase-driven symbol swap in `SpeakPasteMacApp.swift:32-41` is the right pattern, but nothing confirms the rendered image is treated as a template — a colored glyph reads as broken on a light menu bar. The HUD currently uses `.regularMaterial`, which is correct today; once the project builds against the macOS 26 SDK, `NSGlassEffectView` is the difference between looking native and looking bolted-on for a panel that floats over arbitrary app content.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/SpeakPasteMacApp.swift:27-29` — verify against both appearances; if the SwiftUI `Image(systemName:)` does not render as a template inside MenuBarExtra, drop to an `NSImage` with `isTemplate = true`. For the HUD, `SpeakPasteMac/MacStatusHUD.swift:201-208` is the single place to swap the background material behind an availability check.

### Cooperative activation yield and Help menu

*platform-integration · small · seen in: superwhisper (Help menu), macOS platform expectations (WWDC23 cooperative activation)*

Yielding activation back to the destination app after any activation SpeakPaste performs, plus a native Help menu linking to the README/docs.

**Why it matters.** Small platform-citizenship items. `activateAndPaste` correctly uses the modern `activate(options: [])` rather than the deprecated `activate(ignoringOtherApps:)`, but never yields back, so a delivery into a background app can leave focus in a state the user did not ask for. The Help menu is the HIG-designated home for the replayable onboarding.

**Implementation.** `/Users/pedroantoniovillanuevajuarez/Developer/SpeakPaste/.claude/worktrees/macos-audio-mic-bug-e29518/SpeakPasteMac/MacPasteController.swift:61-68` — call `NSApp.yieldActivation(toApplicationWithBundleIdentifier:)` before activating so the handoff is cooperative (macOS 14+). Add `CommandGroup(replacing: .help)` to the Mac scene in `SpeakPasteMac/SpeakPasteMacApp.swift` with links to the docs and a 'Show Onboarding' item.

## Already covered (61)

- Continuity-microphone-first device discovery with iPhone/Mac source badges
- No-silent-fallback microphone gating: refuses to substitute a Mac mic and explains why
- Deliberate-choice-only device persistence, with the legacy auto-persisted key purged at launch
- Steady-audio liveness gate (6 consecutive 30 ms windows) before file recording starts
- Mandatory audio-monitor tap: refuses to record when macOS will not grant a liveness proof
- Native-PCM WAV capture with no compressor or channel mixer in the capture graph
- Full Continuity session release on stop, before transcription, returning the iPhone
- In-place retry of a stuttering recording start without tearing down the connection
- Mid-dictation salvage of a finalized partial WAV when the stream dies
- Bounded watchdogs on recording start (8s), WAV finalization (8s) and the network request (45s)
- Session-generation matching and synchronous runtime-error latching against stale streams
- Live AVCaptureDevice connect/disconnect handling with re-resolution and failure logging
- Microphone permission request with System Settings-specific denial messaging
- Right-Command bare-tap global toggle via an Accessibility-authorized CGEventTap
- Chord-safe tap recognizer: any other modifier, keyDown, mouse down or scroll cancels the tap
- CGEventTap self-healing on tapDisabledByTimeout and tapDisabledByUserInput
- Graceful degradation to an NSEvent local monitor when Accessibility is not granted
- ⌥⌘V global shortcut to release held transcripts at the current caret
- In-app and menu-bar recording triggers, disabled when no device is selected
- Delivery-target capture (pid, app name, AX focused element) at record start, not delivery time
- Auto-paste via a real synthetic ⌘V rather than a kAXSelectedText write (toolkit-safe)
- Activate-then-paste with a 140 ms settle delay so the keystroke is not dropped
- Clipboard always receives the transcript on every delivery path
- Hold-instead-of-guess when focus moved away from the captured destination
- Held-transcript auto-delivery on return, joined in spoken order as a single insert
- Password/secure-field refusal by AX role and subrole before any unattended delivery
- Two-tier focus safety model: frontmost-only for immediate, identity-or-text-field for unattended
- Manual held-transcript controls (release, copy, discard) in the window and menu bar
- Microphone freed immediately after stop; transcription runs detached in the background
- Multiple dictations in flight at once with a 'mic is free' affordance
- Spoken-order delivery queue: ticketed at speak time, drained strictly in order
- Failed transcriptions still occupy their queue slot so they cannot stall later ones
- Live input-level meter (26-bar) and monospaced elapsed timer
- Floating non-activating, click-through NSPanel HUD that never steals focus
- HUD collectionBehavior with canJoinAllSpaces and fullScreenAuxiliary
- Complete HUD state vocabulary: WAIT / SPEAK NOW / RECORDING STOPPED / TRANSCRIBING xN / READY / TEXT WAITING / DONE / ERROR
- HUD auto-hide policy (1.5s success, 4s error) that stays up while anything is held or in flight
- HUD placed top-center under the menu bar, deliberately clear of the target's text field
- Menu bar extra with live phase-driven SF Symbol and matching VoiceOver labels
- ElevenLabs Scribe v2 batch transcription as the single, non-configurable backend
- no_verbatim wired to a clean-speech toggle
- tag_audio_events explicitly disabled so no [laughter] annotations reach the cursor
- language_code hint sent when a language is chosen
- Synchronous request/response mode (correct choice; no webhook infrastructure needed)
- Empty transcript treated as a loud, specific failure instead of a silent no-op
- ElevenLabs error message extraction from detail / detail.message / message
- Editable last-transcript pane with Copy (with flash confirmation) and Clear
- Persisted reliability attempt log with success rate and per-attempt recording/transcription timings
- Delivery route and destination recorded per attempt ('Transcribed and pasted → Slack')
- AVFoundation error translation into actionable plain language (mediaDiscontinuity, noDataCaptured, deviceWasDisconnected)
- Continuity connection-latency measurement and display
- Explicit 'do not speak yet' guidance during the connecting phase
- API key stored in the macOS Keychain with data-protection plus a traditional-keychain fallback
- ELEVENLABS_API_KEY environment-variable fallback for local development
- Recorded audio deleted after transcription, and stale segment files cleaned on teardown
- Auto-paste on/off toggle
- In-app documentation of both shortcuts and the left-⌘ non-interference guarantee
- Manual device refresh that deliberately skips re-resolution mid-dictation
- App Sandbox correctly disabled (required for AX writes and CGEventTap)
- Accessibility labels, hints and traits throughout the UI, plus reduce-motion support
- Single global capture phase machine driving window, HUD and menu bar consistently

## Deliberately rejected (22)

### Voice/transcription model picker, multi-provider backends, local Whisper or Parakeet

Hard constraint: ElevenLabs Scribe is the only transcription backend. superwhisper ships adapters for ElevenLabs, Deepgram, Cohere, OpenAI, Groq and WhisperKit plus BYOK custom models; the entire surface is deliberately out of scope. model_id=scribe_v2 should stay a constant in ElevenLabsClient.swift, not a setting.

### Realtime / streaming transcription with live word-by-word display

Hard constraint: quality beats latency, batch Scribe is deliberate. Also note this costs nothing to forgo — the batch endpoint is where keyterms at 1000 terms x 50 chars (vs 50 x 20 on realtime), no_verbatim, entity redaction, seed and transcript retrieval all live. The no-realtime constraint buys the entire advanced feature set.

### LLM post-processing modes with per-mode prompts (superwhisper Modes, Wispr Transforms / Flow Styles / Auto-Polish / writing samples)

Requires a second AI provider, a second API key, and by necessity a language-model picker — exactly what the single-backend, no-model-picker constraint forecloses. It also adds seconds of latency to a pipeline whose whole design is 'release the mic and deliver fast'. Scribe's own no_verbatim already covers filler-word and false-start removal server-side, and the local text pipeline proposed above (keyterms, replacements, capitalization, system Text Replacements, spelling normalization) covers the deterministic remainder without a second model.

### Command Mode / voice commands that rewrite selected text

Same reason as above — it is an LLM rewriting stage in disguise. It also inverts the product's safety model: SpeakPaste's rule is to never guess a destination, and a mode that silently replaces the user's selection with model output is the opposite of that.

### ElevenLabs asynchronous webhook delivery (webhook, webhook_id, webhook_metadata)

Requires a public HTTPS endpoint to receive the callback and signature verification via the elevenlabs-signature header. A local macOS app has no server, so this is structurally unavailable — not a future option. Synchronous request/response is the correct and only shape here.

### additional_formats export (srt, txt, docx, html, pdf, segmented_json)

Aimed at subtitling and document workflows. A tool that pastes plain text at the cursor has no use for rendered representations, and requesting them needlessly enlarges every response.

### use_multi_channel and multichannel_output_style

Changes the response shape to a `transcripts` array keyed by channel_index, which would break any client decoding a single `text` field. Dictation from one microphone is mono by definition. Worth knowing as a trap, not a feature.

### source_url / cloud_storage_url remote input

Alternative to multipart upload for hosted audio and YouTube/TikTok URLs. Irrelevant to a local-capture app; noted only so it is not confused with the local `file` path SpeakPaste already uses correctly.

### num_speakers and diarization_threshold hints

The ElevenLabs skill reference is explicit that a wrong num_speakers hint corrupts label assignment on real-world noisy audio and that auto-detection should always be used. Passing either would make output worse, not better.

### Speaker diarization, meeting mode, and named speaker profiles

Single-user dictation has no speakers to separate. Adding diarize=true costs a processing pass and invites false positives from background TV or a colleague talking nearby, with no corresponding benefit. detect_speaker_roles and use_speaker_library are call-center features specifically.

### System-audio / meeting capture (Wispr Notetaker, superwhisper Record from System Audio)

Out of scope for a dictation utility, and expensive: it requires a ScreenCaptureKit screen-recording TCC grant on top of the three permissions the app already needs, which directly works against the permission-surface reduction this matrix argues for.

### enable_logging=false zero-retention mode

Documented as enterprise-customers-only, so a personal app cannot promise it and would be shipping a setting that fails for its actual user. It is also mutually exclusive with transcript recovery via transcription_id.

### Single-use auth token (POST /v1/single-use-token/batch_scribe)

Exists to keep long-lived API keys off clients by minting tokens server-side. SpeakPaste has no backend and reads the user's OWN key from their own Keychain, so the threat model this solves does not apply.

### InputMethodKit input method as the text-insertion path

Would eliminate the Accessibility grant entirely — genuinely attractive in principle — but requires shipping and installing a separate input-method bundle and the user manually selecting it as an input source. Enormous change for a path the existing AX + synthetic ⌘V pipeline already covers once layout-correctness and Secure Event Input handling are fixed. Recorded as a known alternative, not proposed.

### App Sandbox / Mac App Store distribution

The AXUIElement write API and CGEventTap do not function inside the App Sandbox even with the user's Accessibility grant. ENABLE_APP_SANDBOX = NO is already correct and must stay; Developer ID plus Sparkle is the only viable channel.

### Profanity filter

Scribe exposes no such parameter, so it would be a local word-substitution pass. For a single-user personal dictation tool it adds a category of silent text mutation with no benefit — precisely the kind of invisible rewriting the no-silent-fallback principle argues against.

### Remote desktop / Citrix / VDI delivery support

Wispr documents it because it sells to enterprises with virtualized fleets. Not Pedro's environment, and it would add a delivery path that cannot be tested locally.

### Localized application interface

Single-user personal tool with an English-speaking owner. Localizing the UI is real ongoing cost against zero benefit here — note this is separate from transcription language support, which is a listed gap.

### Team, enterprise and compliance surfaces (SSO, SCIM, MDM deployment, admin usage dashboards, leaderboards, shared snippets, SOC 2 / HIPAA BAA / Trust Center)

Every one of these presupposes an organization, a seat model and a vendor relationship. SpeakPaste is a personal app using the owner's own ElevenLabs key with no server and no accounts.

### Cross-machine settings/history sync (superwhisper FileSync, Wispr Private Cloud Sync)

Requires either a server or an iCloud container plus conflict resolution, and it puts transcripts somewhere other than the user's disk — against the local-only posture. A hand-editable config folder plus a manual copy covers the real need at a fraction of the cost.

### Free-tier word caps, subscription plumbing and entitlement resync

SpeakPaste is billed through the user's own ElevenLabs API key. There is no product subscription to gate, sync or troubleshoot.

### Shareable stat cards and typing-speed tests

Growth-marketing surface for a commercial product. Basic usage statistics are listed as a nice-to-have gap; the shareable-card and viral layer on top of them is not.

## Adversarial review of this matrix

A completeness critic re-researched both competitors and re-read this repository
to find what the matrix above missed, and what it got wrong.

```
MISSING and WRONG report below. Evidence base: read every file in `SpeakPasteMac/` plus `SpeakPaste/ElevenLabsClient.swift`, `TranscriptionModels.swift`, `project.pbxproj`; inspected superwhisper 2.17.0 (`/Applications/superwhisper.app`, binary strings, `bundled_app_info.json`, GRDB schema, `defaults read com.superduper.superwhisper`) and Wispr Flow 1.5.433 (`/Applications/Wispr Flow.app`, asar strings, `wispr-flow.mcpb`); checked ElevenLabs claims against the `elevenlabs` skill's `references/api.md`.

```
================================================================================
MISSING
================================================================================

--- A. CAPTURE / RELIABILITY (the product's own thesis, and the thinnest area
    relative to what the code already almost does) ---

A1. THE LIVENESS GATE PROVES BUFFERS ARRIVE, NOT THAT THEY CONTAIN AUDIO
What it is: making the steady-audio gate require acoustic energy, not just
sample-buffer delivery.
Why it matters: MacAudioRecorder.captureOutput(_:didOutput:from:) (lines
233-239) does exactly one thing -- sampleFlow.increment(). waitForSteadyAudio
(198-215) then requires 6 consecutive windows in which that counter moved. A
microphone delivering all-zero PCM -- hardware-muted mic, a muted Continuity
session, an iPhone that has handed audio to a phone call -- passes this gate
perfectly. SpeakPaste then shows SPEAK NOW, the user speaks a paragraph, and
the run ends in ElevenLabsClientError.emptyTranscript. Wispr treats this as a
named, recurring macOS defect: its strings include "Audio silence bug
detected", "Audio silence persisting, escalating notification." and "Audio
recovered after sustained silence". The matrix has this only as a soft
post-hoc warning ("Silent-microphone warning during recording"); it is
actually a correctness hole in the single guarantee the product sells.
How: in captureOutput, pull the audio via
CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer and compute per-buffer
peak/RMS; have MacSampleFlowCounter track both a buffer count and a
"non-silent window" count. Require N windows above a floor before returning
from connect(). Add a distinct MacAudioRecorderError case (e.g.
.audioStreamSilent) so "connected but sending silence" is diagnosable
separately from .audioStreamNotReady. This subsumes the matrix's
"Local silence pre-check before upload" gap for free.

A2. NO CONTINUOUS STREAM-HEALTH MONITORING DURING RECORDING
What it is: watching sampleFlow while phase == .recording, not only before it.
Why it matters: the flow counter is consulted exclusively inside
waitForSteadyAudio, i.e. before startSegment(). Once recording begins, nothing
watches the stream; SpeakPaste depends entirely on AVFoundation raising
runtimeErrorNotification or finishing the file. A stream that stalls without
emitting an error yields a truncated or silent WAV under a clean, ticking
SPEAK NOW HUD for the whole take. superwhisper runs a periodic health check
and restarts the audio unit: "Audio unit successfully restarted after health
check failure", "Failed to restart audio unit: ", isRestartingStream,
"Stream restart already in progress.", healthCheckInterval.
How: MacAppModel.startMeter() (604-613) already ticks every 80 ms; have it
also read a new MacAudioRecorder.sampleFlowCount. If the count is static for
>1.5 s, publish a HUD state ("MIC STALLED"); past a bound, drive the existing
handleUnexpectedRecordingFailure path, which already salvages a finalized
partial WAV. Cheapest correct version needs no new threading -- the counter is
already lock-protected and Sendable.

A3. MICROPHONE INPUT GAIN IS NEVER READ, REPORTED, OR WARNED ABOUT
What it is: surfacing the selected input device's volume scalar.
Why it matters: superwhisper ships "Sets microphone input volume to max when
starting a recording. Only works if using system default device.", plus
"Default device volume is ", "Cannot set input volume: no default input
device". SpeakPaste has no concept of input level at all. A Continuity or USB
mic sitting at 15% input produces quiet audio, materially worse WER, and zero
explanation anywhere in the app -- and the reliability log will record it as a
successful attempt.
How: resolve each AVCaptureDevice.uniqueID to its CoreAudio AudioObjectID (the
same lookup the matrix's transport-type gap needs) and read
kAudioDevicePropertyVolumeScalar in kAudioObjectPropertyScopeInput. Show it in
microphoneSection; warn below ~0.25. Do not silently boost -- that is exactly
the invisible mutation the product forbids -- but offer an explicit
"boost while recording, restore on stop" toggle.

A4. NO HANDLING OF ANOTHER PROCESS TAKING THE MICROPHONE MID-DICTATION
What it is: AVCaptureSession interruption handling, distinguishing "another
app took the mic" from "the device disconnected".
Why it matters: this is the "what happens mid-call" journey moment, entirely
unaddressed. Wispr ships AudioInterruptionEvent, IsAudioInterruptionMonitoring
Enabled, and "Audio interruption began during active recording". For SpeakPaste
the worst case is specific and likely: an incoming call on the very iPhone
serving as the Continuity microphone. Today the only response is whatever
AVFoundation happens to report, translated by continuityHint(for:) into
"The iPhone paused its microphone stream." -- which is a symptom, not a cause.
How: observe AVCaptureSession.wasInterruptedNotification /
interruptionEndedNotification on the session created in configureAndConnect
(357-434) and read AVCaptureSessionInterruptionReasonKey; map
audioDeviceInUseByAnotherClient to "another app is using the microphone" and
name the app via NSRunningApplication where possible. Salvage through the
existing partial-file path, and on interruptionEnded offer to resume rather
than forcing a fresh connect.

A5. NO SLEEP / WAKE / SCREEN-PARAMETER / SPACE OBSERVERS ANYWHERE
What it is: NSWorkspace and NSApplication lifecycle observation.
Why it matters: grep confirms the Mac target contains zero NSWorkspace
notification observers -- the only NSWorkspace uses are frontmostApplication
reads in MacDeliveryTarget (lines 25, 66, 78). Consequences, all real:
(a) a Mac that sleeps mid-dictation leaves the recorder in .recording over a
dead Continuity session; (b) after wake, the Continuity device's uniqueID can
change, so mac-chosen-device-id no longer resolves and resolveSelection()
strands the user on "The microphone you chose is no longer available" until a
manual refresh; (c) positionPanelOnActiveScreen() runs only inside showPanel(),
so the HUD never repositions on display hot-plug or resolution change --
directly undercutting the matrix's own multi-display gap.
How: observe NSWorkspace.willSleepNotification (stop and salvage any live
recording before the session dies), didWakeNotification and
screensDidWakeNotification (call refreshDevices()), and
NSApplication.didChangeScreenParametersNotification (reposition the panel).

A6. NO SINGLE-INSTANCE GUARD
What it is: refusing to launch a second copy.
Why it matters: superwhisper ships "App is already running, quitting". This
project's install flow (build in Xcode, copy to /Applications -- the project
memory records the recipe) makes two live copies genuinely likely. Two
instances means two CGEventTaps on bare right-Command: every tap starts two
recordings, two AVCaptureSessions contend for the same iPhone, and the loser
throws .recorderBusy / .connectionFailed. That failure will read to the user
as "the Continuity bug is back" -- i.e. it will be blamed on the exact defect
this app exists to fix.
How: at launch, NSRunningApplication.runningApplications(withBundleIdentifier:)
minus ProcessInfo.processInfo.processIdentifier; if non-empty, activate the
existing instance and NSApp.terminate(nil). Requires the stable bundle
identifier from the signing gap. While there, add superwhisper's launch
preconditions ("App is not supported on this version of MacOS. Quitting.").

--- B. DELIVERY ---

B1. THE PASTE IS NEVER VERIFIED -- AND THE HELD QUEUE IS CLEARED ON AN
    UNVERIFIED PASTE (live data-loss defect)
What it is: confirming the transcript actually landed before treating delivery
as done.
Why it matters: sendPasteKeystroke() (MacPasteController.swift:75-88) returns
true whenever CGEvent construction succeeds; CGEvent.post returns nothing.
Both competitors verify: superwhisper ships PasteConfirmationMonitor,
CursorContext, "Detected paste redirected into input, took ", "No cursor
context before paste"; Wispr diffs the field before and after ("Attempted to
get before and after text but formatted text is not found in pasted text,
should never happen"). This is not only the Secure-Event-Input case the matrix
already lists. It is a data-loss bug today:
MacAppModel.deliverHeldTranscriptsIfTargetFocused() lines 502-503 --

    guard pasteController.pasteAtCurrentFocus(text) != .copiedNeedsAccessibility else { return }
    heldTranscripts.removeAll { readyIdentifiers.contains($0.id) }

-- removes the held items on any result other than .copiedNeedsAccessibility.
A swallowed keystroke returns .pasted, so the held text is dropped and the
HUD's "Nothing is lost" promise (MacContentView.swift:112) is already false
without any quit or crash.
How: before pasting, read kAXValueAttribute + kAXSelectedTextRangeAttribute on
the focused element (the same reads the smart-capitalization gap needs); after
a short delay re-read and confirm the transcript is present at the insertion
point. On failure keep the item held and fall through to the AX menu-action
path (B2). Where AX cannot read the field (Electron), fall back to a
pasteboard changeCount check and record the route as "pasted (unverified)" --
the reliability log currently counts unverifiable deliveries as successes,
which quietly inflates the success-rate figure the app displays.

B2. AX MENU-ACTION PASTE AS THE PRIMARY DELIVERY PATH
What it is: driving the target app's Edit > Paste menu item via
AXUIElementPerformAction(item, kAXPressAction), with synthetic Cmd-V as
fallback.
Why it matters: superwhisper's ordering is menu-first -- "Failed to paste via
menu action: " followed by "Falling back to keyboard shortcut paste" -- and it
walks target menu bars to do it ("Fetch Menubar UITree", "Fetch Menubar Extra
UITree", menuBarOwningApplication, extrasMenuBar). The menu path is
layout-independent (no UCKeyTranslate, no keycode 0x09 problem at all), immune
to Secure Event Input, and needs no Post Event TCC grant. The matrix buries it
as "a belt-and-braces alternative for stubborn apps" inside the
keyboard-layout gap; it deserves to be its own item because it collapses three
listed gaps into one change.
How: from the captured target's pid, AXUIElementCreateApplication ->
kAXMenuBarAttribute -> locate the Edit menu -> the item whose
kAXMenuItemCmdCharAttribute is "v" (locale-proof, better than matching the
title "Paste") -> kAXPressAction. Cache per bundle identifier. Pair with
AXUIElementSetMessagingTimeout (already a listed gap) so a hung target cannot
stall this.

B3. NO AUTO-SEND (PRESS RETURN AFTER PASTE)
What it is: optionally posting Return once delivery is confirmed.
Why it matters: superwhisper ships "Hold shift to auto-send after paste";
Wispr lets you bind a mouse button "to trigger enter and send messages
faster". For this user's actual destinations -- Slack, WhatsApp, iMessage,
Claude Code and Codex TUIs -- the dictation is a message that still has to be
sent by hand, which is most of the remaining friction after the paste works.
How: a modifier held during the stop tap (CommandTapRecognizer already tracks
hasOtherModifiers and would need only to report which), or a per-app rule.
Hard dependency on B1: sending an unverified paste sends an empty message.

B4. NO TYPE-OUT DELIVERY MODE
What it is: emitting the transcript as synthesized Unicode keystrokes instead
of pasting.
Why it matters: superwhisper ships simulateKeypressesEnabled. Clipboard + Cmd-V
is SpeakPaste's only delivery mechanism, so any destination that does not
honor a synthetic paste -- terminals with bracketed paste off, some remote
sessions, canvas-based editors, environments under clipboard policy -- is
simply unreachable, and (per B1) reports success anyway.
How: CGEvent(keyboardEventSource:virtualKey:0,keyDown:) +
CGEvent.keyboardSetUnicodeString, throttled ~1-2 ms/char, length-capped,
selected by the per-app rule the matrix already proposes. This is also the
only path that needs no pasteboard write at all, so it is what makes
superwhisper's "Bypass clipboard" option meaningful.

B5. NO SCRATCHPAD / DICTATE-WITH-NO-DESTINATION SURFACE
What it is: a place to dictate when there is no target app.
Why it matters: Wispr's scratchpad is prominent enough that half its bundled
MCP server exists to serve it (search/get/create/update_scratchpad_note).
Today, when SpeakPaste itself is frontmost, MacDeliveryTarget.captureCurrent()
returns nil, delivery degrades to .copied, and the text lands in the
single-slot model.transcript that the next dictation overwrites. There is no
"just capture this thought" mode.
How: a Window("Scratchpad", id:) scene backed by the transcript-history store
(matrix gap), appending rather than replacing when SpeakPaste is the target.

--- C. CONTEXT AND TEXT QUALITY (all Scribe-only compatible; no second model) ---

C1. DYNAMIC KEYTERMS HARVESTED FROM THE DESTINATION'S ON-SCREEN TEXT
What it is: per-request keyterms derived from what is actually in the field
and window you are dictating into, on top of the static glossary.
Why it matters: this is the single biggest thing the matrix's static
keyterm list leaves on the table, and it is fully available under the
Scribe-only constraint. superwhisper ships the equivalent as
applicationContextEnabled / CursorContext / "Focused Content (LLM Context)" /
"Characters that would be sent as focused element content to the LLM".
SpeakPaste already captures the focused AXUIElement at record start
(MacDeliveryTarget.captureCurrent(), line 33), so the surrounding text is one
kAXValueAttribute read away. Dictating into a code review, a Linear issue, or
a Slack thread about specific people means the right proper nouns are already
on screen.
How: at record start, read the focused element's value, the window title
(kAXTitleAttribute) and the app name; extract capitalized tokens, camelCase,
snake_case and code identifiers not in a common-word list; dedupe against the
static glossary; append as keyterms[] for that request only. Cap at the
per-request limit with the static list winning on overflow. Must reuse
MacAccessibility.focusedElementAcceptsText()'s secure-field refusal -- a
password manager's field content must never be read, let alone uploaded --
and must be per-app disableable.

C2. NO VOCABULARY LEARNING FROM THE USER'S OWN CORRECTIONS
What it is: proposing glossary/replacement entries from edits the user makes
to a delivered transcript.
Why it matters: both competitors ship it -- superwhisper
autoVocabCaptureEnabled + VocabularyCaptureManager; Wispr "Adds corrected
words automatically" plus its post-paste diff ("Attempted to update history
and dictionary but formatted text is not found or empty"). A hand-maintained
list is the version that empirically stays empty, which is why the matrix's
keyterm gap is lower-yield than its "table-stakes" tier implies.
How: MacContentView's transcript pane is already editable and bound to
model.transcript. When the user edits it after a delivery, diff against the
delivered text, and surface word-level substitutions as candidates
("Add 'Wippo' to vocabulary?"). Never auto-add silently -- offer, don't apply.

C3. NO PHONETIC / FUZZY POST-TRANSCRIPTION VOCABULARY CORRECTION
What it is: correcting low-confidence words against the glossary after the
response comes back, rather than relying only on server-side biasing.
Why it matters: superwhisper devotes an entire framework to this
(Supervocab_Supervocab.bundle, "On-device audio vocabulary correction
(wav2vec2 phoneme CTC + G2P)", PhonemeAcousticModel, G2PModel.swift,
SpellChecking.swift) with separate thresholds per word class
(commonWordAcousticThreshold, properNounAcousticThreshold,
protectedAcousticThreshold, floorRescueAcousticThreshold, logProbThreshold).
Keyterm biasing alone routinely misses names. This is also what makes the
matrix's own words[].logprob differentiator pay for itself.
How: no model needed for a first version. Decode words[] + logprob (already
proposed in the matrix), and for each word below a confidence threshold run
edit-distance plus a Metaphone/Double-Metaphone match against the glossary,
substituting only above a similarity bar. Pure value type, unit-testable,
lives in the same MacTranscriptPostProcessor as the replacement rules.

C4. NO SPOKEN PUNCTUATION / FORMATTING COMMANDS
What it is: mapping "new line", "new paragraph", "bullet point" to characters.
Why it matters: superwhisper carries literalPunctuationEnabled. Scribe returns
those phrases as literal words and offers no server parameter to change it, so
dictating anything structured -- a list, a multi-paragraph message -- is
impossible today. This is one of the few remaining text-quality levers that
does not need an LLM.
How: opt-in pass in MacTranscriptPostProcessor, restricted to a small fixed
command set and to sentence boundaries so prose that legitimately contains
"new line" is not mangled. Off by default; it is a text mutation.

C5. LANGUAGE HINT FROM THE ACTIVE KEYBOARD INPUT SOURCE
What it is: using the input source the user is currently typing in to choose
language_code, or to define the "expected language" set.
Why it matters: superwhisper does exactly this -- "[Supervocab][LangID]
keyboard bias: ", "keyboard-confirmed ", "[Supervocab][LangID] locked ". Pedro
dictates in English and Spanish with the picker usually on Auto; the layout he
is typing in right now is free, strong evidence, and it makes the matrix's
language-probability warning gap actionable instead of arbitrary.
How: TISCopyCurrentKeyboardInputSource() ->
kTISPropertyInputSourceLanguages, refreshed on
kTISNotifySelectedKeyboardInputSourceChanged -- the same observer the
keyboard-layout gap already requires, so it is nearly free once that lands.

--- D. JOURNEY MOMENTS THE MATRIX DOES NOT COVER ---

D1. NO MICROPHONE TEST-AND-VERIFY AFFORDANCE
What it is: "Test this microphone" -- record a few seconds, play it back,
report quality.
Why it matters: Wispr ships a dedicated testing mode ("Action click ignored -
currently in mic testing mode", "Audio quality metrics", "Help us identify the
best microphone setup for you.", "Choose another microphone") and device-class
guidance ("AirPods may be slow to start and have more errors in dictation. We
recommend the built in microphone."). For an app whose entire premise is
microphone reliability, there is currently no way to answer "is this mic
working well?" except by doing a real dictation and reading the transcript.
How: a button that runs a 3-second capture through the existing
connect()/startSegment()/stop() path, plays it back through the alert device,
and reports peak level, clipping fraction, silence fraction and connect
latency (connectionLatency is already measured and displayed). Natural home
for A1's silence detection and A3's gain warning. Belongs in onboarding and in
Settings.

D2. NO WAY TO CANCEL AN IN-FLIGHT TRANSCRIPTION
What it is: aborting a dictation that has already been spoken but not yet
delivered.
Why it matters: Wispr ships "Aborting transcription task on dismiss". The
matrix's cancel gap aborts a *recording* only. Because SpeakPaste deliberately
runs several transcriptions concurrently and auto-delivers them in spoken
order, a dictation you regret the instant you stop speaking will still paste
itself into your editor a minute later, and no control anywhere stops it.
How: retain the Task handles from startTranscription (MacAppModel.swift:
329-339) in [Int: Task<Void, Never>]; add per-item cancel to the HUD's
TRANSCRIBING xN state and to MacMenuBarView. A cancelled ticket must still
advance nextDeliverySequence or it stalls every dictation spoken after it --
the same invariant the failure path already honors at lines 381-389.

D3. NO STALENESS GUARD ON DELIVERY
What it is: refusing to auto-paste a dictation that finished long after it was
spoken.
Why it matters: deliver(_:) has no age check. canDeliverImmediately only asks
whether the app is still frontmost (MacDeliveryTarget.swift:65-67), which
after five minutes of slow network is very weak evidence that the same field
is still the right destination. A retry queue (matrix gap) makes this strictly
worse by extending the window.
How: stamp MacFinishedDictation with its speak time and route anything older
than a configurable window (60-90 s) to the held queue with "spoken 4 minutes
ago -- check before placing" rather than pasting unattended.

D4. NO CRASH / HANG DETECTION OR RECOVERY NOTICE
What it is: knowing the app died, and saying so on next launch.
Why it matters: superwhisper links Sentry.framework and carries
crashedSessionFilePath, abnormalSessionFilePath, appHangEventFilePath and ANR
timing; Wispr ships a crash reporter plus a "Blocked event loop monitor". For
a background agent whose whole value is "the shortcut is always live", a crash
is discovered by tapping right-Command and getting nothing. The matrix covers
the held queue evaporating but not the crash itself. A main-thread hang is
also a live risk: MacAccessibility calls run on the main actor, so a wedged
Electron target can freeze the app -- the matrix's AX-timeout gap is the cause,
this is the detection.
How: local-only fits the privacy posture. Write a "clean shutdown" marker on
applicationWillTerminate and a heartbeat while running; on launch, absence of
the marker means "SpeakPaste quit unexpectedly last time", shown alongside the
recovered held transcripts. Add a lightweight main-thread watchdog that logs a
reliability entry when the main queue is unresponsive past ~3 s.

D5. NO POST-ONBOARDING DISCOVERABILITY MECHANISM
What it is: contextual, dismissible coach marks driven by real usage triggers.
Why it matters: superwhisper ships OnboardingToastManager / OnboardingToastCard
/ OnboardingToastStore with per-feature dismissal (the live prefs on this
machine read dismissedOnboardingToasts = "vocabulary.firstItem,
vocabulary.firstReplacement"); Wispr ships TypingReminderEnabled, nudging when
it sees you typing instead of dictating. The matrix's onboarding gap is a
one-time first-run flow only, so every feature added from this matrix ships
undiscovered.
How: a small toast store keyed by feature id, triggered off state the app
already has -- first held transcript ("Opt-Cmd-V places it anywhere"), first
failed transcription (Retry exists), the same proper noun mis-transcribed
across three attempts (vocabulary exists).

D6. THE GLOBAL SHORTCUT NEVER RECOVERS FROM AN ACCESSIBILITY REVOCATION
What it is: a defect sharper than the matrix's "only re-checks on
didBecomeActive" framing.
Why it matters: MacGlobalHotKey.refreshMonitor() (177-186) is

    if AXIsProcessTrusted() { if eventTap == nil { removeLocalMonitor(); installEventTap() } }
    else if localMonitor == nil { installLocalMonitor() }

If the grant is revoked while running, the now-dead CFMachPort is never
invalidated and eventTap stays non-nil. The local monitor gets installed, so
the shortcut half-works while SpeakPaste is frontmost. But when the user
re-grants Accessibility, the eventTap == nil test is false, so nothing is
installed -- the global shortcut is permanently dead until relaunch, and
nothing anywhere says so.
How: make refreshMonitor idempotent in both directions: track the active mode
explicitly, and on !AXIsProcessTrusted() tear the tap down
(CFRunLoopRemoveSource + CFMachPortInvalidate + nil out) before falling back.
Fold into the matrix's permission-dashboard gap, which needs the same
DistributedNotificationCenter "com.apple.accessibility.api" observer.

D7. NO "RESET PERMISSION" AFFORDANCE FOR THE STALE-TCC CASE
What it is: detecting and explaining "checked in System Settings but
AXIsProcessTrusted() is false".
Why it matters: superwhisper ships this as a named control ("Click Reset
Permission below, then click Allow."), and SpeakPaste's current state
guarantees users hit it: ad-hoc signature, PRODUCT_BUNDLE_IDENTIFIER =
com.example.SpeakPasteMac, rebuilt from Xcode. macOS keys the TCC row to the
code signature, so after every rebuild the app appears granted while it is
not. The matrix names "Reset Permission" only inside a seenIn list and gives
no implementation note.
How: an app cannot tccutil-reset itself in any supported way, so the value is
in detection and instruction: compare "listed in the Accessibility pane" (not
directly readable -- use the AXIsProcessTrusted() == false while a prior
successful grant was recorded in UserDefaults heuristic) and show the
remove-then-re-add sequence with a deep link. This becomes far rarer once the
signing gap lands, but it is the state users are in today.

D8. NO "EDIT THE TRANSCRIPT AND DELIVER THE FIXED VERSION"
What it is: the other half of the "transcript is wrong" journey moment.
Why it matters: the matrix's Retry gap re-uploads the same audio, which fixes
transport failures but not recognition failures. When Scribe simply got a word
wrong, the user's only route is Copy, switch app, paste, fix by hand. Yet the
transcript pane is already editable, and MacPasteController.pasteAtCurrentFocus
already exists (52-56) -- so "Insert this corrected text at my cursor" is
roughly a button and a call. It also feeds C2.

--- E. PLATFORM INTEGRATION ---

E1. NO LOCAL MCP SERVER
What it is: a stdio MCP server over SpeakPaste's own data and controls.
Why it matters: Wispr ships one as a first-class bundled resource --
Resources/wispr-flow.mcpb, a PEP-723 stdio server reading the local
flow.sqlite directly, explicitly "no network calls", installable into Claude
Desktop, Claude Code and Cursor, exposing search_scratchpad_notes /
get_scratchpad_note / create/update + search_meetings / get_meeting. Given
that this repo is worked from Claude Code and Codex, this is the single most
on-point integration in the entire competitive set, and the matrix does not
mention MCP once -- it lists App Intents, URL scheme, Services, Focus filters
and a coding-agent hook instead. It is also strictly cheaper than the
agent-hook gap (tier: nice-to-have, effort: large) while delivering most of
the same value.
How: once the transcript-history store exists, a small stdio server exposing
search_transcripts / get_transcript / get_last_transcript, plus
start_dictation and paste_held that call the same MacAppModel entry points the
MenuBarExtra uses. Ship it as a .mcpb bundled in Resources with an
"Install for Claude" button, exactly as Wispr does.

E2. NO UPDATE-SAFETY STORY FOR A BACKGROUND AGENT
What it is: the part of Sparkle adoption that is specific to a dictation tool.
Why it matters: the matrix's Sparkle gap correctly identifies
CURRENT_PROJECT_VERSION = 1 as the blocker (verified: both Mac configurations
pin it), but stops at "add Sparkle". An update that relaunches silently drops
the held-transcript queue, kills every in-flight transcription, and re-triggers
TCC if the signature moves. superwhisper carries SUEnableAutomaticChecks and
SUScheduledCheckInterval = 86400 plus "Automatically check for updates ...
every three hours"; Wispr verifies the outcome ("Auto-update failed: app
restarted but version unchanged").
How: use SPUUpdaterDelegate to refuse installation while phase.isBusy,
inFlightCount > 0, or heldTranscripts is non-empty; persist the held queue
before relaunch (already a matrix gap, now load-bearing); verify
CFBundleVersion actually changed post-restart and log a reliability entry if
not.

--- F. SETTINGS / DATA ---

F1. NO DELIBERATE FALLBACK-DEVICE CHAIN
What it is: an ordered list of user-approved microphones instead of one.
Why it matters: the no-silent-fallback rule is right, but its current shape is
binary -- resolveSelection() (167-195) picks the chosen device, else any
Continuity device, else nothing at all. A user who has explicitly said "iPhone
first, then my desk mic, never the built-in" has consented; refusing to record
is the wrong answer for that user, and today the only escape is a manual pick
every single time the iPhone is away. superwhisper tracks
deviceSelectionCounts and supports exclusion ("System default input device is
excluded (").
How: persist an ordered list in place of mac-chosen-device-id, resolve
top-down, and always name which entry won in the HUD detail and in the
reliability attempt -- the principle is "never a mic the user did not name",
not "never more than one name".

F2. NO RETENTION POLICY OR ONE-CLICK PURGE
What it is: a single control governing how long audio and transcripts live,
plus "delete everything now".
Why it matters: superwhisper has recordingRetentionDuration and a real sweep
("Retention cleanup: chunk delete failed, retrying individually: "); Wispr has
"Are you sure you want to delete all transcripts?" and "Delete this
transcript". The matrix scatters retention across three gaps (retry retention
cap, history 30-day sweep, "discard all pending audio") and never makes it one
first-class privacy control. Once retry retains failed audio and history
retains text, a fragmented answer is worse than none.

--- G. CATEGORIES THAT LOOK THIN RELATIVE TO COMPETITORS ---

- onboarding: one entry for an entire journey stage. Competitors ship guided
  flow + mic test + practice dictation + permission cards + post-onboarding
  toasts. See D1, D5.
- history: three entries, none of which is "edit and re-deliver" (D8), none of
  which is deletion/purge (F2), and no MCP/agent read surface (E1).
- trigger: five entries, but no answer to "what invokes dictation when the
  keyboard is unavailable" beyond App Intents -- no auto-send (B3), no
  cancel-in-flight (D2).
- capture: the category carrying the product's entire thesis has no live
  health monitoring (A2), no energy-based liveness (A1), no gain awareness
  (A3), no interruption handling (A4), and no test mode (D1).
- context: two entries. Both competitors treat destination context as a
  first-class input; C1 is the version available under Scribe-only.

Constraint check: every MISSING item above is either local post-processing, a
macOS platform API, or a request-shaping change to the existing batch
multipart body. None requires a second model provider, a second API key, a
webhook endpoint, or realtime streaming.

================================================================================
WRONG
================================================================================

W1. "Deterministic transcription via temperature and seed" -- LIKELY A
    NON-EXISTENT API SURFACE
The ElevenLabs skill's Scribe reference (references/api.md in the elevenlabs
plugin) enumerates the batch STT knobs -- model_id, language_code, diarize,
num_speakers, diarization_threshold, timestamps_granularity (none/word/
character), no_verbatim, keyterms, use_multi_channel, source_url -- and
temperature and seed are not among them. Those are TTS parameters. Sending
unknown multipart fields is at best ignored and at worst a 422 on an endpoint
that currently has no retry path. This is classified as a shippable
nice-to-have with a two-line implementation note; it needs verification
against the live convert-endpoint docs before it goes on any list. Same
caution applies to two other unverified API claims used as implementation
detail: file_format=pcm_s16le_16 (plausible, but confirm it is accepted on the
batch convert endpoint, not just realtime), and the
current-concurrent-requests / maximum-concurrent-requests response headers the
concurrency gap proposes sizing a semaphore from.

W2. THE URL-SCHEME GAP'S PLIST ADVICE IS NOT A REAL MECHANISM
It proposes adding CFBundleURLTypes "via INFOPLIST_PREFIX_HEADER-style plist
merging". INFOPLIST_PREFIX_HEADER is the C preprocessor prefix used with
INFOPLIST_PREPROCESS; it does not merge structured plist keys. The supported
route is to keep GENERATE_INFOPLIST_FILE = YES and additionally set
INFOPLIST_FILE to a small checked-in partial plist containing only
CFBundleURLTypes / CFBundleDocumentTypes / NSServices -- Xcode merges the
INFOPLIST_KEY_* build settings into that file. The gap is right that there is
no INFOPLIST_KEY_CFBundleURLTypes; it is wrong about the workaround. The same
bad note is inherited by "Transcribe an existing audio or video file" and
"Services menu provider", which both defer to it.

W3. THE KEYBOARD-LAYOUT GAP UNDER-SCOPES ITSELF AND MIS-RANKS ITS OWN
    ALTERNATIVE
It leads with a UCKeyTranslate scan over keycodes 0...127 plus a
kTISNotifySelectedKeyboardInputSourceChanged observer, and demotes the AX menu
action to "a belt-and-braces alternative for stubborn apps". superwhisper does
the opposite: menu action first, keystroke as fallback. The menu path needs no
keycode resolution at all, is immune to Secure Event Input, and requires no
Post Event grant -- so it resolves three separate table-stakes gaps
(keyboard-layout, Secure Event Input, Input Monitoring/Post Event preflight)
with one change. Reordering these changes the whole delivery workstream's
sequencing. See B2.

W4. "Recorded audio deleted after transcription" IS LISTED AS A STRENGTH WHILE
    THE SAME LINE IS CALLED A DATA-LOSS BUG
alreadyHave contains "Recorded audio deleted after transcription, and stale
segment files cleaned on teardown", and the retry gap correctly identifies the
identical defer block (MacAppModel.swift:354-357) as destroying dictations on
429/offline/expired-key. Both cannot stand. The alreadyHave entry should read
"deleted after success" only once retry lands; today it should not be
presented as a completed feature at all.

W5. "Hold-instead-of-guess" AND "Two-tier focus safety model" OVERSTATE THE
    GUARANTEE THEY DESCRIBE
Both are listed in alreadyHave, and the held-transcript persistence gap
attributes the broken "Nothing is lost" promise solely to quit/crash. In fact
deliverHeldTranscriptsIfTargetFocused() (MacAppModel.swift:502-503) clears
held items on any paste result except .copiedNeedsAccessibility, and
sendPasteKeystroke() cannot detect a swallowed keystroke -- so held text is
already droppable in a normally running app. The safety model is one
unverifiable boolean away from being real. See B1.

W6. THE AUDIO-DUCKING GAP'S PROPOSED MECHANISM IS THE ONE COMPETITORS
    ABANDONED
It proposes posting NX_KEYTYPE_PLAY via CGEvent. superwhisper ships
MediaRemoteAdapter.framework plus a mediaremote-adapter.pl helper script
precisely because a synthesized play/pause key is unreliable: it toggles rather
than pauses, and it lands on whichever app owns the Now Playing session, which
may not be the one making noise. The honest framing is that there is no
supported public API for "pause the current Now Playing app", which makes this
riskier than "effort: medium, tier: differentiator" implies. The
voice-processing / AEC caveat in the same note is correct and should stay.

W7. THE CUSTOM-VOCABULARY GAP IS THE LOW-YIELD HALF OF A THREE-PART FEATURE
It is ranked the single highest-leverage item, but as scoped -- a static,
hand-maintained list uploaded as keyterms[] -- it is the version that stays
empty in practice. Neither competitor ships it alone: superwhisper pairs it
with automatic capture (autoVocabCaptureEnabled, VocabularyCaptureManager) and
with acoustic post-hoc correction (Supervocab, wav2vec2 phoneme CTC + G2P);
Wispr pairs it with "Adds corrected words automatically" driven by its
post-paste diff. Keep the ranking, but the item as written under-delivers
without C1/C2/C3.

W8. THE MENU-BAR-AGENT GAP'S statusHUD.start() WARNING IS RIGHT BUT WILL READ
    AS ALREADY-HANDLED
It says the HUD "never starts when no window is open". Today that is not
observable: MacStatusHUDController is a @StateObject on the App struct,
start() is called from MacContentView.onAppear (SpeakPasteMacApp.swift:18),
WindowGroup reopens the window on relaunch, and start() is idempotent
(guard phaseCancellable == nil). The breakage appears only after converting to
Window/LSUIElement. Stating it that way prevents the fix being deferred as
"works fine, ignore".

W9. "Trackpad haptic confirmation" seenIn IS INCOMPLETE
It cites only "macOS platform expectations (NSHapticFeedbackManager)". Wispr
Flow ships haptic handling. Minor, but seenIn is what the matrix uses to
justify tier, and this entry reads more speculative than it is.

W10. THE "Localized application interface" REJECTION SITS IN TENSION WITH THE
     CONTINUITY-DETECTION GAP
The rejection is correct on its own terms (a single English-speaking owner),
but it is phrased as "zero benefit here", and the capture gap correctly warns
that MacAudioInputDevice.isContinuityDevice (MacAudioDevice.swift:8-11) is a
localizedName substring match that a non-English *system locale* would break.
UI localization and system-locale robustness are independent; the rejection
should cross-reference the capture gap so nobody reads it as dismissing the
locale risk.

Nothing in the matrix's gap list is already implemented. I verified the
absence of every API the gaps depend on in SpeakPasteMac/: no NSSound /
AudioServices, no UNUserNotificationCenter, no SMAppService, no Settings
scene, no SettingsLink, no IsSecureEventInputEnabled, no CGPreflight*, no
AXUIElementSetMessagingTimeout, no ProcessInfo.beginActivity, no
NSWorkspace notification observers, no bundleIdentifier capture. Two gaps are
better-supported than stated: MacAudioRecorder.disconnect() (the cancel gap's
plumbing) is already exercised in production by the device-disconnect path at
MacAppModel.swift:644, and the paste-last gap needs only a binding since
pasteAtCurrentFocus and a "Copy Last Transcript" menu item both already exist.
```
```
