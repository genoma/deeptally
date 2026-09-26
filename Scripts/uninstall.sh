#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Uninstall DeepTally by handing over to the app's own --uninstall mode.
#
# Finds DeepTally.app (--app PATH, then /Applications, then ~/Applications) and execs its binary
# with --uninstall plus the flags it was given. The app owns the removal list, so this script
# removes nothing itself. With no bundle found it prints docs/PRIVACY.md's manual removal commands
# and exits 1.
set -euo pipefail

APP_NAME="DeepTally"

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--app PATH] [app flags]

  --app PATH        the DeepTally.app to uninstall (default: /Applications, then ~/Applications)
  --yes             do not ask the app for confirmation
  --print-only      show what the app would remove, then stop
  --home PATH       treat PATH as the home directory whose data is removed
  --keep-data       keep the ledger, preferences and caches
  --keep-keychain   keep the API key in the Keychain
  --keep-login-item keep the macOS login item registered (the release gate uses this)
  --trash-dir PATH  move the app to PATH instead of the Trash
  --help            show this help and exit

With no bundle found, nothing is removed: the manual commands from docs/PRIVACY.md are printed.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

manual_removal() {
  cat <<'MANUAL'
Nothing was removed. Remove DeepTally's data by hand (docs/PRIVACY.md):

  rm -rf "$HOME/Library/Application Support/DeepTally"   # the ledger and any Step 2 spike logs
  defaults delete io.github.genoma.deeptally              # all three preference keys above
  rm -rf "$HOME/Library/Caches/io.github.genoma.deeptally"

Then open Keychain Access, search for DeepTally, and delete the item (service
io.github.genoma.deeptally, account api-key) — or run: deeptally key delete
MANUAL
}

APP_PATH=""
PASS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      [ $# -ge 2 ] || fail "--app needs a value — use --app PATH"
      APP_PATH="$2"
      shift 2
      ;;
    --yes|--print-only|--keep-data|--keep-keychain|--keep-login-item)
      PASS+=("$1")
      shift
      ;;
    --home|--trash-dir)
      [ $# -ge 2 ] || fail "$1 needs a value — use $1 PATH"
      PASS+=("$1" "$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option '$1' — the app accepts only --yes, --print-only, --home PATH, --keep-data, --keep-keychain, --keep-login-item and --trash-dir PATH"
      ;;
  esac
done

BUNDLE=""
if [ -n "$APP_PATH" ]; then
  if [ ! -d "$APP_PATH" ]; then
    echo "error: no DeepTally.app at $APP_PATH — check the path or drop --app" >&2
    manual_removal
    exit 1
  fi
  BUNDLE="$APP_PATH"
elif [ -d "/Applications/${APP_NAME}.app" ]; then
  BUNDLE="/Applications/${APP_NAME}.app"
elif [ -d "$HOME/Applications/${APP_NAME}.app" ]; then
  BUNDLE="$HOME/Applications/${APP_NAME}.app"
fi

if [ -z "$BUNDLE" ]; then
  echo "error: no DeepTally.app found in /Applications or $HOME/Applications — drop --app only if you keep DeepTally elsewhere" >&2
  manual_removal
  exit 1
fi

BIN="$BUNDLE/Contents/MacOS/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: $BUNDLE has no executable at $BIN — reinstall DeepTally, or remove the bundle by hand" >&2
  manual_removal
  exit 1
fi

# exec: the app replaces this shell, so its exit code and prompts are the script's.
if [ "${#PASS[@]}" -gt 0 ]; then
  exec "$BIN" --uninstall "${PASS[@]}"
else
  exec "$BIN" --uninstall
fi
