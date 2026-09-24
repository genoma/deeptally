# DeepTally — implementation plan

**Status:** Step 0 complete · Step 1 in progress · **Last updated:** 2026-09-24 · **Owner:** @genoma
**Name:** DeepTally · **Repo:** `genoma/deeptally` · **Bundle:** `io.github.genoma.deeptally` · **CLI:** `deeptally`

> **How we work:** one step at a time. A step is only done when its **gate** passes, its checkboxes are
> flipped in the same commit, and a dated line is added to the progress log (§10). Nothing gets built
> ahead of the plan without a decision recorded here first.

---

## 1. Locked decisions

| # | Decision | Value | Reason |
|---|---|---|---|
| 1 | Distribution | GitHub Releases, **DMG, ad-hoc signed, not notarized** | No Apple Developer Program |
| 2 | Apple Developer Program | **No** ($99/yr declined) | Consequence: no cask, no Sparkle, an **Open Anyway detour on every browser-downloaded update** (measured: the exception is per-build), "Open Anyway" docs required |
| 3 | Platform | **macOS 15.0+**, arm64-only, 64-bit native | macOS 27 Golden Gate is Apple-silicon-only; 15+ ≈ 98% of tracked installs |
| 4 | Stack | Swift 6.4 + SwiftPM, AppKit `NSStatusItem` + SwiftUI popover, system `libsqlite3` | No Xcode, no third-party deps |
| 5 | License | **GPL-3.0-or-later** | User requirement; App Store is incompatible by design → GitHub distribution |
| 6 | Name | **DeepTally** (repo `deeptally`) | 0 GitHub name collisions; "DeepSeek" kept in the README, not the product name |
| 7 | CLI | `deeptally` sharing `DeepTallyCore` | Enables brew **formula** (not cask), scripting, SwiftBar, testability. Renamed from `dtally` — too cryptic |
| 8 | Repo model | **Git flow** (`main`/`develop`, `feature/*`, `release/*`, `hotfix/*`) + **SemVer** + Conventional Commits | User requirement |
| 9 | Proxy capture | Deferred to v1.1, opt-in, loopback only | v1 covers the real usage path (opencode) already |
| 10 | Privacy | Local-only, no telemetry, counters never content | Non-negotiable |
| 11 | Menu bar metric | **balance** | Glanceable, slow-moving |
| 12 | Low-balance alert | **$2.00** | User choice; configurable in Settings |
| 13 | Currency | Show the account currency **as-is** (USD or CNY) | No FX guessing; `balance_infos[]` can hold both |
| 14 | Rate-now indicator | Show **current peak/off-peak window in the user's local timezone**, countdown to the next transition, and the effective $/1M for each model | User idea: the window flips twice a day, so a static price list is less useful than "what am I paying right now" |

## 2. Non-goals (v1)

App Store · Intel/universal binaries · notarization · Homebrew cask · Sparkle auto-update · cloud sync ·
iOS · scraping DeepSeek's private dashboard endpoints · storing prompt or completion text ·
per-request cost claims from gateway providers (kilo/openrouter are labelled *estimated*).

## 3. Verified evidence (2026-09-24)

**Platform**
- macOS 27 "Golden Gate" is shipping; build `26A428` = this machine. First Apple-silicon-only macOS.
  macOS 26.7 / 15.8 still receive security updates; Sonoma is out of support.
- API floors: `MenuBarExtra` 13.0, `SMAppService` 13.0, `Observation`/`SwiftData` 14.0 → all ≤ 15.0.
- `MenuBarExtra`-only accessory apps can die silently on macOS 26+ when disabled in Control Center → use `NSStatusItem`.
- No `actool`; `iconutil` + `sips` present → prebuilt `.icns`.
- 0 code-signing identities on this machine → ad-hoc (`codesign --sign -`) is the only option.

**DeepSeek API (probed live)**
- `GET /user/balance` → `{ is_available, balance_infos: [{ currency, total_balance, granted_balance, topped_up_balance }] }`, amounts are **strings**, no timestamp → show "as of".
- `GET /models` → exactly `deepseek-flash`, `deepseek-v4-pro`.
- Chat usage carries `prompt_tokens`, `completion_tokens`, `total_tokens`,
  `prompt_cache_hit_tokens`, `prompt_cache_miss_tokens`, `prompt_tokens_details.cached_tokens`.
  `prompt_tokens = cache_hit + cache_miss`.
