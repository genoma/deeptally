# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project foundation: GPL-3.0-or-later license, README, `AGENTS.md`, implementation plan in `docs/PLAN.md`.
- Buildable skeleton: `DeepTallyCore` (types, errors, DeepSeek balance/models client), `DeepTallyApp` menu bar shell
  (`NSStatusItem` + popover, `LSUIElement`), `deeptally` CLI (`balance`), hand-assembled ad-hoc-signed `.app` bundle.
- Pricing: `PriceTableLoader` (bundled + user override), `HolidayCalendar`, `PeakOffPeakEngine` (UTC windows, Shanghai
  holidays, exact next transition) and `CostEngine` (peak/off-peak pricing, effective rates).
- Usage parsing: non-streaming and SSE accumulators, streaming model extraction, typed error envelopes for 401/402/429.
- opencode importer: read-only SQLite, unions both schema generations, SHA-256 dedupe hashes, credential-table read denial.
- Assets: deterministic icon generator (10 iconset sizes → `.icns`), menu bar template glyph, README hero.
- Docs: `INSTALL`, `UNSIGNED`, `PRIVACY`, `ARCHITECTURE`, `DEVELOPMENT`, `RELEASING`, `SECURITY`, `CONTRIBUTING`.
- 72 tests across 14 suites; `swift format` config pinned.

### Changed

- **The balance refresh policy is event-driven with a deferrable backstop.** Opening the popover fetches
  when the reading is over a minute old, so the value the user is looking at is current; wake, display
  wake, a returning user session, a returning network and a power-state change are recovery checks bounded
  by five minutes (a failed attempt always retries); the backstop timer runs at the user's interval on the
  power adapter and at least an hour on battery or in Low Power Mode. The timer is a one-shot wall-clock
  dispatch timer with a tolerance of at least 10% of the interval, so macOS can coalesce the wake-up. The
  stale window is now twice the effective interval instead of a fixed hour, an install's jitter offset is
  drawn once and persisted instead of re-randomised per poll, and the default refresh interval is 30
  minutes (still 5–240). A clock change re-derives the age and deadline without a fetch. Rationale and
  evidence: `docs/PLAN.md` Step 6.7.

- The menu bar always shows the account balance. The menu-bar metric picker is gone, along with the
  today-spend and cache-hit modes; a low balance replaces the balance with a warning glyph as before.
- Settings are now refresh interval, low-balance threshold, notifications on/off, notification cooldown and
  the key import/forget row; `menuBarMetric`, `proxyEnabled`, `proxyPort` and `showSecondaryMetric` were
  removed from the stored settings (an old blob keeps every remaining field and falls back to defaults for
  the removed ones).

### Removed

- The local usage ledger (schema, rollups, migrations) and everything that filled it: the opencode importer,
  the opt-in loopback proxy and its response reader, the analytics panel, CSV import/export, `ledger reprice`,
  the unpriced-row machinery, the `usage` / `import` / `ledger` CLI commands and `DEEPTALLY_LEDGER`.
  DeepSeek returns per-response usage only to the caller of that request and stores nothing queryable, so the
  usage half of the product had no API-only source; the decision and its evidence are in
  `docs/COUNCIL-2026-09-26.md`, and the plan steps are marked reverted in `docs/PLAN.md`.
