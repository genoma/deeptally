# Architecture

How DeepTally is put together, and why. The plan of record and current status live in
[`PLAN.md`](PLAN.md); this page is the map.

## Targets

| Target | Kind | Ships as | Role |
|---|---|---|---|
| `DeepTallyCore` | library | linked into both executables | types, DeepSeek client, pricing, importer, ledger |
| `DeepTallyApp` | executable | `DeepTally.app` | AppKit status item + SwiftUI popover |
| `deeptally` | executable | CLI binary | scripts, terminals, SwiftBar |
| `DeepTallyCoreTests` | test target | — | core suites: ledger, pricing, importer, rate, settings |
| `DeepTallyCLITests` | test target | — | the CLI's parsers, local-day windows, reports and reprice |
| `DeepTallyAppTests` | test target | — | the app layer: `AppModel`, `AppEnvironment`, `LocalUsageLedger` |

The two executables are linked into their own test bundles in place, so the CLI command surface and the app's
state owner are tested without extracting a library ([`DEVELOPMENT.md`](DEVELOPMENT.md)).

The app target is `DeepTallyApp`, not `DeepTally`: SwiftPM product names must differ by more than letter
case because APFS is case-insensitive, and `DeepTally` vs `deeptally` collided at link time. For the same
reason the CLI target declares an explicit `path: Sources/DeepTallyCLI` ([`../AGENTS.md`](../AGENTS.md) §9.10).

Current status (after Step 4): `DeepTallyCore` carries the ledger, the incremental import flow and the
reprice repair; `DeepTallyApp` imports local usage and shows two ledger-backed menu-bar metrics beside the
balance; the `deeptally` CLI has `usage`, `import`, `ledger export|prune|reprice` next to the Step 3
commands. The analytics popover and CSV import are Step 5; what any of it does for a user is in
[`USAGE.md`](USAGE.md).

## Data flow

```
DeepSeek API ──balance──> DeepSeekClient ──> BalanceMonitor ──> AppModel ──┬──> StatusItemController
                        (one per refresh,                                 │        (menu bar title)
                         bound to the key)                               │
                                                                         └──> PopoverView
                                                                              ├─ StatusBanner ×n
                                                                              ├─ BalanceSection
                                                                              ├─ RateNowPanel
                                                                              ├─ login item toggle
                                                                              ├─ SettingsPanel
                                                                              └─ Quit + key origin

local usage:
  opencode.db ──read-only──> OpenCodeImporter ──┐
                                                ├─> LedgerSync ──> LedgerStore (SQLite, WAL)
  PriceTable.json + ChinaHolidays.json ─> CostEngine (prices each row once, at its own instant)
                                                                      │
                                     local-day ts ranges ──> LedgerSummary ──> `deeptally usage`
                                                                      └────────> menu-bar metrics
```

Balance and usage are deliberately separate paths. The balance comes from the account and is authoritative
but eventually consistent; usage comes from local sources and is the only way to see history, because
DeepSeek has no historical usage API. The rate-now panel reads the price table directly — no network, no
ledger.

Local usage has one writer (`LedgerStore`, used by `LedgerSync`) and two readers: the CLI's `usage` report
and the app's menu-bar metrics. Both ask the ledger for a `ts` range built from the **local** calendar, which
is the split the next section explains. The app runs one import pass at launch and every fifteen minutes
(`LocalUsageLedger`, an actor, so neither the SQLite work nor a full scan of a large database reaches the
main actor); the CLI imports on demand. Both use the same `LedgerSync` flow, so "what happens if I import
twice?" has one answer in one place.

## Menu bar and lifecycle

`DeepTallyApp` is an `LSUIElement` accessory app: no Dock icon, no main window, just a status item whose
button hosts an `NSPopover` containing a SwiftUI view. That is AppKit `NSStatusItem`, deliberately **not** a
SwiftUI `MenuBarExtra`-only app: on macOS 26+, such an accessory app can be killed silently when the user
disables the item in Control Center → Menu Bar ([`../AGENTS.md`](../AGENTS.md) §9.1, [`PLAN.md`](PLAN.md) §3).

One related macOS 27 trap: `NSMenu` hides item symbol images by default. When menus are added, use
`labelStyle(.titleOnly)` or set `preferredImageVisibility` explicitly ([`../AGENTS.md`](../AGENTS.md) §9.8).

### How the app target is assembled

