# Installing DeepTally

DeepTally is **ad-hoc signed and not notarized** — there is no Apple Developer Program membership. That is a
deliberate, documented trade-off and it shapes every install path below. If a Gatekeeper dialog worries you,
read [`UNSIGNED.md`](UNSIGNED.md) first: it explains exactly what macOS is warning about and what is harmless.

**Status:** v1 is not released yet. Paths 1 and 2 describe the shipping machinery planned in Step 6 of
[`PLAN.md`](PLAN.md); their exact URLs and flags are frozen when that step lands. Path 3 works today.

## Requirements (all paths)

- macOS **15.0 or later**. The app is built and verified on macOS 27 "Golden Gate"; Step 7's release gate
  installs on a fresh macOS 15/26/27 machine using only these instructions.
- **Apple silicon (arm64) only.** The binaries are arm64; Intel Macs and Rosetta are not supported.
- No admin rights are needed for the CLI, and the install script's `--user` mode needs none either.

## Path 1 — install script (recommended; planned in Step 6)

The release pipeline publishes an install script (`Scripts/install.sh`) next to the DMG. It:

1. downloads the DMG with `curl` — **not** a browser;
2. verifies the download against the published `SHA256SUMS`;
3. copies `DeepTally.app` into `/Applications`, or into `~/Applications` with `--user`.

Why `curl` matters: Gatekeeper only gates files carrying the `com.apple.quarantine` attribute, and browsers
add it to downloads. `curl` does not — a `curl`-downloaded file carries only `com.apple.provenance`
(verified 2026-09-24, spike S6). So this path skips the block/`Open Anyway` dance entirely, while still
checking the hash of what it installed.

TODO (Step 6): the one-line invocation and the release URL are frozen together with `Scripts/install.sh`.
Nothing is published yet — do not run a guessed URL.

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
```

Both halves resolve the key the same way — **Keychain first, then `DEEPSEEK_API_KEY`** — so
`swift run deeptally key import --shell zsh` stores it once and the CLI and the app then use the same key. The
full command set, the exit codes and the settings are in [`USAGE.md`](USAGE.md).

## After installing

**1. Connect your API key.** Until you do, the popover says *"No API key yet. Import it from your login shell
in Settings below."* Export `DEEPSEEK_API_KEY` in the file your login shell sources (`~/.zprofile` or
`~/.zshrc` for zsh, `~/.bash_profile` or `~/.bashrc` for bash), then click the status item → **Settings** →
**Import from shell** → **zsh** or **bash**. The key ends up in the macOS Keychain — never in a file or a
preference. Why a GUI app cannot read your shell environment, and everything else the app does, is in
[`USAGE.md`](USAGE.md).

**2. Decide about launch at login.** **Startup → Launch at login** registers DeepTally through macOS
`SMAppService` — no helper bundle, no LaunchAgent. The switch is disabled while the app runs from a temporary
App Translocation copy, which is one more reason to install into `/Applications` before the first launch.

**3. Every browser-downloaded update needs the Gatekeeper detour again.** Measured 2026-09-24: the exception
is bound to the exact build, so after you approve build 1, build 2 — same bundle ID, different ad-hoc
signature hash — is killed by the kernel (`Killed: 9`) until it is approved too. That is a *System Settings →
Privacy & Security → Open Anyway* trip per update for the DMG path. The `curl` install path (Path 1) never
quarantines the app, so it needs no detour ([`UNSIGNED.md`](UNSIGNED.md), [`SPIKES.md`](SPIKES.md) S1/S6).

**4. Expect no Keychain prompt per update.** Measured: an item written by one build is read back silently by
the next, because the default keychain ACL is permissive for your own session ([`UNSIGNED.md`](UNSIGNED.md)).

## Uninstalling

See the export/delete section of [`PRIVACY.md`](PRIVACY.md). A one-step in-app uninstaller is planned in
Step 6 (`install → uninstall → reinstall` is that step's gate).
