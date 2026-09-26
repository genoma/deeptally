# Using DeepTally

DeepTally is a menu bar app: a status item shows one of three metrics, and clicking it opens a popover with
the balance, the peak/off-peak rate in force right now, the login-item switch, every setting, and a way out.
Everything it stores is on your Mac ([`PRIVACY.md`](PRIVACY.md)).

![The DeepTally popover](assets/popover.png)

**Status: pre-alpha (development build `0.1.0`).** This page describes what the shipping code does after
Step 4 — balance, menu bar, the local usage ledger and the CLI. The analytics popover and CSV import are
Step 5 ([`PLAN.md`](PLAN.md) §5); where a feature does not exist yet, this page says so rather than
describing an intention.

---

## Where the numbers come from

DeepTally shows three numbers, from two different sources.

| Metric | Source | What it measures |
|---|---|---|
| **Balance** | `GET /user/balance` | The account's own figure, in the account's own currency, as of the last fetch. |
| **Today's spend** | The local ledger | What the requests imported today cost, each priced with the peak/off-peak window it fell in. |
| **Cache-hit rate** | The local ledger | Cache-read tokens ÷ prompt tokens over the **trailing 30 local days**. |

**There is no historical usage API.** DeepSeek publishes a balance endpoint, per-response usage counters, and
a manual monthly CSV export — nothing that answers "what did I spend last Tuesday" ([`PLAN.md`](PLAN.md)
§3, [`SPIKES.md`](SPIKES.md) S7). So the history lives in a **local ledger**: one SQLite file at
`~/Library/Application Support/DeepTally/ledger.sqlite`, shared by the app and the CLI.

Rows get there by importing opencode's local database (`~/.local/share/opencode/opencode.db`) — read-only,
and never its credential tables. **If you use opencode on this Mac, the app imports it for you**: once at
launch, then every 15 minutes, on a fixed cadence with nothing to configure. `deeptally import` does the same
on demand. If you do not use opencode there is nothing to import, which is a normal state rather than an
error — the metrics stay em dashes and Settings says so ([`INSTALL.md`](INSTALL.md)).

- **Each row is priced once, at import**, with the peak/off-peak window in force **at that row's own
timestamp** — importing an old row today does not restate it at today's prices.
- **The import is incremental.** The ledger remembers the newest instant it has already imported (a
watermark), so a second run adds nothing. `deeptally import --full` rescans everything instead, which is the
repair pass for a row whose timestamp arrived behind the watermark.
- **"Today" means your local day**, not UTC. Every window is built from your calendar — the `usage` windows
and the two ledger-backed metrics alike. The ledger also keeps UTC-keyed rollups, which answer for a day
whose raw rows were pruned; such a day enters a report as the whole UTC day it is, and `usage` notes that
and names any day it could not answer for ([`ARCHITECTURE.md`](ARCHITECTURE.md)).
- **The spend is an estimate.** The token counters are real, but the price applied to them comes from the
versioned price table, and model line-ups and prices changed three times in 2026. DeepSeek's own billing is
the only authoritative figure, and there is no API for it.

What the ledger does **not** hold: prompt or completion text, request or response bodies, your API key, or
anything from another machine. What it does hold, and how to remove it, is in [`PRIVACY.md`](PRIVACY.md).

---

## Connect your API key

A fresh install has no key. The popover says so, and keeps saying it until you import one:

> **No API key yet. Import it from your login shell in Settings below.**

Until then the balance block reads *"Not loaded yet"* and the menu bar title is an em dash (`—`).

### Why there is an import instead of reading your shell

A GUI app launched by macOS inherits almost none of your shell environment: launching DeepTally from Finder
or `open` does **not** read `~/.zshrc`, so `DEEPSEEK_API_KEY` is simply not there (measured —
[`SPIKES.md`](SPIKES.md), "Shell environment does not reach a GUI launch"). DeepTally therefore imports the
variable once, from your own login shell, and stores it where a GUI app can read it: the macOS **Keychain**.

### Importing

1. Export the key in the file your login shell actually sources — `~/.zprofile` or `~/.zshrc` for **zsh**,
   `~/.bash_profile` or `~/.bashrc` for **bash**:

   ```sh
   export DEEPSEEK_API_KEY=sk-…        # your real key, in your own file — never in the repository
   ```

2. Click the DeepTally status item and go to **Settings → Import from shell**, then click **zsh** or
   **bash** (whichever shell you exported it in).
