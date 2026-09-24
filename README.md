# DeepTally

**DeepSeek usage meter for the macOS menu bar.** Balance, spend, tokens and cache-hit rate — at a glance, locally.

> **Status: pre-alpha.** The step-by-step build plan is in [`docs/PLAN.md`](docs/PLAN.md).

## What it does

- Shows your DeepSeek account balance in the menu bar, with an explicit "as of" timestamp
- Tallies token usage, spend and **cache-hit rate** from the requests made on your Mac
- Estimates cost per model, including DeepSeek's peak / off-peak pricing windows
- Tells you whether you are in a **peak or off-peak window right now** — in your local time — with a countdown
  to the next switch and the effective price for each model in that window
- Ships a small CLI (`deeptally balance`) for scripts and terminals
- Alerts when the balance drops below a threshold you set
- Starts at login, lives in the menu bar, no Dock icon

How to connect your API key, what each popover section shows and every setting are documented in
[`docs/USAGE.md`](docs/USAGE.md).

## What it does not do

- No telemetry, no account, no cloud sync. Everything stays on your Mac.
- Never stores prompt or completion **content** — counters, timestamps and model names only
- Does not scrape DeepSeek's private dashboard endpoints (balance + per-response usage only)
- Not affiliated with, endorsed by, or connected to DeepSeek

## Install

Not released yet. Planned: a DMG on GitHub Releases (ad-hoc signed, not notarized), plus a hash-pinned
install script that avoids the Gatekeeper dialog entirely. See [`docs/PLAN.md`](docs/PLAN.md).

## CLI

```sh
deeptally balance                        # account balance
deeptally rate                           # peak/off-peak window now, with prices
deeptally key status                     # which store supplies the key
deeptally key import [--shell zsh|bash]  # import the key from the login shell into the Keychain
deeptally key delete                     # forget the stored key
deeptally usage [--json]                 # usage summary (stub until Step 4)
deeptally --version | --help
```

Like the app, the CLI reads the API key from the **Keychain first, then `DEEPSEEK_API_KEY`**, so a terminal
and the menu bar use the same key. Exit codes are `0` ok, `2` no usable key, `1` usage error or any other
failure. Full command reference: [`docs/USAGE.md`](docs/USAGE.md).

## Screenshots

Rendered from the shipping views by `make screenshots`, not drawn by hand:

![The DeepTally popover](docs/assets/popover.png)
![The DeepTally popover in dark mode](docs/assets/popover-dark.png)
![The DeepTally settings block](docs/assets/settings.png)

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

If the app is running but its status item is hidden, `make kill` is the reliable way out until a menu-bar
fallback lands.

## Privacy

DeepTally talks to exactly one host today: `api.deepseek.com` (balance and models; a loopback-only proxy
that forwards your own requests is planned for v1.1, opt-in). `api.github.com` is reserved for a future
update check and is not contacted by any current build. No analytics. No crash reporting. No third-party
servers. The API key lives in the macOS Keychain, never in a file or a preference.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
