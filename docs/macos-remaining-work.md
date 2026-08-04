# macOS remaining work

The adopted core Superwhisper/Wispr Flow parity set is represented in source.
The ledger names the behaviors deliberately excluded from SpeakPaste's
quality-first, ElevenLabs-Scribe-only boundary; the smaller unresolved candidate
set below is explicit rather than hidden behind a blanket parity claim.

What remains is acceptance and release engineering. Partial isolated UI
inspection is useful evidence, but it is not a full real-device run: the
system-owned Continuity surface, physical microphone release, and destination
apps' Accessibility behavior can only be proved on the actual Mac/iPhone chain.

## Deferred capability candidates

These are not claimed as implemented. They are narrower than the excluded
automation/model/media-control surfaces, but still need product or release work:

- Opt-in macOS notifications for a background failure or newly held output when
  the capture indicator is no longer visible. Authorization, categories, and
  delivery should be tested only after the permanent signed bundle identity
  exists.
- Removing a large retained-audio library without ever waiting behind an
  in-progress copy on the main actor. The current lock preserves consistency,
  but a worst-case privacy-toggle cleanup can temporarily make the UI
  unresponsive.

## Automated candidate gates

- [ ] Run the complete focused Swift test suite, including persistence failure,
      pending-audio, pending-transcript ambiguity, Command gesture/input mode,
      vocabulary boundary, retained-audio quota/free-space, and single-instance
      coverage.
- [ ] Build `SpeakPasteMac` from a clean candidate checkout with the documented
      ad-hoc command. Review every warning and confirm the generated app contains
      the intended sources and no credential or local state.
- [ ] Recheck the ElevenLabs multipart body: `scribe_v2` only; no redirects;
      repeated `keyterms` fields; at most 1,000 terms; 49 characters accepted
      and 50 rejected; no more than five words; forbidden characters rejected.
- [ ] Prove that dynamic app/caret context receives keyterm slots before global
      vocabulary when the combined list reaches 1,000.
- [ ] Run storage tests on malformed, future-schema, symlinked, unreadable, and
      write-failing documents. Each store must preserve bytes and fail closed,
      not publish state it could not commit.
- [ ] Run the product-wide lease test with two normal app processes using
      different bundle identifiers. Also cover a running legacy SpeakPaste build
      that predates the lease. The secondary process must not initialize or
      change shared defaults, History, recovery journals, or retained audio.

## Isolated macOS UI acceptance

Use a disposable build compiled with `SPEAKPASTE_UI_TEST_INSTANCE`, a unique
bundle identifier, redirected `CFFIXED_USER_HOME`/`TMPDIR`, and a non-secret
placeholder API key. Do not point this run at the installed app's Keychain,
TCC grants, or Application Support.

- [ ] Complete and revisit every onboarding step. Check API-key states,
      permission/readiness explanations, microphone selection/test, shortcuts,
      successful-audio disclosure, and the language menu.
- [ ] Select Auto and several entries near the beginning, middle, and end of the
      full 100-choice language catalog, then relaunch and confirm persistence.
      Inject a low-confidence Auto response and confirm the text is preserved
      while the detected-language review warning appears.
- [ ] Exercise the capture indicator at top, bottom, left, and right. Confirm the
      active display is chosen correctly, the pill stays click-through, and no
      state clips at normal accessibility text sizes.
- [ ] Exercise Connecting, Listening, Releasing, and Transcribing. Confirm the
      native Liquid Glass surface is used on macOS 26 and the stack stays
      wordless apart from live-work numeric badges. Confirm the
      listening waveform follows the real voice level with fast attack and
      slower release, state changes spring-morph, and each transcription card
      uses its own directional heuristic progress that never reaches completion
      before the request does. The indicator must hide at idle and after the
      last in-flight transcription, success, errors, and offline state; it must
      never become an error notification. Dictate several rapid chunks and
      confirm the capture card is always frontmost, earlier transcriptions
      recede behind it with their own rails, deeper work folds into the "+N"
      badge on the rearmost card, and only verified deliveries pop from the
      rear; overflow and timeout changes must fold or crossfade. Force a held
      chunk and confirm one count-free clipboard glyph appears only while the
      hold owns the private live pasteboard claim, changes to a neutral tray
      after another app replaces the clipboard, and disappears within two
      seconds. Relaunch with waiting or uncertain recovery entries and confirm
      none are replayed into the HUD; the dashboard remains authoritative. Hold the
      model in Connecting and Releasing
      and confirm those cards hide no later than 20 and 15 seconds after the
      phases began, respectively. Keep one request transcribing and confirm its
      card hides after 90 continuously visible seconds — without hiding
      younger cards — while the dashboard and menu bar continue to report the
      real work state. With Reduce Motion enabled, confirm depth changes and
      state changes become restrained crossfades without depth travel and
      without losing state clarity.