3. On success the popover prints *"Imported the key from your zsh login shell."* and the balance follows
   shortly after: pressing **Import** queues a refresh, so a fetch that is already in flight is followed by
   another one instead of the import being swallowed by it.

The import runs that login shell once as `/bin/zsh -lic 'printenv DEEPSEEK_API_KEY'` (or `/bin/bash`), so it
sees the same variable a terminal would. The key is never passed on a command line: the shell prints it and
DeepTally reads stdout, which is why it cannot show up in a process listing.

### Where the key lives

- One macOS Keychain item: generic password, service `io.github.genoma.deeptally`, account `api-key`,
  accessible when the login keychain is unlocked.
- Never in a file, never in `UserDefaults`, never in a log, never in a CSV export.
- DeepTally never displays or logs it — not even in an error message. The CLI reports only its *shape*
  (length, and the constant `sk-` prefix when present).
- **Forget key** deletes the item. Nothing is sent anywhere except `api.deepseek.com`
  ([`PRIVACY.md`](PRIVACY.md)).
- There is no text field to paste a key into, by design: the only path into the Keychain is the import.

### Which key wins

Both the app and the CLI resolve a key the same way: **Keychain first, then `DEEPSEEK_API_KEY`** in the
process environment. The popover footer names the winner (never the value):

| Footer line | Meaning |
|---|---|
| `API key: Keychain` | Imported. Survives reboots and terminal changes. |
| `API key: DEEPSEEK_API_KEY` | No stored item; the process inherited the variable. A key like this works now and stops working in the next terminal — import it to make it stick. |
| `API key: none` | No key anywhere; see the banner above. |

A Keychain read that fails adds no fourth line: the footer names the origin actually in use. The failure is
reported as a banner instead — *"Keychain read problem: …"* — and when `DEEPSEEK_API_KEY` is set the same
banner ends *"Using DEEPSEEK_API_KEY instead."*; when it is not, the no-key banner sits above it.

---

## The `deeptally` CLI

The same engine, without the UI. Build it with `make build`, run it from a checkout as
`swift run deeptally <command>` (already in [`INSTALL.md`](INSTALL.md)), or use the binary shipped in Step 6.

```sh
deeptally balance                        # the account balance
deeptally rate                           # the peak/off-peak window in force, with prices
deeptally usage [--json] [--days N]      # today, last 7 and last 30 days, then per model
deeptally import [--full]                # import local opencode usage into the ledger
deeptally ledger export <path.csv>       # write every raw ledger row as CSV
deeptally ledger prune --days N          # delete raw rows older than N days; their UTC days stay in usage
deeptally ledger reprice [--json]        # recompute stored costs with the current price table
deeptally key status                     # which store supplies the key, and any Keychain problem
deeptally key import [--shell zsh|bash]  # import from the login shell into the Keychain (default: zsh)
deeptally key delete                     # remove the stored key
deeptally --version | --help
```

`deeptally balance` prints the balance exactly as the API reports it — the currency is shown as-is, never
converted; the numbers are printed as parsed, so a trailing zero is dropped (illustrative):

```text
USD 41.2  (available)
  granted:   0
  topped up: 41.2
```

If the key came from the environment rather than the Keychain, the command adds a hint on **stderr**, so a
script reading stdout is unaffected.

`deeptally rate` needs no key at all. It answers "what am I paying right now", in your local time:

```text
Off-peak  (50% off, CN public holiday)
  window ends:  03:00 local, 75h 45m left
  next change:  Mon 03:00
  prices:       USD per 1M tokens, price table 2026-09-24
    deepseek-flash    cache hit 0.003   cache miss 0.15   output 0.6
    deepseek-v4-pro   cache hit 0.022   cache miss 0.66   output 1.98
```

(That output is real, from 2026-09-24 — a Chinese public holiday, hence off-peak on a weekday. The window,
the countdown and the prices move; only the shape is fixed.) Prices and model IDs come from the versioned
`Sources/DeepTallyCore/Resources/PriceTable.json`, which the app and the CLI share, and which you can
override per user — see [`ARCHITECTURE.md`](ARCHITECTURE.md).

`deeptally key import` is the only command that runs a shell. `deeptally key status` reports the origin
(`source: keychain`, `source: environment` or `source: none`), a `keychain: <problem>` line when the
Keychain read failed, and the key's shape (`shape: <n> chars, starts with sk-`) — never the key itself: the
length is the only number it will tell you, and only the constant `sk-` prefix is ever echoed. It exits `0`
whenever a key resolved, including a Keychain read that failed while `DEEPSEEK_API_KEY` supplied one, and
`2` only when there is no key at all.

