# macOS dictation controls

The four-key control model, as shipped. `MacDictationKeys.swift` owns the
keys, the phases, and the bare-tap recognizer; `MacAppModel.handleDictationKey`
is the single implementation of the matrix below; `MacKeyboardMapModel.swift`
projects the same matrix onto the menu-bar map, so the picture on screen
cannot drift from what the keys do.

## Keys

| Key | Verb |
|---|---|
| right ⌘ | Mac mic: start / pause / resume |
| right ⌥ | iPhone mic: start / pause / resume |
| fn | End / hold / release: close the dictation toward delivery, park it while Draining, or release it from Held |
| Esc | Dismiss: close the dictation away from the cursor, into recovery |

- A source key can never deliver text and never destroy it. `fn` only ever
  moves text toward delivery: the first press ends the dictation, a press
  while Draining parks *when* it may land, and a press from Held releases it
  toward the then-current cursor. `Esc` always dismisses — and dismissal
  destroys nothing: the dictation becomes a recovery entry. No key changes
  consequence class with state.
- Bare taps, acting immediately — no double-taps, no chords, no timing
  windows. Modifier double-press belongs to the OS.
- There is no stored Mac/iPhone mode. The key pressed is the microphone
  used, decided fresh at each start.
- Left ⌘ and left ⌥ keep their system behavior.

## State machine

A dictation is an ordered list of segments plus at most one hot or
pending capture. **There is only ever one dictation.** States: **Idle**,
**Connecting(source)**, **Recording(source)**, **Paused**, and
**Draining** — ended, delivery not yet landed — and **Held** — ended,
transcription still running or complete, but landing parked by the user.

| | right ⌘ | right ⌥ | fn | Esc |
|---|---|---|---|---|
| Idle | start Mac | start iPhone | inert | inert |
| Connecting Mac | inert | inert + HUD nudge | deliver banked, abort¹ | abort → safe floor |
| Connecting iPhone | inert + HUD nudge | inert | deliver banked, abort¹ | abort → safe floor |
| Recording Mac | **pause** | inert + HUD nudge | end | dismiss² |
| Recording iPhone | inert + HUD nudge | **pause** | end | dismiss² |
| Paused | resume Mac | resume iPhone | end | dismiss² |
| Draining | **reopen** on Mac | **reopen** on iPhone | **hold** | dismiss² |
| Held | **reopen** on Mac | **reopen** on iPhone | **deliver now** | dismiss² |

¹ Inert when nothing is banked.
² Dismissal is instant and destroys nothing: the whole dictation — hot
capture included — folds into recovery, off screen and away from the
cursor. Getting the text back is a recovery action, not a keyboard one,
and deleting it for real is a deliberate act there, under the retention
setting. No confirmation prompt and no grace window — recovery replaces
both.

- **While any capture exists — connecting or recording — the other
  source key does nothing** beyond a HUD nudge. Switching sources =
  pause, then resume on the other key. A wrong-key start is corrected
  with Esc, then the right key.
- **Safe floor:** any failed or aborted transition (Esc during connect,
  iPhone unreachable) lands in Paused if audio is banked, Idle otherwise.
  Never a silent fallback to the other microphone, and never a dismissed
  dictation by accident: Esc during connect closes only the pending
  capture.

## Delivery

While a dictation is open, nothing reaches the cursor. **Delivery is
atomic**: End closes the dictation, and when every segment's transcript
is in, the whole message lands at the cursor as one delivery. The first
landed character **seals** the dictation — until then a source key
**reopens** it (back to recording; delivery called off) and Esc
dismisses it (delivery called off; everything to recovery). While Draining,
another `fn` parks the landing in **Held**. Held is indefinite: it has no
expiry, grace period, or timing window. Transcription continues normally in
the background, but the ordered drain may not enter the delivery escrow or
resolve a destination until `fn` releases the hold. Release resolves the
currently focused destination fresh and delivers exactly once there when the
complete transcript is ready. After the seal the dictation is immutable and
leaves the HUD.
There is no queue of concurrent dictations: starting during Draining is
a reopen, not a second message, and the same is true from Held. Pause finalizes eagerly — the
microphone is released first, then the segment transcribes immediately —
so End after a pause is typically near-instant, and the reopen window
correspondingly short unless the user deliberately extends it with Held.

Esc never delivers. It dismisses instantly, and a dismissed dictation
is a recovery entry, not a loss — slower to get back than text at the
cursor, and that is the whole cost. The unheld fn path takes no artificial
delay — delivery is only ever as slow as transcription itself. Held adds only
the delay the user explicitly owns and ends with the next `fn`.

## Competing-media integration contract

“While transcribing” means **Recording(source)** — the interval in which the
user can still be speaking and competing sound can make them raise their voice.
It does not mean Scribe's later network request: by then the microphone is free
and reducing media no longer protects the spoken capture.

A conforming recorder integration enables the public macOS 14+
`voiceProcessingOtherAudioDuckingConfiguration` with advanced (speech-aware)
ducking at the medium level only in Recording. Every transition out of
Recording must disable it before or as capture releases: pause, End, Esc,
stream/device failure, sleep, and normal Quit. Connecting does not duck because
the go-signal has not arrived; Paused and Draining never duck. Reopen/resume may
enable it again only after the new segment is actually recording.

The same contract applies to the built-in Mac and Continuity/iPhone sources. An
integration must surface setup failure rather than silently recording one
source without ducking. It must avoid transport control, per-app automation,
and permanent volume changes; macOS owns attenuation and restoration as part of
the Voice Processing session. Physical acceptance still needs media playing
through the real output route while exercising both sources through start,
pause/resume, End, Esc, disconnect, sleep/wake, and Quit, including a check that
a user-initiated media/volume change is never overwritten.

## Menu bar keyboard sheet

Clicking the menu bar icon opens a small anchored panel that is a live
keyboard map, replacing menu items.

- A rendered keyboard, all keys blank except the four bound ones,
  glyphed: laptop (right ⌘), phone (right ⌥), deliver (fn), dismiss
  (Esc).
- Live: keys re-glyph from the current state per the matrix — while
  Recording on Mac, right ⌘ shows pause and right ⌥ is dark; while Draining,
  `fn` shows hold; while Held, it shows delivery. The panel is a mirror, not a
  control surface.
- The keyboard drawn is the user's physical layout (ANSI/ISO/JIS).
- Opening the panel never grants Dock or Command-Tab presence.
- Footer only: Settings, Quit, readiness/offline notices.

## fn requires the 🌐 setting

A modifier's `flagsChanged` cannot be suppressed without breaking that
key for everything else, so a bare `fn` tap also triggers whatever
System Settings has under "Press 🌐 to" — physically confirmed: at the
macOS default it opens the emoji picker alongside End. fn therefore
requires "Press 🌐 to: Do Nothing" (`AppleFnUsageType = 0`). Onboarding
must detect the setting and offer a one-click fix; without it, End still
fires but the OS action fires too.

If that proves intolerable, the End verb moves to right ⇧: one constant
in `MacDictationKey` and one bit in `MacModifierSide`. Nothing else
about the model changes.
