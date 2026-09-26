# DeepTally — implementation plan

**Status:** Step 6 complete · **Last updated:** 2026-09-26 · **Owner:** @genoma
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
**Status:** complete — gate run and recorded below (2026-09-24)
- [x] Keychain-backed API key: `KeychainStore` + `APIKeySource`, one-time import from the shell rc *(lane KEYCHAIN — 20 tests; the key is never logged, errors never echo it)*
- [x] Settings model: `AppSettings` + `SettingsStore`, tolerant decoding + clamping (\$2 threshold, 20 min cadence, balance metric) *(lane SETTINGS — 14 tests)*
- [x] Rate-now presenter: local-time window, countdown, effective per-model prices *(lane RATE — 12 tests; non-vacuity proven by mutating the rounding and watching tests fail)*
- [x] Balance logic: `BalanceMonitor`, `PollingPlan` (jitter is additive only), `NotificationPolicy` *(lane BALANCE — 30 tests, re-run green under 5 timezones)*
- [x] Quit affordance: popover Quit button + `make kill`, documented in README
- [x] App wiring: import UI replacing the "No API key" dead end, polling on wake/manual, settings panel, rate-now panel, **translocation banner** (S2 showed real launches running from AppTranslocation)
- [x] Launch at login via `SMAppService.mainApp` — **no LaunchAgent fallback**: S3 measured ad-hoc registration working (status `enabled`, no prompt). The toggle reads the live system status and re-reads it on the ticker
- [x] Notifications wired to `NotificationPolicy`, with the menu-bar warning glyph as the fallback when the system will not deliver
- [x] CLI: `deeptally key import|status|delete`, `deeptally rate` *(lane CLI — 418 lines; `rate` correctly reports a Mid-Autumn holiday today, and the key is never printed)*
- [x] Docs: `docs/USAGE.md` + privacy update for the Keychain item

  **Gate evidence (2026-09-24, all observed):**
  - **Real balance, Keychain only:** rendered the shipping popover with `DEEPSEEK_API_KEY` unset → `keyOrigin: keychain`, `$11.66`, "as of", off-peak panel, no banners.
  - **Kill/restart:** two consecutive `make smoke` cycles (app alive after 4 s each) plus the persisted reading in the app domain (`...last-reading`, 173 bytes) adopted at launch.
  - **Wake:** `--spike simulate-wake` → `refreshedOnWake: true`, fetch timestamp advanced 21:44:49Z → 21:44:50Z. *Honest limit:* this proves our handler; delivery on a real lid-open is macOS behaviour and is not simulated.
  - **`make verify`-class gate:** build · 164 tests at the time · lint clean · bundle · `codesign --verify --strict` · `make smoke`. (The suite is 319 tests by the end of Step 4.)
  - **Independent review:** blocked the gate on two P1 defects and seven P2s; all fixed, each core fix proven by a test that fails without it, and the two P1s re-verified by a forced-low render (`menuBarWarningGlyph: true`, tooltip "DeepSeek balance … is low.") and by a 401 → Forget key → banner-gone sequence.
  - **Still human-checkable (recorded, not claimed):** offline/airplane mode end to end (deliberately not simulated — it would disrupt the network; the error path itself was exercised by a real 401), and real sleep/wake. A first-run login-item registration was measured in S3 but not re-exercised here, because it would leave a login item pointing at a development path.
  - **Was a known gap, closed in Step 4:** the app target had no automated tests at all, so every app-layer claim above rested on renders and inspection. Step 4 added `Tests/DeepTallyAppTests` (55 tests by the end of the step, over documented injection seams), which is why the layer could absorb the ledger without becoming guesswork.
  **Gate:** real balance visible ✅ · survives kill/restart ✅ · sleep/wake handler ✅ (simulated notification) · airplane mode ⏳ human-checkable · login item registers on a fresh install ✅ measured in S3.
  **Lanes:** Wave A (keychain, settings, rate, balance) · Wave B (views, cli, integration, docs) · Wave C (review fixes: core, app, docs)