### `deeptally usage`

The whole ledger in one report: **today**, the **last 7 days** and the **last 30 days** — each a run of local
days ending today — then a per-model breakdown for the `--days` window (default 30; `--days 1` is today).
Needs no key. An empty ledger prints zeros and one hint instead of failing.

The ledger examples in this section are literal output from a throwaway home directory (`CFFIXED_USER_HOME`
pointed at a scratch folder, seeded with a small fixture database), so the ledger paths read `/tmp/…`; on
your Mac the same command prints `~/Library/Application Support/DeepTally/ledger.sqlite`. Everything else —
the columns, the arithmetic, the wording — is exactly what the command prints.

```text
$ deeptally usage
Usage — local days (Europe/Rome), spend in USD.

                  spend  requests  tokens  cache hit
  today         $0.0006         2   4,610      66.7%
  last 7 days   $0.0016         3   7,260      66.7%
  last 30 days  $0.0017         4   8,260      66.7%

per model, last 30 days:
  provider  model                           spend  requests  tokens  cache hit
  deepseek  deepseek-flash                $0.0001         1   1,000      66.7%
  deepseek  deepseek-v4-flash             $0.0006         1   4,250      66.7%
  deepseek  deepseek-v4-pro-0813          $0.0011         1   2,650      66.7%
  kilo      deepseek-v9-not-in-the-table    $0.00         1     360      66.7%

ledger: /tmp/deeptally-doc-home/Library/Application Support/DeepTally/ledger.sqlite — 5 raw rows
```

- **Tokens** is prompt + completion, where completion already includes reasoning (the ledger's own
definitions, added rather than re-derived). **Cache hit** is cache reads ÷ prompt tokens, or `n/a` when the
window held no prompt tokens — a ratio with no denominator is unknown, not 0%.
- **Spend** is in the price table's currency (USD with the shipped table), not the account's, and is never
converted. On screen it gets two decimals, plus up to two more when the amount needs them.
- **A day whose raw rows were pruned is reported as a whole UTC day.** Its totals come from the `daily`
rollups instead of from the rows, so it is exact but not splittable: a window that only covers part of such
a day leaves it out and names the date, and the report says which days came from the rollups:

  ```text
  note: 1 day in these windows comes from the daily rollup table, which is keyed by whole UTC days.
  2026-09-19 is only partly inside these windows, so its partial totals are not included.
  ```

  Those lines appear only when they explain something: an unpruned ledger reads exactly as it always did.
- The header names the time zone the local days were computed in, and the last line names the ledger file and
its raw row count.

With `--json` the same numbers come as one document with stable key names: `schema`, `generated_at`,
`timezone`, `currency`, `days`, `selected`, `windows[]` (`key`, `from`, `until`, `rollup_days`,
`unavailable_days`, plus the numbers) and `models[]`. `rollup_days` counts the days of that window that came
from the rollups, and `unavailable_days` lists the `YYYY-MM-DD` UTC dates it left out — the plain report says
the same thing in its footnote. Money is a decimal **string**
(`"spend": "0.000577"`) so no float ever touches it, and `cache_hit_pct` is `null` — not 0 — when there is
no denominator. Boundaries are ISO-8601 in the report's own time zone, offset included. With no rows at all,
the report still answers:

```text
$ deeptally usage
Usage — local days (Europe/Rome), spend in USD.

                spend  requests  tokens  cache hit
  today         $0.00         0       0        n/a
  last 7 days   $0.00         0       0        n/a
  last 30 days  $0.00         0       0        n/a

No rows in the ledger yet — import local usage with `deeptally import`.

ledger: /tmp/deeptally-doc-empty/Library/Application Support/DeepTally/ledger.sqlite — 0 raw rows
```

### `deeptally import`

Reads opencode's database and adds what the ledger does not already have, pricing each row on the way in.
Needs no key. A **missing opencode database is not an error**: the command prints one sentence and exits `0`.

```text
$ deeptally import
warning: 1 offered row uses a model the price table does not list (deepseek-v9-not-in-the-table); they were recorded with a cost of 0.
Imported 5 new rows of 5 offered (incremental scan).
  watermark: 2026-09-24T22:51:26.000Z
  ledger:    /tmp/deeptally-doc-home/Library/Application Support/DeepTally/ledger.sqlite
$ deeptally import
Imported 0 new rows of 0 offered (incremental scan).
  nothing new: the ledger already holds every row opencode offered.
  watermark: 2026-09-24T22:51:26.000Z
  ledger:    /tmp/deeptally-doc-home/Library/Application Support/DeepTally/ledger.sqlite
```

