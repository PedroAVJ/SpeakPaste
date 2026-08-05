#!/bin/sh
# Build, sign, and install the macOS menu-bar app into /Applications.
#
# Xcode's Run button is enough while developing. This script exists for the
# other case: replacing the copy in /Applications with a build of the current
# checkout, without losing the permissions that copy has already been granted.
#
# The repo ships a generic `com.example` identifier on purpose. macOS keys
# microphone and Accessibility grants to the bundle identifier and signature
# together, and keeps per-identifier Application Support state, so a build
# installed under a different identity is a *different app* to the system: no
# permissions, no settings, no enrolled voice profile, and a second SpeakPaste
# in the Accessibility list. Reusing one identity is the whole point of this
# script. It reads the same untracked scripts/local-identity.env the iPhone
# installer uses and never edits tracked files. When running from a Git
# worktree, point SPEAKPASTE_IDENTITY_ENV at the main checkout's copy:
#
#   DEVELOPMENT_TEAM=ABCDE12345
#   APP_BUNDLE_ID=com.you.SpeakPaste      # the iPhone app; see install-iphone.sh
#   MAC_BUNDLE_ID=com.you.SpeakPasteMac   # optional; defaults to ${APP_BUNDLE_ID}Mac
#
# The bundle cannot be replaced underneath a running process, so SpeakPaste is
# asked to quit first and the new build is launched at the end. Quitting also
# lets it release the Continuity-microphone session cleanly rather than having
# it torn away.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

destination=/Applications/SpeakPaste.app

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

if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    echo "error: DEVELOPMENT_TEAM is not set in $env_file" >&2
    exit 1
fi
if [ -z "${MAC_BUNDLE_ID:-}" ]; then
    if [ -z "${APP_BUNDLE_ID:-}" ]; then
        echo "error: set MAC_BUNDLE_ID or APP_BUNDLE_ID in $env_file" >&2
        exit 1
    fi
    MAC_BUNDLE_ID="${APP_BUNDLE_ID}Mac"
fi

# Installing under an identifier the existing copy does not use would leave the
# granted one behind and start from zero. Say so before spending a build.
if [ -d "$destination" ]; then
    installed_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$destination/Contents/Info.plist" 2>/dev/null || echo "")
    if [ -n "$installed_id" ] && [ "$installed_id" != "$MAC_BUNDLE_ID" ]; then
        echo "error: $destination is $installed_id but this run would install $MAC_BUNDLE_ID." >&2
        echo "       Installing anyway would create a second app with no microphone or" >&2
        echo "       Accessibility permission. Set MAC_BUNDLE_ID=$installed_id in $env_file" >&2
        echo "       to keep upgrading the installed copy." >&2
        exit 1
    fi
fi

build_dir=$(mktemp -d /tmp/SpeakPasteMac.XXXXXX)
build_succeeded=false

cleanup() {
    if [ "$build_succeeded" = true ]; then
        rm -rf "$build_dir"
    else
        echo "==> Preserving failed build artifacts at $build_dir" >&2
    fi
}
trap cleanup EXIT

echo "==> Building $MAC_BUNDLE_ID"
xcodebuild \
    -project SpeakPaste.xcodeproj \
    -scheme SpeakPasteMac \
    -configuration Release \
    -derivedDataPath "$build_dir/DerivedData" \
    PRODUCT_BUNDLE_IDENTIFIER="$MAC_BUNDLE_ID" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    build >"$build_dir/build.log" 2>&1 || {
        echo "error: build failed. Last lines:" >&2
        tail -30 "$build_dir/build.log" >&2
        exit 1
    }

app="$build_dir/DerivedData/Build/Products/Release/SpeakPaste.app"
if [ ! -d "$app" ]; then
    echo "error: the build did not produce $app" >&2
    exit 1
fi

# A mismatch here means the override did not take, and installing would orphan
# the permissions the existing copy holds.
built_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
if [ "$built_id" != "$MAC_BUNDLE_ID" ]; then
    echo "error: built $built_id but expected $MAC_BUNDLE_ID" >&2
    exit 1
fi
codesign --verify --strict "$app"
built_team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ "$built_team" != "$DEVELOPMENT_TEAM" ]; then
    echo "error: signed by team ${built_team:-none} but expected $DEVELOPMENT_TEAM" >&2
    exit 1
fi

if pgrep -x SpeakPaste >/dev/null 2>&1; then
    echo "==> Quitting the running SpeakPaste"
    osascript -e 'quit app "SpeakPaste"' >/dev/null 2>&1 || pkill -x SpeakPaste || true
    waited=0
    while pgrep -x SpeakPaste >/dev/null 2>&1; do
        if [ "$waited" -ge 10 ]; then
            echo "error: SpeakPaste is still running; quit it and re-run" >&2
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

# Only ever replace a bundle that is actually this app.
if [ -d "$destination" ]; then
    replaced_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$destination/Contents/Info.plist" 2>/dev/null || echo "")
    if [ "$replaced_id" != "$MAC_BUNDLE_ID" ]; then
        echo "error: refusing to replace $destination (identifier ${replaced_id:-unknown})" >&2
        exit 1
    fi
    rm -rf "$destination"
fi

echo "==> Installing $destination"
cp -R "$app" "$destination"

echo "==> Launching"
open "$destination"

echo "==> Installed"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$destination/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$destination/Contents/Info.plist"

build_succeeded=true
