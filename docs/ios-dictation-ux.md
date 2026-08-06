# iPhone dictation UX

Dictation on iPhone starts with a double tap on the back of the phone and ends
at the keyboard. Back Tap runs the `Toggle Dictation` App Intent, which starts
microphone capture without leaving the current app; **Stop & Insert** in the
SpeakPaste keyboard ends the capture and lands the transcript exactly once at
the cursor. In the happy path, SpeakPaste's own screens never appear.

When the Back Tap route is unavailable, SpeakPaste falls back to the Wispr Flow
keyboard pattern: start from the keyboard, let the containing app briefly own
the microphone, return to the same host app while capture continues, then stop
and insert from the keyboard.

The detailed device evidence, failure reproductions, runtime contract, and
acceptance matrix are in
[`ios-keyboard-roundtrip-spec.md`](ios-keyboard-roundtrip-spec.md). That file is
the source of truth for the return implementation.

## Primary interaction

1. Double-tap the back of the phone, from anywhere. Capture starts where you
   are: no app switch, and no waiting for a focused field or an active
   keyboard — the thought does not wait for the UI.
2. Speak. The system microphone indicator and the Live Activity confirm the
   capture is hot for its whole duration.
3. Focus the destination field, bring up the SpeakPaste keyboard, and tap
   **Stop & Insert**. Stop lives at the point of insertion: the same tap that
   ends the capture places the text.

The trigger choice is deliberate, on everyday per-use cost alone:

- Back Tap is an eyes-free, one-handed gesture with no target to aim at, and it
  works from anywhere — mid-scroll, before the destination field exists.
  Capture is decoupled from destination: speak first, aim second.
- A keyboard start can only begin once a field is focused and the keyboard is
  up, and it pays the visible app bounce on every single dictation.
- The intent route is public API end to end (`AudioRecordingIntent`, Live
  Activity, background capture); the bounce rests on recovered private
  behavior that an iOS update can break. The durable route carries the daily
  load.

Back Tap requires one-time configuration in Settings > Accessibility > Touch.
That setup cost is accepted: SpeakPaste is a power tool first, and the everyday
experience outranks first-run ease.

## Verbs and their surfaces

iOS collapses the macOS source dimension — one phone, one microphone — so four
keys become three verbs. Each verb goes to the cheapest surface that can carry
it, and as on macOS the trigger is fixed while the current state picks the
meaning:

| Verb | Surface |
|---|---|
| start / pause / resume | double-tap — one gesture, state picks the verb |
| end, deliver | **Stop & Insert** in the keyboard — stop lives at the point of insertion |
| dismiss into recovery | **Cancel** on the Live Activity — island hold, or the Lock Screen card |

Assignment follows one principle: a verb lives on a surface guaranteed to
exist at the moment the verb is needed. Delivery needs the keyboard because
only the keyboard can insert. Pause and cancel are needed during capture, and
during capture the only guaranteed surface is the Live Activity — the
keyboard is merely conditional, so it carries no copy of either. The Live
Activity also mirrors pause, so an interruption is handled where the eyes
already are, keyboard or no keyboard.

Pause and resume keep the macOS segment model: a dictation is an ordered list
of segments plus at most one hot capture. Pause finalizes the current segment
eagerly — microphone released, segment transcribed immediately. Resume does
not un-pause a recording; it opens a new segment in the same dictation, and
stitching happens at the transcript layer by concatenation. The double tap is
the same fixed trigger throughout: idle starts, recording pauses, paused
resumes — state picks the verb, exactly as the macOS source keys do.

The Live Activity is the iOS HUD: a persistent control strip for the whole
capture. Compact in the Dynamic Island; touch and hold to expand an authored
SwiftUI card with working Pause and Cancel buttons (App Intent-backed,
executed in place, no app launch); the same card sits on the Lock Screen with
zero presses to see it. Executing a control still follows iOS's current lock
and authentication policy; visibility is not a promise that a locked phone
will run the action without authentication.

Dismissal keeps the macOS invariant: it destroys nothing. A canceled
dictation folds into recovery, so a misfired Cancel costs a trip to recovery,
never text.

Provisional, pending real use:

- Whether pause earns its keep on the phone at all — pocket dictations are
  short, and the players ship start/stop/cancel only. Toggle-as-start/stop
  may be enough.