(The warning goes to stderr, the report to stdout. Rows with no price are the subject of *Unpriced models*
below.)

`--full` rescans from the beginning instead of resuming at the watermark. It costs a full read of the
database, and `raw_hash` uniqueness keeps it idempotent — it exists to pick up a row that arrived with a
timestamp at or before the stored watermark, which the incremental scan cannot see:

```text
$ deeptally import --full
Imported 1 new row of 5 offered (full resync).
  watermark: 2026-09-24T22:51:26.000Z
  ledger:    /tmp/deeptally-doc-home/Library/Application Support/DeepTally/ledger.sqlite
```

### `deeptally ledger export` and `prune`

```text
$ deeptally ledger export /tmp/doc-evidence/ledger.csv
Exported 5 raw rows to /tmp/doc-evidence/ledger.csv.
$ deeptally ledger prune --days 30
Pruned 1 raw row older than 30 days.
  `deeptally usage` still reports those days' aggregate, read from the daily rollups as whole UTC days;
  `ledger reprice` can no longer revise pruned rows.
```

`export` writes every raw row, oldest first, as CSV with the columns
`ts,source,provider,model,input,output,reasoning,cache_read,cache_write,cost_usd,session_id,raw_hash`. CSV is
an inspection and interchange format, never the primary store; the file round-trips back into a ledger
(importing it is core functionality, not yet a CLI command).

`prune --days N` deletes **raw rows** older than N days and keeps the `daily` rollups; the cutoff is floored
to a UTC day, so a day is never half-deleted. `deeptally usage` still reports the pruned days out of those
rollups, with the two limits that follow from a rollup being one whole UTC day: a window that only covers
part of a pruned day leaves it out and names the date, and the day can no longer be re-sliced at a
local-time boundary. The other cost of a prune is repair: `ledger reprice` reads raw rows, so it can no
longer revise a pruned day. Nothing prunes by itself — the horizon is yours to choose, and `--days` is
required. `deeptally ledger prune --days` without a value is a usage error (exit `1`), not a default
horizon.

`reprice` is the repair path for stored costs; see the next section.

**Both commands write to the ledger, so try them on a copy first.** Point the CLI at another file with
`DEEPTALLY_LEDGER=/tmp/ledger-copy.sqlite` instead of the standard one; it applies to every command. `HOME`
does **not** redirect the ledger — macOS resolves the application-support directory from the real home — so
this variable is the way to prune or reprice experimentally without touching the app's ledger. Restoring the
real one after an accidental prune is `deeptally import --full`, which re-reads opencode and re-inserts the
rows `raw_hash` no longer has.

### Unpriced models: what the warning means, and the repair

Model ids are resolved through the price table, **including its `aliases` list**: an id DeepSeek renamed keeps
its price when the old id is listed as an alias of the current row, so a row imported under
`deepseek-v4-flash` prices exactly like `deepseek-flash`. That is data in
`Sources/DeepTallyCore/Resources/PriceTable.json`, not a Swift special case ([`ARCHITECTURE.md`](ARCHITECTURE.md)).

An id the table does not know cannot be priced at all, and that is visible three ways:

- `deeptally import` names it on **stderr**: `warning: 1 offered row uses a model the price table does not
  list (…); they were recorded with a cost of 0.`
- The row is still stored — its counters are real — with a **zero cost**. Zero is what "unknown price" looks
  like in the ledger, and it is also what a genuinely free model would look like, which is why the warning
  exists.
- **Re-importing will never fix it**: the row is already there, deduplicated by `raw_hash`. `deeptally ledger
  reprice` is the repair. It recomputes every stored row from its own model, counters and timestamp, writes
  only the rows whose cost changes, and reports what it still cannot price:

```text
$ deeptally ledger reprice
Repriced 5 rows with price table 2026-09-24 (USD); nothing changed.
  spend before: 0.002321
  spend after:  0.002321
  unpriced:     1 rows the table does not price
    deepseek-v9-not-in-the-table   1 rows  0.000000
    Add those ids to the price table, then run `deeptally ledger reprice` again.
```

Fix the table — a new model entry, or the id as an alias — and run it again:

```text
$ deeptally ledger reprice
Repriced 5 rows with price table 2026-09-24 (USD); 1 rows changed.
  spend before: 0.002321
  spend after:  0.002356
  unpriced:     none
```

