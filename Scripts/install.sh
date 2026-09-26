#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install DeepTally from a published release DMG.
#
# Downloads DeepTally-X.Y.Z.dmg and SHA256SUMS from GitHub Releases, verifies the DMG's SHA-256
# (a mismatch or a missing checksum refuses the install), mounts it read-only, copies DeepTally.app
# into place, runs 'codesign --verify --strict' on the installed app, and clears the quarantine
# attribute only after the hash matched — so this curl path never hits the Gatekeeper block.
#
# Usage: Scripts/install.sh [--version X.Y.Z] [--user] [--dir DIR] [--dmg PATH] [--sha256 HEX] [--yes]
set -euo pipefail

APP_NAME="DeepTally"
REPO="genoma/deeptally"
RELEASE_BASE="https://github.com/${REPO}/releases"
LATEST_URL="${RELEASE_BASE}/latest"
DEFAULT_DIR="/Applications"

VERSION=""
USER_MODE=0
DIR_FLAG=""
LOCAL_DMG=""
PINNED_SHA=""
ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Install DeepTally.app from a GitHub release, after verifying the DMG's SHA-256.

  --version X.Y.Z  install this release (default: the latest release tag)
  --user           install into ~/Applications instead of /Applications
  --dir DIR        install into DIR (default: /Applications, or ~/Applications with --user)
  --dmg PATH       install from a local DMG instead of downloading one
  --sha256 HEX     pin the SHA-256 of the DMG instead of reading SHA256SUMS
  --yes            do not ask before quitting a running app or replacing an existing install
  --help           show this help and exit

Downloads come from https://github.com/genoma/deeptally/releases/download/vX.Y.Z/
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

confirm() {
  reply=""
  printf '%s [y/N] ' "$1"
  read -r reply || true
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_latest_version() {
  latest_url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$LATEST_URL" 2>/dev/null)" \
    || fail "could not reach $LATEST_URL to find the latest release — check your network, or pass --version X.Y.Z"
  case "$latest_url" in
    */tag/v*) VERSION="${latest_url##*/tag/v}" ;;
    *) fail "could not read a release tag from $LATEST_URL (got '$latest_url') — pass --version X.Y.Z" ;;
  esac
  case "$VERSION" in
    ""|*[!0-9A-Za-z.+-]*) fail "the latest release tag at $LATEST_URL is not a version ('$VERSION') — pass --version X.Y.Z" ;;
  esac
  echo "==> latest release is v$VERSION"
}

verify_dmg() {
  expected=""
  source=""
  if [ -n "$PINNED_SHA" ]; then
    expected="$PINNED_SHA"
    source="--sha256"
  elif [ -f "${DMG_PATH}.sha256" ]; then
    expected="$(awk 'NR == 1 { print $1 }' "${DMG_PATH}.sha256")"
    source="${DMG_PATH}.sha256"
  else
    [ -n "$VERSION" ] || resolve_latest_version
    sum_file="$WORKDIR/SHA256SUMS"
    echo "==> downloading SHA256SUMS for v$VERSION"
    curl -fSL --retry 3 -o "$sum_file" "${RELEASE_BASE}/download/v${VERSION}/SHA256SUMS" \
      || fail "could not download SHA256SUMS for v$VERSION — check the version, or pass --sha256 HEX"
    expected="$(awk -v f="$DMG_NAME" '$2 == f || $2 == "*" f { print $1; exit }' "$sum_file")"
    [ -n "$expected" ] \
      || fail "SHA256SUMS for v$VERSION has no line for $DMG_NAME — refusing to install an unverified DMG"
    source="SHA256SUMS"
  fi
  case "$expected" in
    ""|*[!0-9a-fA-F]*) fail "the checksum in $source is not a hex SHA-256 — do not use this DMG" ;;
  esac
  [ "${#expected}" -eq 64 ] || fail "the checksum in $source is not 64 hex characters — do not use this DMG"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  actual="$(shasum -a 256 "$DMG_PATH" | awk '{ print $1 }')"
  if [ "$actual" != "$expected" ]; then
    fail "SHA-256 of $DMG_NAME does not match $source (expected $expected, got $actual) — delete the file, download it again, and retry"
  fi
  echo "verified SHA-256 of $DMG_NAME against $source: $actual"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || fail "--version needs a value — use --version X.Y.Z"
      VERSION="${2#v}"
      shift 2
      ;;
    --user)
      USER_MODE=1
      shift
      ;;
    --dir)
      [ $# -ge 2 ] || fail "--dir needs a value — use --dir DIR"
      DIR_FLAG="$2"
      shift 2
      ;;
    --dmg)
      [ $# -ge 2 ] || fail "--dmg needs a value — use --dmg PATH"
      LOCAL_DMG="$2"
      shift 2
      ;;
    --sha256)
      [ $# -ge 2 ] || fail "--sha256 needs a value — use --sha256 HEX"
      PINNED_SHA="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option '$1' — run Scripts/install.sh --help for the flags"
      ;;
  esac
done

if [ -n "$VERSION" ]; then
  case "$VERSION" in
    *[!0-9A-Za-z.+-]*) fail "--version '$VERSION' is not a version number — use --version X.Y.Z" ;;
  esac