- [ ] Dictate three rapid chunks into one field and confirm delivery remains in
      spoken order even when Scribe completes them out of order. Verify every
      seam against the live caret: words get exactly one needed space,
      punctuation attaches, existing spaces/newlines do not gain another, and a
      sentence-ending mark gives the next ordinary chunk sensible casing.
- [ ] Move focus away after the first chunk so it holds, then dictate later
      chunks pinned to that same field. Confirm they chain-hold explicitly, the
      clipboard remains the first single chunk instead of being overwritten,
      the HUD does not become a queue counter, and returning to the exact field releases the whole
      run as one ordered, cleanly fitted insertion. Force the first member into
      an unconfirmed state and confirm no later same-field member skips ahead.
      When delivery leaves one hold, confirm clipboard ownership transfers only
      if its original private claim still exists. Confirm a different field in
      the same app does not qualify.
- [ ] Turn **Hold delivery while recording** on, dictate overlapping chunks, and
      confirm completed work never dequeues while capture is active but flushes
      in the pauses between chunks. Turn it off during capture and confirm the
      ready queue resumes without changing transcription or spoken order.
- [ ] With VoiceOver, confirm capture/transcription/held/delivery announcements
      identify chunk ordinals. With Reduce Motion, confirm stack depth changes
      and delivery removal crossfade rather than travel or scale.
- [ ] On MacBook speakers at low volume, confirm capture and release are distinct
      E5/B5 single pings with no load delay, then a higher E6 single ping plays
      only after verified insertion. Confirm errors use the only two-note phrase,
      E4 to B3 low and falling, and disabling Sounds silences the complete family.
- [ ] Verify every vocabulary action: add, search, edit Save/Cancel, paste-list
      Save/Cancel, file-picker Cancel, and remove confirm/Cancel. Check the
      1,000-term ceiling, fewer-than-50-character and five-word limits, forbidden
      characters, duplicate handling, and the 20% / over-100 billing disclosure.
- [ ] Verify every replacement and per-app-rule action, including validation,
      enabled state, auto-send warning, Save/Cancel, and delete confirm/Cancel.
- [ ] With an empty profile, switch History through Never store, 1, 7, 30, 90,
      and Forever. Confirm Never store produces no false persistence error,
      successful-audio controls disable appropriately, and Delete All is disabled
      when there is nothing to delete.
- [ ] Seed disposable History records and retained audio. Exercise search, Play,
      Stop, Edit Save/Cancel, per-record delete confirm/Cancel, Delete All
      confirm/Cancel, Process Again, and Process Again cancellation. During
      reprocessing, actions that could race the record must stay disabled.
- [ ] Fill retained History audio to the 1 GiB quota and simulate the 2 GiB
      free-space reserve boundary. In both cases the transcript must remain saved,
      the optional audio omission must be visible, and existing retained files
      must remain usable.

## Delivery-crash and Never-store acceptance

Run these in a disposable profile with fault injection around each durable
write. Inspect the files after every restart rather than trusting the UI alone.

- [ ] Under each History retention mode, prove the transcript enters the durable
      pending-delivery escrow before source-audio proof is retired and before
      external output. Then finish a Never-store dictation and prove that after
      resolved delivery no completed History row or successful-audio copy remains.
- [ ] Fail escrow creation. The transcript must not paste; History and recovery
      audio must remain available with a visible explanation. Copy/Paste Last
      must remain blocked; History Copy may proceed only after it repairs that
      exact escrow and retires the source-audio retry path.
- [ ] Fail the transition to `deliveryUncertain`. External paste must be blocked
      and the text must remain recoverable.
- [ ] Terminate after `deliveryUncertain` is durable and before cleanup. Relaunch
      must label the entry possibly delivered, refuse automatic/hotkey retry, and
      offer Copy, Discard, or a separately confirmed one-shot Paste Anyway arm.
      Arming from the dashboard must not paste into SpeakPaste; it must require
      returning to the destination and pressing the release shortcut.
- [ ] Exercise a definite no-paste result and prove only entries that were
      originally pending return to pending. An entry recovered as uncertain must
      never be silently downgraded to safe-to-retry.
- [ ] Exercise confirmed and unverified paste results, then force recovery-entry
      deletion failure. Confirmed output with failed cleanup must remain visibly
      uncertain; unverified output must never be replayed automatically.
- [ ] Hold a pasteboard-backed delivery open while attempting Copy on a different
      History/held transcript. The explicit copy must wait or fail without
      replacing the text the destination is consuming, and no escrow may resolve
      until its own clipboard write succeeds.
