# Architecture

How DeepTally is put together, and why. The plan of record and current status live in
[`PLAN.md`](PLAN.md); this page is the map.

## Targets

| Target | Kind | Ships as | Role |
|---|---|---|---|
| `DeepTallyCore` | library | linked into both executables | types, DeepSeek client, balance logic, pricing, key handling, settings |
| `DeepTallyApp` | executable | `DeepTally.app` | AppKit status item + SwiftUI popover |
| `deeptally` | executable | CLI binary | scripts, terminals, SwiftBar |
| `DeepTallyCoreTests` | test target | — | core suites: balance, pricing, rate, keychain, settings |
| `DeepTallyCLITests` | test target | — | the CLI's exit codes and command behaviour |
| `DeepTallyAppTests` | test target | — | the app layer: `AppModel`, `LaunchStateStore`, `Uninstaller` |

The two executables are linked into their own test bundles in place, so the CLI command surface and the app's
state owner are tested without extracting a library ([`DEVELOPMENT.md`](DEVELOPMENT.md)).

The app target is `DeepTallyApp`, not `DeepTally`: SwiftPM product names must differ by more than letter
case because APFS is case-insensitive, and `DeepTally` vs `deeptally` collided at link time. For the same
reason the CLI target declares an explicit `path: Sources/DeepTallyCLI` ([`../AGENTS.md`](../AGENTS.md)
§9.9).

Current status (after Step 6.6): `DeepTallyCore` carries the balance client, the monitor, the price table
loader, the holiday calendar, the peak/off-peak engine and the rate presenter; `DeepTallyApp` shows the
balance in the menu bar and the balance, rate panel, login item, settings and uninstaller in its popover;
the `deeptally` CLI has `balance`, `rate` and `key`. The app is API-only — there is no ledger, no importer
and no local capture. What any of it does for a user is in [`USAGE.md`](USAGE.md).

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

PriceTable.json + ChinaHolidays.json ──> PeakOffPeakEngine ──> RateNowPresenter ──> PopoverView
                                                                                 └─> `deeptally rate`
```

The balance and the rates are deliberately separate paths. The balance comes from the account, is
authoritative but eventually consistent, and is therefore always shown with the time it was fetched. The
rates are local data: the rate-now panel reads the price table and the holiday calendar directly — no
network, no key — and answers "what would a request cost right now", never "what did I spend". DeepSeek
exposes no usage endpoint, so the app has no third path ([`PLAN.md`](PLAN.md) §3,
[`COUNCIL-2026-09-26.md`](COUNCIL-2026-09-26.md)).

## Menu bar and lifecycle

`DeepTallyApp` is an `LSUIElement` accessory app: no Dock icon, no main window, just a status item whose
button hosts an `NSPopover` containing a SwiftUI view. That is AppKit `NSStatusItem`, deliberately **not** a
SwiftUI `MenuBarExtra`-only app: on macOS 26+, such an accessory app can be killed silently when the user
disables the item in Control Center → Menu Bar ([`../AGENTS.md`](../AGENTS.md) §9.1, [`PLAN.md`](PLAN.md) §3).

One related macOS 27 trap: `NSMenu` hides item symbol images by default. When menus are added, use
`labelStyle(.titleOnly)` or set `preferredImageVisibility` explicitly ([`../AGENTS.md`](../AGENTS.md) §9.7).

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
  `PriceTable.json`), the merged holiday calendar, `PeakOffPeakEngine`, `CostEngine` and `RateNowPresenter`,
  so the popover's rate panel and `deeptally rate` price the same window the same way;
- `makeFetcher`, which binds one `DeepSeekClient` to the key a refresh resolved, so a re-imported key takes
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
follows shortly" true; the next refresh always comes from `RefreshPolicy` and `PollingPlan` (the cadence for
the current power state, then backoff, then the install's persisted jitter offset) rather than a hand-rolled
timer chain; nothing blocking runs on the main actor (the one blocking kind
of work — the key import's shell — runs in a detached task). It re-renders the countdown on a 30-second
ticker. Refreshes are trigger-classed: opening the popover is the user looking, so it fetches unless the
reading is younger than a minute; wake, display-wake, a returning user session, a returning network and a
power-state change are recovery checks bounded by five minutes, and a failed attempt always retries; the
wall-clock dispatch-timer backstop runs at the user's interval on the adapter and at least an hour on battery
or in Low Power Mode, with a tolerance of at least 10% so macOS can coalesce the wake-up. A clock change
re-derives the age text and the deadline and fetches nothing. It posts low-balance alerts through
`NotificationPolicy` — stamping the cooldown only once
macOS accepted the post, so a denial or a failed post is retried rather than silencing the alert. While macOS
will not deliver, the menu bar carries a warning glyph instead.

`StatusItemController` owns the `NSStatusItem` and the `NSPopover` and mirrors `AppModel.menuBarPresentation`
through Observation, so the title follows a refresh the model started on its own timer.

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

`Uninstaller` owns the removal list behind the popover button and `DeepTally --uninstall`; every step that
leaves the process (file manager, login item, Keychain, preferences daemon, Trash move) is an injectable
seam, so tests and the release gate run the whole plan against throwaway paths ([`PRIVACY.md`](PRIVACY.md)).

The `Views/` directory and `PopoverView` are **presentation only**: they read state and call closures, run no
shell, open no Keychain item and know no key. Strings arrive ready to place from the `DeepTallyCore`
presenters (`BalanceMonitor`, `RateNowPresenter`), and prices are never hardcoded in the UI. Previews use
`PreviewProvider` structs, because `#Preview` cannot compile under Command Line Tools
([`../AGENTS.md`](../AGENTS.md) §9.12, [`DEVELOPMENT.md`](DEVELOPMENT.md)).