A third run is a no-op, and says so:

```text
$ deeptally ledger reprice
Repriced 5 rows with price table 2026-09-24 (USD); nothing changed. The costs already came from this table.
  spend before: 0.002356
  spend after:  0.002356
  unpriced:     none
```

`--json` prints the same report with numbers as numbers and money as six-decimal strings
(`rowsExamined`, `rowsChanged`, `spendBefore`, `spendAfter`, `spendDelta`, `rowsUnpriced`,
`unpricedModels[]`, `priceTableVersion`, `previousPriceTableVersion` — absent until the first reprice).

**Why this matters, measured.** On this project's own ledger — real opencode usage, 5,275 rows — only one of
six model ids matched the price table before aliases existed, so most rows were stored at 0. After the alias
list was added, `deeptally ledger reprice` reported **5,275 rows, 4,237 changed, `$3.754373 → $14.378060`, 0
rows unpriced**, with the integrity check clean and the rollups agreeing exactly; a second run changed
nothing. The examples above are the same shape at fixture scale.

**Exit codes** are contractual for scripts, and `--help` prints the same table: `0` success · `2` no usable
key · `1` a usage error or any other failure. Two commands are worth spelling out: `key status` exits `0`
whenever it can name a key — a Keychain read that failed while `DEEPSEEK_API_KEY` supplied one still
answers — and `2` only when there is no key at all; `balance` exits `2` both when there is no key and when
the `/user/balance` request itself failed (authentication, network, rate limit — the stderr line says
which). Errors go to stderr.

---

## What the popover shows

The popover is a fixed 320 × 420 pt panel that scrolls; the settings block is taller than the window. It is
laid out top to bottom as follows.

### The menu bar title

The status item shows the gauge glyph plus the metric you picked in **Settings → Menu bar**. All three have a
number behind them:

| Metric | Shows | Measured over |
|---|---|---|
| **Balance** (default) | The account amount, e.g. `$11.99`, or `—` before the first reading | The last `/user/balance` fetch |
| **Today's spend** | The ledger's spend, e.g. `$0.42`, in the price table's currency | **Your local day**, from midnight to now |
| **Cache-hit rate** | `62%`, or `—` when the window holds no prompt tokens | The **trailing 30 local days**, today included |

The two ledger-backed figures are em dashes (`—`) until the first import pass finishes — never a fabricated
zero. If opencode is absent or the ledger cannot be read, the settings panel adds one quiet line,
*"Local usage is not being imported yet."*, and the balance keeps working; see
[`INSTALL.md`](INSTALL.md).

The spend label uses two decimals, exactly like the balance, so a day that cost less than half a cent reads
`$0.00` even though the ledger knows the precise amount — `deeptally usage` prints up to four decimals in its
table and the exact micro-USD string in `--json`.

While the balance is below your threshold the gauge gives way to a warning triangle, and the button's
tooltip names the amount — *"DeepSeek balance $1.42 is low."* That glyph is the fallback for a low balance
whenever macOS will not deliver the notification.

### 1. Notices

A banner appears only when there is something to say, most actionable first. They are derived from live
state, so a fixed problem removes its own banner:

| Banner | Raised when |
|---|---|
| *"Running from a temporary read-only copy. Drag DeepTally into /Applications and relaunch — the login item cannot be registered from here."* | macOS launched the app through App Translocation ([`UNSIGNED.md`](UNSIGNED.md), [`INSTALL.md`](INSTALL.md)). |
| *"No API key yet. Import it from your login shell in Settings below."* | No Keychain item and no environment key. |
| *"Keychain read problem: …"* | The stored item could not be read — a locked keychain or a denied item ACL. When `DEEPSEEK_API_KEY` is set the banner ends *"Using DEEPSEEK_API_KEY instead."*; when it is not, the no-key banner is above it. The status it names is a Keychain code, never a secret. |
| *"Pricing data problem: … No prices are shown until it is fixed."* | The bundled `PriceTable.json` is missing or unreadable — the rate panel is suppressed rather than guessing. |
| *"Holiday data problem: … Peak hours on Chinese public holidays may be over-reported."* | The holiday calendar could not be read; prices still work. |
| A refresh failure, e.g. an HTTP or TLS error | The last `/user/balance` request failed. |
| A key-import failure or a login-item failure | The action you just tried did not complete; the text names the fix. |

### 2. DeepSeek balance

