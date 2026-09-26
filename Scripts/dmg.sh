#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build dist/DeepTally-<version>.dmg: the app, an /Applications symlink and a first-launch README.
#
# --simulate-download also sets com.apple.quarantine on the DMG, which is what a browser does and
# what Gatekeeper reacts to. A locally built DMG has no quarantine attribute, so without this flag
# the DMG installs without any Gatekeeper dialog — useful for local testing, useless for
# reproducing what a user downloading from GitHub actually experiences.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIMULATE_DOWNLOAD=0
[ "${1:-}" = "--simulate-download" ] && SIMULATE_DOWNLOAD=1

APP="dist/DeepTally.app"
DMG="dist/DeepTally-${VERSION}.dmg"
STAGE="dist/dmg-stage"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run 'make bundle' first" >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'TXT'
DeepTally is ad-hoc signed and NOT notarized.

  1. Drag DeepTally.app into /Applications. Do this BEFORE launching it.
  2. Launch it once. macOS will block it — click Done.
  3. Open System Settings > Privacy & Security, scroll to Security, click "Open Anyway".
  4. Authenticate with Touch ID or your password; DeepTally opens.

Full instructions and why this happens:
  https://github.com/genoma/deeptally/blob/develop/docs/INSTALL.md
  https://github.com/genoma/deeptally/blob/develop/docs/UNSIGNED.md
TXT

hdiutil create -volname "DeepTally ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ "$SIMULATE_DOWNLOAD" = "1" ]; then
  # The value mirrors what Safari writes: flags;hex-timestamp;agent-name
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$DMG"
  echo "quarantine simulated on the DMG (Gatekeeper will block a first launch)"
fi

echo "built $DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
xattr -l "$DMG" 2>/dev/null || echo "(no extended attributes)"
