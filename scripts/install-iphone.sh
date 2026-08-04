#!/bin/sh
# Build, sign, and install the iPhone app and its keyboard on a physical device.
#
# The repo ships generic `com.example` identifiers on purpose. A real device
# needs identifiers owned by a developer account, so this script supplies local
# values through overridable build settings. It never edits tracked files. Put
# your own values in scripts/local-identity.env, which is untracked. When
# running from a Git worktree, point
# SPEAKPASTE_IDENTITY_ENV at the main checkout's copy:
#
#   APP_BUNDLE_ID=com.you.SpeakPaste
#   APP_GROUP=group.com.you.SpeakPaste
#   DEVELOPMENT_TEAM=ABCDE12345
#   SIGNING_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"
#   DEVICE=00000000-0000000000000000        # xcrun devicectl list devices
#   BUILD_NUMBER=2                          # optional; defaults to 1
#
# Two Xcode constraints shape the steps below:
#
#   1. `-scheme` + `-destination` needs the full iOS *platform* installed, not
#      just the SDK. Building the target directly with `-sdk` does not.
#   2. Xcode 26's `actool` refuses to run at all without a simulator runtime
#      ("No available simulator runtimes"), even for a device-only build. The
#      asset catalog is therefore skipped and the app icon is installed the
#      pre-asset-catalog way, with plain PNGs and CFBundleIconFiles.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

env_file=${SPEAKPASTE_IDENTITY_ENV:-scripts/local-identity.env}
if [ ! -f "$env_file" ]; then
    echo "error: $env_file not found. See the header of $0 for its contents." >&2
    exit 1
fi
case "$env_file" in
    /*) ;;
    *) env_file="./$env_file" ;;
esac
# shellcheck disable=SC1090
. "$env_file"

for required in APP_BUNDLE_ID APP_GROUP DEVELOPMENT_TEAM SIGNING_IDENTITY DEVICE; do
    eval "value=\${$required:-}"
    if [ -z "$value" ]; then
        echo "error: $required is not set in $env_file" >&2
        exit 1
    fi
done

build_number=${BUILD_NUMBER:-1}
keyboard_bundle_id=${KEYBOARD_BUNDLE_ID:-$APP_BUNDLE_ID.Keyboard}
live_activity_bundle_id=${LIVE_ACTIVITY_BUNDLE_ID:-$APP_BUNDLE_ID.LiveActivity}
tests_bundle_id=${TESTS_BUNDLE_ID:-${APP_BUNDLE_ID}Tests}
build_dir=$(mktemp -d /tmp/SpeakPasteiOS.XXXXXX)
build_succeeded=false

cleanup() {
    if [ "$build_succeeded" = true ]; then
        rm -rf "$build_dir"
    else
        echo "==> Preserving failed build artifacts at $build_dir" >&2
    fi
}
trap cleanup EXIT

echo "==> Building $APP_BUNDLE_ID ($build_number) for device"
xcodebuild \
    -project SpeakPaste.xcodeproj \
    -target SpeakPaste \
    -configuration Debug \
    -sdk iphoneos \
    CONFIGURATION_BUILD_DIR="$build_dir/Products" \
    OBJROOT="$build_dir/obj" \
    SYMROOT="$build_dir/sym" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$build_number" \
    SPEAKPASTE_APP_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
    SPEAKPASTE_KEYBOARD_BUNDLE_IDENTIFIER="$keyboard_bundle_id" \
    SPEAKPASTE_LIVE_ACTIVITY_BUNDLE_IDENTIFIER="$live_activity_bundle_id" \
    SPEAKPASTE_TESTS_BUNDLE_IDENTIFIER="$tests_bundle_id" \
    SPEAKPASTE_APP_GROUP_IDENTIFIER="$APP_GROUP" \
    EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets \
    ASSETCATALOG_COMPILER_APPICON_NAME= \
    ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME= \
    -allowProvisioningUpdates \
    build >"$build_dir/build.log" 2>&1 || {
        echo "error: build failed. Last lines:" >&2
        tail -30 "$build_dir/build.log" >&2
        exit 1
    }

if grep -q '/usr/bin/actool' "$build_dir/build.log"; then
    echo "error: the device-only build unexpectedly invoked actool" >&2
    exit 1
fi

app="$build_dir/Products/SpeakPaste.app"
icons="SpeakPaste/Assets.xcassets/AppIcon.appiconset"

echo "==> Installing app icon without the asset catalog"
for pair in "60@2x:AppIcon60x60@2x" "60@3x:AppIcon60x60@3x" \
            "40@2x:AppIcon40x40@2x" "40@3x:AppIcon40x40@3x" \
            "29@2x:AppIcon29x29@2x" "29@3x:AppIcon29x29@3x" \
            "20@2x:AppIcon20x20@2x" "20@3x:AppIcon20x20@3x"; do
    source_name=${pair%%:*}
    dest_name=${pair##*:}
    cp "$icons/AppIcon-${source_name}.png" "$app/${dest_name}.png"
done

if [ -e "$app/Assets.car" ]; then
    echo "error: the device-only build unexpectedly produced Assets.car" >&2
    exit 1
fi

plist="$app/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" >/dev/null
for name in AppIcon60x60 AppIcon40x40 AppIcon29x29 AppIcon20x20; do
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles: string $name" \
        "$plist" >/dev/null
done

actual_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
actual_build_number=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
if [ "$actual_bundle_id" != "$APP_BUNDLE_ID" ] || \
   [ "$actual_build_number" != "$build_number" ]; then
    echo "error: built identity does not match the requested app" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFiles" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles array" "$plist" >/dev/null
for name in AppIcon60x60 AppIcon40x40 AppIcon29x29 AppIcon20x20; do
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIconFiles: string $name" \
        "$plist" >/dev/null
done

# Editing the bundle invalidated the signature Xcode applied. Re-seal it with
# the entitlements the build already resolved, so the App Group survives.
echo "==> Re-signing"
codesign -d --entitlements "$build_dir/app.entitlements" --xml "$app" 2>/dev/null
codesign -f -s "$SIGNING_IDENTITY" \
    --entitlements "$build_dir/app.entitlements" \
    --generate-entitlement-der "$app" >/dev/null 2>&1
codesign --verify --deep --strict "$app"

echo "==> Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$app" | tail -5

# A Mac cannot write to the device Keychain. Launch the debug build once with
# the key in its environment so it can store the key itself. DEVICECTL_CHILD_
# keeps the value out of the command line, and nothing prints it.
if [ -n "${ELEVENLABS_API_KEY:-}" ]; then
    echo "==> Seeding the ElevenLabs key into the device Keychain"
    if DEVICECTL_CHILD_ELEVENLABS_API_KEY="$ELEVENLABS_API_KEY" \
        xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$APP_BUNDLE_ID" >"$build_dir/launch.log" 2>&1; then
        echo "    seeded"
    else
        echo "    installed; unlock the iPhone and open SpeakPaste to finish launch"
    fi
else
    echo "==> Launching"
    if ! xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$APP_BUNDLE_ID" >"$build_dir/launch.log" 2>&1; then
        echo "    installed; unlock the iPhone and open SpeakPaste to finish launch"
    fi
fi

echo "==> Verifying installed build"
xcrun devicectl device info apps \
    --device "$DEVICE" \
    --bundle-id "$APP_BUNDLE_ID" \
    --columns '*' | tail -2

build_succeeded=true
