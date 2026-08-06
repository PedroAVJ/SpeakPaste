# macOS dictation HUD

Behavior and design specification for the floating dictation indicator.
Companion to `macos-dictation-controls.md`; the HUD renders that machine.

## Surface

- **Liquid Glass.** The HUD is a single Liquid Glass capsule — real
  material, with its depth and adaptation, not a flat translucent
  rectangle. One dictation, one capsule, always. It floats above everything, adapts to light and dark, and
  never changes app presence.
- **Click-through at rest.** The HUD never steals a click from the app
  beneath it.
- **Draggable.** The HUD can be moved anywhere on screen and its position
  persists. Dragging requires a deliberate grab (it must never compromise
  click-through at rest). A sensible default position exists for users
  who never move it.

## States

States are distinguished by motion. The grammar: **pop = delivered,
fold = dismissed to recovery, still = waiting on you, breath = waiting
on the world, dots = being typed.**

- **Hot** — the live capture: source glyph at the bloom, then the red
  waveform. The capsule, identity layer, and waveform layer persist;
  capture-live expands the whole capsule at center while the glyph fades
  and scales down and the already-mounted bars stand up. Nothing slides to
  make room and no layer is structurally replaced. Banked segments are
  invisible plumbing; the capsule is the dictation.
- **Resting** (= paused) — pause adds nothing; pause is the capsule
  refusing to leave. Its waveform goes still, dim, and gray — bars
  frozen in place, not settled. **The resting capsule is the whole
  dictation**: banked segments are plumbing and get no faces, no
  slivers, and no counts.
  Sourceless: no source glyph — there is no current source; the next
  source key decides. Never times out.
- **Draining** — End was pressed. The capsule shrinks to the typing
  pill — dots jumping — if delivery cannot land at once (see *Closing
  on deliver*). Every paused/resumed segment waits behind that one face;
  no completed prefix may reach the cursor ahead of a slower suffix. The
  segments are seam-fitted, appended, and delivered in one external
  transaction, then the whole message lands as one pop and the dictation
  seals into Away. Until that delivery side effect begins, a
  source key **reopens** it (back to Hot) and Esc dismisses it to
  recovery — Draining is a Resting that leaves on its own.
- **Away** — clean screen, nothing owed.

Invariants:

- **Presence means owed text.** The HUD may not disappear while a
  dictation is open (Hot or Resting). Timeouts apply to transcription
  work only, never to a resting dictation.
- Esc's exit (the fold, a squash to nothing) is visibly distinct from
  End's (the pop, a bloom) — distinct shapes, both in place. Nothing
  travels.
- A state gets a face only if the user can act differently during it.

## Closing on dismiss — the fold is the face

Esc closes the dictation in one gesture: the bars freeze (mic
truthfully off) and the capsule folds inward to recovery, instantly.
No window, no countdown, no pending state — everything banked is
already a recovery entry, so nothing on screen needs guarding, and Esc
destroys nothing. There is no face to design because there is no state
to show: a source key afterwards starts a fresh dictation, and getting
the dismissed text back is a recovery action, not a keyboard one.

## Closing on deliver — the typing dots

**The face is a loading state, not progress.** Decided: Scribe reports
no progress and no ETA for any segment request, and a multi-segment
dictation still crosses the output boundary only as one whole message,
so the machine has no divisible quantity to draw; and a
progress face invites supervising, when the product wants the user
comfortable looking away. Kept principles: never a meter; the face
draws only real signals; the animation alone never claims completion —
the pop rides delivery-verified, and delivery never waits for
animation.

**The typing indicator**, as shipped. At fn the
capsule shrinks straight from the live red wave into the small typing
pill — three jumping dots, no gray intermediate: a frozen beat would
wear Paused's body, so the voice hands off to the dots directly. The
dots are the messaging idiom for a message being composed for you,
the one loading state the world is already trained on, and the
training is exactly right: the message arrives whole, as one bubble,
with a sound; there is no progress and no ETA; staring at the dots
does not help. The idiom is output-side — your text being written —
where the wave treatments were input-side, the machine consuming
audio. On delivery-verified the pill pops in place — a bubble
bursting at center, no travel; a bubble pops where it stands — and
the arrival sound calls back a user who looked away. Dots exist
only while delivery is owed; a near-instant delivery shows a blink of
them at most, and delivery never waits for the animation. A long wait
gets the same dots, never an escalation. Reopen stands the capsule
back up into the live wave; Esc folds the pill to recovery.

The face's sound, settled with it. **No cue fires at the fn press**: the
patter starts a moment later and is itself the acknowledgment, so a
release chime there announced one act twice. (Pause and Escape keep
their low held/fold cues — there the release is the whole event, and
on iPhone it is the receipt that the phone is free again.) While the dots
are up, the **typing patter** loops: the family's own struck tone
played as keystrokes — short, dry, low, in irregular bursts across the
low E-major degrees, well under every other cue so it can sit behind
whatever the user went back to doing. It is the one continuous sound
in the product, and it is what makes leaving the HUD safe. The arrival
is the **delivery plop**, a struck tone falling E5→E4: a message
landing, not a rising ping claiming a milestone. Both are synthesized
by `scripts/generate-macos-earcons.py` — deterministic, no samples —
and the patter loop is verified to begin and end in silence so the
wrap cannot click.

