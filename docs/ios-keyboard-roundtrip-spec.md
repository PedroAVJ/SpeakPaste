# iPhone keyboard dictation round-trip specification

This specification is grounded in two screen recordings and one validation
screenshot captured on Pedro's iPhone 15 running iOS 26.5.2. The media and its
matching diagnostic state are versioned beside this document so later
implementation work can be compared with the original behavior rather than
relying on a prose recollection.

## Evidence

### Reference: Wispr Flow 1.67 in Notes

[Watch the reference recording](spec-evidence/wispr-flow-notes-roundtrip-2026-08-02.mp4)

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

[Watch the failing SpeakPaste recording](spec-evidence/speakpaste-launch-failure-2026-08-02.mp4)

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

[View the resulting keyboard error](spec-evidence/speakpaste-audio-session-error-2026-08-02.png)
and [inspect the matching App Group state](spec-evidence/speakpaste-audio-session-error-2026-08-02.json).

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

### Regression: generic suspension returns to the Home Screen

[View the Home Screen result](spec-evidence/speakpaste-suspend-returned-home-2026-08-02.png).

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
7. **The transcript is inserted at the original cursor.** Successful completion
   inserts exactly once and returns the keyboard to its normal layout.
8. **Failures are diagnosable.** Every launch route and its actual Boolean result
   are persisted in the shared session so a device-only failure is actionable.
   Audio failures must also identify the failed setup stage rather than exposing
   only a raw `OSStatus` value.

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
2. `NSExtensionContext.open` as the supported extension fallback.
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

### iOS 26.5 system-navigation return

The primary return path uses the live `UISystemNavigationAction` attached to
`UIApplication`. This is the same system mechanism that backs the status-bar
breadcrumb, not a guessed application identifier. Inspection of the exact
iPhone 15 iOS 26.5.2 UIKitCore, BaseBoard, and SpringBoard binaries established
the following contract:

- `UIApplication._systemNavigationAction` uses the object-returning encoding
  `@16@0:8`;
- `isValid` and `canSendResponse` use `B16@0:8`;
- `destinations` returns an array of `NSNumber` destination values;
- destination `0` is SpringBoard's primary/back destination, constructed from
  the previous application scene; destination `1` is secondary/forward;
- destination metadata methods use `@24@0:8Q16`; and
- `sendResponseForDestination:` uses `B24@0:8Q16` and consumes a strict
  one-shot BaseBoard response.

SpeakPaste resolves each selector through the Objective-C runtime and invokes
its IMP only when the exact encoding matches. Immediately before sending, it
re-fetches the current action, requires a real `UISystemNavigationAction`,
`isValid == true`, `canSendResponse == true`, and destination `0`, and marks the
object identity attempted before entering the response method. It never creates
or reuses an action and never substitutes an `NSNumber` for the scalar
destination argument.

A `true` response means the destination existed and BaseBoard accepted the
response; by itself it does not prove the visible transition completed.
SpeakPaste therefore installs a scene-specific background observer before
sending and accepts the system route only if its foreground scene enters the
background within the short transition window. Otherwise it proceeds to a known public host URL and,
for this private sideload only, bundle activation. If no fallback host is known,
the manual home-bar instruction remains available.

UIKit invalidates a replaced action and clears it when the app backgrounds, so
retaining an earlier object cannot preserve the capability. SpeakPaste probes
at launch, URL delivery, activation, and the action-changed notification for
diagnostics, but always uses the live object at send time.

These private selectors are an implementation choice for SpeakPaste's personal
sideload. The reference recording proves Wispr's behavior, not that Wispr uses
the same APIs.

The recording session uses an input-only audio category without playback-only
options. In particular, it must not combine `.record` with `.duckOthers`; that
combination is invalid and produced the `OSStatus -50` evidence above.

### iOS 26.5 scene-identity probe

The generic private `suspendReturningToLastApp:` route is excluded from the
implementation. It returned the test phone to the Home Screen and its `Void`
return value cannot establish that the intended host opened.

For this private diagnostic build, the keyboard now probes the exact iOS 26.5
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

For Notes, a direct host-process bundle value or a structurally bounded scene
component beginning `com.apple.mobilenotes-` maps to the fixed bundle
`com.apple.mobilenotes`. That mapping is now a fallback after the system
breadcrumb response. If reached, the fallback uses `mobilenotes://` and
persists its actual asynchronous Boolean result as `host-url:true` or
`host-url:false`. The scene probe remains a controlled on-device hypothesis,
not evidence that Wispr uses the same private method.

## Device acceptance matrix

Before the round-trip is called complete, exercise these actions directly on
the phone:

- Notes: first launch, explanation, automatic return, stop, and insertion.
- Notes: a second launch without the one-time explanation.
- At least one third-party host such as ChatGPT or WhatsApp.
- Microphone permission denied, then enabled.
- Full Access disabled.
- Cancel while recording.
- Transcription failure and retry.
- Unknown return target, confirming the manual-swipe fallback remains usable.

The next validation is intentionally one focused Notes run: open a fresh Notes
cursor, select SpeakPaste, tap Start once, accept the one-time explanation if it
appears, and record whether the destination is Notes, Home, or SpeakPaste. Keep
the resulting shared session intact until its host-resolution and return
diagnostics have been copied. The decisive fields are whether a live action
exposed destination `0`, whether its response returned `true`, whether
SpeakPaste observed its scene enter the background, and whether a URL fallback
ran.
