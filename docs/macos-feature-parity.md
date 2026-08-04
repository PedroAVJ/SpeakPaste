# macOS product-parity ledger

This is the product boundary for SpeakPaste on macOS after reviewing the public
documentation and changelogs for Superwhisper and Wispr Flow. It is a capability
ledger, not a claim that their private implementations were copied.

Research snapshot: 2026-08-03.

## Product thesis

- One transcription engine: ElevenLabs Scribe v2. There is no model or provider
  selector.
- Quality-first batch transcription, not live word-by-word streaming.
  Recognition quality wins over first-token latency.
- The Continuity microphone must be completely released before any network work
  begins.
- At the delivery boundary, a transcript may enter only the currently focused
  writable, non-secure editor. If none exists, the exact newest transcript
  becomes the clipboard fallback regardless of older recovery entries.
- Accessibility object continuity across a dictation is not a universal
  invariant. Electron and Chromium may rebuild, proxy, or replace their
  Accessibility tree and editable node while the user remains in an editor.
- No silent microphone fallback, silent paste fallback, or destructive recovery
  path.

Those constraints are stricter than either reference product in a few places.
They are product decisions, not missing parity.

## Adopted capability set

| Area | Reference behavior worth adopting | SpeakPaste implementation |
| --- | --- | --- |
| Global capture | Start and stop without bringing the app forward | One bare right-Command tap toggles capture globally after the user-adjusted system double-tap window; two taps switch the persistent Mac/iPhone input mode, including during capture. Ordinary Command shortcuts pass through. One Escape immediately cancels connecting or recording. Companion chords fire once per physical keypress, never on OS key-repeat. |
| Capture status | A small recording surface that reports, rather than commands | A wordless, click-through Liquid Glass depth stack gives each live dictation its own card from capture through delivery, because users chunk one message into several short dictations. The live capture capsule is always frontmost and spring-morphs through connecting, listening (a real voice waveform), and releasing; each in-flight transcription recedes behind it with its own directional heuristic progress rail capped below completion, so no rail ever inherits another request's estimate. Deeper live work folds into a numeric "+N" badge on the rearmost card, which is always the oldest. Only a verified delivery uses the rear-card slide and earcon; overflow and timeout changes simply fold or crossfade. A new hold is acknowledged by one count-free clipboard or document glyph for two seconds, then the HUD disappears; durable waiting and possibly-delivered text belongs only to the dashboard and is never replayed into the HUD on launch. The stack has no controls, is never visible at idle, and never carries success, error, setup, model, network, or recovery-queue notifications. A stuck connecting state is hidden after 20 seconds, releasing after 15, and each continuously visible transcription card after 90; the dashboard and menu bar own long-lived state. Reduce Motion replaces depth travel and shape morphs with crossfades. High-priority VoiceOver announcements describe consequential phase changes. |
| Interaction sounds | Confirm state without demanding a glance | Preloaded earcons share one timbre family: three single pings rise through capture, release, and verified delivery; error is the only phrase, low and falling. The capture cues follow the recorder's proven state, and the whole family obeys the Sounds setting. |
| First run | Guided setup and visible readiness | Onboarding covers the API key, explicit permission requests, microphone selection/test, shortcuts, language, and cleanup behavior. It can be replayed. |
| Microphones | External-device choice and troubleshooting | Exact Core Audio transport classification, persistent semantic Mac/iPhone mode, ranked user-approved fallback list within that mode, gain display, connect latency, live level, and a three-second record/playback test. No cross-mode fallback. A live mode switch finalizes and releases the current source before capture resumes as the next ordered segment. |
| Continuity reliability | Do not record through the iPhone wake-up gap | Capture waits for a steady, audible sample stream. Stop synchronously ends the AVCapture session before transcription starts. Sleep, disconnects, startup cancellation, and mid-stream stalls are handled explicitly. |
| Long dictation | Longer sessions with visible limits | Twenty-minute hard limit, one-minute warning, no-audio warning, automatic safe finalization, and immediate explicit cancellation with Escape. Short finalized recordings are still sent to Scribe; there is no arbitrary minimum-duration discard. |
| Existing audio | Transcribe a file without blocking live dictation | Audio import has a separate manual-output lane, a fail-closed 20-minute duration limit, a 1 GB local admission limit, and never auto-pastes when it finishes. It does not block capture or spoken-order delivery, although imports and live dictations share Scribe's three-request admission limit. Normal Quit waits for secure import staging to finish or refuses to quit after the bounded wait. |
| Network failure | Retry without losing what was said | Every finalized recording is moved into a private, crash-safe pending-audio journal before upload and is removed only after its final text and consumption receipt are durable. Interrupted active WAVs are recovered on the next primary launch. Transient network/429/5xx failures retry with bounded backoff; terminal or history-write failures remain individually retryable or discardable. |
| Concurrent work | Let another dictation start while an earlier one transcribes | The microphone is released immediately, Scribe requests are admission-limited, and completed live dictations are delivered in spoken order. Imports do not block that queue. The default keeps immediate delivery; the persisted, default-off **Hold delivery while recording** setting pauses dequeue only while capture is active and flushes ready work in the gaps between chunks. It does not invent a batch-at-end mode or an end-of-message signal. |
| Destination safety | Avoid pasting into the wrong place | Inside the serialized delivery gate, SpeakPaste resolves the currently focused writable editor, refuses secure fields, and revalidates that live destination at every slow or queued side-effect boundary. A different writable field or application is the intended destination when it owns focus at delivery time. Record-start AX object identity is not required: Electron and Chromium may rebuild, proxy, or replace the tree and editable node. No current writable editor means clipboard fallback rather than a guessed insertion. |
| Delivery compatibility | Work across native, web, and terminal-style fields | Current target-app Paste menu first, layout-aware Command-V fallback, optional chunked Unicode type-out, clipboard-only mode, and clipboard restoration after an exact verified insertion. Every pasteboard writer participates in the same serialized transaction, including fallback and explicit History/held copies. The live focused writable target is rechecked at every slow/queued side-effect boundary; partial type-out is never automatically replayed. Unconfirmed delivery remains visibly unconfirmed, recoverable, and on the clipboard. |
| Return to destination | Recover when the user switched away | When no writable editor is focused, the exact newest transcript becomes the clipboard fallback even when older recovery entries exist; every unresolved entry also remains durable in the dashboard. Delayed same-session and recovered text is released explicitly into the current focused writable editor rather than waiting for an archived AX node to return. User clipboard changes are reconciled from the private claim rather than inferred from queue size. A side effect that may have landed remains marked possibly delivered and is never retried automatically; reviewed uncertain text additionally requires a one-shot dashboard authorization for exactly the reviewed queue. |
| Last transcript | Quickly reuse or correct recent text | Editable transcript, copy, clear, learn-edits, and global copy/paste-last shortcuts. While first-output recovery is unresolved, the transcript is visibly read-only and nonselectable so standard editor shortcuts cannot bypass the handoff. Copy/Paste Last refuse any transcript whose first output lacks a durably resolved handoff; a History-backed handoff can be repaired on demand without making the source audio retryable. |
| Per-app behavior | Different apps need different insertion rules | Durable rules keyed by the delivery-time destination's bundle identifier select automatic, Paste-menu, type-out, or clipboard-only delivery; they can opt into context and explicitly confirmed auto-send. Auto-send is never used for delayed held text. |
| Vocabulary | Teach names and domain language | Up to 1,000 validated batch keyterms are sent to Scribe. The current service contract requires fewer than 50 characters and no more than five words per term and forbids `<`, `>`, `{`, `}`, `[`, `]`, backslashes, and control characters. Bulk paste/import and deterministic duplicate handling are included. The UI discloses ElevenLabs' current 20% keyterm surcharge and the 20-second minimum billing unit above 100 terms. Edits publish only after a private atomic write; damaged or newer documents remain byte-for-byte untouched. |
| Replacements and snippets | Expand or correct recurring phrases | Ordered, enableable heard-as → written-as rules support exact spellings and longer text expansions. Transcript edits teach corrections as one atomic transaction, with the same fail-closed persistence guarantees as vocabulary. |
| Local cleanup | Predictable formatting without another model | Scribe's clean-speech option plus local spoken punctuation/new-line commands, deterministic replacements, and cursor-aware spacing/capitalization. Intrinsic cleanup is prepared when Scribe returns, but each chunk's seam is fitted only inside the serialized paste transaction against the current delivery editor's live pre-caret text. Explicit delayed runs fold one chunk at a time at the current focus, preventing stale record-start snapshots, `word.Next` collisions, duplicate spaces, and broken sentence casing. |
| Context | Use nearby text to improve recognition, transparently | Recognition context is off by default. When enabled globally or for one app, only a small caret-local window, selection, app name, and window title are reduced to candidate keyterms. The UI shows how many terms were captured. Dynamic app/caret terms are validated and receive the finite 1,000 slots before global vocabulary, so a full dictionary cannot silently suppress the more specific context. Separately, local spacing/capitalization may read at most 256 pre-caret characters in process memory; those characters are never uploaded or stored. Secure fields are never read by either path. |
| Language | Automatic and pinned language hints | The macOS picker exposes 100 choices: Auto plus all 99 documented Scribe language hints. Auto, English, and Spanish stay pinned above the alphabetical catalog, and the setting persists. Auto results below 50% Scribe language confidence are preserved but visibly flagged for review. |
| History | Search, replay, reprocess, and control retention | Local searchable and editable History with per-record deletion, Never/1/7/30/90-day or forever retention, a 500-record ordinary cap, and confirmed purge. Source-linked recovery proofs may temporarily exceed that cap rather than be destroyed. Successful source audio is retained by default for playback and Process Again, follows transcript retention, is capped at 1 GiB, and refuses a new optional copy if less than 2 GiB would remain free. Process Again uses the current language/vocabulary/replacement settings, updates only that record, never pastes or auto-sends, and can be cancelled. Edit and Process Again are blocked while the row still owns source recovery or a same-ID delivery escrow, so saved and deliverable text cannot diverge. A History row that is still durable recovery proof cannot expire or be deleted until the audio journal owns the linked completion receipt. Failed audio remains in a separate recovery queue. |
| Permissions | Explain why global input or paste is unavailable | Live Microphone, Accessibility, Input Monitoring, Keyboard Output, and Login Item status with explicit request/open-settings actions. Secure Input is surfaced rather than treated as a mysterious failure. |
| Diagnostics | Make intermittent failures reportable without exporting content | Privacy-safe JSON includes versions, permission booleans, microphone transport category/gain, timing/outcome metadata, and queue counts. It excludes names, transcripts, audio, clipboard data, captured context, and credentials. |
| Offline recovery | Never lose speech to a network transition | Connectivity status is visible in the app and menu bar, outside the capture indicator. When the network is known to be unavailable, SpeakPaste journals new audio without making a doomed request. Typed connectivity failures remain in the same private queue and retry once after `NWPathMonitor` reports an actual usable-path recovery; satisfied-to-satisfied churn cannot loop them. A reconnect that races ahead of the final request error is recovered by a path-generation receipt. Every automatic retry finishes in held/manual output and can never use a stale caret or auto-send. Authentication, validation, rate-limit, certificate/ATS, and no-speech failures remain manual so reconnect cannot create an unrelated retry loop. |
| Lifecycle | Behave like a native menu-bar utility | A product-wide per-user process lease protects the shared stores across signed, ad-hoc, renamed, and differing-bundle-ID builds; a legacy-running-app check covers builds that predate the lease, and secondary launches never construct the data-owning model. Also included: menu-bar controls, optional Dock presence, launch at login, settings window, session heartbeat, crash/unclean-quit notice, idle display/system sleep prevention only while the microphone is recording, primary-instance-only temp recovery, and an asynchronous Quit barrier that finalizes, releases, and journals active speech before termination. |

