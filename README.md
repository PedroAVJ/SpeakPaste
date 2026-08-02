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
6. Click the record control or press **Control–Option–Space**. Press it again to stop and transcribe.

The microphone session stays warm between dictations to reduce subsequent Continuity startup time. Automatic paste requires macOS Accessibility permission; without it, the transcript remains on the clipboard.

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

The macOS target builds with local ad-hoc signing and the shared sources pass Swift 6 type-checking. The core ElevenLabs multipart request and local history/session stores have XCTest coverage.

The iPhone app and keyboard remain experimental. Their physical-device microphone, background recording, switchback, insertion, cancellation, retry, Full Access denial, and manual fallback flows have not all been verified end to end.

## License

SpeakPaste is available under the [MIT License](LICENSE).
