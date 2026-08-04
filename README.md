# SpeakPaste

SpeakPaste is a native Swift dictation project for macOS and iPhone. It sends
recorded audio directly to [ElevenLabs Scribe](https://elevenlabs.io/speech-to-text),
then lets you edit, copy, or paste the transcript.

The Xcode project contains four product targets:

- **SpeakPasteMac** — the primary macOS target, producing the **SpeakPaste** app
  with Continuity Microphone support, a global dictation shortcut, and automatic
  paste.
- **SpeakPaste** — an iPhone containing app with record, edit, copy, share, and
  local transcript history.
- **SpeakPasteKeyboard** — a custom typing keyboard that starts a containing-app
  recording, controls it after switchback, and inserts the result at the cursor.
- **SpeakPasteLiveActivity** — the Lock Screen and Dynamic Island recording
  indicator used by the optional Shortcut-driven background capture path.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- An [ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys)
- An iPhone and Apple development signing if you want to run the iPhone app or
  keyboard

## Run the macOS app

1. Open `SpeakPaste.xcodeproj` in Xcode.
2. Select the **SpeakPasteMac** scheme and **My Mac** as the destination.
3. Build and run. The product is named **SpeakPaste.app**.
4. Save your ElevenLabs API key when prompted.
5. Keep your iPhone nearby and locked and SpeakPaste selects its Continuity
   microphone automatically. Your current **Mac** or **iPhone** input mode is
   remembered across launches. If that source is unavailable, SpeakPaste says
   so instead of silently substituting the other one.
6. Click the record control or tap the **right Command (⌘)** key once. A single
   tap starts or stops dictation after the system double-tap window. The left ⌘
   is deliberately untouched, so ⌘C, ⌘V, and ⌘Tab keep their normal behavior.
7. The click-through Liquid Glass indicator is a depth stack with one stable
   card per chunk. Live capture stays in front and spring-morphs from wake pulse
   to real waveform to release glint; each transcribing chunk recedes behind it
   with its own directional progress rail. The oldest card is rearmost and pops
   out when delivered, while deeper work folds into a numeric `+N`. Progress is
   only an estimate and stops short of claiming completion. A stalled rail hides
   after 90 seconds; success, errors, model details, and offline notices stay in
   the app instead of becoming floating notifications.
8. Double-tap right Command to switch between **Mac** and **iPhone** input. The
   choice is sticky. During a recording, SpeakPaste first finalizes and releases
   the current source, queues that segment, and then starts a new ordered segment
   on the other source.
9. Tap right Command once to stop and transcribe, or press **Escape** once to
   cancel immediately and discard the active segment. Preloaded sounds
   use three single pings that rise through capture, release, and verified
   delivery, while errors are the family's only phrase: low and falling.

You do not have to wait at the keyboard. If the field you dictated into is no
longer focused when the transcript arrives, SpeakPaste converts that card into a
safe hold instead of pasting somewhere else. The HUD acknowledges that once with
a count-free clipboard or tray glyph, then disappears after two seconds; the
dashboard owns the durable recovery state. Later chunks for that exact field
join the held run without repeatedly overwriting your clipboard. Click back into
the field to insert the run in spoken order, or press
**⌥⌘V** to drop it wherever your cursor is. Delivery is attempted only into the
captured field — never merely the same application. If a web editor rebuilds its
Accessibility proxy while you remain in place, SpeakPaste accepts it only when
the same window, editor structure, geometry, and absence of user input prove
continuity. The optional **Hold delivery while recording** setting pauses only
the delivery dequeue while the mic is live and flushes work between chunks.

Stopping ends the Continuity session before transcription starts, allowing
macOS to dismiss its system-owned capture surface on the iPhone. Each new
dictation reconnects and may briefly show the capsule's connecting pulse before
the capture-live cue confirms that audio is ready. Automatic paste and the
global shortcut require macOS Accessibility permission; without it, the
transcript remains on the clipboard.

You can also build the macOS target from Terminal:

```sh
xcodebuild \
  -project SpeakPaste.xcodeproj \
  -scheme SpeakPasteMac \
  -configuration Debug \
  -derivedDataPath /tmp/SpeakPasteDerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  build
```

Settings live behind **⌘,** and cover the full Scribe language catalog,
delivery, sounds, capture-indicator placement, launch at login, the API key,
custom vocabulary, text replacements, per-app rules, transcript history,
privacy-safe diagnostics, and a live view of every permission the app depends
on.

**Vocabulary** is the main quality control. Names, jargon, and product spellings
added there are sent with every dictation as ElevenLabs keyterms, biasing
recognition toward them without forcing a substitution. Scribe's current batch
contract permits up to 1,000 keyterms, each fewer than 50 characters and no
more than five words; SpeakPaste also rejects `<`, `>`, `{`, `}`, `[`, `]`,
backslashes, and control characters before upload. Dynamic terms derived from
opt-in caret context take the finite slots before the global vocabulary because
they are more specific to that dictation. ElevenLabs currently adds a 20%
surcharge whenever keyterms are sent, and using more than 100 makes every
request bill for at least 20 seconds. **Replacements** are the blunt instrument
for the cases Scribe gets wrong every time; they always fire locally.

When language is **Auto**, SpeakPaste also reads Scribe's language-confidence
metadata. A result below 50% is kept intact but visibly flagged for review, with
the option to pin a language for later dictations.

Transcripts are kept on this Mac in Application Support, searchable, with
Never/1/7/30/90-day or forever retention and a confirmed one-click purge.
Successful recordings are retained by default for playback and **Process
Again**; that optional library is capped at 1 GiB and refuses a copy that would
leave less than 2 GiB free. Hitting either limit does not discard the transcript.

Every new recording first moves into a separate private, crash-safe recovery
journal. It leaves that journal only after the final transcript and its linked
consumption receipt are durable; a failed request or write leaves the audio
available for retry or explicit discard instead of losing what was said. Every
connectivity-caused failure is also marked for automatic retry: while offline,
the app and menu bar say that recordings are staying local, and the saved queue
wakes once when macOS reports that the connection has
returned. Because an old caret or message draft is not a safe destination, the
recovered transcript waits for explicit manual placement and never auto-sends.
All other service and content failures still require an explicit Retry after
the client's bounded request retries, so a network transition cannot repeat an
unrelated request. Every completed transcript also enters a temporary durable
delivery escrow before
copy or paste, under every History setting. **Never store** removes the
completed History row and creates no successful-audio copy, while the escrow
remains only until output is resolved. Before any external paste the escrow is
marked as possibly delivered, so a crash at the side-effect boundary cannot
cause an unattended duplicate after relaunch. Copy/Paste Last cannot bypass an
unfinished handoff, and every SpeakPaste clipboard writer shares one serialized
transaction so concurrent output cannot substitute a different transcript. A
normal Quit during recording
first finalizes and journals the audio; it also waits for an in-progress file
import to finish secure staging or cancels Quit rather than abandoning a partial
copy. Imports whose duration cannot be established fail closed and are never
uploaded. A validated active WAV left by a process crash is recovered on the
next primary launch. Short recordings are never discarded merely because they
are under an arbitrary duration threshold.

For local development, `SpeakPasteMac` also accepts the API key through the
`ELEVENLABS_API_KEY` environment variable. Never commit an API key.

## Run the iPhone app and keyboard

The checked-in identifiers use the `com.example` namespace. Override these
build settings with identifiers owned by your Apple Developer account; source,
entitlements, and property lists stay in sync automatically:

- `SPEAKPASTE_APP_BUNDLE_IDENTIFIER`
- `SPEAKPASTE_KEYBOARD_BUNDLE_IDENTIFIER`
- `SPEAKPASTE_LIVE_ACTIVITY_BUNDLE_IDENTIFIER`
- `SPEAKPASTE_TESTS_BUNDLE_IDENTIFIER`
- `SPEAKPASTE_APP_GROUP_IDENTIFIER`

The app and keyboard must use the same App Group override. The defaults remain
safe public examples, so a personal sideload no longer requires source edits.

For a repeatable physical-device install, put those values plus your team,
signing identity, and device identifier in the ignored
`scripts/local-identity.env`, then run `scripts/install-iphone.sh`. The installer
builds directly against the device SDK, packages the checked-in icon PNGs using
`CFBundleIcons`, signs the result, installs it, and launches it. It does not
require an iOS Simulator runtime or modify tracked identifiers.

Then:

1. Select the same development team for **SpeakPaste** and
   **SpeakPasteKeyboard**.
2. Run **SpeakPaste** on your iPhone and save your ElevenLabs API key in
   Settings.
3. In iOS Settings, open **General → Keyboard → Keyboards → Add New Keyboard**,
   add SpeakPaste, and enable **Allow Full Access**.
4. Open Notes or another text field, switch to SpeakPaste with the globe key,
   and tap **Start**.
5. SpeakPaste briefly opens to own the microphone. Accept microphone permission
   if needed. On the first keyboard dictation, tap **OK** on the one-time
   switchback explanation.
6. SpeakPaste returns to the previous app while recording continues. Tap
   **Stop & Insert** in the keyboard to transcribe and insert the result at the
   existing cursor.

The keyboard renders its own QWERTY, number, and symbol planes because iOS does
not place Apple's keyboard beneath a third-party keyboard extension. Its idle
layout has the **Start** action; active dictation replaces the keys with
**Listening**, **Cancel**, and **Stop & Insert**, then shows **Transcribing**
until the result is inserted exactly once. If automatic return is unavailable,
recording continues and the app explains how to swipe back manually.

The reference recording, device evidence, and acceptance criteria live in
[the iPhone keyboard round-trip specification](docs/ios-keyboard-roundtrip-spec.md).

## Keyboard handoff implementation

Apple does not provide microphone access to custom keyboards, so the containing
app must briefly foreground and start capture. SpeakPaste uses typed
`UIScene.open` or `UIApplication.open` calls where the responder chain exposes
them, attempts the public `NSExtensionContext.open` method as a keyboard fallback,
and keeps private bundle activation as the last resort for this personal
sideload. Every route persists its real asynchronous result.

For the return, SpeakPaste follows the architecture exposed by Wispr Flow 1.67's
signed metadata and Swift symbols. On iOS 26.4 and later, an early keyboard-
arbiter hook captures the host bundle identifier before the extension opens the
containing app. The app then looks that identifier up in the fixed scraped
bundle/scheme catalog and opens the cataloged URL with `UIApplication.open`.
Unknown hosts use the manual home-bar swipe instead of guessing at a generic
previous app.

This switchback sequence is protected compatibility code. Do not replace,
reorder, or refactor it without re-inspecting the current reference app and
passing the complete physical-device matrix in
`docs/ios-keyboard-roundtrip-spec.md`. Direct host-bundle activation, generic
suspension, and system-navigation guesses are deliberately excluded.

The keyboard-arbiter hook uses private iOS implementation details for this
personal sideload. It may change in future iOS releases and is not suitable for
App Store submission. Apple provides no public generic API for a keyboard to
identify and return to its host app.
Wispr's executable code is FairPlay-encrypted, so SpeakPaste reproduces the
observable behavior rather than claiming knowledge of inaccessible method
bodies. The adapted hook retains its MIT license in
`THIRD_PARTY_NOTICES.md`.

The implementation was compared with
[Wispr Flow's iPhone keyboard guide](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone),
[its iOS switchback release note](https://wisprflow.ai/whats-new),
[Apple's custom keyboard documentation](https://developer.apple.com/documentation/uikit/uiinputviewcontroller),
[Apple's extension URL-opening contract](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)),
and [Apple DTS's current public-API boundary](https://developer.apple.com/forums/thread/826851).

### Optional Shortcut trigger

SpeakPaste still includes a `Toggle Dictation` App Intent and Live Activity for
people who prefer a global Shortcut or Back Tap trigger. That path records
without the foreground bounce and queues its result for keyboard insertion, but
it is an alternative automation surface rather than the primary keyboard UX.

## Privacy

- API keys are stored in the platform Keychain. The keyboard extension never
  receives the key.
- Audio is sent directly to ElevenLabs at
  `POST https://api.elevenlabs.io/v1/speech-to-text` using the `scribe_v2`
  model. Upload requests do not follow HTTP redirects, so the API key and
  speech body cannot be forwarded to another origin by a 3xx response.
- On macOS, audio is staged in a private recovery journal before upload.
  Interrupted, failed, or not-yet-durable work remains locally recoverable.
  After the recovery transaction closes, successful audio is retained by
  default in a separate History library for playback and reprocessing. That
  library is capped at 1 GiB, preserves a 2 GiB free-space reserve, follows the
  History retention setting, and can be disabled or purged. **Never store**
  keeps neither completed History nor successful-audio copies. On iPhone,
  manual in-app recordings are retained after an API failure so Retry can reuse
  them. Shortcut-driven background recordings are deleted after success,
  cancellation, or failure. A hard suspension can interrupt
  normal upload-copy cleanup, so the next iPhone app launch removes only exact
  private `SpeakPaste-upload-<UUID>.multipart` artifacts left by that process.
- macOS transcript History stays on-device, has a 500-entry ordinary cap, and
  supports Never/1/7/30/90-day or forever retention. Recovery-linked proof may
  temporarily exceed that cap rather than be destroyed. Unresolved output
  remains in a private delivery escrow under every retention setting; an entry
  marked possibly delivered is never retried implicitly. A row cannot be edited
  or reprocessed while its source-audio or delivery transaction is open. The
  iPhone history remains capped at 50.
- Optional recognition context reduces a small caret-local window, selection,
  application name, and window title to spelling keyterms before upload. It is
  off by default, never reads secure fields, and does not store the captured
  text in diagnostics. Independently of that setting, cursor-aware local
  formatting may read at most 256 characters before the caret in process memory
  to choose spacing and capitalization. That local text is never uploaded or
  stored, and secure fields remain excluded.
- Full Access lets the keyboard share dictation state with the containing app.
  SpeakPaste does not collect general keystrokes.

Review [ElevenLabs' privacy policy](https://elevenlabs.io/privacy-policy) before
sending sensitive audio.

## Development status

The macOS target builds with local ad-hoc signing. Its floating indicator is a
click-through Liquid Glass depth stack with stable per-dictation cards. Capture
is always frontmost; listening uses a real voice waveform, while every
transcription behind it owns a directional heuristic rail that remains below
completion until that request actually finishes. The oldest card is rearmost,
deeper work collapses into `+N`, and only a verified delivery slides out with its
earcon; overflow and timeout changes simply fold or crossfade. A new hold appears
only as one count-free clipboard-or-tray glyph for two seconds. Recovered and
possibly delivered text stays in the dashboard and is never replayed into the
HUD on launch. The stack has no controls and never presents results, offline
notices, or errors. Each continuously transcribing card is capped at 90 seconds
so a stalled request cannot pin it onscreen; the dashboard and menu bar remain
authoritative. A stuck connecting card is capped at 20 seconds and releasing at
15 seconds. Connecting normally stays visible until
the microphone proves it is delivering a steady sample stream, so
file recording does not begin inside the Continuity wake-up gap; if macOS
refuses the monitoring tap that proves liveness, the connection fails loudly
instead of recording unguarded.
Interrupted startup is retried in place, a stream that dies mid-dictation
salvages its finalized partial file, and recording startup, WAV finalization,
network requests, retry concurrency, and long-session limits are bounded.

The indicator can be anchored at any screen edge without becoming a second
control surface. One bare right-Command tap starts or stops; two taps switch the
persistent Mac/iPhone input mode. A switch during live capture safely finalizes
the current segment, releases its hardware, then resumes as the next ordered
segment on the target source. One Escape cancels connecting or recording
immediately. Its preloaded sound family uses three single pings that rise
through capture, release, and verified delivery, while errors are the family's
only phrase: low and falling. All normal builds that own SpeakPaste's
shared local stores use one product-wide process lease,
independent of bundle identifier; a secondary launch exits without initializing
app data. While the microphone is recording, SpeakPaste prevents idle display
and system sleep, and VoiceOver announces the consequential capture phases.

macOS offers Auto plus all 99 documented Scribe language hints in its settings,
onboarding, and menu-bar picker. It intentionally exposes no provider, model,
realtime, or speed-versus-quality selector: quality-first ElevenLabs Scribe v2
batch transcription is the product.

The current macOS capability set and the features deliberately excluded from
the product are recorded in [the product-parity ledger](docs/macos-feature-parity.md).
Compilation, focused logic tests, and isolated UI inspection do not prove the
system-owned Continuity UI or a real destination application's accessibility
behavior; follow
[the direct-device acceptance run](docs/macos-remaining-work.md) before calling
the complete Mac experience physically verified.

For iPhone:

- Both app and keyboard sources pass focused Swift 6 type-checking against the
  installed iOS SDK.
- The optional Shortcut/Back Tap recording path uses the paired
  `AudioRecordingIntent` and
  `LiveActivityIntent` contracts, with a WidgetKit Live Activity spanning the
  full capture. Its finite post-stop background lane makes one bounded
  25-second Scribe request; expiration cancels it, publishes failure, removes
  the recording, and stops the heartbeat before iOS can suspend the process.
- Launch, host-resolution, audio-stage, shared-session, and return-route
  diagnostics are persisted in the App Group.
- Recorded regressions cover a failed containing-app launch, the invalid
  `.record` / `.spokenAudio` / `.duckOthers` audio configuration, and a generic
  suspension that incorrectly returned to the Home Screen.
- An earlier signed app and embedded-keyboard build was installed on a physical
  iPhone with matching App Group entitlements. The API key survived replacement,
  and microphone permission, keyboard installation, and Full Access were
  exercised.

The primary Notes round trip is physically verified on the iPhone 15 running
iOS 26.5.2. Two consecutive sessions captured `com.apple.mobilenotes` through
the keyboard-arbiter hook, opened `mobilenotes://`, returned automatically, and
ended in the keyboard's `inserted` phase; the second run did not repeat the
first-use explanation. One third-party host, Full Access denial, failure
recovery, and the manual-swipe fallback remain to be exercised before calling
every iPhone path end-to-end verified.

## License

SpeakPaste is available under the [MIT License](LICENSE).
