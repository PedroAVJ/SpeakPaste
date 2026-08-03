# SpeakPaste

SpeakPaste is a native Swift dictation project for macOS and iPhone. It sends recorded audio directly to [ElevenLabs Scribe](https://elevenlabs.io/speech-to-text), then lets you edit, copy, or paste the transcript.

The Xcode project contains three targets:

- **SpeakPasteMac** — the primary macOS target, producing the **SpeakPaste** app with Continuity Microphone support, a global dictation shortcut, and automatic paste.
- **SpeakPaste** — an iPhone containing app with record, edit, copy, share, and local transcript history.
- **SpeakPasteKeyboard** — an experimental custom keyboard that hands microphone capture to the containing app and inserts the result at the cursor.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- An [ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys)
- An iPhone and Apple development signing if you want to run the iPhone app or keyboard

## Run the macOS app

1. Open `SpeakPaste.xcodeproj` in Xcode.
2. Select the **SpeakPasteMac** scheme and **My Mac** as the destination.
3. Build and run. The product is named **SpeakPaste.app**.
4. Save your ElevenLabs API key when prompted.
5. Select any available microphone. To use Continuity Microphone, keep your iPhone nearby and locked, then select its microphone from the list.
6. Click the record control or tap either **Command (⌘)** key by itself. Command-key combinations such as ⌘C, ⌘V, and ⌘Tab keep their normal behavior.
7. Wait for the click-through floating HUD to change from **WAIT** to **SPEAK NOW**, then begin speaking.
8. Tap Command again to stop. SpeakPaste closes the recording, fully releases the microphone, and then moves through **TRANSCRIBING** to **DONE** or **ERROR**.

The second Command press ends the Continuity session before transcription starts, allowing macOS to dismiss its system-owned capture surface on the iPhone. Each new dictation reconnects and may briefly show **WAIT** or play the connection sound again. Automatic paste and the global shortcut require macOS Accessibility permission; without it, the transcript remains on the clipboard.

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

For local development, `SpeakPasteMac` also accepts the API key through the `ELEVENLABS_API_KEY` environment variable. Never commit an API key.

## Run the iPhone app and keyboard

The checked-in identifiers use the `com.example` namespace. Before signing, replace these with identifiers owned by your Apple Developer account, keeping the app and keyboard App Group values identical in all of these locations:

- the **SpeakPaste**, **SpeakPasteKeyboard**, and **SpeakPasteTests** bundle identifiers in Xcode
- `SpeakPaste/SpeakPaste.entitlements`
- `SpeakPasteKeyboard/SpeakPasteKeyboard.entitlements`
- `SharedDictationConfig.appGroupIdentifier` in `SpeakPaste/SharedDictation.swift`

Then:

1. Select your development team for **SpeakPaste** and **SpeakPasteKeyboard**.
2. Run **SpeakPaste** on your iPhone and save your ElevenLabs API key in Settings.
3. In iOS Settings, open **General → Keyboard → Keyboards → Add New Keyboard**, add SpeakPaste, and enable **Allow Full Access**.
4. Switch to the keyboard in another app, tap **Start Dictation**, return to SpeakPaste when prompted, speak, and tap **Stop & Insert**.

Apple does not provide microphone access to custom keyboards. The keyboard demo therefore relies on runtime host-app recovery and a dynamic switchback mechanism, with a manual-swipe fallback. These techniques use unsupported behavior, may change in future iOS releases, and are not suitable for App Store distribution without redesign.

## Privacy

- API keys are stored in the platform Keychain. The keyboard extension never receives the key.
- Audio is sent directly to ElevenLabs at `POST https://api.elevenlabs.io/v1/speech-to-text` using the `scribe_v2` model.
- Finished recordings are deleted after transcription on macOS. On iPhone they are deleted after success or cancellation and retained after an API failure so Retry can reuse them.
- Transcript history stays on-device and is capped at 50 entries.
- Full Access lets the keyboard share dictation state with the containing app. SpeakPaste does not collect general keystrokes.

Review [ElevenLabs' privacy policy](https://elevenlabs.io/privacy-policy) before sending sensitive audio.

## Development status

The macOS target builds with local ad-hoc signing and the shared sources pass Swift 6 type-checking. Its floating HUD exposes **WAIT**, **SPEAK NOW**, **RECORDING STOPPED**, **TRANSCRIBING**, **DONE**, and **ERROR**, including an elapsed timer for busy states. Connecting stays in **WAIT** until the microphone proves it is delivering a steady sample stream (15-second limit), so file recording never starts inside the Continuity wake-up gap that AVFoundation reports as a media discontinuity. A recording that still stutters before its first written sample is retried in place, and a stream that dies mid-dictation hands its finalized partial file to transcription instead of discarding it. Recording startup and WAV finalization have eight-second watchdogs, and ElevenLabs requests time out after 45 seconds. The core multipart request and local history/session stores have XCTest coverage.

The iPhone app and keyboard remain experimental. Their physical-device microphone, background recording, switchback, insertion, cancellation, retry, Full Access denial, and manual fallback flows have not all been verified end to end.

## License

SpeakPaste is available under the [MIT License](LICENSE).