- **There is no historical usage/spend API.** Only per-request usage + a manual monthly CSV export.
- Rate limits are concurrency-based (2500 flash / 500 pro); errors 401/402/429.

**Pricing (USD per 1M tokens, peak / off-peak) — volatile data, never hardcoded**

| Model | cache-hit | cache-miss | output |
|---|---|---|---|
| `deepseek-flash` (V4.1-Flash) | 0.006 / 0.003 | 0.30 / 0.15 | 1.20 / 0.60 |
| `deepseek-v4-pro` | 0.044 / 0.022 | 1.32 / 0.66 | 3.96 / 1.98 |

Peak = 01:00–04:00 and 06:00–10:00 UTC, Mon–Fri, excluding Chinese public holidays; everything else is
off-peak at exactly half. Model line-up/prices changed three times in 2026 → `Resources/PriceTable.json`.

**Local usage source**
- `~/.local/share/opencode/opencode.db` (SQLite): `message.data` JSON has `tokens.input/output/reasoning/cache.read/cache.write`
  plus `cost`, `modelID`, `providerID`; `session` denormalises per-model totals (do not trust those — they ignored cache-read pricing).
  Cache reads verified non-zero locally. **Both schema generations are live and hold largely distinct rows** — the importer
  unions `message` + `session_message` (2590 rows only in `message`, 1062 only in `session_message`; 0 divergent counters
  across the 1638 overlapping token-bearing rows).
- The DB also stores credentials **in plaintext** in a credential table → read `message` only, never that table.
- Two schema generations exist (`message`+`part`, `session_message`) → feature-detect.