- Triple-tap is a second free global gesture (a candidate eyes-free dismiss,
  safe precisely because dismissal destroys nothing). Unbound unless
  double-tap alone proves insufficient.
- A Control Center control, placeable in the Lock Screen bottom slots:
  capture without unlocking — speak first, unlock and aim later. Optional
  addition, not part of the core loop.

## Delivery

At-cursor insertion on iOS has exactly one door: a custom keyboard extension,
while it is the active keyboard on the focused field. Nothing else can type
into another app, and the clipboard is constitutionally manual. Inside that
door, delivery is automatic: when a transcript completes and the SpeakPaste
keyboard is up, the text lands at the cursor without a second tap.
**Stop & Insert** owns both halves of the final action: it ends capture and
claims the cursor synchronously. If transcription finishes afterward, the
words appear there automatically. Aiming is focusing — wherever the cursor
sits when the keyboard is up is where the dictation was aimed.
If the field or cursor changes before transcription finishes, SpeakPaste keeps
the transcript and exposes **Insert Here** instead of guessing at a new target.

Automatic delivery requires residency: SpeakPaste is the daily keyboard. The
bet behind residency is explicit. SpeakPaste is a transcription application,
not a keyboard — it does not compete with Apple's keyboard at typing, it
competes with typing. Residency is won at the transcription layer, accuracy
and register, never by reimplementing autocorrect or lexicon memory.

- The typing surface only clears the residual bar: what remains once
  dictation carries the prose. It is designed as a correction surface first
  and a keyboard second — the three-second fix of a mistranscribed word is
  the one typing task that cannot be escaped. Typed corrections are signal:
  they feed keyterm biasing and the register pass, so the loop shrinks
  itself.
- Apple's keyboard stays one globe-switch away for heavy typing, permanently.
  Secure fields are not our problem: iOS refuses custom keyboards there and
  substitutes the system keyboard on its own.
- The keyboard sees both input streams, so the bet is measurable: dictated
  words versus typed characters. If the dictated share is not overwhelming
  after real use, residency is not paying its rent.
- Where a field or app refuses custom keyboards entirely, the clipboard
  fallback is part of the product — same status as the manual swipe in the
  round trip, a documented fallback, not an error.

## Decisions and platform implications

The double-tap start, stop-at-the-keyboard, and exactly-once insertion at the
cursor are product decisions. How iOS realizes them — whether background
capture demands the Live Activity, whether the app must surface for a moment,
what feedback marks the start — is dictated by the platform. Those
implications are recorded here from device evidence as they are discovered,
not designed in advance.

Apple's supported background entry point is the paired
`AudioRecordingIntent` / `LiveActivityIntent` route: the intent may launch the
app process without presenting its UI, and the Live Activity must span the
recording. That is the implementation contract, not a guarantee about every
process condition. A user force-quit normally suppresses later background
launches until the app is opened again, while ordinary cold-launch, eviction,
lock-state, and resume behavior remain physical-device acceptance cases.
Superwhisper's signed iOS package is an existence proof for the architecture;
its encrypted executable and Shortcut metadata do not prove those runtime
boundaries on this phone.

### Superwhisper iOS package evidence

This comparison is against the downloaded **iPhone IPA**, not Superwhisper's
macOS app:

- Package: `Superwhisper-2.19-build3.ipa`
- Version/build: 2.19 (3)
- SHA-256: `97bf9b57b6f6bf574653d0eef57286493e2e014f459b4cca61c8835555b72e08`
- Its signed Shortcut runs `ToggleRecordingIntent`. An empty result is the
  start/no-result branch; a non-empty result is copied to the clipboard, joined
  into the completion message, shown in a notification, and acknowledged with
  vibration.
- The containing-app intent is background-capable with
  `openAppWhenRun = false`, accepts an optional mode name, and declares audio
  recording/session protocols. The Live Activity extension exposes a separate
  zero-parameter **Toggle Recording** intent with no output.

That metadata validates the start/stop/clipboard architecture and the need for
an intent-backed Live Activity control. It does not validate SpeakPaste's
pause/resume segment model: Superwhisper's shipped flow is a toggle that ends
and returns text, and its FairPlay-encrypted executable prevents method-body
inspection. Cold launch, lock state, process eviction, and microphone release
still require direct tests on this iPhone.