### Step 4 — Ledger, pricing, importer
**Status:** complete — acceptance-reviewed 2026-09-24/25 (all findings closed; see the note below)
- [x] `LedgerStore` over the system `libsqlite3` with schema versioning from v1, `INSERT OR IGNORE` dedupe on `raw_hash`, UTC-keyed daily rollups, pruning, CSV round-trip *(lane LEDGER — 16 tests; money is INTEGER micro-USD because this project refuses Double for money; the store is deliberately not `Sendable`, which the compiler enforces)*
- [x] Importer extended with an incremental `since:` watermark, and `LedgerSync` as the one flow the CLI and the app share *(the ledger owns the watermark, because the ledger is what knows which rows committed)*
- [x] CLI: `deeptally import [--full]`, `deeptally usage [--json] [--days N]`, `deeptally ledger export|prune|reprice`
- [x] Menu-bar metrics: `todaySpend` and `cacheHitRate` enabled, fed by an actor that imports on launch and every 15 minutes off the main actor
- [x] **Model aliases as data**: `ModelPrice.aliases` + a four-rule resolver (exact id, exact alias, last path component against ids, then against aliases), case-sensitive, `nil` for anything unrecognised; collisions rejected loudly via `PricingDataError.duplicateAlias`
- [x] **`reprice`**, the repair path for rows already stored with a wrong cost
- [x] One user-facing sentence per error, defined once (the three duplicated switches are gone)

  **The finding that mattered (2026-09-24).** Importing the real opencode database showed 4,237 of 5,275 rows stored at **$0** — opencode writes model ids the price table did not list (`deepseek/deepseek-v4-flash-vision-exp`, `deepseek-v4-flash`, `deepseek-v4-pro-0813`, …), and Step 1's research had already recorded that those ids route to the V4.1-Flash and V4-Pro prices. Two flaws compounded: a resolution gap, and a stored cost that re-importing could never repair, because `raw_hash` treats those rows as duplicates. Fixed by aliases (data, so the next rename is a JSON edit) plus `reprice`. Result on the real ledger:

  | | before | after |
  |---|---|---|
  | rows at $0 | 4,237 of 5,275 | **0** |
  | total spend | $3.754373 | **$14.378060** |
  | unpriced models | 5 | **none** |

  **Gate evidence (all observed):**
  - **Idempotence:** `import` twice → `Imported 5275 new rows` then `Imported 0 new rows of 0 offered`; `import --full` → `0 new rows of 5275 offered`. After the N3 fix the *second* incremental import offers nothing even when opencode has touched a row since the first: the watermark now covers every instant the scan looked at, not just the newest creation.
  - **Acceptance review (fresh-context, read-only):** "F1, F2, F3, F4, F5, F6, F8 and F9 are each genuinely closed... no P0/P1." Every finding was checked against the deciding lines *and* against the test that fails if the fix is reverted. It then found eight lesser issues in the fixes' blast radius, of which six were fixed in the same step (N1, N2, N3, N5, N6, N7) and one is documented as a limitation (N4, in the importer's own comment).
  - **Hand-calculated cost, independently derived in SQL from the price table's own numbers:** every row of two real sessions matches exactly (flash 6/6 rows, v4-pro 1/1). Across the whole ledger the float-SQL cross-check agrees on **5,274 of 5,275 rows**; the single difference is a half-micro-USD rounding case (exact value 3657.5 µUSD) where floating point lands one micro below the ledger's exact `Decimal` arithmetic. The ledger is the correct one.
  - **Reasoning is billed as output:** the first version of that cross-check disagreed on five of six rows, and every gap was exactly the reasoning-token count multiplied by the output price — confirming the rule Step 1's research had only been able to infer.
  - **Reprice:** 4,237 rows changed, `integrity_check` ok, rollups agreeing with the raw rows to the micro-dollar, and a second run reporting `rowsChanged: 0`.
  - **Known limitations, tracked rather than hidden:**
    - **N4 (Step 5):** an incremental scan can offer a different copy of a row than a full scan when one
      copy's timestamps are both below the watermark and another copy was touched. No ledger effect today
      (equal counters are left alone); it can change which model a report names. The importer's comment
      states it plainly.
    - **Rollup reader (closed in Step 5):** nothing read the `daily` table, so a pruned range was gone
      from `deeptally usage` even though its aggregate survived. `LedgerStore.usageWindow` now reads it
      (whole UTC days only), and the command, its help and the docs say what that resolution costs.
    - **Rollup versus full resync (pre-existing):** a `--full` resync after a prune rebuilds only the days
      it touches from the surviving rows, so a day that a resync re-inserts *part* of can lose the rest
      of its kept aggregate. A prune itself removes whole UTC days, so it cannot leave the half-day case;
      the hole needs opencode to have lost rows the import can no longer offer. Step 5 makes it visible
      rather than silent: the day is reported as a rollup day.
  - **Environment note (2026-09-25):** the machine spent the night in DarkWake cycles (~16-minute
    maintenance wakes). Two effects, both diagnosable and neither a code defect: four lane runs stalled at
    their 30-minute deadline during throttled windows, and the Keychain returned `-25320 In dark wake, no
    UI possible` — which the app reported as a keychain problem and fell back on, exactly as the F7 fix
    intends. The menu bar shows a stale reading until the Mac is awake and the key resolves again.