**Distribution mechanics (verified on macOS 27)**
- Gatekeeper gates on **quarantine**: browser downloads → blocked; `curl` downloads carry only `com.apple.provenance` → launch cleanly.
- macOS 15+ removed the Control-click bypass → *System Settings → Privacy & Security → Open Anyway*.
- Ad-hoc identity is content-derived: a rebuilt bundle has a different code hash, so a Gatekeeper exception
  approved for one build does **not** carry over to the next (verified: `Killed: 9` after approving the
  previous build) — but Keychain access is *not* affected (verified: no prompt across a rebuild, because the
  item's default ACL is permissive).
- Homebrew casks now require Gatekeeper-passing apps and `--no-quarantine` was removed → no cask; a **formula** for the CLI is allowed.
- GitHub Actions: free arm64 `macos-26` runner with Xcode 26.x for public repos (CI is easier than local builds).

## 4. Architecture

```
DeepSeek API ──balance──┐
                        ├──> BalanceService ──> MenuBarLabel + Popover
usage sources:          │
  opencode.db ──import──┤
  loopback proxy (1.1) ─┼──> LedgerStore (SQLite) ──> CostEngine ──> Analytics views
  CSV import ───────────┘         ▲                      ▲
                                  │                      │
                          PriceTable.json        ChinaHolidays.json
```

**Targets** (`Package.swift`): `DeepTallyCore` (library) · `DeepTallyApp` (app executable, bundled as `DeepTally.app`) · `deeptally` (CLI) · `DeepTallyCoreTests`.

> The app target is `DeepTallyApp`, not `DeepTally`: SwiftPM product names must differ by more than case
> (APFS is case-insensitive), and `DeepTally` vs `deeptally` collided at link time.

**Ledger schema (SQLite, WAL)**

```sql
CREATE TABLE request (
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('proxy','opencode','csv','manual')),
  provider TEXT NOT NULL, model TEXT NOT NULL,
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  reasoning INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0, cost_usd REAL NOT NULL DEFAULT 0,
  session_id TEXT, raw_hash TEXT UNIQUE
);
CREATE TABLE daily (                                   -- rebuilt from request
  date TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
  input INTEGER, output INTEGER, reasoning INTEGER, cache_read INTEGER,
  cost_usd REAL, request_count INTEGER, PRIMARY KEY (date, provider, model)
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);  -- schema_version, last_balance, …
```

Raw rows pruned at 400 days; `daily` rollups kept. Export = CSV (never the primary store).

## 5. Step-by-step

### Step 0 — Repository foundation  ✅
- [x] Create `~/Developer/deeptally`, `git init -b main`
- [x] GPL-3.0 `LICENSE`, `README.md`, `AGENTS.md`, `CHANGELOG.md`, `.gitignore`
- [x] `docs/PLAN.md` (this file) with the step protocol
- [x] Git flow branches (`main`, `develop`) + gitflow config prefixes
- [x] Public GitHub repo `genoma/deeptally`, default branch `develop`
  **Gate:** `git log` shows the foundation commit on both branches; repo reachable on GitHub.

### Step 1 — Buildable skeleton + first parallel lanes
- [x] `Package.swift` (macOS 15, Swift 6 mode, 4 targets), `Makefile`, `.swift-format`
- [x] `DeepTallyCore`: types, errors, `DeepSeekClient` (balance + models) — verified against the live API
- [x] `DeepTallyApp` shell: `NSStatusItem` + `NSPopover` + SwiftUI popover; `LSUIElement`; ad-hoc bundle builds
- [x] `deeptally` CLI: `--version`, `balance` (real balance verified 2026-09-24), `usage` stub
- [x] `Scripts/bundle.sh` — hand-assembled `DeepTally.app`, ad-hoc signed, `codesign --verify` clean
- [x] `PriceTable` loader, `PeakOffPeak`, `CostEngine` + holiday calendar *(lane PRICING — 32 tests; independently cross-checked against a Python reference over 2268 comparisons, 0 mismatches)*
- [x] usage/SSE parsing + error mapping *(lane API — 21 tests)*
- [x] opencode importer *(lane OPENCODE — 14 tests, read-only, credential-table DENY authorizer, union of both generations)*
- [x] `Scripts/make-icon.swift`, `Resources/AppIcon.icns`, menu bar **gauge** template glyph, README hero *(lane ICON — deterministic generator, 10 iconset sizes; ~40 glyph variants measured, gauge chosen over bars because descending bars read as signal strength next to Wi-Fi/battery; evidence: `docs/assets/menubar-glyph-comparison.png`)*
- [x] `docs/` set: INSTALL, UNSIGNED, PRIVACY, ARCHITECTURE, DEVELOPMENT, RELEASING + SECURITY/CONTRIBUTING *(lane DOCS — 63 links verified, commands checked against the Makefile)*
- [ ] Wire the pricing engine + opencode importer into the ledger and CLI (`LedgerStore`, `deeptally usage`) — Step 4
- [x] Holiday calendar: official 2026 CN State Council dates (33 days, 国办发明电〔2025〕7号) shipped in `ChinaHolidays.json`; prior years are not included — user override available
- [ ] Decide the API lane's `DeepSeekAPIError` vs `DeepSeekClient.APIError` duplication at wiring time
  **Gate:** `make build && make test && make bundle` pass with CLT only ✅ 2026-09-24 · `deeptally balance` prints a real balance ✅ · status item visible ⏳ needs a human look.
  **Lanes:** ICON, PRICING, API, OPENCODE, DOCS (see §6) — parent owns Package.swift/Makefile/UI/scripts.

### Step 2 — M0 spikes (evidence, not features)
- [ ] **S1** ad-hoc `.app` → DMG → real macOS 27 Gatekeeper flow  *👤 needs user screenshots*
- [ ] **S2** App Translocation: launch from DMG vs from `/Applications`
- [ ] **S3** `SMAppService.mainApp.register()` under ad-hoc, in `/Applications` and `~/Applications`
- [ ] **S4** `UNUserNotificationCenter` authorization under ad-hoc  *👤 needs an "Allow" click*
- [ ] **S5** Keychain prompt behaviour across a rebuilt bundle (same bundle ID)
- [x] **S6** `curl` download leaves no quarantine (verified: only `com.apple.provenance`)
- [x] **S7** live DeepSeek probe: balance + models + usage fields (done 2026-09-24)
  **Gate:** findings recorded in `docs/SPIKES.md` with observed output; fallbacks chosen for S3/S4 if they fail.

### Step 3 — Balance, menu bar, lifecycle
**Status:** core logic merged (Wave A) · app wiring + UI in progress (Wave B)
- [x] Keychain-backed API key: `KeychainStore` + `APIKeySource`, one-time import from the shell rc *(lane KEYCHAIN — 20 tests; the key is never logged, errors never echo it)*
- [x] Settings model: `AppSettings` + `SettingsStore`, tolerant decoding + clamping (\$2 threshold, 20 min cadence, balance metric) *(lane SETTINGS — 14 tests)*
- [x] Rate-now presenter: local-time window, countdown, effective per-model prices *(lane RATE — 12 tests; non-vacuity proven by mutating the rounding and watching tests fail)*
- [x] Balance logic: `BalanceMonitor`, `PollingPlan` (jitter is additive only), `NotificationPolicy` *(lane BALANCE — 30 tests, re-run green under 5 timezones)*
- [x] Quit affordance: popover Quit button + `make kill`, documented in README
- [ ] App wiring: import UI replacing the "No API key" dead end, polling on wake/manual, settings sheet, rate-now panel, **translocation banner** (S2 showed real launches running from AppTranslocation)
- [ ] Launch at login via `SMAppService.mainApp` — **no LaunchAgent fallback**: S3 measured ad-hoc registration working (status `enabled`, no prompt)
- [ ] Notifications wired to `NotificationPolicy`, with a menu-bar fallback when denied
- [ ] CLI: `deeptally key import|status|delete`, `deeptally rate`
- [ ] Docs: `docs/USAGE.md` + privacy update for the Keychain item
  **Gate:** real balance visible; survives kill/restart, sleep/wake and airplane mode; login item registers on a fresh install.
  **Lanes:** Wave A (keychain, settings, rate, balance) merged · Wave B (views, cli, integration, docs)

### Step 4 — Ledger, pricing, importer
- [ ] `LedgerStore` + migrations + dedupe (`raw_hash`); pricing table + holiday calendar + peak/off-peak engine
- [ ] opencode importer (read-only, feature-detected, resumable, never credential tables)
- [ ] `deeptally usage --json` and `deeptally import --opencode`
  **Gate:** cost computed for a known opencode session matches a hand-calculated value; importer is idempotent.

### Step 5 — Analytics popover + exports
- [ ] Popover: balance card, today/7d/30d spend, cache-hit %, per-model breakdown, cache sparkline
- [ ] Menu bar metric modes (balance / today $ / cache %), thresholds; CSV export + import
  **Gate:** cache % matches ledger query; export→import round-trips to identical rollups.

### Step 6 — Release machinery + uninstaller
- [ ] `Scripts/sign.sh` (`SIGNING=adhoc|devid` seam), `dmg.sh`, `install.sh` (hash-pinned, `--user`), **`uninstall.sh`**
- [ ] In-app *Uninstall DeepTally…*: unregister login item, move app to Trash, purge app-support/prefs/caches, delete Keychain item, optional ledger export
- [ ] `.github/workflows/ci.yml` (build, test, lint, SPDX-header grep, codesign verify) and `release.yml` (tag → DMG + `SHA256SUMS` + release)
- [ ] `docs/INSTALL.md`, `docs/UNSIGNED.md`, `docs/PRIVACY.md`, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`, `SECURITY.md`, `CONTRIBUTING.md`
- [ ] Homebrew **formula** tap for `deeptally` only; GitHub Immutable Releases enabled
  **Gate:** `install → uninstall → reinstall` leaves no residue (verified with a throwaway `HOME`), and the DMG works on a second macOS version.

### Step 7 — v0.1.0
- [ ] `release/0.1.0` branch, CHANGELOG, tag `v0.1.0` on `main`, DMG + checksums published
- [ ] `docs/PLAN.md` closed out with the release link
  **Gate:** a fresh macOS 15+/26/27 machine installs using only the published instructions.

## 6. Lane assignments (for parallel subagent work)

| Lane | Owns (exclusive files) | Gate |
|---|---|---|
| ICON | `Scripts/make-icon.swift`, `Resources/AppIcon.icns`, menu bar template glyph, `docs/assets/hero.png`, `docs/ICON.md` | valid `.icns`, legible at 16px, `sips`-verified sizes |
| PRICING | `Sources/DeepTallyCore/Pricing/*`, `Resources/PriceTable.json`, `Resources/ChinaHolidays.json`, `Tests/.../PricingTests.swift` | `swift test --filter Pricing` |
| API | `Sources/DeepTallyCore/API/*`, `Tests/.../APITests.swift` (fixtures only, no network) | `swift test --filter API` |
| OPENCODE | `Sources/DeepTallyCore/Import/OpenCode*.swift`, `Tests/.../OpenCodeTests.swift` (fixture DB) | idempotent import, no credential-table reads |
| DOCS | `docs/INSTALL.md`, `UNSIGNED.md`, `PRIVACY.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, `RELEASING.md`, `SECURITY.md`, `CONTRIBUTING.md` | every claim traceable to §3 evidence |

Parent keeps: `Package.swift`, `Makefile`, app UI, `Scripts/*`, `.github/*`, `AGENTS.md`, this plan.
One writer per worktree; lanes branch from `develop` and merge back with `--no-ff`.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| No usage-history API | Blind spots (other machines, web use, app closed) | Local ledger + CSV import + explicit "estimated" labelling |
| Pricing/model churn | Wrong costs | Versioned JSON table + user override + live probe before releases |
| Ad-hoc signing quirks | Gatekeeper re-approval on every browser-downloaded update (**confirmed**) · login-item/notification failures (**disproved**: both work, see S3/S4) · Keychain re-prompts (**disproved**) | Spikes S1–S5 complete; findings written into `INSTALL.md`/`UNSIGNED.md`; `curl` install path is the friction-free route |
| Gatekeeper friction | Install drop-off | `curl` install script (no quarantine) + screenshots for the DMG path |
| opencode schema drift | Import breaks | Feature-detection + fixture tests + CLI `--json` escape hatch |
| macOS 26/27 UI bugs | Silent app death | `NSStatusItem` instead of `MenuBarExtra`-only |
| Balance is eventually-consistent | Users think it's live | "as of" timestamp, never claim real-time |

## 8. Versioning & release policy

SemVer, `0.y.z` until stable. `feature/*` → `develop`; `release/x.y.z` cut from `develop` (CHANGELOG freeze),
merged `--no-ff` into `main`, tagged `vX.Y.Z`; `hotfix/*` branch from `main`, merged to both. Conventional
Commits drive the CHANGELOG. Artifacts: DMG + `SHA256SUMS` + source tarball, published with Immutable Releases on.

## 9. Decisions resolved (2026-09-24)

| Question | Answer |
|---|---|
| Menu bar default metric | **balance** |
| Low-balance threshold | **$2.00**, surfaced in Settings (DeepSeek's own platform also flags a low balance, so this matches the mental model) |
| Personal tap with a `deeptally` formula | **yes**, Step 6 (CLI only — never a cask) |
| CNY handling | **show as-is**, never convert |
| Off-peak visibility | **rate-now indicator** in local time + countdown + effective prices |

## 10. Progress log

| Date | Step | Note |
|---|---|---|
| 2026-09-24 | 0 | Repo created, license/README/AGENTS/plan committed, remotes pushed |
| 2026-09-24 | 2 | S6 (quarantine/curl) and S7 (live API probe) verified during planning |
| 2026-09-24 | — | Decisions resolved: balance metric, $2 threshold, tap yes, CNY as-is, rate-now indicator added; CLI renamed `dtally` → `deeptally` |
| 2026-09-24 | 1 | Skeleton builds: `DeepTallyCore` + `DeepTallyApp` + `deeptally`, 5 tests green, ad-hoc bundle verified, live balance via CLI |
| 2026-09-24 | 1 | Traps fixed + documented: APFS case-insensitivity merged `DeepTally`/`deeptally` paths; CLT needs `-plugin-path .../plugins/testing` for swift-testing macros |
| 2026-09-24 | 1 | Five lanes merged (icon, pricing, api, opencode, docs): 41 files, 72 tests in 14 suites, lint clean, bundle signed |
| 2026-09-24 | 1 | opencode importer evidence: both schema generations live with disjoint rows (2590 / 1062 / 1638 overlap); union rule adopted, 0 divergent counters |
| 2026-09-24 | 1 | Menu bar glyph revised to a gauge after a measured bars-vs-gauge comparison; app icon/hero byte-identical across the revision |
| 2026-09-24 | 1 | `ChinaHolidays.json` filled with the official 2026 State Council list (33 days) + integration test on shipped data |
| 2026-09-24 | 2 | Spikes complete. Measured: SMAppService works under ad-hoc (no LaunchAgent needed); notifications grant; Keychain does NOT re-prompt across rebuilds (docs corrected); Gatekeeper exceptions are **per-build**, so every browser-downloaded update needs a fresh approval; App Translocation observed twice on real launches. |
| 2026-09-24 | 3 | Wave A merged (keychain, settings, rate, balance): 12 files, 150 tests in 25 suites, lint clean. Quit affordance added. Settings-test preference residue reduced from one file per run to exactly one. |
