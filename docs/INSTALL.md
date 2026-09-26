# Installing DeepTally

DeepTally is **ad-hoc signed and not notarized** — there is no Apple Developer Program membership. That is a
deliberate, documented trade-off and it shapes every install path below. If a Gatekeeper dialog worries you,
read [`UNSIGNED.md`](UNSIGNED.md) first: it explains exactly what macOS is warning about and what is harmless.

**Status:** no release has been published yet. The first one, v0.1.0, is what makes the release URLs below
resolve; until then, build from source (Path 3).

## Requirements (all paths)

- macOS **15.0 or later**. The app is built and verified on macOS 27 "Golden Gate"; installing on a fresh
  macOS 15, 26 or 27 machine is part of the release checklist.
- **Apple silicon (arm64) only.** The binaries are arm64; Intel Macs and Rosetta are not supported.
- No admin rights are needed for the CLI, and the install script's `--user` mode needs none either.

## Path 1 — install script (recommended)

The release publishes an install script (`Scripts/install.sh`) next to the DMG. One line installs the app
into `~/Applications`, which needs no admin rights:

```sh
curl -fsSL https://github.com/genoma/deeptally/releases/latest/download/install.sh | bash -s -- --user
```

Without `--user` the script installs into `/Applications`; `--dir DIR` overrides the destination. The script:

1. downloads the DMG with `curl` — **not** a browser;
2. verifies it against the release's `SHA256SUMS` — a mismatch, or a missing line for the DMG, refuses the
   install and copies nothing;
3. mounts the DMG read-only and copies `DeepTally.app` into place;
4. runs `codesign --verify --strict` on the copy;
5. clears the `com.apple.quarantine` attribute from the copy only after the hash matched.

Why `curl` matters: Gatekeeper only gates files carrying the `com.apple.quarantine` attribute, and browsers
add it to downloads. `curl` does not — a `curl`-downloaded file carries only `com.apple.provenance`
(verified 2026-09-24, spike S6). So this path skips the block/`Open Anyway` dance entirely, while still
checking the hash of what it installed.

Other flags: `--version X.Y.Z` installs a specific release instead of the latest tag; `--yes` answers the
"quit the running app?" and "replace the existing install?" questions without a prompt — needed when you
re-run the piped command to update, because the pipe leaves the script no terminal to ask on;
`--dmg PATH --sha256 HEX` installs from a DMG you downloaded yourself. `Scripts/install.sh --help` lists them
all. On any refusal the script prints one sentence to stderr and exits `1`.

## Path 2 — DMG (manual)

1. Download `DeepTally-<version>.dmg` from the GitHub Releases page.
2. Double-click the DMG to mount it.
3. **Drag `DeepTally.app` into `/Applications` before launching anything.** This is not cosmetic:
   launching a quarantined app from outside `/Applications` makes macOS run it through App Translocation,
   from a random read-only path, which breaks the login item and the Keychain item in confusing ways.
4. Eject the DMG (drag it to the Trash), then launch DeepTally from `/Applications`.
5. macOS blocks the first launch. Dismiss the dialog ("Done").
6. Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click
   **Open Anyway** next to DeepTally.
7. Authenticate (Touch ID or your password), then confirm **Open**.

The old bypass — Control-click → Open — was removed in macOS 15, so the System Settings route above is the
supported way through.

<!-- SCREENSHOT PLACEHOLDERS (spike S1): docs/assets/install-{block-dialog,privacy-security,
     confirm-open}.png are still MISSING. S1 recorded the outcome in text (kernel-killed until approved,
     and the per-build exception), not the dialogs, and the wording differs per macOS release. Replace these
     three placeholders and delete this comment after Step 7's fresh-machine install exercises the flow. -->
> 📷 *Screenshot placeholder — the first-launch block dialog on macOS 27 (spike S1; not captured yet).*
>
> 📷 *Screenshot placeholder — System Settings → Privacy & Security with the "Open Anyway" button (not captured yet).*
>
> 📷 *Screenshot placeholder — the final confirmation dialog after "Open Anyway" (not captured yet).*

