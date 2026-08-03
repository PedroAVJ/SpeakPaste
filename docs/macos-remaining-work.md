# macOS: what is still unbuilt

Companion to [the feature parity matrix](macos-feature-parity.md), which
inventories 446 features across superwhisper, Wispr Flow, macOS platform
expectations and the ElevenLabs Scribe API, and diffs them against this repo.
That document holds the full reasoning, the implementation notes, and the 22
features rejected on purpose. This one is only the outstanding list.

Everything below is unstarted. Nothing here is blocked by anything already
shipped.

## Blocked on the repository owner

- **Developer ID signing and notarization.** Until this lands, every rebuild
  invalidates the app's TCC grants, because macOS keys them to the code
  signature — the microphone and Accessibility permissions have to be granted
  again after each install. Notarization additionally needs an app-specific
  password for `notarytool`, which only the account holder can mint.
- **Sparkle in-app updates.** Needs a hosted appcast feed and a signing key.
  `CURRENT_PROJECT_VERSION` is also still pinned at 1, so there is no version
  to compare against.

## Capture

- Stream-health monitoring *during* recording. The liveness gate only runs
  before the first sample is written, so a stream that stalls mid-dictation
  produces a truncated file under a clean, ticking SPEAK NOW.
- `AVCaptureSession` interruption handling, distinguishing "another app took
  the microphone" from "the device disconnected". The likely case is an
  incoming call on the same iPhone serving as the Continuity microphone.
- Sleep, wake, and screen-parameter observers. A Mac that sleeps mid-dictation
  leaves the recorder live over a dead session; after wake the Continuity
  device's unique ID can change, stranding the saved selection.
- Microphone test mode: record a few seconds, play it back, report peak level,
  clipping, silence fraction and connect latency.
- Input gain awareness. A device sitting at 15% produces materially worse
  recognition with no explanation anywhere in the app.
- Maximum-duration guard, and a minimum-length guard for accidental taps.

## Delivery

- Staleness guard. A dictation that finishes long after it was spoken is
  currently delivered on the sole evidence that its app is still frontmost.
- Per-app delivery rules keyed on bundle identifier.
- Auto-send: optionally press Return once delivery is confirmed.
- Type-out mode for destinations that refuse a synthetic paste.
- `CGPreflightPostEventAccess` in the permissions dashboard. Without it the
  dashboard can read all-green while synthetic keystrokes are being discarded.

## Text quality

- Dynamic keyterms harvested from the destination's on-screen text and window
  title, on top of the static glossary. The focused element is already captured
  at record time, so its surrounding text is one attribute read away. Must
  reuse the existing secure-field refusal so password fields are never read.
- Vocabulary learned from the user's own corrections to a delivered transcript.
- Spoken punctuation and formatting commands.
- Language hint taken from the active keyboard input source.

## Product surface

- First-run onboarding with staged permission requests.
- Menu-bar agent mode (`LSUIElement`) with a hide-icon control. Note that the
  HUD controller is started from `MacContentView.onAppear`, so it will need
  another owner once there is no window at launch.
- Held transcripts surviving quit and crash. The HUD promises "nothing is
  lost"; today that promise ends at process exit.
- Scratchpad for dictating with no destination.
- Editing a transcript and delivering the corrected version.
- Diagnostics export, and a crash/unexpected-quit notice on next launch.
- App Intents for Shortcuts and Spotlight; a URL scheme; a Services provider.
- A local MCP server over the transcript history, which is how Wispr Flow
  integrates with Claude Code and Cursor.
- Automated test coverage for the macOS target. There is none.

## Unverified

No change shipped in this line of work has been exercised by a real dictation.
Builds, installs, dylib hashes and one benchmark were verified; speech was not.
The menu-action delivery path in `MacPasteController` is a rewrite of the
paste mechanism and is the first thing that should be confirmed by hand — the
attempt log names the route and whether the result was confirmed.