- Caption **DeepSeek balance**, then the amount in the account's own currency: `$11.99`, `¥98.00`, or
  `CHF 12.00` for a currency without a known symbol. Two decimals, `.` decimal separator, no thousands
  separator — the same text on every machine. The amount turns **orange** while it is below your threshold.
- The reading's age: *"as of 23:13"* while it is under an hour old, *"3h 12m old"* from then on (days stay in
  hours). This is the fetch time, not a claim that the balance is live — DeepSeek's balance endpoint is
  eventually consistent.
- A status line: *"Balance is up to date."*, *"Balance is not up to date."*, or — when the amount is below
  the threshold — *"Low balance — top up to keep requests running."* with a warning icon. If the account
  reports itself unavailable it reads *"Balance unavailable — top up to keep requests running."*; before any
  reading exists you get *"Not loaded yet."*
- **Refresh** fetches immediately; while a request is in flight you get a spinner and *"Refreshing…"*.
  Refreshes never stack, and they also happen automatically — see the settings table below.

### 3. Current rate

*"Current rate"*, then the window in force:

- **Peak** (full price) or **Off-peak** (displayed as *"50% off"* — the discount is read from the price
  table, not assumed).
- *"Ends 03:00 · 75h 46m left"* — the end of the window in **your local time**, plus a countdown floored to
  whole minutes. Hovering the line shows the same instant with the local weekday (*"Mon 03:00"*).
- *"CN public holiday"* when off-peak is in force because of one.
- A **`<currency>` per 1M tokens** table — the label is the price table's own currency (`USD per 1M tokens`
  for the shipped table), never converted — with the columns Model / Cache-hit / Cache-miss / Output and the
  effective price of each model for the window that is in force. Two decimals, and up to two more for
  three-decimal cache-hit rates.

The classification is computed in UTC (peak is 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding
Chinese public holidays); only the presentation is local. If the bundled price table cannot be read, this
section says *"Rate information is not available yet."* and a banner above names the problem; an invalid user
override falls back to the bundled table instead, so prices stay on screen.

### 4. Local usage

What the ledger holds, read on the same fifteen-minute cadence as the import (and immediately when you press the
refresh button next to the heading):

- **Three windows** — **Today**, **7 days**, **30 days** — each with spend in the price table's currency and the
  cache-hit rate for that window. They end with today, so each total contains the one before it.
- **Cache hit**, one bar per UTC day that recorded usage over the last 30 days, drawn against 0–100% rather than
  against the best day in the series — a 55% day is drawn at 55% even if every other day was worse. A day with
  no usage has no bar (a faint stub), and hovering a bar names its date and rate.
- **Per model**, the last 30 days: each model's spend, requests and cache-hit rate.

Two notes can appear under the panel. The first is about provenance: when a day's raw rows have been pruned, its
numbers come from the daily rollups, which are keyed by **whole UTC days** — the panel says how many such days it
used, and names any day a window only partly covers, because a whole-day rollup cannot be sliced. The second is
the quiet caveat that also appears when opencode is absent or a row has no price: *“Local usage is not being
imported yet.”*, or the unpriced-rows sentence. Neither is a banner; the balance, the alerts and the rate panel
are unaffected by both.

The menu bar's **Today's spend** and **Cache-hit rate** metrics read exactly the same windows, so the panel and
the menu bar can never disagree about what the ledger holds.

### 5. Local usage file

The ledger's two CSV actions, in the order you would use them.

- **Export CSV…** writes every stored row to a file you choose, defaulting to
  `DeepTally-usage-YYYY-MM-DD.csv` with today's date in your timezone. The format is exactly what
  `deeptally ledger export` writes, and the line under the buttons reports how many rows went out.
- **Import CSV…** adds the rows of a file DeepTally or the `deeptally` CLI wrote. A row already in the
  ledger is skipped — the ledger keys every row on the source it came from — so importing the same file
  twice adds nothing the second time, and the line says so rather than reporting a silent zero.

An import is all-or-nothing: a file with one malformed row is refused whole and the line names the line
number and the reason, so a half-imported spreadsheet cannot exist. A successful import re-reads the
menu bar metrics and the unpriced-rows note immediately, instead of waiting for the next fifteen-minute
pass. Exporting is also the first thing to do before uninstalling, since the ledger is the only copy of
your history.

### 6. Startup