Notes:

- Gatekeeper remembers the app you approved, **but only for that exact build**. Measured 2026-09-24: after
  approving one build, the next build (different ad-hoc signature) was killed by the kernel until it was
  approved too. Every browser-downloaded update therefore costs another System Settings trip — while the
  `curl` install path avoids this, because it never quarantines the app. See [`UNSIGNED.md`](UNSIGNED.md).
- Removing the quarantine attribute by hand works but skips the only check macOS performed — see
  [`UNSIGNED.md`](UNSIGNED.md).
- On an MDM-managed Mac the block may not be bypassable at all; also covered in [`UNSIGNED.md`](UNSIGNED.md).
- After the first launch, see [After installing](#after-installing) — the app has no key until you import one.

## Path 3 — from source

Needs the Command Line Tools and Swift 6.4+; Xcode is not required (details in [`DEVELOPMENT.md`](DEVELOPMENT.md)).

```sh
git clone https://github.com/genoma/deeptally.git
cd deeptally
make run        # bundles dist/DeepTally.app and launches it
```

`make run` depends on `make bundle`, which does a release build for arm64 and ad-hoc signs the bundle
([`../Scripts/bundle.sh`](../Scripts/bundle.sh)). A bundle you built locally carries no quarantine attribute,
so it launches without a Gatekeeper dialog.

You can also build the DMG locally: `make dmg` produces `dist/DeepTally-<version>.dmg` — the app, an
`/Applications` symlink and a README with the four first-launch steps. `make dmg SIMULATE=1` additionally sets
the `com.apple.quarantine` attribute a browser download would, which is how the Gatekeeper flow is reproduced
([`SPIKES.md`](SPIKES.md) S1).

The CLI is built alongside the app and can be run directly:

```sh
swift run deeptally balance     # prints the account balance
swift run deeptally rate        # the peak/off-peak window now, no key needed
swift run deeptally usage       # spend, tokens and cache-hit rate from the local ledger
swift run deeptally import      # import local opencode usage into the ledger
```

Both halves resolve the key the same way — **Keychain first, then `DEEPSEEK_API_KEY`** — so
`swift run deeptally key import --shell zsh` stores it once and the CLI and the app then use the same key. The
full command set, the exit codes and the settings are in [`USAGE.md`](USAGE.md).

## Path 4 — CLI only (release tarball)

Each release publishes `deeptally-X.Y.Z-arm64.tar.gz` for a CLI without the menu bar app. The archive holds
the `deeptally` binary and the `DeepTally_DeepTallyCore.bundle` directory it reads its price table and
holiday calendar from; both sit at the archive root and have to stay side by side.

```sh
VERSION=0.1.0
curl -fSL --retry 3 -o "deeptally-${VERSION}-arm64.tar.gz" \
  "https://github.com/genoma/deeptally/releases/download/v${VERSION}/deeptally-${VERSION}-arm64.tar.gz"
mkdir -p ~/.local/bin
tar -xzf "deeptally-${VERSION}-arm64.tar.gz" -C ~/.local/bin
deeptally --version
```

`~/.local/bin` is not on the default `PATH`: add `export PATH="$HOME/.local/bin:$PATH"` to your shell
profile, or extract into a directory that already is. Check the tarball's SHA-256 against `SHA256SUMS` before
extracting ([`UNSIGNED.md`](UNSIGNED.md)). The key handling, commands and exit codes are the same as for the
source build above; the full reference is [`USAGE.md`](USAGE.md).

## After installing

**1. Connect your API key.** Until you do, the popover says *"No API key yet. Import it from your login shell
in Settings below."* Export `DEEPSEEK_API_KEY` in the file your login shell sources (`~/.zprofile` or
`~/.zshrc` for zsh, `~/.bash_profile` or `~/.bashrc` for bash), then click the status item → **Settings** →
**Import from shell** → **zsh** or **bash**. The key ends up in the macOS Keychain — never in a file or a
preference. Why a GUI app cannot read your shell environment, and everything else the app does, is in
[`USAGE.md`](USAGE.md).

