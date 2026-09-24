# DeepTally

**DeepSeek usage meter for the macOS menu bar.** Balance, spend, tokens and cache-hit rate — at a glance, locally.

> **Status: pre-alpha.** The step-by-step build plan is in [`docs/PLAN.md`](docs/PLAN.md).

## What it does

- Shows your DeepSeek account balance in the menu bar, with an explicit "as of" timestamp
- Tallies token usage, spend and **cache-hit rate** from the requests made on your Mac
- Estimates cost per model, including DeepSeek's peak / off-peak pricing windows
- Alerts when the balance drops below a threshold you set
- Starts at login, lives in the menu bar, no Dock icon

## What it does not do

- No telemetry, no account, no cloud sync. Everything stays on your Mac.
- Never stores prompt or completion **content** — counters, timestamps and model names only
- Does not scrape DeepSeek's private dashboard endpoints (balance + per-response usage only)
- Not affiliated with, endorsed by, or connected to DeepSeek

## Install

Not released yet. Planned: a DMG on GitHub Releases (ad-hoc signed, not notarized), plus a hash-pinned
install script that avoids the Gatekeeper dialog entirely. See [`docs/PLAN.md`](docs/PLAN.md).

## Development

Requires macOS 15+, Xcode Command Line Tools, Swift 6.4+. Xcode itself is not required.

```sh
make build     # build app + CLI
make test      # run tests
make bundle    # assemble DeepTally.app (ad-hoc signed)
make run       # launch the bundled app
```

`AGENTS.md` documents the toolchain, environment and conventions in detail.

## Privacy

DeepTally talks to exactly two hosts: `api.deepseek.com` (balance, models, and — only if you opt in —
a local proxy that forwards your own requests) and `api.github.com` (update check only). No analytics.
No crash reporting. No third-party servers. The API key lives in the macOS Keychain.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