### Step 5 — Analytics popover + exports
**Status:** complete — acceptance-reviewed 2026-09-26 (findings below)
- [x] Menu bar metric modes (balance / today $ / cache %), thresholds — landed with Step 4's ledger
- [x] Popover analytics: today/7d/30d spend, cache-hit %, per-model breakdown, cache trend — the panel and
      the two menu-bar metrics now come from one `usageWindow` read, so they cannot disagree
- [x] **Rollup reader**: `LedgerStore.usageWindow(since:until:provider:)` answers each UTC day from `request`
      while its rows are there and from `daily` once they are not; `deeptally usage` reads through it, so a
      pruned range stays visible as whole UTC days, with the rollup days counted and an unsliceable partial
      day named rather than folded in
- [x] Fix finding **N4** in the importer (decide each merge group from all of its copies before the watermark
      filter) and add the fixture the review said was missing — the incremental path re-reads every copy of
      an admitted group (ids chunked at 500, NULL session matched in memory)
- [x] CSV import/export surfaced in the UI (the ledger round-trips it; the CLI can export, and gained
      `DEEPTALLY_LEDGER` so a prune or reprice can be tried on a copy)

  **Gate evidence (2026-09-26, all observed on the real 5,275-row ledger):**
  - **A pruned range still shows its aggregate.** On copies of the real ledger, `usage --json --days 200`
    before and after `ledger prune --days 30` returns identical numbers for every window (today $0.000000,
    7 days $0.000000, 30 days $0.424729; the long window $14.378060 · 5,275 requests · 859,652,607 prompt
    tokens). The prune removed 4,936 raw rows; after it the long window reports **13 rollup days** and no
    unavailable day, and the human report prints *"note: 13 days in these windows come from the daily
    rollup table, which is keyed by whole UTC days."* Gate harness: `/tmp/deeptally-step5-gate.sh`.
  - **cache % matches a ledger query.** The 30-day window's spend, requests, prompt tokens and cache-hit
    rate were recomputed from `ledger export` output with Python `Decimal` over the same local range
    (99.2%, spend 0.424729, 279 requests, 41,601,554 prompt tokens) — exact, the rate within the 0.05-pt
    one-decimal rounding.
  - **export→import round-trips to identical rollups.** `LedgerTests.csvRoundTrips` now compares the `daily`
    tables as an ordered text snapshot between the source ledger and a fresh ledger imported from the CSV:
    identical, besides the raw-summary comparison that was already there.
  - **N4 non-vacuity:** the new `untouchedWinnerSurvivesIncrementalScan` failed on the unmodified importer
    (the incremental scan returned the sibling copy's model where a full scan returned the message copy's)
    and passes after the fix; the lane recorded both runs. The 501-group chunk test pins the chunk split.
  - **Independent review (fresh context, read-only, on `2423fea`):** no code defect; five documentation
    gaps. Disposition: **(P1)** the stale "after Step 4" status paragraphs in `USAGE.md`/`ARCHITECTURE.md` —
    fixed; the Step 5 checkboxes and the "nothing reads `daily`" lines it flagged had already been flipped
    in `4c874d9`, a commit after the one its checkout saw. **(P2)** the day-count contract overstated the
    provider-filtered case (a raw day with rows only for other providers was counted and listed empty) —
    fixed **in code**, not in prose: a filtered read now skips such a day, and the docs and the
    `providerFilter` test were updated with it. **(P2)** a comment claiming a CSV failure can never echo
    field text, and two comments still naming the settings panel as the caveat's home — corrected. The
    reviewer's session had no shell, so the parent re-ran its three requested mutation checks in a
    disposable clone: reverting the N4 second read, the rollup branch, and the whole-day gate each makes
    its guarding test fail (`untouchedWinnerSurvivesIncrementalScan`, `prunedDayKeepsItsTotals`,
    `partialDayWithoutRawRows`). Harness: `/tmp/deeptally-mutations.sh`.
  - **Known limitations, tracked rather than hidden:** the `daily` table has no `cache_write` column, so a
    rollup day reports `cacheWriteTokens = 0` — exact for every row this store writes (cache writes fold
    into `input`; the real ledger has 0 of 5,275 rows with a nonzero `cache_write`), inexact only for a row
    written by hand-written SQL. A day that is only partly inside a window and whose raw rows are pruned is
    named, not guessed at. `ledger reprice` still cannot revise a pruned row.
  **Gate:** cache % matches a ledger query ✅ · export→import round-trips to identical rollups ✅ · a pruned
  range still shows its aggregate through the rollup reader ✅