**2. Local usage appears by itself — or does not apply.** If opencode is installed, DeepTally imports
`~/.local/share/opencode/opencode.db` at launch and then every 15 minutes, and the menu bar can show
**Today's spend** and the **Cache-hit rate** beside the balance ([`USAGE.md`](USAGE.md)). If opencode is not
installed there is simply nothing to import, and that is not an error: the two ledger-backed metrics stay em
dashes, Settings adds the quiet line *"Local usage is not being imported yet."*, and the balance, rate panel
and alerts are unaffected. `deeptally import` says the same thing in a terminal:

```text
$ deeptally import
No opencode database at /tmp/deeptally-doc-empty/.local/share/opencode/opencode.db — nothing to import.
That is expected if you do not use opencode; the ledger records opencode usage only.
```

(Pasted from a throwaway home directory; on your Mac the path is
`~/.local/share/opencode/opencode.db`.) The ledger lives at
`~/Library/Application Support/DeepTally/ledger.sqlite` and holds counters, timestamps, model ids and
estimated costs — never prompt or completion content ([`PRIVACY.md`](PRIVACY.md)).

**3. Decide about launch at login.** **Startup → Launch at login** registers DeepTally through macOS
`SMAppService` — no helper bundle, no LaunchAgent. The switch is disabled while the app runs from a temporary
App Translocation copy, which is one more reason to install into `/Applications` before the first launch.

**4. Every browser-downloaded update needs the Gatekeeper detour again.** Measured 2026-09-24: the exception
is bound to the exact build, so after you approve build 1, build 2 — same bundle ID, different ad-hoc
signature hash — is killed by the kernel (`Killed: 9`) until it is approved too. That is a *System Settings →
Privacy & Security → Open Anyway* trip per update for the DMG path. The `curl` install path (Path 1) never
quarantines the app, so it needs no detour ([`UNSIGNED.md`](UNSIGNED.md), [`SPIKES.md`](SPIKES.md) S1/S6).

**5. Expect no Keychain prompt per update.** Measured: an item written by one build is read back silently by
the next, because the default keychain ACL is permissive for your own session ([`UNSIGNED.md`](UNSIGNED.md)).

## Uninstalling

DeepTally uninstalls itself: click the status item, then **Uninstall DeepTally…** in the popover footer. The
confirmation lists everything it will remove and offers **Export CSV First…** — the ledger is the one file
that cannot be recreated, so exporting it before the removal is one click. Then, in order:

1. unregisters the **login item** (`Launch at login`);
2. deletes the **API key** from the Keychain;
3. removes `~/Library/Application Support/DeepTally` — the ledger, its side files and the launch logs;
4. removes the **preferences** domain `io.github.genoma.deeptally`;
5. removes `~/Library/Caches/io.github.genoma.deeptally`;
6. removes `~/Library/Saved Application State/io.github.genoma.deeptally.savedState`, when macOS wrote one;
7. moves `DeepTally.app` to the Trash, so it stays recoverable.

Nothing outside that list is touched. If you built from source (Path 3), [`../Scripts/uninstall.sh`](../Scripts/uninstall.sh)
drives the same code from a terminal: it finds the app in `/Applications` or `~/Applications` (`--app PATH`
overrides that) and passes `--yes`, `--print-only`, `--keep-data`, `--keep-keychain`, `--keep-login-item`
and `--trash-dir PATH`
through to `DeepTally --uninstall`. With no bundle found it removes nothing and prints the manual commands
from [`PRIVACY.md`](PRIVACY.md). The export and delete details are in the export/delete section of
[`PRIVACY.md`](PRIVACY.md).
