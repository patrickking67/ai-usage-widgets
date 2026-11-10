#!/usr/bin/env bash
# Build, sign, notarize and package TokenMeter for macOS.
#
#   scripts/release-macos.sh                 signed, notarized, stapled DMG and zip in dist/
#   scripts/release-macos.sh --no-notarize   signed only (local smoke test; Gatekeeper will warn)
#
# Needs, once per Mac:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. A notarytool keychain profile, created with an app-specific password or an
#      App Store Connect API key. The secret goes into the keychain, never into this repo:
#        xcrun notarytool store-credentials tokenmeter-notary \
#          --apple-id you@example.com --team-id ABCDE12345
#   3. DEVELOPMENT_TEAM in apps/macos/Config/Local.xcconfig, or exported in the environment.
#
# Environment overrides:
#   NOTARY_PROFILE   keychain profile name (default tokenmeter-notary)
#   SIGN_IDENTITY    codesign identity (default "Developer ID Application")
#   NOTARY_KEYCHAIN  keychain holding the profile (CI uses a temporary one)
#
# Nothing here prints or stores a credential. Output lands in dist/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

notarize=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) notarize=0 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 ($2)"; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
need xcodegen "brew install xcodegen"
need xcodebuild "install Xcode"

profile=${NOTARY_PROFILE:-tokenmeter-notary}
identity=${SIGN_IDENTITY:-Developer ID Application}
keychain_args=()
[ -n "${NOTARY_KEYCHAIN:-}" ] && keychain_args=(--keychain "$NOTARY_KEYCHAIN")

team=${DEVELOPMENT_TEAM:-}
if [ -z "$team" ] && [ -f apps/macos/Config/Local.xcconfig ]; then
  team=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' apps/macos/Config/Local.xcconfig | head -n 1)
fi
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "set DEVELOPMENT_TEAM (10-character team ID) in apps/macos/Config/Local.xcconfig or the environment"

security find-identity -v -p codesigning | grep -q "\"$identity: .*($team)\"" \
  || die "no \"$identity\" certificate for team $team in the keychain. Create one in Xcode > Settings > Accounts > Manage Certificates."

version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' apps/macos/project.yml | head -n 1)
[ -n "$version" ] || die "could not read MARKETING_VERSION from apps/macos/project.yml"
build=${BUILD_NUMBER:-$(git rev-list --count HEAD)}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dist="$root/dist"
rm -rf "$dist"; mkdir -p "$dist"
archive="$work/TokenMeter.xcarchive"
export_dir="$work/export"
app="$export_dir/TokenMeter.app"
name="TokenMeter-$version"

step "Generate project"
(cd apps/macos && xcodegen generate --quiet)

step "Archive $version ($build)"
xcodebuild -project apps/macos/TokenMeter.xcodeproj -scheme TokenMeter -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath "$work/dd" \
  DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build" -quiet archive

step "Export with $identity"
cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$identity</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$work/ExportOptions.plist" -quiet

step "Verify signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -E '^(Authority=Developer ID Application|TeamIdentifier|Runtime Version|Timestamp)' \
  || die "app is not signed with Developer ID, hardened runtime and a secure timestamp"
for bundle in "$app" "$app/Contents/PlugIns/TokenMeterWidget.appex"; do
  if codesign -d --entitlements - --xml "$bundle" 2>/dev/null | grep -q 'get-task-allow'; then
    die "$bundle carries get-task-allow; a debug-signed build would be rejected by notarization"
  fi
done

submit() {
  xcrun notarytool submit "$1" --keychain-profile "$profile" "${keychain_args[@]}" --wait --timeout 30m \
    --output-format json > "$work/notary.json" || true
  status=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$work/notary.json" 2>/dev/null || true)
  if [ "$status" != "Accepted" ]; then
    id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$work/notary.json" 2>/dev/null || true)
    echo "notarization status: ${status:-unknown}" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" "${keychain_args[@]}" >&2 || true
    die "notarization failed for $(basename "$1")"
  fi
  echo "accepted"
}

if [ "$notarize" = 1 ]; then
  step "Notarize app"
  ditto -c -k --keepParent "$app" "$work/notarize.zip"
  submit "$work/notarize.zip"
  xcrun stapler staple "$app"
fi

step "Package"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$name.zip"
dmg_src="$work/dmg"
mkdir -p "$dmg_src"
ditto "$app" "$dmg_src/TokenMeter.app"
ln -s /Applications "$dmg_src/Applications"
hdiutil create -quiet -volname "TokenMeter $version" -srcfolder "$dmg_src" -fs HFS+ -format UDZO "$dist/$name.dmg"
codesign --sign "$identity" --timestamp "$dist/$name.dmg"

if [ "$notarize" = 1 ]; then
  step "Notarize disk image"
  submit "$dist/$name.dmg"
  xcrun stapler staple "$dist/$name.dmg"

  step "Gatekeeper"
  spctl --assess --type execute --verbose=2 "$app"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dist/$name.dmg"
fi

(cd "$dist" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS)

step "Done"
cat "$dist/SHA256SUMS"
[ "$notarize" = 1 ] || echo "Not notarized: for local testing only, do not publish."
