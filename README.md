# DeepTally

[![CI](https://github.com/genoma/deeptally/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/genoma/deeptally/actions/workflows/ci.yml)

**DeepSeek balance and rate meter for the macOS menu bar.** How much is left, and what a request costs
right now.

> **Status: pre-alpha.** The app is API-only: the menu bar shows the DeepSeek account balance, the popover
> shows the peak/off-peak rate in force with the effective price of each model, and low-balance alerts and
> launch at login work. There is no usage or spend history — DeepSeek exposes no usage endpoint, and the
> app makes no completion calls of its own. Step 6, the release machinery, is built and waiting for the
> v0.1.0 tag in [`docs/PLAN.md`](docs/PLAN.md).

## What it does

- Shows your DeepSeek account balance in the menu bar, with an explicit "as of" time — the account's own
  figure, in the account's own currency, never converted
- Tells you whether you are in a **peak or off-peak window right now** — in your local time — with a
  countdown to the next switch and the effective price per 1M tokens for each model
- Alerts when the balance drops below a threshold you set — and while macOS will not deliver the alert, a
  warning glyph stands in for the balance
- Starts at login, lives in the menu bar, no Dock icon
- Ships a small CLI (`deeptally balance`, `deeptally rate`, `deeptally key …`) for scripts and terminals

The rates are **estimates of what a request would cost**, computed locally from the shipped, versioned
price table — not a bill. The balance is not an estimate: it comes straight from `GET /user/balance`.

How to connect your API key, what each popover section shows and every setting are documented in
[`docs/USAGE.md`](docs/USAGE.md).

## What it does not do

- **No usage or spend history.** DeepSeek has no endpoint that answers "what did I spend last Tuesday";
  it returns per-response usage counters only to the caller of that one request, and DeepTally makes no
  completion calls. Your DeepSeek account is the place for spend reporting.
- No telemetry, no account, no cloud sync. Everything stays on your Mac.
- Never stores prompt or completion **content** — the app never sees a prompt or a completion at all.
- Does not scrape DeepSeek's private dashboard endpoints (account balance only)
- Not affiliated with, endorsed by, or connected to DeepSeek

## Install

Ad-hoc signed, not notarized — [`docs/UNSIGNED.md`](docs/UNSIGNED.md) explains what macOS is warning about.
Released: the commands below resolve to the [latest release](https://github.com/genoma/deeptally/releases/latest).

**Install script** (recommended; verifies the DMG's SHA-256 and never triggers the Gatekeeper dialog):

```sh
curl -fsSL https://github.com/genoma/deeptally/releases/latest/download/install.sh | bash -s -- --user
```

**DMG** — download `DeepTally-<version>.dmg` from the
[releases page](https://github.com/genoma/deeptally/releases), drag `DeepTally.app` into `/Applications`,
then follow the first-launch steps in [`docs/INSTALL.md`](docs/INSTALL.md).

**CLI only** — download `deeptally-X.Y.Z-arm64.tar.gz` from the releases page and keep the `deeptally`
binary and `DeepTally_DeepTallyCore.bundle` from the archive together in a directory on your `PATH`.
[`docs/INSTALL.md`](docs/INSTALL.md) has the commands.

**Uninstall** — the popover's **Uninstall DeepTally…** button removes the login item, the Keychain item,
`~/Library/Application Support/DeepTally`, the preferences domain, caches and saved state, and moves the
app to the Trash. Nothing else changes.
[`docs/INSTALL.md`](docs/INSTALL.md#uninstalling) describes each step and the `Scripts/uninstall.sh`
route for source builds.

## CLI

```sh
deeptally balance                        # the account balance
deeptally rate                           # the peak/off-peak window in force, with prices
deeptally key status                     # which store supplies the key, and any Keychain problem
deeptally key import [--shell zsh|bash]  # import from the login shell into the Keychain (default: zsh)
deeptally key delete                     # remove the stored key
deeptally --version | --help
```

Like the app, the CLI reads the API key from the **Keychain first, then `DEEPSEEK_API_KEY`**, so a terminal
and the menu bar use the same key. Exit codes are contractual: `0` ok, `2` the key path failed (no key, or
the balance request itself rejected it), `1` a usage error or any other failure. Full command reference:
[`docs/USAGE.md`](docs/USAGE.md).

## Screenshots

Rendered from the shipping views by `make screenshots`, not drawn by hand:

![The DeepTally popover](docs/assets/popover.png)
![The DeepTally popover in dark mode](docs/assets/popover-dark.png)

## Development

Requires macOS 15+, Xcode Command Line Tools, Swift 6.4+. Xcode itself is not required.

```sh
make build     # build app + CLI
make test      # run tests
make bundle    # assemble DeepTally.app (ad-hoc signed)
make run       # launch the bundled app
```

`AGENTS.md` documents the toolchain, environment and conventions in detail.

### Quitting

DeepTally is an accessory app (`LSUIElement`): it has no Dock icon, nothing in the app switcher and no menu
bar of its own. To stop it:

- **Quit** in the popover footer, or ⌘Q while the popover is open, or
- `make kill` (equivalent to `pkill -f 'DeepTally.app/Contents/MacOS/DeepTally'`).

If the app is running but its status item is hidden, `make kill` is the reliable way out.

## Privacy

DeepTally talks to exactly one host today: `api.deepseek.com`, for your account balance. `api.github.com`
is reserved for a future update check and is not contacted by any current build. No telemetry, no crash
reporting, no third-party servers. The API key lives in the macOS Keychain, never in a file or a
preference; if the Keychain read fails, the app falls back to `DEEPSEEK_API_KEY` and says so in a banner.
There is no usage data to store — the preferences hold the settings, the last balance reading and the last
alert time, and nothing else. What is stored, and how to delete it, is in
[`docs/PRIVACY.md`](docs/PRIVACY.md).

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
