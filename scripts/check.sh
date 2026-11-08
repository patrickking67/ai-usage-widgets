#!/usr/bin/env bash
# The one check for this repo: lint, tests and the macOS build. CI runs it too.
#
#   scripts/check.sh                     everything
#   CHECK_SKIP_XCODE=1 scripts/check.sh  skip the Xcode steps (no Xcode, or not macOS)
#
# Nothing here reads a real credential or makes a network request: the tests
# use spec/fixtures and temp directories only.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1 (install: $2)" >&2; exit 1; }; }

need python3 "brew install python"
need pwsh "brew install powershell"
need shellcheck "brew install shellcheck"
need actionlint "brew install actionlint"

step "Shell scripts (shellcheck)"
shellcheck extras/*.sh plugin/scripts/*.sh plugin/hooks/*.sh scripts/*.sh

step "Workflows (actionlint)"
actionlint

step "JSON manifests and fixtures"
for f in plugin/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugin/hooks/hooks.json \
         .claude/launch.json spec/fixtures/*.json; do
  python3 -m json.tool "$f" > /dev/null || { echo "invalid JSON: $f" >&2; exit 1; }
done
echo "ok"

step "PowerShell syntax"
# shellcheck disable=SC2016  # PowerShell variables, not shell ones
pwsh -NoProfile -Command '
  $bad = 0
  Get-ChildItem apps/windows -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { $bad++; Write-Host ("{0}:{1}: {2}" -f $_.Name, $e.Extent.StartLineNumber, $e.Message) }
  }
  if ($bad) { exit 1 } else { "ok" }'

step "Claude Code plugin tests"
python3 -m unittest discover -s plugin/tests

step "Windows core tests"
log=$(mktemp)
pwsh -NoProfile -File apps/windows/tests/Core.Tests.ps1 > "$log" 2>&1 || { cat "$log"; rm -f "$log"; exit 1; }
tail -n 1 "$log"; rm -f "$log"

if [ "${CHECK_SKIP_XCODE:-}" = "1" ] || [ "$(uname -s)" != "Darwin" ]; then
  step "macOS unit tests and build: skipped"
  exit 0
fi
need xcodegen "brew install xcodegen"
need xcodebuild "install Xcode"

cd apps/macos
xcodegen generate --quiet

step "macOS unit tests"
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -derivedDataPath build \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -quiet test

step "macOS build (Release, unsigned)"
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release -derivedDataPath build \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet build
echo "ok"

printf '\nAll checks passed.\n'