- [ ] Seed two source-linked History rows for one pending-audio identifier. Launch
      must queue only the completion-marker row when one is durable (otherwise
      the newest row), suppress Retry for that audio, and preserve the
      noncanonical History row without allowing a joined duplicate. If a sibling
      is marked possibly delivered, that warning must move atomically onto the
      canonical row before the sibling handoff is retired.

## Direct physical Mac and iPhone acceptance

Run this with a signed candidate, a paired iPhone, Notes, and at least one opaque
Electron or browser text field. Record screen/video plus privacy-safe diagnostics
for the release evidence.

- [ ] Grant permissions through onboarding, select the Continuity microphone,
      and complete the three-second microphone test.
- [ ] Focus a Notes field, tap bare right Command, wait for **Listening**,
      dictate, and tap it again. Confirm text reaches that exact field and the
      iPhone's system-owned capture surface dismisses before transcription.
- [ ] Repeat immediately to prove clean Continuity release and reconnect, not
      merely one successful transcription.
- [ ] Start in Mac mode, double-tap bare right Command while idle, and confirm
      iPhone mode is selected. Relaunch and confirm the mode persists. Double-tap
      back and verify Mac mode also persists.
- [ ] While speaking through the Mac, double-tap bare right Command. Confirm the
      Mac segment is finalized and its input released before iPhone Connecting
      then Listening begins; continue speaking and confirm both transcripts are
      delivered in spoken order. Repeat in the opposite direction.
- [ ] While connecting and while recording, press Escape once. Each must cancel
      immediately, discard the active segment, release the microphone, and leave
      no capture indicator behind. A normal single-Command stop must still
      transcribe.
- [ ] Start in one field and switch to another before the response returns. No
      text may enter the second field. Returning to the exact original field must
      release only its matching held text.
- [ ] Repeat in an opaque field. An unverifiable paste must be labelled
      unconfirmed/possibly delivered, remain recoverable, and never insert a
      second copy automatically.
- [ ] Exercise an unavailable/disconnected microphone, device reconnect,
      mid-stream loss with partial salvage, secure input, revoked permissions,
      sleep/wake, and the 20-minute automatic stop path.
- [ ] Exercise forced offline/timeout/429/5xx failures, automatic reconnect
      retry, manual retry, discard, imported audio, paste/copy last,
      clipboard-only and type-out app rules, clipboard restoration, and guarded
      auto-send.
- [ ] Quit normally during capture and confirm the microphone is released and the
      finalized audio is waiting after relaunch. Terminate disposable candidates
      during capture, upload, History commit, and delivery bookkeeping; each
      restart must produce one recoverable item and no unattended duplicate.
- [ ] Launch a second normal candidate while the first is active. It must bring
      forward the owner or exit with the safety explanation, never show a second
      recorder or mutate shared data.

Until every applicable box above has recorded evidence, describe the parity
implementation as source/build/logic tested only to the degree actually run —
not fully end-to-end verified.

## Repository-owner release work

These items are genuinely unimplemented because they require product identity,
credentials, and distribution decisions that this source pass cannot make:

- [ ] Choose the final product name. "SpeakPaste" is a working title; reuse of
      "Near" was considered and rejected because that name is parked with the
      Clockwork hardware direction. Rename the display name together with the
      permanent bundle-identifier work below.
- [ ] Design the real app icon to replace the placeholder mic artwork in the
      shared `SpeakPaste/Assets.xcassets` catalog (used by both the iPhone and
      macOS targets). It should be full-bleed in the macOS squircle and legible
      at 16 px; direction is open until the name is chosen.
- [ ] As part of the same branding pass, decide whether the menu bar item's
      idle glyph stays a system SF Symbol (`waveform` today) or becomes a
      custom monochrome template glyph matching the brand. The menu bar item
      itself stays: it bootstraps login-item launches when no window opens and
      is the persistent state surface after HUD cards time out. The non-idle
      state symbols (recording, error, offline, setup needed) keep their
      system-semantic forms either way.
- [ ] Choose the permanent macOS bundle identifier and Apple Developer team.
- [ ] Configure the release entitlements, Developer ID signing, hardened runtime,
      versioning, notarization, and stapling; then repeat the physical acceptance
      run with that exact artifact because TCC and Keychain behavior follow its
      code identity.
- [ ] Choose and implement an update channel. If Sparkle is selected, protect the
      signing key, host the appcast, and test a real update and rollback. Do not
      expose an inert **Check for Updates** control before the channel exists.
- [ ] Archive the final acceptance evidence and publish only the notarized,
      stapled artifact that produced it.