## Fallback interaction: keyboard round trip

1. Focus a text field and select the SpeakPaste keyboard.
2. Tap **Start** in the keyboard.
3. SpeakPaste opens and starts microphone capture.
4. On first use, accept the one-time switchback explanation.
5. SpeakPaste returns to the originating app while recording continues.
6. Tap **Stop & Insert** in the keyboard.
7. The keyboard shows transcription progress, inserts the result exactly once at
   the cursor where the user taps Stop, and restores its typing layout.

If automatic return is unavailable, SpeakPaste keeps recording and tells the
user to swipe right along the bottom home bar. That fallback is part of the
product, not an error that discards the recording.

## What the app shows during a round trip

SpeakPaste is only on screen for a moment, so a keyboard session replaces the
dashboard with one hand-off surface covering three states: starting, recording,
and transcribing. It shows the state, the way back, and where the transcript
will land. The surface is up from the frame the keyboard hands off — before
permission and audio activation have finished — through the end of capture. A
failure hands the screen back to the dashboard, which owns retry, the API key,
and the recovered recording.

The launch screen is painted in the app's own background color. The default
empty `UILaunchScreen` renders `systemBackground`, which flashed white on every
cold-launch bounce.

## What Wispr documents

Wispr's iPhone guide documents the same visible app bounce and a manual-swipe
fallback on affected iOS versions. Its release notes say automatic switchback
works in more supported apps over time. The reference recording in the
round-trip specification shows Wispr Flow 1.67 moving from Notes to Flow and
back, then inserting through the keyboard.

Wispr does not publish source code or identify a public Apple API that performs
the generic return. Inspection of Wispr Flow 1.67/build 1313 adds stronger
evidence than the recording alone: its signed property list contains a fixed
50-scheme allowlist, and its exported Swift symbols name host-bundle lookup,
per-app launch URLs, a switchback scene, and an unsupported-app presentation.
Its executable bodies remain FairPlay-encrypted.