Considered and rejected: word-shaped dashes confirming word by word
(invents per-word progress, pace, and widths no signal provides; the
words are born at the cursor, not in the capsule), wave greening span
by span as segment transcripts land (honest edges, but progress
machinery over an almost-always-binary signal, and it rewards
watching), estimate-driven progress from audio length (an estimate is
a promise, and it breaks on camera — early snap or the 90% stall),
frozen wave with the amber wait-dot beside it (the capsule's body
reads as Paused — departure dressed as parking; a seven-pixel
accessory cannot overrule the body), the read glint over the frozen
wave (honest and calm, but input-side — the machine reading — and the
frozen wave still wears Paused's body), caret with a progress rail
(discards the message's identity), fixed-frontier wave read (flow
without progress), bare shimmer on an empty capsule (says nothing at
all).

## Starts

Both starts share one **center-out** choreography: the capsule blooms
small wearing only the source glyph, dead center. The glyph then
dissolves — fast — as the waveform rises through the same center and the
capsule widens around it. Identity first, then voice, always at the same
address: no frame in the lifecycle has anything off-axis, and nothing
ever slides sideways. (Inline glyph-beside-bars is rejected: it splits
the voice's center from the capsule's center, and the glyph's exit makes
the bars change address.)

- **Mac (right ⌘): no connecting face.** Capture is effectively
  immediate, so the glyph beat is a courtesy with a short maximum
  (~0.5 s) — and first detected voice energy cuts the dissolve
  immediately. The beat is a maximum, not a duration; the mic is already
  live during it, and the ping has already said go.
- **iPhone (right ⌥): glyph plus wait-dot.** The glyph stays neutral —
  it carries identity and never recolors. Beside it a small dot breathes
  amber while Continuity wakes: the dot is the status LED, and **the dot
  is the wait** — the Mac start has no dot because it has no wait. Not a
  spinner; nothing is being measured. On capture-live the pair dissolves
  together and the bars rise at true center (transient elements may sit
  side by side; only persistent elements demand the center). The
  dissolve is gated on capture-live, never on voice: bars may not appear
  before audio can flow. It is the "speak now" moment, paired with the
  capture-live cue.

## Color

Fixed meanings, HUD-wide: **amber = not yet** (the wait-dot), **red =
hot mic** (live waveform), **gray = cold** (resting). Red never appears
unless the microphone is capturing. Glyphs never recolor: identity and
status are separate channels.

## Sound

Earcons fire on real edges of the machine, never on cosmetic animation.
The one carve-out is the typing patter, which is not an edge but a
state: it is continuous because the state it reports is, and because it
is the thing that lets the user look away.

Three families with fixed meanings. **Pings rise and mean forward
progress**: capture-live at capture-live. **The wait family is low,
soft, and level**: the tick (tap acknowledged, go-signal pending), the
hold tone (paused — held, owed), and the muted fold tone (dismissed to
recovery). They fire only after the microphone is actually free. Pause never
plays a rising ping; suspension is not progress. **The closing
family is the message being written and landing**: the typing patter
while the dots are up, then the delivery plop on the pop. Closing
carries no rising ping at either end — see *Closing on deliver*.

- **The capture ping fires at capture-live. The tick is the wait**, like
  the dot: it exists only when the go-signal cannot come immediately. The
  iPhone tap gets a tick, then the wait, then the ping on the dissolve.
  The Mac has no wait, so no tick — one ping, effectively at the
  keypress.
- End needs no tick and no chime: the patter starts as the dots appear,
  and the plop lands on the pop.
- `wait-tick`, `dictation-held`, and `dismiss-fold` are low, restrained
  members of the same synthesized family. The fold carries Escape visually;
  its muted low tone only confirms that the dismissal reached recovery.
- The Mac dissolve is silent — it is visual settling, not a state
  change, and first-voice can cut it short while the user is already
  speaking.

## Prototypes

Self-contained pages in `hud-prototypes/` (real earcons embedded);
open in a browser. Where prose and prototype disagree, the prototype
is the approved behavior — except where a page is marked candidate or
placeholder below.

- `hud-starts.html` — both starts, sounds and timing. Settled.
- `hud-pause.html` — pause and resume on either source. Settled.
- `hud-transcribe.html` — the typing-dots deliver face, with the
  patter and the plop. Settled and shipped.
- `hud-closing.html` — the instant dismiss. Settled.
- `hud-dictation.html` — the whole machine in one capsule, every key
  in every state, speaking the shipped closing face.

The Mac implementation follows: `MacStatusHUD.swift` draws the dots and
both exits, `MacSoundEffects.swift` owns the patter and plop, and
`scripts/generate-macos-earcons.py` synthesizes and verifies every cue.