**Startup** holds one switch, **Launch at login**. It registers DeepTally through macOS
`SMAppService.mainApp` — no helper bundle, no LaunchAgent (that was measured as unnecessary,
[`SPIKES.md`](SPIKES.md) S3). The switch is disabled while the app runs from a translocated copy. If macOS
wants something from you, a line below the switch says so: *"Waiting for approval in System Settings →
General → Login Items."*, *"macOS has no login item for DeepTally; registration works best from
/Applications."*, or an unknown-status report.

### 7. Settings

The settings block — refresh cadence, threshold, menu bar metric, notifications and the key row. It sits
below the popover's fold (scroll the popover to reach it), and it is all in the reference below.

### 8. Footer

One compact line: the version from the bundle (`0.1.0` for a local `make bundle`, `dev` for a bare binary),
*"local-only"*, a **Quit** button, and the key-store line described above.

---

## Settings reference

| Setting | Control | Default | What it does |
|---|---|---|---|
| **Refresh every** | stepper | 20 min | 5–240 minutes between balance refreshes. The wait doubles after each consecutive failure, capped at 1 hour, and up to 60 s of jitter is added so installs do not poll in lockstep. A refresh also runs on wake from sleep, when the network comes back, and whenever you press Refresh. |
| **Low-balance threshold** | number field | 2 | Compared **strictly** with the account amount: `1.99 < 2` is low, `2.00` is not. Compared as reported — never converted. Valid range 0–1000. |
| **Menu bar** | picker | Balance | Which metric the title shows: **Balance**, **Today's spend** (your local day, in the price table's currency) or **Cache-hit rate** (cache reads ÷ prompt tokens over the last 30 local days; `—` when there is no denominator). The picker's tooltip names the two windows. If local usage is not being imported, a quiet line below says so and the picker stays usable. |
| **Notify on low balance** | switch | on | A macOS notification when the balance falls below the threshold: *"DeepSeek balance is low"* / *"Balance $1.42 is below your $2.00 threshold."* macOS asks for permission once, at launch. An alert counts as sent only after macOS accepts it, so a denial or a failed post is retried instead of consuming the cooldown — and the **menu-bar warning glyph** (above) carries a low balance whenever macOS will not deliver the alert. While the switch is on and macOS reports the permission denied, the panel adds one line: *"macOS notifications are off for DeepTally, so low-balance alerts are not delivered. While the balance is low the menu bar shows a warning glyph; re-allow DeepTally in System Settings → Notifications to get the alert."* |
| **Notify again after** | stepper | 12h | 15 min – 7 days (10 080 min) in 30-minute steps, shown as `12h`, `30 min`, `1h 30m`. A balance that stays low re-alerts at most once per cooldown, and the time of the last **delivered** alert survives a relaunch. Only a low balance triggers an alert; an old reading neither triggers nor silences one. The stepper is disabled while **Notify on low balance** is off. |
| **Import from shell** | zsh / bash buttons | — | The one-time Keychain import (above). |
| **Forget key** | button | — | Deletes the Keychain item. If `DEEPSEEK_API_KEY` is still exported, the CLI says so on stderr so you are not told the key is gone while it still works. |

---

## Quitting

DeepTally is an accessory app (`LSUIElement`): it has **no Dock icon**, nothing in ⌘-Tab, and no menu bar of
its own. That is deliberate — the item you want is the status item, not a window.

To stop it:

- **Quit** in the popover footer, or ⌘Q while the popover is open (the app installs the minimum main menu
  needed for that key equivalent), or
- from a checkout, `make kill` — `pkill -f 'DeepTally.app/Contents/MacOS/DeepTally'`.

If the app is running but its status item is hidden behind macOS 27's menu-bar controls, `make kill` is the
reliable way out.

There is no one-step uninstaller yet: quitting, turning off **Launch at login**, and the deletion steps in
[`PRIVACY.md`](PRIVACY.md) are manual until Step 6 lands the in-app uninstaller.

---

## Troubleshooting

