# SpeakPaste

SpeakPaste is an open-source native Swift dictation project. It contains a macOS reliability demo plus an earlier iPhone app and custom-keyboard demo.

## Targets

- `SpeakPasteMac`: macOS SwiftUI app; current development focus.
- `SpeakPaste`: iPhone containing app.
- `SpeakPasteKeyboard`: iPhone custom keyboard extension.
- `SpeakPasteTests`: shared and iPhone-focused tests.

## Working rules

- Never commit or print the ElevenLabs API key. Runtime code reads it from the per-app Keychain or `ELEVENLABS_API_KEY`.
- Fully release the Continuity-microphone session after every dictation, before transcription. Returning control of the iPhone takes priority over warm-start latency.
- Keep generated builds, DerivedData, user Xcode state, and packaged ZIPs out of Git.
- Prefer focused Swift type-checks and target builds. Do not modify signing teams or publish through the App Store unless explicitly requested.
- Never synthesize or inject keyboard input to test SpeakPaste, including with
  `CGEvent`, AppleScript/System Events, Computer Use, or virtual-key tools.
  Modifier-only shortcut acceptance is Pedro-only physical testing; do not
  interfere with the user's active apps or typing.

### Reference-backed behavior

- Before reinventing complex or stateful product behavior, inspect its current
  observable behavior and any legally reusable licensed implementations and
  tests. Record the state transitions, invariants, cancellation and failure
  paths, compatibility assumptions, and any gaps that remain hypotheses.
- Adapt the proven pattern to SpeakPaste's architecture. Never transplant
  private or unlicensed code; reuse licensed code only after checking that its
  license, dependencies, lifecycle, privacy, and failure semantics fit, and
  otherwise implement an independent adaptation.
- Verify the complete sequence on every intended target surface. Builds,
  isolated callbacks, and copied tests alone are not acceptance.

### Protected iPhone switchback

- Do not replace, reorder, or refactor the iPhone switchback architecture. It is
  compatibility code recovered from Wispr Flow 1.67/build 1313 and adapted from
  the MIT-licensed `KeyboardHostBundleID` technique.
- Its required sequence is: early `+load` keyboard-arbiter capture, exact host
  match against the fixed scraped app/scheme catalog, then
  `UIApplication.open` on that cataloged URL. Manual home-bar swipe is the only
  fallback.
- Do not substitute direct bundle activation, `UISystemNavigationAction`,
  generic suspension, or a guessed previous-app API. Those routes have failed,
  produced false positives, or lacked physical-device proof.
- Any future switchback change requires a fresh reference-app inspection and a
  full physical-device pass of `docs/ios-keyboard-roundtrip-spec.md`; builds,
  simulators, unit tests, and Boolean return values are not acceptance.

## macOS build

To check that the project compiles:

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

This proves compilation only. It builds the repo's generic
`com.example.SpeakPasteMac` under local ad-hoc signing and leaves the product in
`/tmp`, so the app in `/Applications` still runs the previous code. Never report
a change as runnable on the strength of this command.

## macOS install

To make a change usable in the installed app, run `scripts/install-macos.sh`.

macOS keys microphone and Accessibility grants to the bundle identifier and
signature together, and keeps Application Support state — including the enrolled
voice profile — per identifier. Installing under any other identity produces a
second app with no permissions and no state rather than an upgrade, so the
installer builds under the identity already in `/Applications`, reading the
untracked `scripts/local-identity.env` and refusing to run on a mismatch. It
quits SpeakPaste before replacing the bundle and relaunches it afterward.

Do not pass one-off `PRODUCT_BUNDLE_IDENTIFIER` or `DEVELOPMENT_TEAM` overrides
by hand to install; that is how a duplicate permission-less app gets created.
Extend the script instead.

See `README.md` for product behavior, installation, privacy, and current verification status.