`AppEnvironment` is the **single composition point**. It is built once, at launch, and holds the collaborators
both the model and the views need, so neither has to know how a key source, a price table or a holiday
calendar is put together — and there is exactly one place where those choices are made:

- `KeychainStore` + `APIKeySource` (Keychain first, then `DEEPSEEK_API_KEY`) and the `KeychainStore` itself,
  so the app can report *where* a key came from without reading it — including a Keychain read that failed
  and fell back to the environment, which the resolver carries as a sentence for the *"Keychain read
  problem: …"* banner;
- `SettingsStore` and `LaunchStateStore` (the last reading and the last alert time);
- the price table (a valid `~/.config/deeptally/PriceTable.json` override wins over the bundled
  `PriceTable.json`), the merged holiday calendar, `PeakOffPeakEngine`, `CostEngine` and `RateNowPresenter`;
  one engine is shared by the rate panel and by costing, so the price a row is stored with cannot drift from
  the price the panel shows;
- the ledger file, the opencode database path and the `LocalUsageLedger` factory, so neither the model nor a
  view knows how store, importer and pricing are assembled. `makeUsageSource` is deliberately `nil` when the
  bundled price table cannot be read: a costing that priced every row at zero would write that zero into the
  ledger permanently, so importing is disabled instead and the next pass with a good table catches up;
- `makeClient`, which binds one `DeepSeekClient` to the key a refresh resolved, so a re-imported key takes
effect on the next request instead of being captured at launch.

Composing is **fail-soft**: an unreadable bundled price table or holiday file is recorded as a sentence for
the popover's banner slot and that part falls back (`PriceTable.unavailable`, an empty calendar) rather than
stopping the app. A present-but-invalid user override is separate: `PriceTableLoader` ignores it in favour of
the bundled table and returns the reason from `loadWithDiagnostics()` to a caller that has somewhere to show
it. Monitor and notification policy are built *for* a threshold and a cooldown, so a settings change gets a
fresh object instead of an object holding the old value.