- [Wispr Flow iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- [Wispr Flow release notes](https://wisprflow.ai/whats-new)
- [Apple DTS: no public generic host-identification or round-trip API](https://developer.apple.com/forums/thread/826851)

## Platform constraints

### The keyboard cannot record

Custom keyboard extensions do not receive microphone access, including with
Full Access. The containing app owns `AVAudioSession` and the audio file. The App
Group carries session state, commands, diagnostics, and the completed transcript
between the app and keyboard.

### There is no public generic switchback API

Apple does not expose a public way for a keyboard extension or its containing
app to identify the arbitrary host app and return to its exact scene. The
keyboard-launch and automatic-return routes in SpeakPaste are guarded private
implementation details for a personal sideload. They are not App Store-safe and
can change with iOS.

`NSExtensionContext.open` is a public method, but keyboards are not a documented
extension point for opening arbitrary URLs. SpeakPaste attempts it only after the
typed responder-chain route and records the Boolean result instead of assuming
that the method was honored.

### A route reporting success is not enough

Earlier device runs showed three distinct false positives:

- an Objective-C selector existed but Notes never left the foreground;
- generic suspension returned to the Home Screen; and
- `UISystemNavigationAction` accepted destination `0`, but that destination was
  Home rather than the originating application.

Those results rule out the old generic system-navigation route. The current
implementation opens only the cataloged URL for an exact captured, supported
host. Otherwise it keeps recording and presents the manual-swipe instruction.

## Implementation

```text
Keyboard Start
  -> capture host bundle from the keyboard arbiter
  -> create one App Group session
  -> open speakpaste://dictate/start
  -> containing app starts verified microphone capture
  -> one-time explanation
  -> open the supported host's cataloged URL scheme
  -> keyboard polls shared recording state
  -> Stop & Insert command
  -> containing app transcribes with ElevenLabs Scribe
  -> keyboard inserts once through textDocumentProxy
```

The implementation is split across:

- `SpeakPasteKeyboard/KeyboardView.swift` — Start, listening, stop, processing,
  error, and Full Access states.
- `SpeakPasteKeyboard/KeyboardModel.swift` — one-shot session creation, polling,
  commands, stale-session recovery, and exactly-once insertion.
- `SpeakPasteKeyboard/KeyboardViewController.swift` — typed responder-chain URL
  launch, public-method fallback, and private bundle fallback.
- `SpeakPasteKeyboard/HostApplicationCapture.m` — iOS 26.4+ early keyboard-
  arbiter hook that captures the callback's host bundle identifier.
- `SpeakPasteKeyboard/HostApplicationResolver.swift` — consumes the captured
  host and retains older resolution paths as diagnostic fallbacks.
- `SpeakPaste/AppModel.swift` — microphone capture, one-time explanation,
  background command monitor, and transcription.
- `SpeakPaste/ContentView.swift` — `KeyboardSessionView`, the single-purpose
  hand-off surface shown for the whole round trip, plus the dashboard used for
  manual recording, transcripts, and failures.
- `SpeakPaste/HostAppSwitcher.swift` — fixed supported-app catalog, URL return,
  and manual fallback.
- `SpeakPaste/SharedDictation.swift` — App Group state and mirrored diagnostics.

The return target validator accepts a cataloged arbiter host identifier, but
rejects SpeakPaste itself and system brokers such as SpringBoard, Spotlight,
and SafariViewService.

## Primary trigger machinery

The `Toggle Dictation` App Intent is backed by `AudioRecordingIntent`,
`LiveActivityIntent`, and a Live Activity. Back Tap — or any Shortcut — uses it
to start capture without foregrounding SpeakPaste and queue the result for
keyboard insertion.

## Verification boundary

Focused builds and tests can verify state transitions, exact-once insertion
bookkeeping, hook linkage, catalog mappings, and bundle filtering. They cannot
prove a visible iOS scene transition.

The August 6 physical screen recording proves that iOS recognized Double Back
Tap and ran the repaired one-action Shortcut. It does not prove microphone
startup: a preceding Mac-tunnel invocation had left a failed parent marked as
recoverable, so the intent rejected the physical tap before capture. The exact
device journal contained zero finalized segments and one active bundle whose
only file was `active-manifest.json`; there was no `audio.m4a`. The current
source now retires only that provably empty shape and refuses cleanup when the
capture contains any audio bytes. That repair still needs a fresh physical run.

Before the primary interaction is called end-to-end verified, exercise directly
on the physical iPhone:

- Back Tap start inside a third-party host: double tap, capture begins with no
  app switch, Stop & Insert from the keyboard, exactly one insertion.
- Back Tap recognition over a week of real use: missed starts and phantom
  triggers, with the phone in its case. A trigger that cannot be trusted loses
  to a slow one that can; persistent flakiness flips the primary back to the
  keyboard start.
- Pause from the island, then resume by double tap: whether the microphone
  re-arms from the background after the paused segment released the session,
  or whether resume needs a warm session or a momentary app surface. The verb
  survives either answer; only its cost is at stake.
- Whatever the platform forces onto the flow — Live Activity requirement,
  momentary app surfacing, start feedback — recorded under
  "Decisions and platform implications".

Before the keyboard round trip is called end-to-end verified, exercise directly
on the physical iPhone:

- Notes first use: Start, explanation, automatic return, Stop & Insert, exactly
  one insertion. **Verified on iPhone 15/iOS 26.5.2.**
- Notes second use without the explanation. **Verified on the same device.**
- One third-party host such as ChatGPT or WhatsApp.
- Full Access disabled.
- Microphone permission denied, then restored.
- Cancel while recording.
- Swipe back into SpeakPaste mid-dictation: the hand-off surface, not the
  dashboard, and it names the host app it came from.
- Transcription failure and Retry.
- Unknown or unavailable return route, preserving the manual-swipe fallback.

Keep the resulting shared session intact until its host-resolution, launch, and
return diagnostics have been copied. The decisive fields are the resolved host
bundle, arbiter-hook status/captured value, catalog route and Boolean result,
manual fallback, and final shared phase.

The two verified Notes sessions reported `arbiter-hook-status:installed`,
`arbiter-hook-cached:com.apple.mobilenotes`, `host-url-can-open:true`, and
`host-url:true`. Their keyboard-side mirrors ended at `phase: inserted`.