| Symptom | What it means, and what to do |
|---|---|
| *"Running from a temporary read-only copy…"* | macOS put the app through App Translocation because it was launched from outside `/Applications` (measured twice, [`SPIKES.md`](SPIKES.md) S2). Quit it, drag `DeepTally.app` into `/Applications`, relaunch. **Launch at login** is disabled in this state, because a login item pointing into a temporary directory is worse than none. |
| *"No API key yet."*, or `deeptally balance` exits `2` with *"No API key: the Keychain has none and DEEPSEEK_API_KEY is not set."* | Import the key (above). For the CLI: `deeptally key import --shell zsh`. |
| *"Keychain read problem: …"* | The stored item could not be read — a locked keychain or a denied item ACL, which is not the same as no key. If `DEEPSEEK_API_KEY` is exported, the banner says *"Using DEEPSEEK_API_KEY instead."*, the footer reads `API key: DEEPSEEK_API_KEY`, and the app keeps working; if it is not, the no-key banner is above it and you need to import again. `deeptally key status` prints the same failure as a `keychain:` line. |
| *"No DEEPSEEK_API_KEY in your zsh login shell. Export it in ~/.zprofile or ~/.zshrc and try again."* | The login shell never printed the variable. Check the rc file for the shell you clicked, export it there, then import again. `The zsh login shell did not finish in time.` means the shell took longer than 8 s (something in your rc file is interactive); `exited with status 1` means the shell itself failed. |
| The key imports but nothing refreshes | A network failure is reported as its own banner and backed off — not retried in a loop. The last good reading, with its honest age, stays on screen. |
| Balance looks stale | A reading over 60 minutes old gets the line *"3h 12m old"* and the status *"Balance is not up to date."* DeepTally keeps showing it instead of an empty panel. Press **Refresh**, or wait: after a failure the next attempt is at most 1 hour + 60 s away, and a wake from sleep or a returning network triggers one immediately. DeepSeek's balance is eventually consistent — the "as of" time is when it was fetched, not a claim about the server. |
| No low-balance notifications | macOS asks for permission once, at launch, when the switch is on. If it was denied, the switch keeps its state and the app keeps working: the fallback is the **menu-bar warning glyph** — while the balance is low the gauge is replaced by a warning triangle whose tooltip names the amount — and Settings states once that alerts are not delivered. Re-allow DeepTally in **System Settings → Notifications** to get the notification too. An alert macOS refused is retried, because only an accepted one counts as sent. |
| *"Pricing data problem: …"* / *"Holiday data problem: …"* | The bundled price table (`Sources/DeepTallyCore/Resources/PriceTable.json`) or the holiday list (`Sources/DeepTallyCore/Resources/ChinaHolidays.json`) could not be read. Prices are data, so the app suppresses the rate panel instead of inventing numbers. Your override at `~/.config/deeptally/PriceTable.json` is different: it wins when it is valid, and an invalid override is ignored in favour of the bundled table rather than suppressing prices. |
| The rate looks wrong on a holiday | The shipped calendar holds the official 2026 Chinese State Council dates; other years are not included. Extra dates can be merged in through the `holidays` array of your `~/.config/deeptally/PriceTable.json`. |
| What does *"estimated"* mean? | Every spend figure in the ledger is an **estimate**: the token counters come from opencode, and the price is computed locally from the versioned price table with the peak/off-peak windows. Model line-ups and prices changed three times in 2026, and no local ledger can see another machine, the web dashboard, or opencode usage that was never recorded. DeepSeek's own billing is the only authoritative figure, and there is no API for it. The balance is not an estimate — it comes straight from `GET /user/balance`. |
| *"Today's spend"* or *"Cache-hit rate"* shows an em dash (`—`) | No ledger pass has read anything yet, or local usage is not being imported. Settings carries the quiet line *"Local usage is not being imported yet."* when that is why. A missing opencode database is the common cause and is normal; otherwise check `deeptally import` for the real diagnostic. |

---

## Screenshots

The three screenshots in this documentation are rendered **from the shipping views**, not drawn by hand —
`make screenshots` runs the real composition root and the real key precedence (`--spike render-popover`) and
writes the PNGs to `dist/`; the copies committed under `docs/assets/` come from that same command:

| File | What it is | Generated as |
|---|---|---|
| [`assets/popover.png`](assets/popover.png) | the popover, light appearance | `dist/popover.png` |
| [`assets/popover-dark.png`](assets/popover-dark.png) | the same popover, dark appearance | `dist/popover-dark.png` |
| [`assets/settings.png`](assets/settings.png) | the settings block, which sits below the popover's 420 pt fold | `dist/popover-settings.png` |

![The DeepTally popover in dark appearance](assets/popover-dark.png)

`settings.png` is byte-identical to what the command writes; the two popover shots differ from a fresh run
only in the balance and the clock they captured. Because the render waits for a settled state and uses the
same key resolution as the app, a successful `make screenshots` without `DEEPSEEK_API_KEY` set is also a live
check that the Keychain import works. The offscreen-rendering details (why a colorScheme and a background
must be set explicitly) are in [`DEVELOPMENT.md`](DEVELOPMENT.md).
