# iPhone dictation: target UX and the constraints that shape it

This is the context pack for SpeakPaste's iPhone dictation. It records what the
product should feel like, what iOS actually permits, and which of those limits
were proven on the device rather than assumed. Everything here was established
on Pedro's iPhone 15 running iOS 26.5.2 between 2026-08-02 and 2026-08-03.

Read this before changing the dictation path. Several obvious-looking designs
are already ruled out by evidence below, and two of them cost a night each.

## The target

One gesture, no context switch:

1. Double-tap the back of the phone. Recording starts immediately.
2. A Live Activity shows that dictation is live, so the state is visible
   without opening anything.
3. Talk. The app you were already in keeps the screen the whole time.
4. Double-tap again. Recording stops, transcription runs, and the text lands
   at the cursor you were already sitting in.

The gesture is Back Tap because Pedro's iPhone 15 has no Action Button. The
reference for "this is achievable" is superwhisper: on his phone it dictates
without switching apps while backgrounded. Apple's recording-intent contract
confirms that this is a supported system experience when its Live Activity is
kept alive for the whole capture.

### What "friction" means here

Dictation is four jobs: **invoke → capture → transcribe → deliver at the
cursor**. Transcription is solved; ElevenLabs Scribe is not the bottleneck and
never was. The entire cost of the feature lives in invocation and delivery.

## Constraints, and how each was established

### 1. Keyboard extensions cannot use the microphone

An Apple restriction since iOS 8. This is the root cause of the original
architecture: because the keyboard cannot record, SpeakPaste had to foreground
itself mid-dictation, and everything brittle in that path existed only to undo
the app switch it forced.

### 2. Generic background work cannot cold-start the microphone

Proven on device. A plain background App Intent died at
`AVAudioSession.setActive(true)`. The screenshot's decimal `560557684` is
`AVAudioSessionErrorCodeCannotInterruptOthers` (`!int`): a nonmixable session
tried to activate while the app was backgrounded.

This does not rule out Apple's purpose-built recording-intent path. A
user-invoked `AudioRecordingIntent` tells the system that the background work is
recording, while `LiveActivityIntent` permits its required indicator to start
without opening the app. Generic background launches, timers, notifications,
and Bluetooth wakeups do not receive that treatment.

### 3. `AudioRecordingIntent` requires a Live Activity

Apple's contract is explicit: the intent must start a Live Activity when capture
begins and keep it active for the whole recording. If it does not, iOS stops the
recording. The activity needs a WidgetKit extension and
`NSSupportsLiveActivities`; adopting the protocol alone is incomplete.

### 4. Background activation is granted, but not instantly, and never by force

Two failure modes proven on device on 2026-08-03, both surfacing as
`AVAudioSession.setActive` errors under a correctly started Live Activity:

- **The grant races the activation.** On a cold background launch the
  recording grant tied to the intent's Live Activity propagates
  asynchronously. An immediate `setActive` failed with "Session activation
  failed"; the same tap repeated 2–3 seconds later succeeded end-to-end,
  every time. The fix is retrying activation with short delays inside one
  gesture, not asking the user to tap twice.
- **A non-mixable session cannot interrupt from the background.** With a
  screen recording running, a bare `.record` session failed with `!int`
  (OSStatus 560557684) on every attempt, retries included. Background
  sessions are never allowed to interrupt whoever holds audio, so the
  session must be mixable: `.playAndRecord` with `.duckOthers` records while
  other audio ducks instead of fighting it.

### 5. A backgrounded app cannot write the pasteboard

Proven on device 2026-08-03 by instrumentation, after theory said both yes
and no: `UIPasteboard.general.string =` from the intent-driven background
process silently no-ops — `changeCount` does not move. Every completed
background session logged `clipboardLanded: false`. The write still works
foregrounded, so it stays for in-app dictation, but background delivery has
exactly one door: the keyboard.

### 6. Back Tap lists shortcuts, not App Shortcuts

`AppShortcutsProvider` entries appear in the Shortcuts app and to Siri, but the
Back Tap picker only offers shortcuts that exist in the user's library. A
one-action wrapper shortcut is therefore required. Superwhisper has the same
requirement; the entry on Pedro's phone is a user shortcut named "Toggle
Superwhisper Dictation".

A signed wrapper shortcut can be generated without hand-building one:

```sh
shortcuts sign --mode anyone --input Toggle.shortcut --output Toggle-signed.shortcut
```

The action identifier is `<app-bundle-id>.<IntentStructName>`, e.g.
`com.pedro.SpeakPaste.ToggleDictationIntent`.

### 7. Foreground continuation is not the recording path

Throwing `needsToContinueInForegroundError()` from the Back Tap path trapped
inside AppIntents (`EXC_BREAKPOINT`, Swift assertion, no frames outside the
framework) and killed the app on the second tap. The supported path declares a
background `AudioRecordingIntent`, starts its Live Activity, and never requests
foreground continuation.

### 8. Intents must not narrate

`ProvidesDialog` results surface a banner on every trigger. A dictation trigger
should be invisible; haptics already confirm state.

### 9. A keyboard extension cannot identify its host app

On iOS 26.5 every strategy returned nil in Notes: the scene-identity probe
yields an opaque UUID, `_FBSScene` is unavailable, the legacy selector returns
null, and SpringBoardServices declines to name either the host process or the
frontmost app from inside an extension.

The host **process identifier** is available. Resolving its executable path
through `libproc` and reading the enclosing `.app` bundle's `Info.plist` is
authoritative and works where the rest do not.

### 10. `UISystemNavigationAction` destination `0` is not a destination

A launch originating in a keyboard extension has no previous *application*
scene, so SpringBoard's primary destination resolves to the Home Screen — while
still reporting that destination `0` exists and `canSendResponse` is true.
`sendResponseForDestination:` is a one-shot value that cannot be inspected or
undone, so the destination must be identified before it is consumed.

Related detail: the status bar is a fast oracle. No back-to-app breadcrumb
means no real destination, so any "successful" system-navigation return is
going to the Home Screen.

## The architecture this implies

```
Back Tap
  └─ wrapper Shortcut
       └─ ToggleDictationIntent   (AudioRecordingIntent + LiveActivityIntent)
            ├─ Live Activity      (visible for the full recording)
            └─ DictationEngine
                 ├─ capture ──> ElevenLabs Scribe
                 └─ App Group ──> keyboard inserts at cursor
                              └─> History tab as the manual fallback
                                  (pasteboard writes only work foregrounded)
```

Two rules follow from the constraints:

- **The Live Activity brackets capture.** It starts before the audio session is
  activated, stays active while recording, changes to transcribing after stop,
  and ends on completion, failure, or cancellation. The app does not loop fake
  silent audio to keep itself resident.
- **Post-stop work fits iOS's finite background window.** Back Tap makes one
  bounded 25-second Scribe request instead of inheriting macOS retries. If iOS
  expires the task first, SpeakPaste cancels the request, commits a terminal
  failure, removes the private recording, and stops the App Group heartbeat
  before suspension. It releases the exact expired assertion immediately as
  UIKit requires, while the cancelled upload and matching Live Activity close
  on a session-scoped best-effort path. A later app launch safely removes any
  exact private multipart artifact left by a hard process suspension.
- **The keyboard is an inserter, never an initiator.** It has no microphone and
  no reliable knowledge of its host, so it should never start a dictation or
  try to navigate anywhere.

### Delivery: the keyboard, on the system's clock

Only the currently active keyboard extension can type into another app's text
field — no background process, intent, shortcut, or accessibility API can, and
nothing can synthesize a paste into another app either.

Clipboard-paste was field-tested as the delivery mode on 2026-08-03 and died
twice over, independently:

- **Mechanically:** background pasteboard writes silently no-op (constraint
  5). The transcript never reached the clipboard at all.
- **As UX, even if the write had worked:** paste is *user-timed* delivery.
  The user absorbs the 2–3 s Scribe round trip on every dictation — hold
  attention, wait for the completion haptic, only then dare to paste.
  Keyboard insertion is *system-timed*: the wait disappears into the UI, and
  only system-timed delivery can ever become progressive (streaming text into
  the field mid-dictation).

**The UX this settles on (the superwhisper pattern):**

1. Double-tap the back of the phone. Recording starts, wherever you are.
2. Talk. Your app keeps the screen the whole time.
3. Double-tap again, and globe-flip to the SpeakPaste keyboard right away —
   no waiting for transcription. The queued transcript inserts itself at the
   cursor the moment Scribe returns.
4. The flip amortizes: SpeakPaste is now the last-used keyboard, so
   consecutive dictations insert with zero flips.

