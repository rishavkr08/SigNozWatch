#!/bin/sh
# One-line installer for SigNozWatch:
#   curl -fsSL https://github.com/rishavkr08/SigNozWatch/releases/latest/download/install.sh | sh
# Downloads the latest release, checks its SHA-256, installs it to /Applications and opens it.
# Files fetched with curl are not quarantined, so macOS opens the app without the
# "cannot verify the developer" prompt that a browser download of an un-notarized app gets.
set -e
BASE="${SIGNOZWATCH_BASE:-https://github.com/rishavkr08/SigNozWatch/releases/latest/download}"

[ "$(uname -s)" = Darwin ] || { echo "SigNozWatch is a macOS app."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "SigNozWatch needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading SigNozWatch…"
curl -fL --progress-bar "$BASE/SigNozWatch.zip" -o "$tmp/SigNozWatch.zip"
curl -fsSL "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
expected=$(awk '$2 == "SigNozWatch.zip" { print $1 }' "$tmp/SHA256SUMS")
actual=$(shasum -a 256 "$tmp/SigNozWatch.zip" | awk '{ print $1 }')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "Checksum mismatch, not installing. Expected $expected, got $actual."; exit 1; }

ditto -x -k "$tmp/SigNozWatch.zip" "$tmp"
codesign --verify --strict "$tmp/SigNozWatch.app" || { echo "The downloaded app's signature is invalid, not installing."; exit 1; }

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

if pkill -x SigNozWatch 2>/dev/null; then
  i=0; while pgrep -x SigNozWatch >/dev/null && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done   # opening before it exits fails with -600
fi
rm -rf "$DEST/SigNozWatch.app"
ditto "$tmp/SigNozWatch.app" "$DEST/SigNozWatch.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/SigNozWatch.app" 2>/dev/null || true
open "$DEST/SigNozWatch.app" 2>/dev/null || { sleep 1; open "$DEST/SigNozWatch.app"; }

echo "Installed $DEST/SigNozWatch.app. Click Allow when macOS asks about notifications, then paste your SigNoz API key under Settings… in the panel."