## Deliberate exclusions

These were present in one or both reference products but conflict with the
product thesis or solve a different job:

- Realtime streaming and live word-by-word text. Scribe v2 batch is the quality
  path and supports the richer keyterm budget.
- Model/provider pickers, local model downloads, and “fast versus accurate”
  choices. Scribe v2 is the product.
- LLM rewrite modes, prompt libraries, command mode, tone transforms, and
  writing-style imitation. They add a second inference system and make output
  less deterministic.
- Meeting recording, system-audio capture, diarization, named speakers,
  summaries, and subtitle/document export. SpeakPaste is single-speaker cursor
  dictation, not a meeting recorder.
- Team administration, shared dictionaries, analytics dashboards, enterprise
  identity, and billing controls.
- Screen-wide OCR/screenshot context. Uploaded recognition context is opt-in,
  caret-local, reduced to spelling hints, and never stored in diagnostics. The
  independent local-only formatting read is limited to 256 pre-caret characters.
- A general developer API, CLI, MCP server, or automation platform over private
  transcript history, including URL schemes, Services, and broad App Intents.
  Those widen the privacy and support surface without improving core dictation.
- Applying the global macOS Text Replacements dictionary or an automatic
  `NSSpellChecker` rewrite. SpeakPaste uses explicit app-owned replacements so
  users can inspect every deterministic transformation and so a hidden system
  correction cannot fight a Scribe keyterm.
