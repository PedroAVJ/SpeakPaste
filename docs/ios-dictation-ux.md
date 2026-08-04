# iPhone dictation UX

SpeakPaste follows the Wispr Flow keyboard pattern on iPhone: start from the
keyboard, let the containing app briefly own the microphone, return to the same
host app while capture continues, then stop and insert from the keyboard.

The detailed device evidence, failure reproductions, runtime contract, and
acceptance matrix are in
[`ios-keyboard-roundtrip-spec.md`](ios-keyboard-roundtrip-spec.md). That file is
the source of truth for the return implementation.

## Target interaction

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
- `SpeakPaste/HostAppSwitcher.swift` — fixed supported-app catalog, URL return,
  and manual fallback.
- `SpeakPaste/SharedDictation.swift` — App Group state and mirrored diagnostics.

The return target validator accepts a cataloged arbiter host identifier, but
rejects SpeakPaste itself and system brokers such as SpringBoard, Spotlight,
and SafariViewService.

## Optional global trigger

The iPhone target also exposes a `Toggle Dictation` App Intent backed by
`AudioRecordingIntent`, `LiveActivityIntent`, and a Live Activity. A Shortcut or
Back Tap can use it to start capture without foregrounding SpeakPaste and queue
the result for keyboard insertion. It remains an optional automation surface;
the default product interaction starts and stops in the keyboard.

## Verification boundary

Focused builds and tests can verify state transitions, exact-once insertion
bookkeeping, hook linkage, catalog mappings, and bundle filtering. They cannot
prove a visible iOS scene transition.

Before the keyboard round trip is called end-to-end verified, exercise directly
on the physical iPhone:

- Notes first use: Start, explanation, automatic return, Stop & Insert, exactly
  one insertion. **Verified on iPhone 15/iOS 26.5.2.**
- Notes second use without the explanation. **Verified on the same device.**
- One third-party host such as ChatGPT or WhatsApp.
- Full Access disabled.
- Microphone permission denied, then restored.
- Cancel while recording.
- Transcription failure and Retry.
- Unknown or unavailable return route, preserving the manual-swipe fallback.

Keep the resulting shared session intact until its host-resolution, launch, and
return diagnostics have been copied. The decisive fields are the resolved host
bundle, arbiter-hook status/captured value, catalog route and Boolean result,
manual fallback, and final shared phase.

The two verified Notes sessions reported `arbiter-hook-status:installed`,
`arbiter-hook-cached:com.apple.mobilenotes`, `host-url-can-open:true`, and
`host-url:true`. Their keyboard-side mirrors ended at `phase: inserted`.
