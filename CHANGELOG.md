# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-26

First public release. DeepTally is **API-only by design**: DeepSeek exposes no usage or spend endpoint to an
API key, so the app shows the balance, the rate in force and the key handling — it does not show spend
history, and it does not pretend to. The decision and its evidence are in `docs/COUNCIL-2026-09-26.md`.

### Added

- A native macOS menu bar app (`NSStatusItem` + SwiftUI popover, `LSUIElement`) and a `deeptally` CLI sharing
  one core library; macOS 15+, Apple silicon only.
- The DeepSeek account balance in the menu bar: account currency shown as-is (no FX conversion), an honest
  "as of" age, a low-balance warning glyph, and a configurable low-balance threshold ($2.00 by default).
- Desktop notifications for a low balance, with the menu-bar warning glyph as the fallback when macOS will not
  deliver, and a configurable cooldown.
- Keychain-backed API key handling: import from the login shell, status and delete (`DEEPSEEK_API_KEY` as a
  fallback); the key never enters preferences, logs or an export.
- A rate-now panel: the peak/off-peak window in the user's local timezone, the countdown to the next
  transition, and the effective USD/1M-token prices, from a versioned price table (bundled, user-overridable)
  and the 2026 Chinese public-holiday calendar.
- A refresh policy built for an API with no change signal: fetch when the popover opens, checks on wake,
  display wake, session switch-in, network return and power-state change, and a deferrable backstop timer
  (30 minutes by default, at least an hour on battery or in Low Power Mode).
- Launch at login via `SMAppService`, a quarantine/translocation warning banner, and an in-app uninstaller
  (also `DeepTally --uninstall`) that removes the login item, Keychain item, preferences, caches and the app.
- Settings: refresh interval (5–240 minutes), low-balance threshold, notifications and cooldown.
- `deeptally` CLI: `balance`, `rate`, `key import|status|delete`, `--version`.
- Distribution: ad-hoc-signed (not notarized) DMG and CLI tarball with `SHA256SUMS`, an `install.sh` that
  verifies the hash and signature, and a Homebrew formula for the CLI; Immutable Releases on GitHub.
- Documentation: `INSTALL`, `UNSIGNED`, `PRIVACY`, `USAGE`, `ARCHITECTURE`, `DEVELOPMENT`, `RELEASING`,
  `SECURITY` and `CONTRIBUTING`.
