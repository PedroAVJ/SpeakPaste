# SpeakPaste

SpeakPaste is a native Swift dictation project for macOS and iPhone. It sends
recorded audio directly to [ElevenLabs Scribe](https://elevenlabs.io/speech-to-text),
then lets you edit, copy, or paste the transcript.

The Xcode project contains three targets:

- **SpeakPasteMac** — the primary macOS target, producing the **SpeakPaste** app
  with Continuity Microphone support, a global dictation shortcut, and automatic
  paste.
- **SpeakPaste** — an iPhone containing app with record, edit, copy, share, and
  local transcript history.
- **SpeakPasteKeyboard** — an experimental custom keyboard that hands microphone
  capture to the containing app and inserts the result at the cursor.

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
6. Click the record control or tap either **Command (⌘)** key by itself.
   Command-key combinations such as ⌘C, ⌘V, and ⌘Tab keep their normal behavior.
7. Wait for the click-through floating HUD to change from **WAIT** to
   **SPEAK NOW**, then begin speaking.
8. Tap Command again to stop. SpeakPaste closes the recording, fully releases
   the microphone, and then moves through **TRANSCRIBING** to **DONE** or
   **ERROR**.

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
4. Open Notes or another text field, switch to SpeakPaste with the globe key,
   and tap **Start Dictation**.
5. The containing app opens to own the microphone. Accept microphone permission
   if needed. On the first keyboard dictation, tap **OK** on the one-time
   switchback explanation.
6. SpeakPaste returns to the previous app while recording continues. Tap
   **Stop & Insert** in the keyboard to transcribe and insert the result at the
   original cursor.

The keyboard renders its own QWERTY, number, and symbol planes because iOS does
not place Apple's keyboard beneath a third-party keyboard extension. If the
automatic return is unavailable, recording continues and the app explains how
to swipe back manually.

The recording-grounded acceptance criteria and source media live in
[the iPhone keyboard round-trip specification](docs/ios-keyboard-roundtrip-spec.md).

## Keyboard handoff implementation

Apple does not provide microphone access to custom keyboards, so the containing
app must briefly foreground and start capture. SpeakPaste uses typed
`UIScene.open` or `UIApplication.open` calls for this launch and persists the
real asynchronous result of every attempted route.

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
- Finished recordings are deleted after transcription on macOS. On iPhone they
  are deleted after success or cancellation and retained after an API failure
  so Retry can reuse them.
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
- Launch, host-resolution, audio-stage, shared-session, and return-route
  diagnostics are persisted in the App Group.
- Recorded regressions cover a failed containing-app launch, the invalid
  `.record` / `.spokenAudio` / `.duckOthers` audio configuration, and a generic
  suspension that incorrectly returned to the Home Screen.
- An earlier signed app and embedded-keyboard build was installed on a physical
  iPhone with matching App Group entitlements. The API key survived replacement,
  and microphone permission, keyboard installation, and Full Access were
  exercised.

The current system-navigation switchback still requires one fresh direct-phone
Notes run. Keep that run's shared session intact until its host-resolution and
return diagnostics have been copied. Insertion, cancellation, retry, Full Access
denial, and the manual fallback must also be exercised before calling every
iPhone path end-to-end verified.

## License

SpeakPaste is available under the [MIT License](LICENSE).
