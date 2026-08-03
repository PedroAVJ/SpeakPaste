# SpeakPaste

SpeakPaste is a native Swift dictation project for macOS and iPhone. It sends
recorded audio directly to [ElevenLabs Scribe](https://elevenlabs.io/speech-to-text),
then lets you edit, copy, or paste the transcript.

The Xcode project contains four product targets:

- **SpeakPasteMac** — the primary macOS target, producing the **SpeakPaste** app
  with Continuity Microphone support, a global dictation shortcut, and automatic
  paste.
- **SpeakPaste** — an iPhone containing app with record, edit, copy, share, and
  local transcript history.
- **SpeakPasteKeyboard** — a custom typing keyboard that inserts queued
  background dictations at the cursor.
- **SpeakPasteLiveActivity** — the Lock Screen and Dynamic Island recording
  indicator required by iOS for background `AudioRecordingIntent` capture.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- An [ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys)
- An iPhone and Apple development signing if you want to run the iPhone app or
  keyboard

## Run the macOS app

1. Open `SpeakPaste.xcodeproj` in Xcode.
2. Select the **SpeakPasteMac** scheme and **My Mac** as the destination.
3. Build and run. The product is named **SpeakPaste.app**.
4. Save your ElevenLabs API key when prompted.
5. Keep your iPhone nearby and locked and SpeakPaste selects its Continuity
   microphone automatically. Only a microphone you pick yourself is remembered,
   and SpeakPaste never substitutes a Mac microphone on its own: if the iPhone
   is unavailable it says so and waits for you to choose.
6. Click the record control or tap the **right Command (⌘)** key by itself.
   The left ⌘ is deliberately untouched, so ⌘C, ⌘V, and ⌘Tab keep their normal
   behavior and cannot start a dictation by accident.
7. Wait for the click-through floating HUD to change from **WAIT** to
   **SPEAK NOW**, then begin speaking.
8. Tap right Command again to stop. SpeakPaste closes the recording, fully
   releases the microphone, and then moves through **TRANSCRIBING** to **DONE**
   or **ERROR**.

You do not have to wait at the keyboard. If the field you dictated into is no
longer focused when the transcript arrives, SpeakPaste holds the text instead of
pasting it somewhere else, and says so. Click back into that same field and it
inserts itself; press **⌥⌘V** to drop it wherever your cursor is instead.
Delivery is attempted only into the exact element that had focus when recording
started — never merely the same application.

The second Command press ends the Continuity session before transcription
starts, allowing macOS to dismiss its system-owned capture surface on the
iPhone. Each new dictation reconnects and may briefly show **WAIT** or play the
connection sound again. Automatic paste and the global shortcut require macOS
Accessibility permission; without it, the transcript remains on the clipboard.

You can also build the macOS target from Terminal:

```sh
xcodebuild \
  -project SpeakPaste.xcodeproj \
  -scheme SpeakPasteMac \
  -configuration Debug \
  -derivedDataPath /tmp/SpeakPasteDerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  build
```

Settings live behind **⌘,** and cover transcription language, delivery, sounds,
launch at login, the API key, custom vocabulary, text replacements, transcript
history, and a live view of the permissions the app depends on.

**Vocabulary** is the main quality control. Names, jargon, and product spellings
added there are sent with every dictation as ElevenLabs keyterms, biasing
recognition toward them without forcing a substitution — an unused term costs
nothing. **Replacements** are the blunt instrument for the cases Scribe gets
wrong every time; they always fire.

Transcripts are kept on this Mac in Application Support, searchable, with a
retention window and a real one-click purge. Failed transcriptions keep their
audio so they can be retried rather than lost.

For local development, `SpeakPasteMac` also accepts the API key through the
`ELEVENLABS_API_KEY` environment variable. Never commit an API key.

## Run the iPhone app and keyboard

The checked-in identifiers use the `com.example` namespace. Before signing,
replace these with identifiers owned by your Apple Developer account, keeping
the app and keyboard App Group values identical in all of these locations:

- the **SpeakPaste**, **SpeakPasteKeyboard**, and **SpeakPasteTests** bundle
  identifiers in Xcode
- `SpeakPaste/SpeakPaste.entitlements`
- `SpeakPasteKeyboard/SpeakPasteKeyboard.entitlements`
- `SharedDictationConstants.appGroupIdentifier` in
  `SpeakPaste/SharedDictation.swift`

Then:

1. Select the same development team for **SpeakPaste** and
   **SpeakPasteKeyboard**.
2. Run **SpeakPaste** on your iPhone and save your ElevenLabs API key in
   Settings.
3. In iOS Settings, open **General → Keyboard → Keyboards → Add New Keyboard**,
   add SpeakPaste, and enable **Allow Full Access**.
4. In Shortcuts, create a shortcut containing the single **SpeakPaste → Toggle
   Dictation** action.
5. In iOS Settings, open **Accessibility → Touch → Back Tap → Double Tap** and
   assign that saved shortcut.
6. Open Notes or another text field and double-tap the back of the phone. Talk,
   then double-tap again to stop.
7. Switch to SpeakPaste with the globe key immediately; you do not need to wait
   for transcription. The keyboard inserts the queued transcript at the cursor
   as soon as Scribe returns.

The keyboard renders its own QWERTY, number, and symbol planes because iOS does
not place Apple's keyboard beneath a third-party keyboard extension. It remains
usable while its passive status bar shows **Listening**, **Transcribing**, or
the insertion result. It never starts dictation or navigates away from the host
app; Back Tap owns invocation and the keyboard owns delivery.

The current UX, device evidence, and acceptance criteria live in
[the iPhone dictation UX specification](docs/ios-dictation-ux.md).

## Background dictation and keyboard delivery

Apple does not provide microphone access to custom keyboards. SpeakPaste avoids
the old foreground-app bounce by invoking an `AudioRecordingIntent` from Back
Tap, keeping a Live Activity visible for the full capture, and transcribing in
the background. The App Group carries the completed text to the active keyboard,
which inserts it through `textDocumentProxy` and marks the session inserted.

### Deprecated keyboard handoff fallback

The earlier keyboard-initiated round trip remains in the code temporarily for
diagnostics while the Back Tap delivery path finishes physical-device
acceptance. It uses typed `UIScene.open` or `UIApplication.open` calls to launch
the containing app and persists the real asynchronous result of each route.

For the return, the personal sideload checks the live
`UISystemNavigationAction` that backs the iOS status-bar breadcrumb. Runtime
inspection is guarded by exact Objective-C method encodings. SpeakPaste sends
only the live, valid, response-capable, unconsumed primary/back destination and
accepts it as successful only after its foreground scene enters the background.
A fixed allowlist of public host URL schemes and, finally, private bundle
activation are fallbacks. System brokers such as SpringBoard are never accepted
as return targets.

The system-navigation selector, scene-identity probe, and bundle launcher are
private APIs used by this experimental sideload. They may change in future iOS
releases and are not suitable for App Store submission. The reference recording
proves Wispr Flow's user-visible round trip; it does not reveal or establish
Wispr's internal implementation.

The implementation was compared with
[Wispr Flow's iPhone keyboard guide](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone),
[its iOS switchback release note](https://wisprflow.ai/whats-new),
[Apple's custom keyboard documentation](https://developer.apple.com/documentation/uikit/uiinputviewcontroller),
and [Apple's extension URL-opening contract](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)).

## Privacy

- API keys are stored in the platform Keychain. The keyboard extension never
  receives the key.
- Audio is sent directly to ElevenLabs at
  `POST https://api.elevenlabs.io/v1/speech-to-text` using the `scribe_v2`
  model.
- Finished recordings are deleted after transcription on macOS. On iPhone,
  manual in-app recordings are retained after an API failure so Retry can reuse
  them. Back Tap recordings are deleted after success, cancellation, or failure;
  its passive keyboard does not expose Retry.
- Transcript history stays on-device and is capped at 50 entries.
- Full Access lets the keyboard share dictation state with the containing app.
  SpeakPaste does not collect general keystrokes.

Review [ElevenLabs' privacy policy](https://elevenlabs.io/privacy-policy) before
sending sensitive audio.

## Development status

The macOS target builds with local ad-hoc signing and the shared sources pass
Swift 6 type-checking. Its floating HUD exposes **WAIT**, **SPEAK NOW**,
**RECORDING STOPPED**, **TRANSCRIBING**, **DONE**, and **ERROR**, including an
elapsed timer for busy states. Connecting stays in **WAIT** until the microphone
proves it is delivering a steady sample stream, so file recording does not begin
inside the Continuity wake-up gap; if macOS refuses the monitoring tap that
proves liveness, the connection fails loudly instead of recording unguarded. Interrupted startup is retried in place, a
stream that dies mid-dictation salvages its finalized partial file, and recording
startup, WAV finalization, and network requests have bounded watchdogs.

For iPhone:

- Both app and keyboard sources pass focused Swift 6 type-checking against the
  installed iOS SDK.
- Back Tap recording uses the paired `AudioRecordingIntent` and
  `LiveActivityIntent` contracts, with a WidgetKit Live Activity spanning the
  full capture.
- Launch, host-resolution, audio-stage, shared-session, and return-route
  diagnostics are persisted in the App Group.
- Recorded regressions cover a failed containing-app launch, the invalid
  `.record` / `.spokenAudio` / `.duckOthers` audio configuration, and a generic
  suspension that incorrectly returned to the Home Screen.
- An earlier signed app and embedded-keyboard build was installed on a physical
  iPhone with matching App Group entitlements. The API key survived replacement,
  and microphone permission, keyboard installation, and Full Access were
  exercised.

The settled delivery path still requires one fresh direct-phone Notes run:
Back Tap to start, speak, Back Tap to stop, immediately switch to SpeakPaste,
and confirm exactly one insertion with the shared phase ending as `inserted`.
Cold launch, music ducking, Full Access denial, failure recovery, and the manual
in-app fallback must also be exercised before calling every iPhone path
end-to-end verified.

## License

SpeakPaste is available under the [MIT License](LICENSE).
