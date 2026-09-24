# Architecture

How DeepTally is put together, and why. The plan of record and current status live in
[`PLAN.md`](PLAN.md); this page is the map.

## Targets

| Target | Kind | Ships as | Role |
|---|---|---|---|
| `DeepTallyCore` | library | linked into both executables | types, DeepSeek client, pricing, importer, ledger |
| `DeepTallyApp` | executable | `DeepTally.app` | AppKit status item + SwiftUI popover |
| `deeptally` | executable | CLI binary | scripts, terminals, SwiftBar |
| `DeepTallyCoreTests` | test target | — | swift-testing suites, fixtures only |

The app target is `DeepTallyApp`, not `DeepTally`: SwiftPM product names must differ by more than letter
case because APFS is case-insensitive, and `DeepTally` vs `deeptally` collided at link time. For the same
reason the CLI target declares an explicit `path: Sources/DeepTallyCLI` ([`../AGENTS.md`](../AGENTS.md) §9.10).

Current status (end of Step 1): `DeepTallyCore` types + `DeepSeekClient`, the `NSStatusItem` app shell, the
CLI and the test target exist. Pricing, usage/SSE parsing, the opencode importer, the ledger and the
analytics views land in Steps 1 (parallel lanes), 4 and 5.

## Data flow

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

Balance and usage are deliberately separate paths. The balance comes from the account and is authoritative
but eventually consistent; usage comes from local sources and is the only way to see history, because
DeepSeek has no historical usage API.

## Menu bar and lifecycle

`DeepTallyApp` is an `LSUIElement` accessory app: no Dock icon, no main window, just a status item whose
button hosts an `NSPopover` containing a SwiftUI view. That is AppKit `NSStatusItem`, deliberately **not** a
SwiftUI `MenuBarExtra`-only app: on macOS 26+, such an accessory app can be killed silently when the user
disables the item in Control Center → Menu Bar ([`../AGENTS.md`](../AGENTS.md) §9.1, [`PLAN.md`](PLAN.md) §3).

One related macOS 27 trap: `NSMenu` hides item symbol images by default. When menus are added, use
`labelStyle(.titleOnly)` or set `preferredImageVisibility` explicitly ([`../AGENTS.md`](../AGENTS.md) §9.8).

## The ledger

One SQLite file — WAL journal, `synchronous=NORMAL`, a single connection, prepared statements. Schema
([`PLAN.md`](PLAN.md) §4):

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

- `raw_hash` is `UNIQUE`: importing the same source row twice is a no-op, which is what makes imports
  idempotent.
- `daily` is rebuilt from `request`; raw `request` rows are pruned at 400 days, rollups are kept.
- CSV is an export format, never the primary store.
- `meta` holds bookkeeping such as `schema_version` and `last_balance`.
- The database lives under `~/Library/Application Support/DeepTally` (Step 4); see [`PRIVACY.md`](PRIVACY.md)
  for what is and is not in it.

## Source trust levels

Rows mean different things depending on where they came from, so provenance is stored (`request.source`,
`request.provider`) rather than inferred — see `UsageSource` and `Provider` in
`Sources/DeepTallyCore/Types.swift`.

| Source | What it measures | How much to trust it |
|---|---|---|
| DeepSeek API | Account balance (`GET /user/balance`) | Authoritative for the account, but eventually consistent — always shown with an "as of" timestamp, never as real-time. |
| DeepSeek per-response usage | Prompt / completion / cache counters | Authoritative for the requests DeepSeek served. |
| opencode import | Tokens and counters recorded in the local DB | Real counters, but scoped to what opencode recorded on this Mac. |
| Gateway imports (`kilo`, `openrouter`) | Per-request cost claims from a gateway | Labelled **estimated** and kept out of the DeepSeek balance. |
| CSV / manual | Rows you supply | Taken at face value, with provenance recorded so they can be filtered or removed. |

Costs are computed locally by `CostEngine` from token counters and the price table (Step 4), so every spend
figure is an estimate: the model line-up and prices changed three times in 2026, peak/off-peak
classification depends on a holiday calendar, and the ledger cannot see other machines, the web dashboard,
or periods when DeepTally was closed ([`PLAN.md`](PLAN.md) §7).

## Rate-now math

DeepSeek prices requests differently inside peak windows, and the windows flip twice a day — so the popover
shows "what am I paying right now" instead of a static price list.

- Peak windows are **01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding Chinese public holidays**.
- Everything else is off-peak, at exactly half the peak price.
- Classification is always computed **in UTC**, against `Resources/ChinaHolidays.json` (holidays are data,
  not code).
- The result is **displayed in the user's local timezone**, with the next transition and a countdown. A
  window label is never derived from local-time arithmetic — only its presentation is local
  ([`../AGENTS.md`](../AGENTS.md) §9.9).
- For each model the popover shows the effective cache-hit, cache-miss and output price per 1M tokens for
  the current window.
- Prices and model IDs are never hardcoded in Swift: they load from `Resources/PriceTable.json`, which is
  versioned data and user-overridable ([`../AGENTS.md`](../AGENTS.md) §9.11).

## Source map

| Path | Contents |
|---|---|
| `Sources/DeepTallyCore/Types.swift` | `UsageSource`, `Provider`, balance types, `Decimal.parse` |
| `Sources/DeepTallyCore/API/DeepSeekClient.swift` | Balance and models HTTP client (the only network code so far) |
| `Sources/DeepTallyCore/Resources/PriceTable.json` | Versioned price data |
| `Sources/DeepTallyApp/` | `main.swift`, `AppDelegate`, `AppModel`, `StatusItemController`, `PopoverView` |
| `Sources/DeepTallyCLI/main.swift` | The `deeptally` CLI |
| `Tests/DeepTallyCoreTests/` | swift-testing suites; fixtures only, never the network |
| `Scripts/bundle.sh` | Hand-assembles `dist/DeepTally.app` and ad-hoc signs it |

Planned modules (`Pricing/`, `Import/`, the ledger store) live under `DeepTallyCore` as they land, so the
CLI and the app share exactly the same engine. See [`DEVELOPMENT.md`](DEVELOPMENT.md) for the build/test
workflow, and [`PLAN.md`](PLAN.md) for the step-by-step.
