# iPhone keyboard dictation round-trip specification

This specification is grounded in screen recordings and validation screenshots
captured on an iPhone 15 running iOS 26.5.2. The media is hosted outside the
repository and linked below; the SHA-256 of each file is recorded here so a
download can be checked against the artifact this document was written from.
Only the reference recording defines acceptance — the rest are reproductions of
defects that have since been fixed, kept for comparison rather than as
requirements.

## Evidence

### Reference: Wispr Flow 1.67 in Notes

[Watch the reference recording](https://storage.googleapis.com/pedro-app-storage-20260801-public/speakpaste-spec-evidence/wispr-flow-notes-roundtrip-2026-08-02.mp4)

- File: `wispr-flow-notes-roundtrip-2026-08-02.mp4`
- Duration: 13.113 seconds
- Resolution: 1180 × 2556 at 60 fps
- SHA-256: `3bcb1a85d225ea8a3908de281dd799b42fb1ea4e21787b27950c14eaa6546de1`

Observed sequence:

1. Notes owns the insertion point and the user selects the Wispr Flow keyboard.
2. The keyboard displays a normal typing layout with a prominent **Start** action.
3. Tapping **Start** foregrounds the Flow containing app; this is a real app
   transition, not a panel drawn inside the keyboard.
4. Recording starts in the containing app.
5. On first use, Flow presents its own one-time explanation: it will return to
   the previous app and iOS may ask for confirmation the first time it opens a
   new app. Recording continues while this explanation is visible.
6. After **OK**, the system transitions back to Notes without a manual home-bar
   swipe.
7. The Flow keyboard displays an active listening UI while the containing app
   continues owning the recording session in the background.
8. Finishing dictation changes the keyboard to processing, inserts `hello` at
   the existing Notes cursor, then restores the typing layout.

The recording proves the user-visible transitions and continuity of the
recording. It does **not** reveal Wispr's private implementation or prove which
specific URL-opening API it calls.

### Regression: SpeakPaste does not leave Notes

[Watch the failing SpeakPaste recording](https://storage.googleapis.com/pedro-app-storage-20260801-public/speakpaste-spec-evidence/speakpaste-launch-failure-2026-08-02.mp4)

- File: `speakpaste-launch-failure-2026-08-02.mp4`
- Duration: 11.648 seconds
- Resolution: 1180 × 2556 at 60 fps
- SHA-256: `8a2e62b6e6877b3c8bb5688e4ea81ad9b31bc9157334ca0444574ec8de6d3ac2`

Observed failure:

1. The SpeakPaste keyboard loads correctly in Notes.
2. Tapping **Start** changes the extension to **Opening SpeakPaste…**.
3. Notes remains foregrounded for the rest of the recording. The SpeakPaste
   containing app never appears and recording never starts.

The on-device App Group snapshot from that attempt remained in `launching` and
contained no return application identifier. This establishes that the defect is
the keyboard-to-containing-app launch, before microphone setup or switchback.

### Regression: app opens, then audio setup fails

[View the resulting keyboard error](https://storage.googleapis.com/pedro-app-storage-20260801-public/speakpaste-spec-evidence/speakpaste-audio-session-error-2026-08-02.png)
and [inspect the matching App Group state](https://storage.googleapis.com/pedro-app-storage-20260801-public/speakpaste-spec-evidence/speakpaste-audio-session-error-2026-08-02.json).

- Screenshot: `speakpaste-audio-session-error-2026-08-02.png`
- Resolution: 1179 × 2556
- Screenshot SHA-256: `9c59df11ea5982c520a2d7be8a212ab4f01ce7586d5a85cbe12a103fe6071883`
- App Group state SHA-256: `17fc6db594466fddf5a0e4291568780224d9c4ae719c34bad9ad409fe03e45a3`
- Session: `219ADC07-940B-4867-BE10-B81424B466BE`

This test was run after the responder-chain launch fix. The containing app did
open, but it did not automatically return to Notes. When the user returned to
Notes, the keyboard showed `OSStatus error -50`.

The matching shared-state snapshot records `responder-scene:true`, a successful
`scene` launch route, and a transition from start to failure in about 160 ms. It
contains no return bundle identifier. This separates two remaining defects:

1. audio-session configuration fails immediately after the app opens; and
2. SpeakPaste has not captured a host-app identifier for automatic switchback.

The screenshot does **not** prove an automatic switchback occurred; the user
returned to Notes manually. It does prove the extension received and rendered
the containing app's failure state through the App Group.

### Regression: the system-navigation response also lands on the Home Screen

[Watch the failing return recording](https://storage.googleapis.com/pedro-app-storage-20260801-public/speakpaste-spec-evidence/speakpaste-return-landed-home-2026-08-02.mp4)

- File: `speakpaste-return-landed-home-2026-08-02.mp4`
- Duration: 6.755 seconds
- Resolution: 1180 × 2556 at 60 fps
- SHA-256: `bc42c1e74daa5e2603b1813a4f71f039652bda24719c49b8af566daca7e2fa02`

This run exercised the responder-chain launch fix plus the `UISystemNavigationAction`
return route. Observed sequence:

1. Notes owns the insertion point and the user selects the SpeakPaste keyboard.
2. Tapping **Start** foregrounds SpeakPaste, which reaches the `Recording`
   state. Launch and microphone setup both succeed.
3. Roughly half a second later SpeakPaste plays the Home Screen suspend
   animation and the phone lands on the Home Screen rather than Notes. The
   orange microphone indicator stays lit, so capture survives the transition.
4. The one-time switchback explanation does not appear, because it was already
   confirmed in an earlier session.

The containing app's own data container shows the app was installed shortly
before this attempt, so the recording exercises the current implementation and
not a stale build. Because the app backgrounded rather than staying foreground
with the manual-return hint, the return was reported as successful; the only
route that can background SpeakPaste without foregrounding another app is the
system-navigation response.

The status bar is decisive about why. Throughout the SpeakPaste segment the
clock renders normally and no back-to-app breadcrumb is present, so SpringBoard
never constructed a destination pointing at Notes. Destination `0` nevertheless
existed and accepted a response, and `canSendPrimaryResponse` only required that
`0` be present. **The existence of destination `0` is not evidence that it leads
anywhere.** A launch that originates in a keyboard extension has no previous
application scene, so the primary destination resolves to the Home Screen — the
same destination the excluded `suspendReturningToLastApp:` route produced, for
the same underlying reason.

The response is a strict one-shot value that cannot be inspected or undone after
sending, so the destination must be identified *before* it is consumed.
SpeakPaste therefore resolves destination `0` through
`bundleIdForDestination:`, falling back to the scheme of `URLForDestination:`,
and sends the response only when that names a real application other than
SpeakPaste and, when the host is known, matches it. An unidentified or
mismatched destination is left unsent and recorded as
`system-navigation-destination-unconfirmed`, and the known host URL scheme
carries the return instead.

### Regression: generic suspension returns to the Home Screen

[View the Home Screen result](https://storage.googleapis.com/pedro-app-storage-20260801-public/speakpaste-spec-evidence/speakpaste-suspend-returned-home-2026-08-02.png).

- Screenshot: `speakpaste-suspend-returned-home-2026-08-02.png`
- Resolution: 1179 × 2556
- SHA-256: `28741caa9c3dd7ceb0cf432a9c5584d2b267209ac8aa97af5581fecadbead75f`

After recording started successfully, SpeakPaste invoked the feature-detected
private `UIApplication.suspendReturningToLastApp(true)` route. On Pedro's iOS
26.5.2 device this suspended SpeakPaste to the Home Screen instead of restoring
Notes. The orange microphone indicators show that audio capture remained active
during the transition, but the destination was wrong. This route is therefore
not an acceptable implementation of automatic switchback on the test device.

## Required behavior

The reference recording is the acceptance target for the round-trip:

1. **Start is a direct user gesture.** It creates one shared session and sends
   one launch request. Repeated taps must not create overlapping sessions.
2. **The containing app actually foregrounds.** The keyboard must not call a
   launch attempt successful merely because an Objective-C selector exists.
3. **The app owns recording.** Microphone authorization and audio capture occur
   in SpeakPaste, not in the keyboard extension.
4. **First use is explained once.** After recording starts, SpeakPaste presents
   a one-time explanation before its first automatic return.
5. **Switchback is automatic.** SpeakPaste returns to the host app while keeping
   the audio session active. A manual home-bar swipe is fallback behavior only.
6. **Keyboard state follows shared state.** It shows listening, processing,
   failure, and normal typing states from the App Group session.
7. **The transcript is inserted at the active cursor.** Successful completion
   inserts exactly once at the cursor where the user taps Stop and returns the
   keyboard to its normal layout. A harmless `nil`/empty proxy transition or a
   deliberate cursor move must not add a second confirmation tap.
8. **Failures are diagnosable.** Every launch route and its actual Boolean result
   are persisted in the shared session so a device-only failure is actionable.
   Audio failures must also identify the failed setup stage rather than exposing
   only a raw `OSStatus` value. The App Group container cannot be listed over
   `devicectl`, so each process also mirrors the session — minus the dictated
   text, which is replaced by its character count — to
   `Documents/last-dictation-session.json` in its own container. Read the
   containing app's copy with:

   ```sh
   xcrun devicectl device copy from \
     --device <device> \
     --domain-type appDataContainer \
     --domain-identifier com.pedro.SpeakPaste \
     --source Documents/last-dictation-session.json \
     --destination .
   ```

## Implementation contract

On iOS 18 and later, the URL-capable object in a keyboard's responder chain can
be either `UIScene` or `UIApplication`. Their `open` methods accept different
option types. SpeakPaste must cast the responder to its real UIKit class, call
the matching typed API, and use the asynchronous completion result. Passing an
`UIApplication` options dictionary to a `UIScene` selector is invalid even
though Objective-C dispatch may accept the call without crashing.

Launch order:

1. Typed responder-chain `UIScene.open`, or `UIApplication.open` when that is
   the responder.
2. The public `NSExtensionContext.open` method as a best-effort fallback. Apple
   does not document custom keyboards as an extension point that can open
   arbitrary URLs, so its asynchronous result must be treated as authoritative.
3. Direct containing-bundle activation only as a final fallback for this
   private sideload.

When the containing app receives the deep link, it starts the matching pending
session. If UIKit supplies a source application identifier, SpeakPaste records
it as a possible fallback target.

The containing app receives keyboard deep links through a `UISceneDelegate`,
not only SwiftUI's `onOpenURL`, so it can preserve the `UIOpenURLContext`
metadata for diagnostics. Apple restricts its source application identifier to
origins signed by the same team, so Notes-to-SpeakPaste delivery correctly
reports `nil` and cannot be the general switchback solution. Both cold-start URL
contexts and URLs delivered to an existing scene must follow the same path.

### Wispr-style iOS 26.4+ return

The generic `UISystemNavigationAction` experiment is excluded from the current
implementation. On the test phone it accepted the primary destination but sent
SpeakPaste to the Home Screen, so its Boolean result did not identify or prove a
return to Notes.

The replacement is based on direct inspection of the signed Wispr Flow 1.67,
build 1313 app package. Its exact `LSApplicationQueriesSchemes` value is a fixed
50-entry allowlist that includes `mobilenotes`, `chatgpt`, `whatsapp`, `slack`,
and other supported apps. Exported Swift symbols include:

- `FlowCore.AppInfo.launchURLScheme` and `appInfo(bundleID:)`;
- `FlowCore.KeyboardSwitchBackScene.url(from:hostBundleID:)` and
  `hostBundleID(from:)`;
- `Keyboard.KeyboardInputViewController.legacyHostAppBundleID()`; and
- presentation and behavior checks parameterized by whether an app supports a
  URL scheme.

The app and framework binaries have FairPlay encryption enabled, so those facts
establish the architecture but do not expose Wispr's method bodies. SpeakPaste
implements the same observable shape:

1. An Objective-C `+load` hook installs before the keyboard view controller.
2. On iOS 26.4+, it enables `_UIKeyboardArbiterClient` and intercepts
   `_UIKeyboardArbiterClientInputDestination`'s
   `queue_keyboardChanged:onComplete:` callback.
3. It reads the callback object's `_sourceBundleIdentifier`, rejects system
   brokers and SpeakPaste itself, then caches the host bundle identifier.
4. After the keyboard is visible, it retries the lazily initialized arbiter for
   a bounded interval instead of treating one early `nil` as final. The Start
   control is briefly disabled while this preflight runs, so the eventual tap
   synchronously resolves and creates one session, then initiates one launch
   task without waiting on host detection.
5. A successful capture is persisted as an exact bundle identifier, host PID,
   and timestamp in the App Group. A later extension process may reuse it only
   as the last fallback, for at most 60 seconds, while the PID still matches; a
   bundle without the matching PID is never trusted. Process-local capture is
   accepted from the first process-load focus callback or when its generation
   postdates the prior host's clean invalidation boundary and the new host PID
   stayed stable. A previous host's bundle is quarantined when the PID changes,
   and process-local capture is invalidated when the keyboard leaves its host.
6. The keyboard writes the resolved identifier to the shared session before
   opening the containing app.
7. The containing app maps only supported bundle identifiers through its fixed
   catalog. This personal sideload first activates the exact captured bundle
   directly, avoiding iOS's custom-URL confirmation sheet. The cataloged URL
   scheme and `UIApplication.open` remain a fallback.
8. A missing host, an unsupported host, or failure of both activation routes
   keeps recording alive and shows the manual home-bar swipe.

The host-capture technique is adapted from the MIT-licensed
`KeyboardHostBundleID` project, with its notice retained in
`THIRD_PARTY_NOTICES.md`. It is a private UIKit dependency suitable for this
personal sideload, not an App Store-safe contract.

The recording session uses an input-only audio category without playback-only
options. In particular, it must not combine `.record` with `.duckOthers`; that
combination is invalid and produced the `OSStatus -50` evidence above.

### Removed generic and scene-identity routes

The generic private `suspendReturningToLastApp:` route is excluded from the
implementation. It returned the test phone to the Home Screen and its `Void`
return value cannot establish that the intended host opened.

An earlier private diagnostic build probed the exact iOS 26.5
class method
`+[_UIKeyboardArbiterClient keyboardClientFBSSceneIdentityStringOrIdentifierFromScene:]`
before it opens SpeakPaste. Runtime inspection of the device's UIKitCore binary
established that the method accepts a scene and returns either an FBS identity
token's string representation or the scene identifier. That value is a **scene
identity, not an application bundle identifier**.

The probe therefore:

- accepts only the observed three-argument object/object Objective-C signature;
- calls only real `UIScene` objects that expose both `_FBSScene` and
  `_sceneIdentifier`, preferring the scene returned by `_settingsScene`;
- records raw and percent-decoded scene identities before leaving the keyboard;
- records the FBS host/client process identity values when they are exposed;
- maps a scene identity only to a fixed, known host allowlist instead of passing
  a value such as `com.apple.mobilenotes-default` to a bundle launcher; and
- fails back to the existing manual return UI when the result is missing,
  ambiguous, or unknown.

That probe remains useful failure evidence, but it is not the return route now.
For Notes, the current hook must capture `com.apple.mobilenotes` directly. The
static catalog then attempts that exact bundle as `host-bundle:true` or
`host-bundle:false`; only a failed direct attempt falls through to
`mobilenotes://` and the `host-url` diagnostics.

## Device acceptance matrix

Before the round-trip is called complete, exercise these actions directly on
the phone:

- Notes: first launch, explanation, automatic return, stop, and insertion.
  **Verified on iPhone 15/iOS 26.5.2.**
- Notes: a second launch without the one-time explanation. **Verified.**
- At least one third-party host such as ChatGPT or WhatsApp.
- The first third-party attempt immediately after installing a build or
  restarting the keyboard extension; it must not depend on a warmed process.
- Switching from Notes to that third-party host in the same keyboard process;
  the persisted PID guard must prevent a stale Notes return.
- Microphone permission denied, then enabled.
- Full Access disabled.
- Cancel while recording.
- Transcription failure and retry.
- Unknown return target, confirming the manual-swipe fallback remains usable.

Two consecutive Notes runs now satisfy the core acceptance path. Sessions
`501FE8BC-816D-48ED-90BD-1A4EF0FE53CB` and
`7575AD2D-DA7C-48D1-9DEB-57AD11A0C3CB` both reported
`arbiter-hook-status:installed`,
`arbiter-hook-cached:com.apple.mobilenotes`,
`return-target-shared-bundle:com.apple.mobilenotes`,
`host-catalog:com.apple.mobilenotes`, and `host-url:true`. Both keyboard-side
mirrors ended at `phase: inserted`; the second run did not show the first-use
explanation.