`Spikes.swift` and `LaunchLog.swift` are the Step 2 measurement commands (`--spike …`) and the optional launch
log. They exit before any UI exists and are not on the normal app path ([`SPIKES.md`](SPIKES.md)).

## Pricing data

Prices and model IDs are **data, not code**: `Sources/DeepTallyCore/Resources/PriceTable.json`, loaded by
`PriceTableLoader`. A user override at `~/.config/deeptally/PriceTable.json` wins when it is valid; an
invalid one is ignored (with a reason) in favour of the bundled table.

- The table carries a `version`, a `currency`, the `off_peak_multiplier`, the peak windows in UTC and the
  per-model cache-hit / cache-miss / output prices per 1M tokens.
- Loading is strict: an unparsable or non-positive price rejects the whole table with a sentence naming the
  model and field (`PricingDataError`), because a price typo silently applied is worse than no prices.
- Each model carries an `aliases` list, and `PriceTable.price(forModel:)` resolves in a fixed order — exact
  id, exact alias, the last `/`-separated path component against the ids, then that component against the
  aliases. Case-sensitive, with no fuzzy matching, no version ordering and no "closest entry" fallback: an id
  the table does not know stays unresolved rather than being priced at a guess. A duplicate alias across two
  rows is a validation error.
- The rate panel labels its prices with the **price table's own currency** (`USD per 1M tokens` for the
  shipped table). Amounts are never converted ([`PLAN.md`](PLAN.md) decision 13).
- If the bundled table cannot be read, `PriceTable.unavailable` (no models, no windows) is used and the rate
  panel is suppressed rather than claiming a period no data supports.

Model ids and prices changed three times in 2026, which is why neither is ever hardcoded in Swift
([`../AGENTS.md`](../AGENTS.md) §9.10).

## Rate-now math

DeepSeek prices requests differently inside peak windows, and the windows flip twice a day — so the popover
shows "what am I paying right now" instead of a static price list.

- Peak windows are **01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding Chinese public holidays**.
- Everything else is off-peak, at exactly half the peak price (the multiplier is read from the table, not
  assumed).
- Classification is always computed **in UTC**, against `Sources/DeepTallyCore/Resources/ChinaHolidays.json`
  (holidays are data, not code).
- The result is **displayed in the user's local timezone**, with the next transition and a countdown. A
  window label is never derived from local-time arithmetic — only its presentation is local
  ([`../AGENTS.md`](../AGENTS.md) §9.8).
- For each model the panel shows the effective cache-hit, cache-miss and output price per 1M tokens for the
  current window.

## Source map

| Path | Contents |
|---|---|
| `Sources/DeepTallyCore/Types.swift` | Balance types, `PriceTable`, `ModelPrice`, `PeakWindow`, `RateSnapshot`, `Decimal.parse` |
| `Sources/DeepTallyCore/API/DeepSeekClient.swift` | Balance and models HTTP client (the only network code) |
| `Sources/DeepTallyCore/Security/` | `KeychainStore` (one generic-password item) and `APIKeySource` (Keychain → environment, one-time shell import) |
| `Sources/DeepTallyCore/Balance/` | `BalanceMonitor`, `PollingPlan`, `NotificationPolicy` — pure logic, no timers |
| `Sources/DeepTallyCore/Settings/` | `AppSettings` (defaults + clamped ranges) and `SettingsStore` |
| `Sources/DeepTallyCore/Pricing/` | `PriceTableLoader` (bundled + user override), `HolidayCalendar`, `PeakOffPeakEngine`, `CostEngine`, `PricingErrorText` |
| `Sources/DeepTallyCore/Rate/RateNowPresenter.swift` | "What am I paying right now", formatted for the injected time zone |
| `Sources/DeepTallyCore/Resources/` | `PriceTable.json` and `ChinaHolidays.json` — versioned data, not code |
| `Sources/DeepTallyApp/AppEnvironment.swift` | The composition root (and `LaunchStateStore`); builds the price table, the key source and the fetcher |
| `Sources/DeepTallyApp/AppModel.swift` | State owner: key origin, polling, refresh, banners, the menu-bar label |
| `Sources/DeepTallyApp/AppScheduling.swift`, `BalanceFetching.swift` | The timer/notification seams and the balance-fetch seam |
| `Sources/DeepTallyApp/Views/`, `PopoverView.swift` | Presentation only |
| `Sources/DeepTallyApp/LoginItem.swift`, `UserNotificationScheduler.swift` | Thin system wrappers |
| `Sources/DeepTallyApp/StatusItemController.swift`, `AppDelegate.swift`, `main.swift` | Status item + popover, lifecycle, entry point |
| `Sources/DeepTallyApp/Uninstaller.swift`, `UninstallCommand.swift` | The removal list behind the button and `DeepTally --uninstall` |
| `Sources/DeepTallyApp/Spikes.swift`, `LaunchLog.swift` | Step 2 measurement commands; not on the normal app path |
| `Sources/DeepTallyCLI/Commands.swift`, `main.swift` | The `deeptally` command set: `balance`, `rate`, `key …` |
| `Tests/DeepTallyCoreTests/`, `Tests/DeepTallyCLITests/`, `Tests/DeepTallyAppTests/` | swift-testing suites; fixtures only, never the network |
| `Scripts/bundle.sh`, `dmg.sh`, `install.sh`, `uninstall.sh`, `release-assets.sh` | Hand-assembled bundle, DMG, install and removal scripts |

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for the build/test workflow, [`USAGE.md`](USAGE.md) for the
user-facing behaviour, and [`PLAN.md`](PLAN.md) for the step-by-step.
