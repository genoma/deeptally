#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The one signing seam for DeepTally: ad-hoc by default, Developer ID when asked.
#
#   Scripts/sign.sh PATH                          # SIGNING=adhoc (default)
#   SIGNING=devid DEVELOPER_ID_APP='Developer ID Application: Name (TEAMID)' Scripts/sign.sh PATH
#
# The ad-hoc identity is content-derived, so every rebuild gets a new code hash — that is why the
# DMG path needs a Gatekeeper exception per build (AGENTS.md §9.4).
set -euo pipefail

SIGNING="${SIGNING:-adhoc}"
BUNDLE_ID="io.github.genoma.deeptally"
TARGET="${1:-}"

usage() {
  cat <<'USAGE'
Usage: Scripts/sign.sh PATH

Signs a bundle or a binary. SIGNING selects the identity:

  SIGNING=adhoc (default)  codesign --force --sign - --identifier io.github.genoma.deeptally
  SIGNING=devid            needs DEVELOPER_ID_APP to name an identity that
                           'security find-identity -v -p codesigning' lists; adds
                           --options runtime --timestamp

Every mode runs 'codesign --verify --strict PATH' afterwards and exits non-zero if it fails.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

usage_error() {
  echo "error: $*" >&2
  exit 2
}

if [ "$TARGET" = "--help" ] || [ "$TARGET" = "-h" ]; then
  usage
  exit 0
fi
if [ -z "$TARGET" ]; then
  usage_error "no path given — run: Scripts/sign.sh PATH (see --help)"
fi
if [ ! -e "$TARGET" ]; then
  usage_error "$TARGET does not exist — build the bundle first ('make bundle') and pass its path"
fi

case "$SIGNING" in
  adhoc)
    echo "==> ad-hoc signing $TARGET"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$TARGET"
    ;;
  devid)
    if [ -z "${DEVELOPER_ID_APP:-}" ]; then
      usage_error "SIGNING=devid needs DEVELOPER_ID_APP, e.g. DEVELOPER_ID_APP='Developer ID Application: Name (TEAMID)'"
    fi
    if ! security find-identity -v -p codesigning | grep -Fq -- "$DEVELOPER_ID_APP"; then
      usage_error "'$DEVELOPER_ID_APP' is not listed by 'security find-identity -v -p codesigning' — install the certificate or fix DEVELOPER_ID_APP"
    fi
    echo "==> Developer ID signing $TARGET as $DEVELOPER_ID_APP"
    codesign --force --sign "$DEVELOPER_ID_APP" --identifier "$BUNDLE_ID" --options runtime --timestamp "$TARGET"
    ;;
  *)
    echo "error: unknown SIGNING='$SIGNING' — use SIGNING=adhoc or SIGNING=devid" >&2
    exit 2
    ;;
esac

if ! codesign --verify --strict "$TARGET"; then
  fail "codesign --verify --strict failed for $TARGET — the signature is not usable; fix the input or the identity and re-sign"
fi
echo "signature ok ($TARGET)"
