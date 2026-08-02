# SpeakPaste

SpeakPaste is an open-source native Swift dictation project. It contains a macOS reliability demo plus an earlier iPhone app and custom-keyboard demo.

## Targets

- `SpeakPasteMac`: macOS SwiftUI app; current development focus.
- `SpeakPaste`: iPhone containing app.
- `SpeakPasteKeyboard`: iPhone custom keyboard extension.
- `SpeakPasteTests`: shared and iPhone-focused tests.

## Working rules

- Never commit or print the ElevenLabs API key. Runtime code reads it from the per-app Keychain or `ELEVENLABS_API_KEY`.
- Preserve the warm Continuity-microphone session between macOS dictations; startup latency, sample readiness, and recording reliability are core product behavior.
- Keep generated builds, DerivedData, user Xcode state, and packaged ZIPs out of Git.
- Prefer focused Swift type-checks and target builds. Do not modify signing teams or publish through the App Store unless explicitly requested.

## macOS build

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

See `README.md` for product behavior, installation, privacy, and current verification status.