### Step 6 — Release machinery + uninstaller
**Status:** complete — acceptance-reviewed 2026-09-26; two items are human and stay open below
- [x] `Scripts/sign.sh` (`SIGNING=adhoc|devid` seam, used by `bundle.sh`), `dmg.sh`, `install.sh`
      (hash-pinned, `--user`, `--dir`, `--dmg`, `--sha256`), **`uninstall.sh`** (delegates to the app),
      `release-assets.sh` and the `make release-assets|release-check|install|uninstall` targets
- [x] In-app *Uninstall DeepTally…*: unregisters the login item, deletes the Keychain item, purges
      app-support/prefs/caches/saved state, moves the app to the Trash, and offers **Export CSV First…** —
      the same `Uninstaller` the headless `DeepTally --uninstall` runs (16 tests, every seam injectable)
- [x] `.github/workflows/ci.yml` (build, test, lint, SPDX grep, `bash -n` under 3.2, CLI `--version`,
      codesign verify) and `release.yml` (tag → five artifacts → GitHub Release, refusing an existing
      release; `workflow_dispatch` is the dry run), plus `DEEPTALLY_LEDGER` already shipped in Step 5
- [x] User docs written during Steps 3–4: `INSTALL.md`, `UNSIGNED.md`, `PRIVACY.md`, `ARCHITECTURE.md`,
      `DEVELOPMENT.md`, `RELEASING.md`, `USAGE.md`, `SECURITY.md`, `CONTRIBUTING.md`
- [ ] **Three Gatekeeper dialog screenshots** remain placeholders in `INSTALL.md`; they need a human to click
      through a quarantined first launch on macOS 27