Why Back Tap and not a button in the keyboard (Wispr Flow's shipping flow,
documented from the 2026-08-02 19:04 recording: globe-flip, tap its dictate
button, a per-new-app confirmation bounce through their app, then stranded in
their keyboard): a keyboard button is gated behind UI state you must assemble
first — text field focused, that keyboard active. Back Tap has no
preconditions; it is the iPhone's global hotkey, the same reason the macOS
flow works. Back Tap's jank is setup-time and amortizes to zero; button-flow
jank is paid on every dictation. On this codebase the button flow is also the
deprecated round trip of constraint 10, which the 2026-08-02 23:15 recording
shows dumping to the Home Screen.

Double-tap-to-stop cannot re-trigger itself: the engine ignores gestures
while a session is starting, stopping, or transcribing, and the 2–3 s
transcription window blankets any accidental double-fire. The residual risk
is Back Tap false positives (pocket, set-down) — visible via the Live
Activity; auto-cancel on sustained silence is the countermeasure if it ever
bites in practice.

**The endgame:** once the SpeakPaste keyboard is livable enough to be the
daily keyboard (exact Apple layout metrics, English + Spanish, credible
autocorrect), the flip in step 3 disappears and the flow collapses into the
MacBook experience — double-tap, talk, double-tap, text appears. Keyboard
livability is the critical path, not polish; it is the only wall left.

## Status

Built and on the device:

- `ToggleDictationIntent` / `Start` / `Stop` / `Cancel`, using the recording and
  Live Activity intent contracts
- `DictationEngine` — session ownership independent of any scene, heartbeat,
  background task across transcription
- Lock Screen and Dynamic Island Live Activity
- Signed wrapper shortcut
- Keyboard insertion at the cursor via the App Group
- Dark mode following the host appearance

Verified on device (2026-08-03, `dictation-sessions.jsonl`):

- The complete `AudioRecordingIntent` + Live Activity path cold-starts capture
  on this phone while backgrounded, through Scribe to a delivered transcript.
  Constraint 4 is why the first tap used to fail: the activation retry and the
  mixable session are the fixes. With both in place, the afternoon sessions
  activated the microphone on the first attempt, no retry consumed.
- Background pasteboard writes do not land (constraint 5): every completed
  background session logged `clipboardLanded: false`.
- An intent output of `ReturnsValue<String?>` compiles but serializes into
  `Metadata.appintents/extract.actionsdata` as an unresolvable output type
  (`typeIdentifier: 0`), and Shortcuts then fails the entire action with
  "could not be found". Non-optional outputs register fine. Check the
  actions database before installing (see below).

Unverified:

- The delivery half of the settled UX: flip to the SpeakPaste keyboard after
  the stop tap and watch the queued transcript insert itself (the session's
  phase should end as `inserted`, not `completed`). Every session so far
  ended under Apple's keyboard, so the queue insert has not run on device.
- First-tap reliability across cold launches over multiple days, and
  behavior while music is playing (it should duck, record, and come back).

Deprecated but still present:

- The keyboard-initiated round trip (`HostAppSwitcher`, host resolution, the
  system-navigation return). It exists as a fallback until the intent path is
  confirmed, then it should be deleted along with its private-API surface.

## Verifying without guessing

The App Group container cannot be listed over `devicectl`, so each process
mirrors state into its own container. Device-only failures are inspectable:

```sh
DEVICE=96439FB7-AC71-570E-A40B-2624711B3E84
for f in last-dictation-session.json dictation-sessions.jsonl; do
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier com.pedro.SpeakPaste \
    --source "Documents/$f" --destination .
done
```

- `dictation-sessions.jsonl` — bounded session history; survives the reset that
  overwrites the latest snapshot exactly when its failure diagnostics matter
- Crash reports: `--domain-type systemCrashLogs`

`devicectl` renders timestamps in **local** time.

Before installing a build that touched any intent, confirm every action
survived metadata extraction — a schema the compiler accepts can still be
one Shortcuts cannot resolve:

```sh
plutil -convert json -o - \
  <Products>/SpeakPaste.app/Metadata.appintents/extract.actionsdata \
  | python3 -c "import json,sys; print(list(json.load(sys.stdin)['actions']))"
```

Install with `./scripts/install-iphone.sh`; see the header of that script for
why a plain `xcodebuild -scheme` invocation does not work on this Mac.