- Controlling unrelated media playback or system volume. Automatic pause/duck
  behavior is invasive, varies by player, and would require physical validation
  against the Continuity capture path before it could be considered safe.

The fixed bare-right-Command toggle is also retained as part of SpeakPaste's
interaction model rather than adding a shortcut editor or push-to-talk mode. It
keeps the existing prototype behavior, does not reinterpret ordinary Command
chords, and makes the start/stop gesture predictable; all companion actions
have distinct documented shortcuts.

## Differences that are intentionally safer

- A successful event post is not called a successful paste. SpeakPaste confirms
  readable fields and otherwise labels the result unconfirmed.
- Auto-send requires an app-specific rule and a warning for that exact bundle
  identifier. It runs only after confirmed immediate insertion.
- A recording is journaled before the first request, not merely retained after
  a request reports failure, and its recovery copy is removed only after the
  final text and a linked consumption receipt are atomically durable. The
  optional successful-audio History copy has its own retention/quota policy.
  Even sub-450 ms recordings are sent rather than guessed to be accidental.
- History retention is a storage policy, not permission to gamble with output.
  Under every retention setting, final text first enters a temporary durable
  delivery escrow before source-audio recovery proof can retire. Before an
  external paste the escrow is atomically marked possibly delivered. A crash or
  unverified paste therefore recovers as an explicit copy/discard/one-shot
  Paste Anyway decision, never as an unattended retry. Never Store additionally
  removes the completed History row and creates no successful-audio copy.