- [x] Homebrew formula **generated** per release (`dist/deeptally.rb`, tarball URL + SHA-256, `libexec` +
      symlink so the CLI finds its resource bundle) and the tap procedure documented; the tap repository
      itself is created with the first release, because a formula before its artifact exists would 404.
      **GitHub Immutable Releases enabled** on the repository (API `PUT /immutable-releases`, `enabled: true`)

  **Gate evidence (2026-09-26, all observed):**
  - **`install → uninstall → reinstall` leaves no residue.** `/tmp/deeptally-step6-gate.sh`, against a
    throwaway `--dir` and `--home`: `make release-assets VERSION=0.0.1` writes five artifacts whose
    `SHA256SUMS` verifies; the CLI tarball runs under `env -i` and reads its bundled price table; the formula
    pins version, url and the tarball's SHA-256; install verifies the DMG hash, verifies
    `codesign --verify --strict`, and the bundle lands in the throwaway prefix; a wrong `--sha256` refuses
    and installs nothing; `--print-only` changes nothing; the uninstall (with `--keep-keychain` and
    `--keep-login-item`, so the machine running the gate is untouched) removes app support, preferences,
    caches and saved state, moves the bundle to the throwaway Trash, and leaves two bystander files intact;
    reinstall is clean.
  - **The release workflow runs end to end.** Dry run on a throwaway branch
    ([run 36227866864](https://github.com/genoma/deeptally/actions/runs/36227866864), macOS-26, 2m37s):
    version + CHANGELOG validation, `make release-check` (verify, assets, checksums), release-notes
    extraction, and the dry-run step; the publish step was correctly skipped and nothing was uploaded.
  - **CI runs on every push.** [Run 36227504013](https://github.com/genoma/deeptally/actions/runs/36227504013):
    `make verify`, SPDX headers, `bash -n` under `/bin/bash` 3.2, CLI `--version` — green in 2m38s. Both
    workflows register as `active` on the repository.
  - **Independent review (fresh context, read-only):** one P1 and four P2s, all closed — the `--keep-data`
    help text described keeping preferences and caches (it keeps only app data), `install.sh` removed the
    working app before copying the new one (now staged and swapped after verification), the manual-removal
    text omitted saved state, `DEVELOPMENT.md` still called `make install|uninstall|release-check` planned
    (targets added, docs updated), and the local `.sha256` sidecar was undocumented. The reviewer could not
    run scripts; the parent re-ran the full gate after the fixes.
  - **Known limitations, tracked rather than hidden:** the real `NSWorkspace.recycle` branch and the
    real-home `removePersistentDomain` branch have no automated coverage (tests and the gate inject a trash
    directory and a home); the real Trash move was probed once in a scratch binary, and
    `DeepTally --uninstall --print-only` exercises the real-path plan without changing anything. The
    publish step (`gh release create` under immutability) has never run: the first tag is its first run,
    which is inherently Step 7's job.
  **Gate:** `install → uninstall → reinstall` leaves no residue ✅ · the DMG works on a second macOS version ⏳
  human (this machine is the only one available)

### Step 7 — v0.1.0
- [ ] `release/0.1.0` branch, CHANGELOG, tag `v0.1.0` on `main`, DMG + checksums published
- [ ] `docs/PLAN.md` closed out with the release link
  **Gate:** a fresh macOS 15+/26/27 machine installs using only the published instructions.

## 6. How lanes are run (learned the hard way)

**What works.** Small briefs with exact file ownership: the files a lane owns, the files it must not touch,
its one gate command, and a compact report format. Every reviewer lane (read-only, no build loop) succeeded.

**What does not.** A brief that covers several findings at once, or that opens by asking the lane to read
`AGENTS.md` and this plan, spends 100k+ tokens before the first edit and cannot finish inside the default
30-minute deadline. Five Step-4 lanes were lost that way having produced nothing (two docs lanes, two fix
lanes, one core lane). The fix was either several narrow lanes or the parent doing the work directly.

**Rules that came out of it**
- One writer per file per wave. Two lanes were given the same CLI file in one wave and their work needed a
  third lane to reconcile; the docs lane noticed the drift before the parent did.
- Lane task text must contain **no backticks and no `${`**: the workflow script is a JavaScript template
  literal, so an inline code span silently truncates the brief. Check the manifest before launching and
  confirm that only the template delimiters carry backticks.
- Give writer lanes an explicit `timeoutMs` (60 minutes) and `checkpointBeforeDeadlineMs` instead of taking
  the 30-minute default. A lane that checkpoints can be continued; a lane that is killed has nothing.
- Verify a lane's claim against the artifact, not its report. Two lanes reported success in words while the
  work was absent from `develop`; both were caught by checking branches and diffs afterwards.
- Lanes need the machine **awake**. DarkWake (display off, short maintenance wakes) throttles background work
  and makes Keychain consent impossible — `-25320 In dark wake, no UI possible` — which is what stalled four
  lanes and one Keychain read on the night of 2026-09-24/25.
- The parent keeps: `Package.swift`, `Makefile`, app UI, `Scripts/*`, `.github/*`, `AGENTS.md`, this plan, and
  every integration merge. Lanes branch from `develop` and merge back with `--no-ff`.

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
| A typo in the user's price table | Real usage silently billed at zero, and a reprice over the bad table would certify it | Strict parsing + positive-price validation reject the whole table with a sentence naming the model and field (Step 4, F2); the app and CLI surface it instead of pricing around it |
| A model id the table does not know | `$0.00` rows, which read as *free* rather than *unknown* | The ledger reports unpriced rows (CLI warning, app note); `reprice` repairs stored rows after the table is fixed |
| Stored cost computed once at import | A table change cannot fix history by re-importing (raw_hash dedupes it) | `reprice` (CLI and app-on-launch) is the repair path; the app runs it once per launch when the table version changed |
| Rollup versus a later full resync | A resync that re-inserts only part of a pruned day's rows replaces that day's rollup with the smaller aggregate | A prune removes whole UTC days, so it cannot itself create the half-day case; the hole needs the source to have lost rows. `usage` reads the rollups, so the day is visible as a rollup day rather than silently gone. Recorded in Step 5 |
| Agent lanes stall or are lost | Work does not land; a lane can report success in words with nothing committed | Small briefs, explicit 60-minute deadlines with checkpointing, one writer per file, and a parent check of branches and diffs (§6) |
| App-layer claims unverified | Regressions in `AppModel` wiring | Closed in Step 4: `Tests/DeepTallyAppTests` covers the app layer (55 tests) over documented seams |

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
| Currency setting | **removed** (Step 4, review finding 2): decision 13 says the account currency is shown as-is, so a control that could not change anything was deleted rather than implemented |
| Price-table amounts | **strict**: an unparsable or non-positive amount rejects the whole table, naming the model and field; the balance API's strings stay tolerant because they come from a remote service |
| Ledger money | **integer micro-USD** exposed as `Decimal` — a deliberate departure from this plan's original `REAL` sketch, because a ledger is the worst place to accept binary-float drift |
| Model id resolution | **aliases as data** in the price table, four documented rules, case-sensitive, `nil` for anything unrecognised so it can be reported as unpriced rather than priced wrongly |
| A partly covered UTC day (Step 5) | **named as unavailable only when `daily` holds rows for it**; a day with nothing in either store contributes nothing and is not listed — a note about a day with no usage would read as missing data |
| New JSON keys (Step 5) | **snake_case** (`rollup_days`, `unavailable_days`), like every other multiword key in the `usage` document |
| Pointing the CLI at another ledger (Step 5) | **`DEEPTALLY_LEDGER=<path>`**: `HOME` does not redirect application support, so this is the one safe way to try `ledger prune`/`ledger reprice` on a copy. It exists because a gate script of mine got this wrong and pruned the real ledger (see the log) |
| Release tamper-protection (Step 6) | **Immutable Releases enabled** on the repository (`PUT /immutable-releases`, verified `enabled: true`): a published tag and its assets cannot be edited or deleted, so a bad release gets the next patch version, never a re-upload |
| Uninstaller ownership (Step 6) | **The Swift `Uninstaller` owns the removal list**; `Scripts/uninstall.sh` execs `DeepTally --uninstall`, so the popover button and the script cannot drift. `--keep-login-item`/`--keep-keychain` exist so the release gate never touches the machine that runs it |
| Install-time trust (Step 6) | `install.sh` verifies the DMG's SHA-256 **before** mounting and `codesign --verify --strict` **after** copying; quarantine is cleared only on a verified install, and a new copy is staged and swapped so a failed copy leaves the working app alone |
| Homebrew tap timing (Step 6) | The **tap repository is created with the first release**; `release-assets.sh` renders `dist/deeptally.rb` per version. A formula published before its artifact exists would 404 |

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
| 2026-09-24 | 3 | Wave B1 merged (views, CLI): four presentation views + `deeptally rate`/`key` commands. Two spec bugs caught by lanes: `#Preview` cannot compile under CLT (now AGENTS.md gotcha 13) and the CLI had to resolve keys keychain-first for its own advice to work. |
| 2026-09-24 | 3 | Wave B2 (integration) + B3 (docs, independent review) merged. The review **blocked the gate** on two P1s: the low-balance alert was marked delivered before it was (cooldown consumed even when the post failed, no menu-bar fallback) and the Currency setting was a live control wired to nothing. Also found seven P2s and one stale claim in SECURITY.md. |
| 2026-09-24 | 3 | Wave C (fixes) merged: 4 core fixes each with a test proven to fail without it, the P1 alert/fallback rework, the ticker re-evaluating staleness and login-item status, a queued refresh after import, banner clearing, the Keychain-problem diagnostic reaching app and CLI, and the real currency in the panel. Also keyed the key import end to end: `deeptally key import --shell zsh`, verified with the environment scrubbed. |
| 2026-09-24 | 3 | Docs lane merged (USAGE/PRIVACY/ARCHITECTURE/README + a regenerated settings screenshot), plus two parent follow-ups the lanes could not do: `AppEnvironment` now actually wires `loadWithDiagnostics()`, and the reviewer-style inspection of that wiring found a defect of my own — a rejected user override suppressed the rate panel and its banner contradicted itself. Both fixed by separating "no table" from "override rejected" and cutting an NSError dump out of the user-facing sentence. |
| 2026-09-24 | 4 | Ledger, importer watermark, aliases, reprice, CLI surface and menu-bar metrics all merged. The real-ledger finding (4,237 rows at $0) is recorded above with the before/after numbers. |
| 2026-09-24 | 4 | **Orchestration error of mine:** I launched two lanes against the same CLI file in one wave, merged one of them, then merged two further lanes on top before noticing. The union had to be reconciled by a dedicated lane with both test suites as the contract. The docs lane caught it first by observing that the code its documentation described was absent from its base. Lesson recorded: two writers, one file, no arbitration point is a brief-level mistake, not a lane-level one. |
| 2026-09-25 | 4 | Step 4 closed. Real ledger: 5,275 rows, 0 unpriced, \$14.378060. 319 tests (231 core + 33 CLI + 55 app). Independent acceptance review: every finding closed, no blockers. Six of its eight follow-ups fixed in the same step; N4 documented as a limitation. Also ported the app-side cost repair, which I had previously reported as delivered while its branch sat unmerged — reported, then corrected here. |
| 2026-09-26 | 5 | **Orchestration note of mine:** the first lane launch had no `cwd`, so worktree admission failed before dispatching anything; relaunched with the repo as cwd, nothing lost. |
| 2026-09-26 | 5 | Wave 1 lanes merged: **N4** (`9c6ada1`; the incremental scan re-reads all copies of an admitted group, ids chunked at 500, NULL matched in memory; new test failed before the fix and passes after) and the **rollup reader** (`96e0c00`; `usageWindow`, CLI reads through it, prune wording corrected). The parent review of the rollup lane sent it back with three findings — `unavailableDays` fired on usage-free boundary days, the new JSON keys were camelCase in a snake_case document, and `ARCHITECTURE.md` still said the rollups were never read — all three fixed in `76a194e` and merged with it. |
| 2026-09-26 | 5 | Parent work merged: CSV export/import in the popover (`ec87f14`), analytics panel + trend scale (`da38375`), then the wiring that reads both menu-bar metrics and the panel from one `usageWindow` pass (`4b64c00`) so a prune cannot blank either. The panel's provenance note was summing nested windows and counting a pruned day three times; fixed to use the largest window, like the CLI. The bulk of the step's test count: 347 tests (242 core + 38 CLI + 67 app). |
| 2026-09-26 | 5 | **Operational mistake of mine, recovered, and turned into a feature.** The first gate script pointed the CLI at a copy with `HOME=...`; macOS resolves the application-support directory from the real home, so `ledger prune --days 30` deleted **4,936 raw rows from the real ledger** (rollups and watermark untouched). `deeptally import --full` re-inserted exactly those rows — "Imported 4936 new rows of 5275 offered" — and the long-window totals are byte-identical to the pre-accident ones ($14.378060 · 5,275 requests · 859,652,607 prompt tokens). The durable fix is `DEEPTALLY_LEDGER=<path>` (`2423fea`), documented in the help and USAGE.md with the `HOME` trap named. An earlier "verification" of mine had checked the report but not the ledger path the CLI printed; the check that failed is now a test. |
| 2026-09-26 | 5 | **Step 5 gate passed** (harness `/tmp/deeptally-step5-gate.sh`, real ledger): window numbers identical before/after a 30-day prune; the long window reports 13 rollup days with no spurious unavailable day; the 30-day window matches the exported raw rows to the micro-dollar (spend 0.424729, 279 requests, 41,601,554 prompt tokens, 99.2% cache hit); `csvRoundTrips` compares the `daily` tables between a source ledger and a fresh ledger imported from its export — identical. |
| 2026-09-26 | 5 | Independent read-only review of `2351178..2423fea` (fresh context): **no code defect**; five documentation gaps, all closed — the stale "after Step 4" status paragraphs, an overstated provider-filter day contract (tightened in code rather than documented as a wart), a comment about CSV error text, and two comments still naming the settings panel as the caveat's home. The reviewer had no shell, so the parent re-ran its three mutation checks in a disposable clone: each reverted fix makes its guarding test fail. Step 5 closed. |
| 2026-09-26 | 6 | Wave 1 lanes merged: **release scripts** (`sign.sh`, `install.sh`, `uninstall.sh`, `release-assets.sh`, Make targets), **CI workflows**, **in-app uninstaller** (363 tests: 242 core + 38 CLI + 83 app). First real CI run green on macOS-26 in 2m38s; both workflows registered `active`; **Immutable Releases enabled** via the repository API. Docs lane merged on top, turning every "planned (Step 6)" sentence into the shipped commands and fixing a real trap: `SHA256SUMS` lists four files, so a DMG-only download needs the grep form. |
| 2026-09-26 | 6 | **Release dry run, first end-to-end execution of the release workflow** (run 36227866864, 2m37s, throwaway branch since the CHANGELOG heading is required): version + CHANGELOG validation, `make release-check`, release-notes extraction, dry-run stop. Nothing was published; the branch was deleted. The publish step itself runs first at the v0.1.0 tag, which is Step 7's job. |
| 2026-09-26 | 5 | **UI defect found by the user on real data, after Step 6:** the cache-hit trend drew every bar with `maxWidth: .infinity`, so the real two-day ledger rendered two 100% days as one panel-wide blue capsule that read as an unlabeled button that did nothing. Bars are now capped (10 pt, 2 pt floor, width shared across a full month) with the width arithmetic extracted to `TrendScale.barWidth` and tested; the same round exposed a swift-testing inference trap (a literal `(280 - 58) / 30` typed as integer division) now written explicitly. `bfdbd64`. The stale Sep-24 DMG that originally hid the fix was ejected and replaced, and the app in `/Applications` was reinstalled from the fresh build. |
| 2026-09-26 | 6 | **Step 6 gate passed:** install into a throwaway prefix (hash verified, signature verified, wrong hash refused), print-only a no-op, uninstall with `--keep-keychain`/`--keep-login-item` leaving no residue and both bystanders intact, reinstall clean; the CLI tarball runs under `env -i`; the formula pins version, url and tarball hash. Independent read-only review found one P1 (the `--keep-data` help text promised to keep preferences and caches; it keeps only app data) and four P2s — `install.sh` deleting the working app before a possibly failing copy (now staged and swapped), the manual-removal text missing saved state, a stale `DEVELOPMENT.md` and the missing `make install|uninstall` targets, and an undocumented local `.sha256` source. All fixed, gate re-run green. **Still human:** the three Gatekeeper dialog screenshots and the DMG on a second macOS version. |
