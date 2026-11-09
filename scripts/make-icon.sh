#!/usr/bin/env bash
# Regenerates apps/macos/Shared/Assets.xcassets/AppIcon.appiconset from IconArt.swift.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$(mktemp -d)/make-icon"
swiftc -O "$root/apps/macos/App/IconArt.swift" "$root/scripts/icon/main.swift" -o "$bin"
"$bin" "$root/apps/macos/Shared/Assets.xcassets/AppIcon.appiconset"
echo "Wrote $root/apps/macos/Shared/Assets.xcassets/AppIcon.appiconset"