`AppModel` is the **state owner**. It is `@MainActor @Observable` and owns the key origin *and the Keychain
problem that resolution reported*, the balance state, the rate-now display, the login-item status and the
banner list derived from all of them. Three rules it keeps: a refresh never runs twice at once — a request
that arrives while one is in flight is *queued*, not dropped, which is what makes "press Import and a refresh
follows shortly" true; the next refresh always comes from `PollingPlan` (interval, then backoff, then additive
jitter) rather than a hand-rolled timer chain; nothing blocking runs on the main actor (the two blocking
kinds of work — the key import's shell and every ledger pass — run in a detached task and in
`LocalUsageLedger`'s actor respectively). It re-renders the countdown on a 30-second ticker, refreshes on
`NSWorkspace.didWakeNotification` and on the unsatisfied → satisfied edge of `NWPathMonitor`, and posts
low-balance alerts through `NotificationPolicy` — stamping the cooldown only once macOS accepted the post, so
a denial or a failed post is retried rather than silencing the alert. While macOS will not deliver, the menu
bar carries a warning glyph instead.

Local usage is a separate, fixed cadence: one pass at launch and every fifteen minutes through
`LocalUsageLedger`, recomputing today's spend and the trailing-30-day cache-hit rate. A tick that arrives
while a pass is running is skipped rather than queued — a fifteen-minute tick must not join a launch scan of
a large database — and a failed pass keeps the last good numbers, because blanking them would turn a
transient unreadable file into "you spent nothing". The only trace of a failure is the quiet settings note.

`StatusItemController` owns the `NSStatusItem` and the `NSPopover` and mirrors `AppModel.menuBarLabel` through
Observation, so the title follows a refresh the model started on its own timer.

`LoginItem` and `UserNotificationScheduler` are **thin system wrappers**. `LoginItem` folds
`SMAppService.Status` into one enum and adds a sentence for a failure. There is deliberately **no LaunchAgent
fallback**: an integration spike measured `SMAppService.mainApp.register()` succeeding for an ad-hoc-signed
bundle with no approval prompt ([`SPIKES.md`](SPIKES.md) S3), so a fallback would be dead code — it is only
needed if a future macOS changes that. `UserNotificationScheduler` is the only type that touches
`UNUserNotificationCenter`; a denial is a normal outcome, not an error path — the **menu bar carries a
warning glyph while the balance is low**, and the settings panel states once that alerts are not delivered.
`postLowBalance` reports back whether the notification centre accepted the post, and `authorization()` reads
the live system status, so the caller can tell "not allowed" from "delivery failed"; a notification carries
the amount and threshold, never a key.

The `Views/` directory and `PopoverView` are **presentation only**: they read state and call closures, run no
shell, open no Keychain item and know no key. Strings arrive ready to place from the `DeepTallyCore`
presenters (`BalanceMonitor`, `RateNowPresenter`), and prices are never hardcoded in the UI. Previews use
`PreviewProvider` structs, because `#Preview` cannot compile under Command Line Tools
([`../AGENTS.md`](../AGENTS.md) §9.13, [`DEVELOPMENT.md`](DEVELOPMENT.md)).

`Spikes.swift` and `LaunchLog.swift` are the Step 2 measurement commands (`--spike …`) and the optional launch
log. They exit before any UI exists and are not on the normal app path ([`SPIKES.md`](SPIKES.md)).

## The ledger

One SQLite file at `~/Library/Application Support/DeepTally/ledger.sqlite` — WAL journal,
`synchronous=NORMAL`, a single connection, prepared statements, money as integers. The schema as built
(migration v1; `meta` is created by the migration runner itself, because the version is a `meta` row):

```sql
CREATE TABLE request (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,                    -- whole epoch seconds, UTC
  source TEXT NOT NULL,                   -- 'opencode' today; 'proxy','csv','manual' reserved
  provider TEXT NOT NULL,                 -- 'deepseek','kilo','openrouter','unknown'
  model TEXT NOT NULL,                    -- the id exactly as the source spelled it
  input INTEGER NOT NULL DEFAULT 0,       -- cache-miss prompt tokens (cache writes folded in)
  output INTEGER NOT NULL DEFAULT 0,      -- completion tokens, reasoning excluded
  reasoning INTEGER NOT NULL DEFAULT 0,
  cache_read INTEGER NOT NULL DEFAULT 0,  -- the cache-hit prompt tokens
  cache_write INTEGER NOT NULL DEFAULT 0,
  cost_micro_usd INTEGER NOT NULL,        -- 1e-6 USD, exact
  session_id TEXT,
  raw_hash TEXT UNIQUE                    -- the dedupe key
);
CREATE INDEX request_ts ON request(ts);
CREATE TABLE daily (                      -- rebuilt from request
  date TEXT NOT NULL,                     -- UTC date: date(ts,'unixepoch')
  provider TEXT NOT NULL, model TEXT NOT NULL,
  input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
  reasoning INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
  cost_micro_usd INTEGER NOT NULL DEFAULT 0, request_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (date, provider, model)
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

Deviations from the sketch in [`PLAN.md`](PLAN.md) §4:

- **Money is an integer.** `cost_usd REAL` became `cost_micro_usd INTEGER` (1e-6 USD, `Decimal` in Swift).
  A binary float makes a cent-level sum drift as rows accumulate, and this project does not put money in a
  `Double`; the conversion happens exactly once, at the database boundary, rounding half away from zero.
- **`daily` has no `cache_write` column**, which loses nothing today: records built from opencode's counters
  fold cache writes into `input`, so the prompt-side columns still add up. `request` stays the exact store.
- **`source` carries no `CHECK`.** The column is written from the `UsageSource` enum, and CSV rows with an
  unknown source are rejected at parse time, so an unknown string cannot arrive through either path.
- An index on `ts` was added; every range query, and the prune, scans by it.

### Why a UTC rollup and local-day ranges

`request.ts` is UTC epoch seconds; `daily` is keyed by **UTC date**, which is what makes a long-range query
cheap and a prune safe. But "what did I spend today" is a question about the user's clock, and a local
midnight can fall in the middle of a UTC day. So the rollup is never asked for local totals: `deeptally
usage` and the app's `LocalUsageLedger` both build `[start of a local day, start of the next)` with
`Calendar` and ask `summary(since:until:)` of the raw rows. Reading "today" out of the UTC rollup would be
off by a day for every user east or west of UTC — the kind of bug that looks like a rounding error. Days are
added through the calendar rather than as 86 400 seconds, so a DST day stays a whole local day.

### The watermark, and why re-running is free

`raw_hash` is `UNIQUE` (a SHA-256 of `(source, id, session_id)`) and inserts are `INSERT OR IGNORE`, so
importing the same source row twice writes nothing. On top of that, the ledger stores the newest instant it
has imported per source in `meta` (`import_watermark.opencode`, epoch milliseconds — opencode's own
resolution). The next incremental scan asks opencode only for rows newer than that instant, which is what
makes a 400 MB database cheap to re-read every fifteen minutes. The watermark is a lower bound and never
moves backwards; `LedgerSync.fullResync()` (`deeptally import --full`) rescans everything for the one row a
strict `>` cannot see.

### Aliases live in the price table

Model ids are volatile — DeepSeek renamed and retired models three times in 2026 — so an id is not matched by
code but by data: each `ModelPrice` in `PriceTable.json` carries an `aliases` list, and
`PriceTable.price(forModel:)` resolves in a fixed order — exact id, exact alias, the last `/`-separated path
component against the ids, then that component against the aliases. Case-sensitive, with no fuzzy matching,
no version ordering and no "closest entry" fallback: an id the table does not know stays unresolved, so a
caller can report it as unpriced instead of billing a guess. A duplicate alias across two rows is a
validation error (`PricingDataError.duplicateAlias`). The shipped table carries the ids the real ledger
needed; the `deepseek/…` route forms resolve by stripping the route, not by being listed.

### Reprice is the repair path

A row's cost is computed **once**, at import, from the window in force at that row's own timestamp, and
stored beside its tokens. That is what makes history stable — and what makes a mispriced row permanent: a
re-import is a duplicate by `raw_hash`, so it cannot correct anything. `LedgerStore.reprice(costing:)`
(`deeptally ledger reprice`) is the one write that touches the past:

- `RowCosting` (implemented by `CostEngine`) returns `nil` — never zero — for a model it cannot price. A
  `nil` row keeps its stored cost and is reported as unpriced, because a zero written there would be
  indistinguishable from a measured zero.
- Rows are read in primary-key batches, and only the rows whose cost actually changes are written, so a
  large ledger costs one batch in memory rather than the whole table.
- The `daily` rollups are rebuilt inside the same transaction, and the price-table version is recorded in
  `meta`, which is how a second pass can say "the costs already came from this table" and write nothing.

**Worked example, measured on this project's own ledger.** Before aliases, only one of six model ids in the
5,275-row ledger resolved against the table, so most rows carried a stored cost of zero. After the alias fix,
`deeptally ledger reprice` reported **5,275 rows examined, 4,237 changed, `$3.754373 → $14.378060`, 0 rows
unpriced**, with `integrity_check` clean and the rollups agreeing with the raw aggregate exactly; a second
run changed nothing. That delta is the whole argument for repricing rather than re-importing: the tokens were
always right, only the prices were missing.

- CSV is an export format, never the primary store: `deeptally ledger export` writes every raw row, and
  `LedgerStore.importCSV` parses it back (no CLI command for the import yet — Step 5).
- `meta` holds `schema_version`, the import watermarks and `reprice.price_table_version`.
- Raw rows are pruned only when asked (`deeptally ledger prune --days N`), whole UTC days at a time, and the
  `daily` rollups are kept — a pruned day's totals survive. Nothing prunes automatically yet; the plan's
  400-day policy is not wired in.
- See [`PRIVACY.md`](PRIVACY.md) for what is and is not in the file.

## Source trust levels

Rows mean different things depending on where they came from, so provenance is stored (`request.source`,
`request.provider`) rather than inferred — see `UsageSource` and `Provider` in
`Sources/DeepTallyCore/Types.swift`.

| Source | What it measures | How much to trust it |
|---|---|---|
| DeepSeek API | Account balance (`GET /user/balance`) | Authoritative for the account, but eventually consistent — always shown with an "as of" timestamp, never as real-time. |
| DeepSeek per-response usage | Prompt / completion / cache counters | Authoritative for the requests DeepSeek served. |
| opencode import | Tokens and counters recorded in the local DB | Real counters, but scoped to what opencode recorded on this Mac. |
| Gateway imports (`kilo`, `openrouter`) | Per-request usage reported by a gateway | Real counters, priced locally like any other row; DeepTally cannot check a gateway's cost claims against DeepSeek's billing, so treat the figure as an estimate. |
| CSV / manual | Rows you supply | Taken at face value, with provenance recorded so they can be filtered or removed. |

Costs are computed locally by `CostEngine` from token counters and the price table, so every spend figure is
an estimate: the model line-up and prices changed three times in 2026, peak/off-peak classification depends
on a holiday calendar, and the ledger cannot see other machines, the web dashboard, or anything opencode
never recorded ([`PLAN.md`](PLAN.md) §7).

## Rate-now math

DeepSeek prices requests differently inside peak windows, and the windows flip twice a day — so the popover
shows "what am I paying right now" instead of a static price list.

- Peak windows are **01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding Chinese public holidays**.
- Everything else is off-peak, at exactly half the peak price.
- Classification is always computed **in UTC**, against `Sources/DeepTallyCore/Resources/ChinaHolidays.json`
  (holidays are data, not code).
- The result is **displayed in the user's local timezone**, with the next transition and a countdown. A
  window label is never derived from local-time arithmetic — only its presentation is local
  ([`../AGENTS.md`](../AGENTS.md) §9.9).
- For each model the popover shows the effective cache-hit, cache-miss and output price per 1M tokens for
  the current window.
- Prices and model IDs are never hardcoded in Swift: they load from
  `Sources/DeepTallyCore/Resources/PriceTable.json`, which is versioned data and user-overridable
  ([`../AGENTS.md`](../AGENTS.md) §9.11).
- The panel labels its prices with the **price table's own currency** (`USD per 1M tokens` for the shipped
  table). Amounts are never converted ([`PLAN.md`](PLAN.md) §1, decision 13).

## Source map

| Path | Contents |
|---|---|
| `Sources/DeepTallyCore/Types.swift` | `UsageSource`, `Provider`, balance types, `PriceTable`, `Decimal.parse` |
| `Sources/DeepTallyCore/API/DeepSeekClient.swift` | Balance and models HTTP client (the only network code) |
| `Sources/DeepTallyCore/Security/` | `KeychainStore` (one generic-password item) and `APIKeySource` (Keychain → environment, one-time shell import) |
| `Sources/DeepTallyCore/Balance/` | `BalanceMonitor`, `PollingPlan`, `NotificationPolicy` — pure logic, no timers |
| `Sources/DeepTallyCore/Settings/` | `AppSettings` (defaults + clamped ranges) and `SettingsStore` |
| `Sources/DeepTallyCore/Pricing/` | `PriceTableLoader` (bundled + user override), `HolidayCalendar`, `PeakOffPeakEngine`, `CostEngine` |
| `Sources/DeepTallyCore/Rate/RateNowPresenter.swift` | "What am I paying right now", formatted for the injected time zone |
| `Sources/DeepTallyCore/Import/OpenCodeImporter.swift` | Read-only union of opencode's two schema generations; credential tables denied at the connection |
| `Sources/DeepTallyCore/Ledger/` | `LedgerStore` (schema, inserts, rollups, prune, CSV), `LedgerSync` (the one incremental flow), `LedgerSummary`, `LedgerCSV`, `LedgerReprice` |
| `Sources/DeepTallyCore/Resources/` | `PriceTable.json` and `ChinaHolidays.json` — versioned data, not code |
| `Sources/DeepTallyApp/AppEnvironment.swift` | The composition root (and `LaunchStateStore`); builds the ledger's importer and costing |
| `Sources/DeepTallyApp/AppModel.swift` | State owner: key origin, polling, refresh, banners, the three menu-bar metrics |
| `Sources/DeepTallyApp/LocalUsageLedger.swift`, `MetricFormatting.swift` | The app's actor around the ledger (import cadence, local-day ranges) and the metric text |
| `Sources/DeepTallyApp/Views/`, `PopoverView.swift` | Presentation only |
| `Sources/DeepTallyApp/LoginItem.swift`, `UserNotificationScheduler.swift` | Thin system wrappers |
| `Sources/DeepTallyApp/StatusItemController.swift`, `AppDelegate.swift`, `main.swift` | Status item + popover, lifecycle, entry point |
| `Sources/DeepTallyApp/Spikes.swift`, `LaunchLog.swift` | Step 2 measurement commands; not on the normal app path |
| `Sources/DeepTallyCLI/Commands.swift`, `Options.swift`, `UsageReport.swift` | The `deeptally` command set, its argument parsers and the usage report |
| `Tests/DeepTallyCoreTests/`, `Tests/DeepTallyCLITests/`, `Tests/DeepTallyAppTests/` | swift-testing suites; fixtures only, never the network, never the real opencode database |
| `Scripts/bundle.sh`, `Scripts/dmg.sh` | Hand-assembled bundle and DMG |

The analytics popover and CSV import are still to land (Step 5), and like the ledger they belong to
`DeepTallyCore` so the CLI and the app share exactly the same engine. See
[`DEVELOPMENT.md`](DEVELOPMENT.md) for the build/test workflow, [`USAGE.md`](USAGE.md) for the user-facing
behaviour, and [`PLAN.md`](PLAN.md) for the step-by-step.
