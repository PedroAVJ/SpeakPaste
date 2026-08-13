#!/bin/zsh
set -euo pipefail

for required in ipatool jq unzip shasum; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "Required command is unavailable: $required" >&2
    exit 1
  fi
done

ipatool_bin="$(command -v ipatool)"
output_dir="${SPEAKPASTE_REFERENCE_IPA_DIR:-$HOME/Library/Application Support/SpeakPaste/ReferenceIPAs}"
mkdir -p "$output_dir"
chmod 700 "$output_dir"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/speakpaste-reference-download.XXXXXX")"
cleanup() {
  [[ -n "$work_dir" && -d "$work_dir" ]] && rm -rf -- "$work_dir"
}
trap cleanup EXIT

if ! "$ipatool_bin" auth info --format json --non-interactive > "$work_dir/auth-info.json"; then
  cat >&2 <<'MESSAGE'
The saved App Store session is unavailable or expired.
Run `ipatool auth login` interactively in Terminal, then rerun this script.
This downloader never reads or passes your Apple ID password itself.
MESSAGE
  exit 1
fi

download_latest() {
  local file_prefix="$1"
  local app_id="$2"
  local versions_file="$work_dir/$file_prefix-versions.json"

  "$ipatool_bin" list-versions \
    --app-id "$app_id" \
    --format json \
    --non-interactive \
    > "$versions_file"

  local external_version_id
  external_version_id="$(jq -er '.externalVersionIdentifiers[-1]' "$versions_file")"

  local metadata_file="$work_dir/$file_prefix-metadata.json"
  "$ipatool_bin" get-version-metadata \
    --app-id "$app_id" \
    --external-version-id "$external_version_id" \
    --format json \
    --non-interactive \
    > "$metadata_file"

  local catalog_version
  catalog_version="$(jq -er '.displayVersion' "$metadata_file")"
  local temporary_ipa="$work_dir/$file_prefix-$catalog_version.ipa"

  echo "Downloading $file_prefix $catalog_version..."
  "$ipatool_bin" download \
    --app-id "$app_id" \
    --external-version-id "$external_version_id" \
    --platform iphone \
    --purchase \
    --output "$temporary_ipa" \
    --format json \
    --non-interactive \
    > "$work_dir/$file_prefix-download.json"

  local unpacked_dir="$work_dir/$file_prefix-unpacked"
  mkdir -p "$unpacked_dir"
  unzip -q "$temporary_ipa" -d "$unpacked_dir"

  local app_bundle
  app_bundle="$(find "$unpacked_dir/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
  if [[ -z "$app_bundle" ]]; then
    echo "The downloaded archive has no application bundle." >&2
    return 1
  fi

  local embedded_version
  local embedded_build
  embedded_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
  embedded_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Info.plist")"
  if [[ "$embedded_version" != "$catalog_version" ]]; then
    echo "Catalog version $catalog_version does not match embedded version $embedded_version." >&2
    return 1
  fi

  local final_ipa="$output_dir/$file_prefix-$embedded_version-build$embedded_build.ipa"
  install -m 600 "$temporary_ipa" "$final_ipa"
  shasum -a 256 "$final_ipa"
}

download_latest "WisprFlow" "6497229487"
download_latest "Superwhisper" "6471464415"

echo "Latest reference IPAs are saved in: $output_dir"
