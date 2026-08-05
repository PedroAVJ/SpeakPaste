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
fold = discarded to recovery, still = waiting on you, rail = working.**

- **Hot** — the live capture: source glyph at the bloom, then the red
  waveform. Banked segments are invisible plumbing; the capsule is the
  dictation.
- **Resting** (= paused) — pause adds nothing; pause is the stack
  refusing to leave. The front card goes still, dim, and gray — bars
  frozen in place, not settled. **The resting capsule is the whole
  dictation**: banked segments are plumbing and get no faces, no
  slivers, no counts. (The `+N` overflow badge keeps its existing,
  different job: separate dictations' work folded behind the stack.)
  Sourceless: no source glyph — there is no current source; the next
  source key decides. Never times out.
- **Draining** — End was pressed. The capsule shows the message
  becoming text (see *Closing on deliver*), then the whole message
  lands as one pop and the dictation seals into Away. Until the seal, a
  source key **reopens** it (back to Hot) and Esc aborts it to
  recovery — Draining is a Resting that leaves on its own.
- **Away** — clean screen, nothing owed.

Invariants:

- **Presence means owed text.** The HUD may not disappear while a
  dictation is open (Hot or Resting). Timeouts apply to transcription
  rails only, never to a resting dictation.
- Esc's exit (fold inward) is visibly distinct from End's (pop outward).
- A state gets a face only if the user can act differently during it.

## Closing on cancel — machine settled, face OPEN

Esc freezes the bars (mic truthfully off) and opens a ~4 s cancel
window. Every key keeps its meaning throughout: a source key reopens
the dictation, fn delivers it after all, and the window lapsing folds
it away with the vanish tone. The fn path never gets an artificial
delay.

**The face of this window is an unresolved design.** The current
prototype (a pending ✕ with a small radial countdown, capsule
otherwise still) is a placeholder, not an approval — treatments tried
and rejected: capsule-scale coral ring, two-press arming, countdown
rail, slow deflate, instant-fold ghost. Revisit rested.

## Closing on deliver — the wave becomes words (CANDIDATE)

Principles for this face, settled: the capsule shows the user's
message, never an abstract process (no meters); it shows material, not
time — a long dictation is visibly more to transcribe; the capsule is a
window, not a container — the full recorded envelope is clipped and
scrolls through it; while recording the wave streams in, while
transcribing it streams back out; the animation alone never claims
completion.

Leading treatment, not yet final: on End the wave freezes, flattens,
and fuses into word-shaped dashes — a skeleton of the text it is
becoming, never readable (privacy: the HUD carries no words). Pending
words shimmer; they confirm solid green left to right as the row
scrolls through the window, so the green fraction is the progress and
the scroll is the material. The last word shimmers until the real text
lands; then the line settles, delivery-verified fires, and the capsule
pops toward the cursor. Reopen mid-read stands the words back up into
the live wave. In the realtime lane, dash widths can come from actual
partial transcripts. Considered and rejected: caret with a progress
rail (discards the message's identity), fixed-frontier wave read (flow
without progress), bare shimmer (says nothing about material or
progress).

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
The shipped family holds: three pings rising through capture, release,
and verified delivery; errors remain the family's only phrase.

Two sound families with fixed meanings. **Pings rise and mean forward
progress**: capture-live at capture-live, capture-released at End,
delivery-verified exactly on the delivery pop. **The wait family is low,
soft, and level**: the tick (tap acknowledged, go-signal pending) and
the hold tone (paused — held, owed). Pause never plays a rising ping;
suspension is not progress.

- **The capture ping fires at capture-live. The tick is the wait**, like
  the dot: it exists only when the go-signal cannot come immediately. The
  iPhone tap gets a tick, then the wait, then the ping on the dissolve.
  The Mac has no wait, so no tick — one ping, effectively at the
  keypress.
- End needs no tick: capture-released fires at the fn press (release is
  immediate) and delivery-verified lands on the pop.
- The tick and the hold tone are assets still to be authored in the
  family's voice. The Esc sound is open: a muted low tick, or silence
  with the fold carrying it alone.
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
- `hud-transcribe.html` — the wave-becomes-words deliver face.
  Candidate, under review.
- `hud-closing.html` — the cancel window. Machine settled; the face is
  a placeholder.
- `hud-dictation.html` — the whole machine in one capsule, every key
  in every state. Its deliver face predates `hud-transcribe.html`.
