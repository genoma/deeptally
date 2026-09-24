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

<!-- SCREENSHOT PLACEHOLDERS (Step 2, spike S1): docs/assets/install-{block-dialog,privacy-security,
     confirm-open}.png — the macOS 27 flow is captured in Step 2; dialog wording differs per release. -->
> 📷 *Screenshot placeholder — the first-launch block dialog on macOS 27 (Step 2, spike S1).*
>
> 📷 *Screenshot placeholder — System Settings → Privacy & Security with the "Open Anyway" button.*
>
> 📷 *Screenshot placeholder — the final confirmation dialog after "Open Anyway".*

Notes:

- Gatekeeper remembers the app you approved. TODO (Step 2, spike S1): confirm whether that exception
  survives an app update (the ad-hoc signature is content-derived, so it may not) and record the observed
  behaviour.
- Removing the quarantine attribute by hand works but skips the only check macOS performed — see
  [`UNSIGNED.md`](UNSIGNED.md).
- On an MDM-managed Mac the block may not be bypassable at all; also covered in [`UNSIGNED.md`](UNSIGNED.md).

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

The CLI is built alongside the app and can be run directly:

```sh
swift run deeptally balance     # prints the account balance
```

Unlike the app, the CLI reads `DEEPSEEK_API_KEY` from the environment. The app will import the key into the
Keychain instead (Step 3; until that lands, development builds fall back to the environment variable too).

## Uninstalling

See the export/delete section of [`PRIVACY.md`](PRIVACY.md). A one-step in-app uninstaller is planned in
Step 6 (`install → uninstall → reinstall` is that step's gate).
