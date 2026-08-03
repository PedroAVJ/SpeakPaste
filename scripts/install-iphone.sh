#!/bin/sh
# Build, sign, and install the iPhone app and its keyboard on a physical device.
#
# The repo ships generic `com.example` identifiers on purpose. A real device
# needs identifiers owned by a developer account, so this script applies local
# values to the tracked files, builds, and restores the originals afterward --
# including on failure. Put your own values in scripts/local-identity.env,
# which is untracked:
#
#   APP_BUNDLE_ID=com.you.SpeakPaste
#   APP_GROUP=group.com.you.SpeakPaste
#   DEVELOPMENT_TEAM=ABCDE12345
#   SIGNING_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"
#   DEVICE=00000000-0000000000000000        # xcrun devicectl list devices
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

env_file="scripts/local-identity.env"
if [ ! -f "$env_file" ]; then
    echo "error: $env_file not found. See the header of $0 for its contents." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "./$env_file"

for required in APP_BUNDLE_ID APP_GROUP DEVELOPMENT_TEAM SIGNING_IDENTITY DEVICE; do
    eval "value=\${$required:-}"
    if [ -z "$value" ]; then
        echo "error: $required is not set in $env_file" >&2
        exit 1
    fi
done

build_dir=$(mktemp -d /tmp/SpeakPasteiOS.XXXXXX)
backup_dir=$(mktemp -d /tmp/SpeakPasteIdentity.XXXXXX)

patched="SpeakPaste.xcodeproj/project.pbxproj
SpeakPaste/SpeakPaste.entitlements
SpeakPasteKeyboard/SpeakPasteKeyboard.entitlements
SpeakPaste/SharedDictation.swift"

restore() {
    echo "$patched" | while read -r file; do
        [ -n "$file" ] || continue
        if [ -f "$backup_dir/$(basename "$file")" ]; then
            cp "$backup_dir/$(basename "$file")" "$file"
        fi
    done
    rm -rf "$backup_dir"
    echo "==> Repo identifiers restored"
}
trap restore EXIT

echo "$patched" | while read -r file; do
    [ -n "$file" ] || continue
    cp "$file" "$backup_dir/$(basename "$file")"
done

echo "==> Applying local identity ($APP_BUNDLE_ID, $APP_GROUP)"
sed -i '' "s/com\.example\.SpeakPaste/${APP_BUNDLE_ID}/g" \
    SpeakPaste.xcodeproj/project.pbxproj
sed -i '' "s/group\.com\.example\.SpeakPaste/${APP_GROUP}/g" \
    SpeakPaste/SpeakPaste.entitlements \
    SpeakPasteKeyboard/SpeakPasteKeyboard.entitlements \
    SpeakPaste/SharedDictation.swift

echo "==> Building for device"
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
    EXCLUDED_SOURCE_FILE_NAMES='*.xcassets' \
    -allowProvisioningUpdates \
    build >"$build_dir/build.log" 2>&1 || {
        echo "error: build failed. Last lines:" >&2
        tail -30 "$build_dir/build.log" >&2
        exit 1
    }

app="$build_dir/Products/SpeakPaste.app"
icons="SpeakPaste/Assets.xcassets/AppIcon.appiconset"

echo "==> Installing app icon without the asset catalog"
for pair in "60@2x:AppIcon60x60@2x" "60@3x:AppIcon60x60@3x" \
            "40@2x:AppIcon40x40@2x" "40@3x:AppIcon40x40@3x" \
            "29@2x:AppIcon29x29@2x" "29@3x:AppIcon29x29@3x"; do
    source_name=${pair%%:*}
    dest_name=${pair##*:}
    cp "$icons/AppIcon-${source_name}.png" "$app/${dest_name}.png"
done

plist="$app/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" >/dev/null
for name in AppIcon60x60 AppIcon40x40 AppIcon29x29; do
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles: string $name" \
        "$plist" >/dev/null
done

# Editing the bundle invalidated the signature Xcode applied. Re-seal it with
# the entitlements the build already resolved, so the App Group survives.
echo "==> Re-signing"
codesign -d --entitlements "$build_dir/app.entitlements" --xml "$app" 2>/dev/null
codesign -f -s "$SIGNING_IDENTITY" \
    --entitlements "$build_dir/app.entitlements" \
    --generate-entitlement-der "$app" >/dev/null 2>&1
codesign --verify --strict "$app"

echo "==> Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$app" | tail -5

# A Mac cannot write to the device Keychain. Launch the debug build once with
# the key in its environment so it can store the key itself. DEVICECTL_CHILD_
# keeps the value out of the command line, and nothing prints it.
if [ -n "${ELEVENLABS_API_KEY:-}" ]; then
    echo "==> Seeding the ElevenLabs key into the device Keychain"
    DEVICECTL_CHILD_ELEVENLABS_API_KEY="$ELEVENLABS_API_KEY" \
        xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$APP_BUNDLE_ID" >/dev/null 2>&1 \
        && echo "    seeded" \
        || echo "    launch failed; open SpeakPaste and add the key in Settings"
else
    echo "==> ELEVENLABS_API_KEY not set; skipping Keychain seed"
fi
