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
