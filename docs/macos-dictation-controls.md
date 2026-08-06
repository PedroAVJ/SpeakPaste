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
| fn | End: close the dictation, deliver everything banked |
| Esc | Dismiss: close the dictation away from the cursor, into recovery |

- A source key can never deliver text and never destroy it. `fn` always
  delivers. `Esc` always dismisses — and dismissal destroys nothing:
  the dictation becomes a recovery entry. No key changes consequence
  class with state.
- Bare taps, acting immediately — no double-taps, no chords, no timing
  windows. Modifier double-press belongs to the OS.
- There is no stored Mac/iPhone mode. The key pressed is the microphone
  used, decided fresh at each start.
- Left ⌘ and left ⌥ keep their system behavior.

## State machine

A dictation is an ordered list of segments plus at most one hot or
pending capture. **There is only ever one dictation.** States: **Idle**,
**Connecting(source)**, **Recording(source)**, **Paused**, and
**Draining** — ended, delivery not yet landed.

| | right ⌘ | right ⌥ | fn | Esc |
|---|---|---|---|---|
| Idle | start Mac | start iPhone | inert | inert |
| Connecting Mac | inert | inert + HUD nudge | deliver banked, abort¹ | abort → safe floor |
| Connecting iPhone | inert + HUD nudge | inert | deliver banked, abort¹ | abort → safe floor |
| Recording Mac | **pause** | inert + HUD nudge | end | dismiss² |
| Recording iPhone | inert + HUD nudge | **pause** | end | dismiss² |
| Paused | resume Mac | resume iPhone | end | dismiss² |
| Draining | **reopen** on Mac | **reopen** on iPhone | inert | dismiss² |

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
dismisses it (delivery called off; everything to recovery). After the
seal it is immutable and leaves the HUD.
There is no queue of concurrent dictations: starting during Draining is
a reopen, not a second message. Pause finalizes eagerly — the
microphone is released first, then the segment transcribes immediately —
so End after a pause is typically near-instant, and the reopen window
correspondingly short.

Esc never delivers. It dismisses instantly, and a dismissed dictation
is a recovery entry, not a loss — slower to get back than text at the
cursor, and that is the whole cost. The fn path takes no artificial
delay — delivery is only ever as slow as transcription itself.

## Menu bar keyboard sheet

Clicking the menu bar icon opens a small anchored panel that is a live
keyboard map, replacing menu items.

- A rendered keyboard, all keys blank except the four bound ones,
  glyphed: laptop (right ⌘), phone (right ⌥), deliver (fn), dismiss
  (Esc).
- Live: keys re-glyph from the current state per the matrix — while
  Recording on Mac, right ⌘ shows pause and right ⌥ is dark. The panel
  is a mirror, not a control surface.
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
