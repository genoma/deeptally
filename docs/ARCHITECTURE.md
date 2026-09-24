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

Current status (end of Step 3): `DeepTallyCore` is complete for Step 3 (types, client, keychain, settings,
balance, rate, pricing, opencode import) and `DeepTallyApp` is wired end to end — composition root, state
owner, popover, login item, notifications. The ledger, the analytics views and the CLI's `usage` command are
Steps 4–5; `deeptally usage` is still a stub. What the app does for a user is in [`USAGE.md`](USAGE.md).

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

usage sources (Step 4):
  opencode.db ──import──┐
  loopback proxy (1.1) ─┼──> LedgerStore (SQLite) ──> CostEngine ──> Analytics views
  CSV import ───────────┘         ▲                      ▲
                                  │                      │
                          PriceTable.json        ChinaHolidays.json
```

Balance and usage are deliberately separate paths. The balance comes from the account and is authoritative
but eventually consistent; usage comes from local sources and is the only way to see history, because
DeepSeek has no historical usage API. The rate-now panel reads the price table directly — no network, no
ledger.

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
  `PriceTable.json`), the merged holiday calendar, `PeakOffPeakEngine` and `RateNowPresenter`;
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
jitter) rather than a hand-rolled timer chain; nothing blocking runs on the main actor (the one blocking call,
the key import's shell, runs in a detached task). It re-renders the countdown on a 30-second ticker,
refreshes on `NSWorkspace.didWakeNotification` and on the unsatisfied → satisfied edge of `NWPathMonitor`, and
posts low-balance alerts through `NotificationPolicy` — stamping the cooldown only once macOS accepted the
post, so a denial or a failed post is retried rather than silencing the alert. While macOS will not deliver,
the menu bar carries a warning glyph instead.

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
| `Sources/DeepTallyCore/Import/OpenCodeImporter.swift` | Read-only opencode import; the ledger wires it up in Step 4 |
| `Sources/DeepTallyCore/Resources/` | `PriceTable.json` and `ChinaHolidays.json` — versioned data, not code |
| `Sources/DeepTallyApp/AppEnvironment.swift` | The composition root (and `LaunchStateStore`) |
| `Sources/DeepTallyApp/AppModel.swift` | State owner: key origin, polling, refresh, banners |
| `Sources/DeepTallyApp/Views/`, `PopoverView.swift` | Presentation only |
| `Sources/DeepTallyApp/LoginItem.swift`, `UserNotificationScheduler.swift` | Thin system wrappers |
| `Sources/DeepTallyApp/StatusItemController.swift`, `AppDelegate.swift`, `main.swift` | Status item + popover, lifecycle, entry point |
| `Sources/DeepTallyApp/Spikes.swift`, `LaunchLog.swift` | Step 2 measurement commands; not on the normal app path |
| `Sources/DeepTallyCLI/Commands.swift` | The `deeptally` command set |
| `Tests/DeepTallyCoreTests/` | swift-testing suites; fixtures only, never the network |
| `Scripts/bundle.sh`, `Scripts/dmg.sh` | Hand-assembled bundle and DMG |

Planned modules (the ledger store and the analytics views) live under `DeepTallyCore` as they land, so the CLI
and the app share exactly the same engine. See [`DEVELOPMENT.md`](DEVELOPMENT.md) for the build/test
workflow, [`USAGE.md`](USAGE.md) for the user-facing behaviour, and [`PLAN.md`](PLAN.md) for the step-by-step.
