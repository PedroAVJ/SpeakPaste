# macOS dictation controls

Behavior specification for the four-key control model. This replaces the
single right-⌘ toggle and the double-tap source switch.

## Keys

| Key | Verb |
|---|---|
| right ⌘ | Mac mic: start / pause / resume |
| right ⌥ | iPhone mic: start / pause / resume |
| fn | End: close the dictation, deliver everything banked |
| Esc | Cancel: discard; transcribed segments stay recoverable |

- A source key can never deliver text and never destroy it. `fn` always
  delivers. `Esc` always discards. No key changes consequence class with
  state.
- Bare taps, acting immediately — no double-taps, no chords, no timing
  windows. Modifier double-press belongs to the OS.
- There is no stored Mac/iPhone mode. The key pressed is the microphone
  used, decided fresh at each start.
- Left ⌘ and left ⌥ keep their system behavior.

## State machine

A dictation is an ordered list of segments plus at most one hot or
pending capture. States: **Idle**, **Connecting(source)**,
**Recording(source)**, **Paused**.

| | right ⌘ | right ⌥ | fn | Esc |
|---|---|---|---|---|
| Idle | start Mac | start iPhone | inert | inert |
| Connecting Mac | inert | retarget to iPhone | deliver banked, abort¹ | abort → safe floor |
| Connecting iPhone | retarget to Mac | inert | deliver banked, abort¹ | abort → safe floor |
| Recording Mac | **pause** | inert + HUD nudge | end | discard |
| Recording iPhone | inert + HUD nudge | **pause** | end | discard |
| Paused | resume Mac | resume iPhone | end | discard all |

¹ Inert when nothing is banked.

- **No mid-recording switching.** While a mic is hot the other source key
  only nudges. Switching sources = pause, then resume on the other key.
- **Connecting retarget** is wrong-key correction, not switching: no
  audio exists yet.
- **Safe floor:** any failed or aborted transition (Esc during connect,
  iPhone unreachable) lands in Paused if audio is banked, Idle otherwise.
  Never a silent fallback to the other microphone. Destroying banked work
  always takes a deliberate Esc from Paused.

## Delivery

While a dictation is open, nothing reaches the cursor. Delivery happens
only at End, segments in order. Pause finalizes eagerly — the microphone
is released first, then the segment transcribes immediately — so End
after a pause is typically instant.

Esc never delivers; already-transcribed segments become recovery
entries, not oblivion. No confirmation prompt.

## Menu bar keyboard sheet

Clicking the menu bar icon opens a small anchored panel that is a live
keyboard map, replacing menu items.

- A rendered keyboard, all keys blank except the four bound ones,
  glyphed: laptop (right ⌘), phone (right ⌥), deliver (fn), discard
  (Esc).
- Live: keys re-glyph from the current state per the matrix — while
  Recording on Mac, right ⌘ shows pause and right ⌥ is dark. The panel
  is a mirror, not a control surface.
- The keyboard drawn is the user's physical layout (ANSI/ISO/JIS).
- Opening the panel never grants Dock or Command-Tab presence.
- Footer only: Settings, Quit, readiness/offline notices.

## Fallback

If a bare `fn` tap cannot work cleanly as a global control, its verb
moves to right ⇧. Nothing else about the model changes.