- If an affected older build left several History rows for one recording,
  canonicalization creates one deliverable handoff and retires its siblings in
  one pending-document transition. A sibling's possibly-delivered receipt is
  transferred to the canonical copy before that sibling disappears.
- Uploaded dynamic recognition context is opt-in and minimized. The separate
  local-only spacing/capitalization read is never uploaded or stored.
- A restored or delayed transcript does not auto-deliver. The user explicitly
  releases it into the current focused writable editor; possibly delivered text
  first requires the reviewed one-shot authorization.
- Speech-to-text requests reject every HTTP redirect before a custom API-key
  header or multipart body can be forwarded. Crash-left upload/import bodies
  are removed only by the surviving primary instance after strict ownership,
  name, mode, link-count, and file-type checks.
- All automatic JSON/audio stores use descriptor-relative no-follow operations;
  malformed, newer, symlinked, or unreadable storage fails closed instead of
  being rewritten or used to enable risky delivery behavior.

## Reference sources

Superwhisper:

- [Introduction](https://superwhisper.com/docs/get-started/introduction)
- [Recording window](https://superwhisper.com/docs/get-started/interface-rec-window)
- [History](https://superwhisper.com/docs/get-started/interface-history)
- [Vocabulary](https://superwhisper.com/docs/get-started/interface-vocabulary)
- [Shortcuts](https://superwhisper.com/docs/get-started/settings-shortcuts)
- [Advanced settings](https://superwhisper.com/docs/get-started/settings-advanced)
- [Context behavior](https://superwhisper.com/docs/common-issues/context)
- [Changelog](https://superwhisper.com/changelog)

Wispr Flow:

- [What is Flow?](https://docs.wisprflow.ai/articles/2772472373-what-is-flow)
- [Longer dictation sessions](https://docs.wisprflow.ai/articles/4841123325-Longer-dictation-sessions-%E2%80%94-now-up-to-20-minutes)
- [External audio devices](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices)
- [Context awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)
- [Retry failed transcriptions](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions)
- [Dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)
- [Snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets)
- [Desktop setup](https://docs.wisprflow.ai/articles/3152211871-setup-guide)
- [Move and dock the Flow bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)
- [Data controls](https://wisprflow.ai/data-controls)
- [What's new](https://wisprflow.ai/whats-new)

ElevenLabs:

- [Speech-to-text overview](https://elevenlabs.io/docs/capabilities/speech-to-text)
- [Create transcript API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)
- [Batch keyterm prompting](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting)

## Verification boundary

The macOS target and focused logic suites can prove compilation, persistence,
request construction, retry behavior, and pure delivery decisions. Isolated UI
inspection can prove that controls are present and locally operable. Neither can
prove the system-owned Continuity UI, physical microphone release/reconnect, or
a target application's real AX behavior. This parity pass does **not** yet claim
full real-device or end-to-end acceptance. The checklist in
[macOS remaining work](macos-remaining-work.md) is required before calling the
complete experience physically verified or release-ready.