fi
if [ -n "$PINNED_SHA" ]; then
  case "$PINNED_SHA" in
    *[!0-9a-fA-F]*) fail "--sha256 '$PINNED_SHA' is not hex — pass the 64-character SHA-256 of the DMG" ;;
  esac
  [ "${#PINNED_SHA}" -eq 64 ] || fail "--sha256 '$PINNED_SHA' is not 64 hex characters — pass the SHA-256 printed by 'shasum -a 256'"
fi

if [ -n "$DIR_FLAG" ]; then
  TARGET_DIR="$DIR_FLAG"
elif [ "$USER_MODE" = 1 ]; then
  TARGET_DIR="$HOME/Applications"
else
  TARGET_DIR="$DEFAULT_DIR"
fi

tmp_base="${TMPDIR:-/tmp}"
tmp_base="${tmp_base%/}"
WORKDIR="$(mktemp -d "$tmp_base/deeptally-install.XXXXXX")" \
  || fail "could not create a temporary directory — check TMPDIR and try again"
MOUNT=""
MOUNTED=0

cleanup() {
  status=$?
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$LOCAL_DMG" ]; then
  DMG_PATH="$LOCAL_DMG"
else
  [ -n "$VERSION" ] || resolve_latest_version
  RELEASE_URL="${RELEASE_BASE}/download/v${VERSION}"
  DMG_PATH="$WORKDIR/${APP_NAME}-${VERSION}.dmg"
  echo "==> downloading ${RELEASE_URL}/${APP_NAME}-${VERSION}.dmg"
  curl -fSL --retry 3 -o "$DMG_PATH" "${RELEASE_URL}/${APP_NAME}-${VERSION}.dmg" \
    || fail "could not download v$VERSION — check the version and your network, or pass --dmg PATH"
fi
[ -f "$DMG_PATH" ] || fail "no DMG at $DMG_PATH — pass --dmg PATH to a file you downloaded"
DMG_NAME="$(basename "$DMG_PATH")"

verify_dmg

if [ ! -d "$TARGET_DIR" ]; then
  mkdir -p "$TARGET_DIR" 2>/dev/null \
    || fail "cannot create $TARGET_DIR — re-run with --user to install into ~/Applications"
fi
[ -w "$TARGET_DIR" ] || fail "no write permission for $TARGET_DIR — re-run with --user to install into ~/Applications"
TARGET_APP="$TARGET_DIR/${APP_NAME}.app"

running_pattern="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
if pgrep -f "$running_pattern" >/dev/null 2>&1; then
  if [ "$ASSUME_YES" != 1 ]; then
    if [ -t 0 ]; then
      confirm "DeepTally is running; quit it and continue the install?" \
        || fail "stopped at your request — quit DeepTally from its menu and re-run, or pass --yes"
    else
      fail "DeepTally is running — quit it from its menu and re-run, or pass --yes to let the installer quit it"
    fi
  fi
  pkill -f "$running_pattern" || true
  tries=0
  while pgrep -f "$running_pattern" >/dev/null 2>&1 && [ "$tries" -lt 20 ]; do
    sleep 0.25
    tries=$((tries + 1))
  done
  pgrep -f "$running_pattern" >/dev/null 2>&1 \
    && fail "DeepTally did not quit — quit it from the menu bar yourself and re-run"
  echo "==> stopped the running DeepTally"
fi

if [ -e "$TARGET_APP" ] && [ "$ASSUME_YES" != 1 ]; then
  if [ -t 0 ]; then
    confirm "replace the existing $TARGET_APP?" \
      || fail "nothing was changed — re-run with --yes to replace it"
  else
    fail "$TARGET_APP already exists — re-run with --yes to replace it"
  fi
fi

echo "==> mounting $DMG_NAME"
MOUNT="$WORKDIR/mount"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG_PATH" >/dev/null \
  || fail "could not mount $DMG_NAME — the file may be incomplete; download it again and retry"
MOUNTED=1
[ -d "$MOUNT/${APP_NAME}.app" ] || fail "$DMG_NAME does not contain ${APP_NAME}.app — refusing to install from it"

echo "==> installing to $TARGET_APP"
rm -rf "$TARGET_APP"
ditto "$MOUNT/${APP_NAME}.app" "$TARGET_APP" \
  || fail "could not copy ${APP_NAME}.app to $TARGET_DIR — check free space and permissions"
if ! codesign --verify --strict "$TARGET_APP" 2>/dev/null; then
  rm -rf "$TARGET_APP"
  fail "the copied app failed 'codesign --verify --strict' — nothing was installed; download the DMG again"
fi
echo "codesign --verify --strict: ok"

if xattr -p com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$TARGET_APP" \
    || fail "could not clear com.apple.quarantine from $TARGET_APP — delete it by hand: xattr -dr com.apple.quarantine '$TARGET_APP'"
  echo "cleared com.apple.quarantine from the installed app (SHA-256 verified)"
else
  echo "no com.apple.quarantine attribute on the installed app (SHA-256 verified)"
fi

installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
echo "installed ${APP_NAME} ${installed_version:-$VERSION} to $TARGET_APP"
echo "ad-hoc signed, not notarized: first launch steps are in docs/INSTALL.md"
