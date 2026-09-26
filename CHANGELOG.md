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
