# Privacy

DeepTally is local-first. There is no account, no telemetry, no crash reporting and no third-party server.
This page lists exactly what it talks to, what it stores, and how to remove all of it.

## Network

DeepTally is allowed to talk to exactly two hosts ([`../AGENTS.md`](../AGENTS.md) §1) and contacts only the
first of them today:

| Host | Purpose | What is sent |
|---|---|---|
| `api.deepseek.com` | Account balance (`GET /user/balance`) — the only request any build makes on its own. While the local proxy is on, everything your clients send through it is forwarded here too, and to no other host. The client also implements the model list (`GET /models`), but nothing calls it itself. | Your API key as the `Authorization: Bearer …` header, and the request path. A proxied request carries whatever your client sent it, body included; none of that is stored ([The local proxy](#the-local-proxy)). |
| `api.github.com` | **Reserved, not used yet** — an update check is the only thing allowed to contact it ([`../AGENTS.md`](../AGENTS.md) §1) | Nothing today: no current build makes this request. TODO: no step in [`PLAN.md`](PLAN.md) schedules the update check, so no release metadata is fetched. |

As with any HTTPS request, the host sees your IP address and the time of the request. DeepTally adds no
identifiers, and there is no other host: no analytics endpoint, no error-reporting endpoint, no CDN.

The optional usage-capture proxy is **off by default** — nothing listens on a port until you turn it on in
Settings. While it is on it binds `127.0.0.1` only, so it is reachable from your Mac and nowhere else, and
it forwards only to `api.deepseek.com`, so it is not a general-purpose relay. It records counters,
timestamps and model names for the completions that pass through it; the bodies and headers it handled are
discarded, and the exact statement is in [The local proxy](#the-local-proxy) below.

## API key

- The key lives in a single macOS Keychain item — generic password, service `io.github.genoma.deeptally`,
  account `api-key`, readable while the login keychain is unlocked — and is sent only to `api.deepseek.com`,
  as the `Authorization: Bearer …` header.
- It is never written to the ledger, preferences, logs, CSV exports or a crash report, and it is never
  committed to the repository.
- In any diagnostic output it is masked (`sk-…1234`). DeepTally has no text field for a key: the only way in
  is the import from your own login shell ([`USAGE.md`](USAGE.md)).
- The `deeptally` CLI resolves the key the same way the app does — **Keychain first, then
  `DEEPSEEK_API_KEY`** — so importing it once makes both halves use the same key. `DEEPSEEK_API_KEY` remains
  your shell's environment; DeepTally never writes it anywhere.
- A Keychain read that fails (locked keychain, denied item ACL) does not block the environment key: the app
  reports the problem as a *"Keychain read problem: …"* banner and, when `DEEPSEEK_API_KEY` is set, keeps
  working with it — and `deeptally key status` prints the same failure as a `keychain:` line. No diagnostic
  can carry the key itself.

## The opencode database

If you use opencode, DeepTally imports usage from `~/.local/share/opencode/opencode.db` — the app at launch
and then every 15 minutes, or on demand with `deeptally import` ([`USAGE.md`](USAGE.md)). That import is:

- **read-only**;
- limited to the `message` **and** `session_message` tables — opencode ships two live schema generations
  holding largely different rows, so both are read and deduped — plus column feature detection;
- never touching the `credential*`, `cred_*`, `account*` or `auth*` tables, which store credentials in
  plaintext (a SQLite authorizer denies those reads at the connection level).

Only token counters, timestamps, model/provider names and cost fields are read. Message content is not
extracted, stored or transmitted. The one identifier the import keeps is opencode's opaque `session_id`,
which groups the requests of one session and says nothing about what was asked; deduplication uses a
SHA-256 hash of the source row's identity (`source`, id, `session_id`), not its content.

## The local proxy

The optional **Local usage proxy** ([`USAGE.md`](USAGE.md#capturing-any-clients-usage-local-proxy)) is the one
local source that sees your requests as they happen. It is **off by default** — nothing listens on a port
until you turn it on in Settings — and its design is what keeps it from being an open relay:

- it binds `127.0.0.1` only, so it is reachable from your Mac and nowhere else;
- it forwards **only** to `https://api.deepseek.com`; a request cannot make it connect anywhere else;
- it handles the full request body and the `Authorization` header **in memory** as the request passes
  through, and relays the response back to the client. That is what proxying means: your request and
  DeepSeek's answer are visible to the app for the moment they transit the port.

What is stored is the same class of data as every other source: token counters, the model id, the provider,
the response `id`, the observation timestamp and the locally estimated cost — one ledger row per completed
completion, with `source: proxy`, priced by the same engine as any other row.

What is **never** stored or logged: request or response bodies, headers (including `Authorization`), the API
key, and message content. Usage is read out of the response's `usage` object — a JSON body for a
non-streaming call, the final chunk of an SSE stream for a streaming one — and the message content beside it
is discarded as the response passes. A request that carries no usage (a balance call, a model list, a
cancelled call) writes nothing. Calls made before the proxy was on cannot be recovered: DeepSeek keeps no
usage history DeepTally can read.

Turning the proxy off closes the listener. A client pointed back at `api.deepseek.com` returns to the direct
path, and the balance is unaffected either way — it always came from `GET /user/balance`.

## What is stored on disk

| What | Where | Notes |
|---|---|---|
| Usage ledger | `~/Library/Application Support/DeepTally/ledger.sqlite` (SQLite; `-wal` and `-shm` side files while it is open) | One row per captured request (imported or proxied): token counters (prompt / cache-read / cache-miss / completion / reasoning), the instant, `source`, `provider`, model id, the estimated cost, the opaque opencode `session_id` and the dedupe `raw_hash`. A `daily` rollup and a `meta` table (schema version, import watermark, last price-table version) live in the same file. No prompt or completion text, ever. |
| Settings | `~/Library/Preferences/io.github.genoma.deeptally.plist` (`UserDefaults`), key `io.github.genoma.deeptally.settings` | One JSON blob: refresh cadence, low-balance threshold, menu bar metric, notifications on/off and the notification cooldown. It also carries `showSecondaryMetric`, an unused flag that no build reads. No currency is stored: the account currency is shown exactly as the API reports it. |
| Last balance reading | Same plist, key `io.github.genoma.deeptally.last-reading` | The last successful `/user/balance` answer — amounts, currency, availability flag — plus the instant it was fetched. It exists so a relaunch can show the amount immediately with a truthful "as of" age instead of an empty panel. |
| Last low-balance alert | Same plist, key `io.github.genoma.deeptally.last-notified` | A timestamp, written only after macOS accepted the alert, so the cooldown survives a relaunch — while a denied or failed post is retried instead of being recorded as delivered. |
| API key | One Keychain item: service `io.github.genoma.deeptally`, account `api-key` | Generic password, accessible while the login keychain is unlocked. Never in a file, a preference or a log. |
| Login item | Registered through `SMAppService` (system-managed) | Removed by the uninstaller, or by turning **Launch at login** off. |
| Saved window state | `~/Library/Saved Application State/io.github.genoma.deeptally.savedState` | Written by macOS, not by DeepTally: AppKit's window restoration, which remembers window placement. DeepTally has one popover and no documents, so this folder often never exists; it holds no usage data. Removed by the uninstaller when it does. |
| Launch diagnostics | `~/Library/Application Support/DeepTally/launch.log` (capped at 200 lines) and `last-launch.json` | Step 2 spike output only: bundle path, App Translocation, quarantine flag, and whether `DEEPSEEK_API_KEY` was visible in the environment — a boolean, never the key's value. **The shipped app never writes these files**: they exist only while the marker `~/Library/Application Support/DeepTally/spike-enabled` does ([`SPIKES.md`](SPIKES.md)). |

Never stored, anywhere: prompt or completion content, request or response bodies, message text from the
opencode database, or your DeepSeek password — DeepTally only ever uses an API key. The balance reading it
persists holds amounts and a timestamp, nothing about what you asked a model. The API key is stored once, in
the Keychain, and nowhere else.

Two things worth stating plainly:

- All spend figures are **local estimates**. DeepSeek has no historical usage API, and the ledger cannot see
  usage from other machines, from the web dashboard, or anything opencode itself did not record and no
  client sent through the proxy. It does catch up on rows that were recorded while DeepTally was closed:
  the next import reads them ([`PLAN.md`](PLAN.md) §7). That is a capability limit, not a data-collection
  one.
- Peak/off-peak classification needs a holiday calendar; it ships as a data file
  (`Sources/DeepTallyCore/Resources/ChinaHolidays.json`) instead of being fetched from a third-party API.

## Retention, export and delete

**Retention.** Nothing is pruned automatically — raw rows stay in `ledger.sqlite` until you prune them. (The
plan's 400-day policy, [`PLAN.md`](PLAN.md) §4, is not wired in yet; the horizon is yours to choose.)
Pruning is one command:

```sh
deeptally ledger prune --days 400     # delete raw rows older than 400 days
```

A prune deletes **raw rows** only, cut at a UTC day boundary so a day is never half-deleted, and keeps the
`daily` rollups — so long-range totals survive after the rows behind them are gone.

**Export.** `deeptally ledger export <path.csv>` writes every raw row: counters, model ids, timestamps,
estimated costs, the opaque session ids and the dedupe hashes. The API key is not in the ledger and therefore
also not in the export; there is nothing to redact. Treat the file as you would the ledger itself.

**Delete everything.**

1. Open the popover and click **Uninstall DeepTally…** (footer, next to **Quit**). It asks first, and the
   alert lists what it will remove. If you want a copy of the ledger, choose **Export CSV First…**: the file
   is written where you choose, and the removal continues only after the write.
2. That removes exactly seven things: the login item; the Keychain item (service
   `io.github.genoma.deeptally`, account `api-key`); `~/Library/Application Support/DeepTally` (the ledger
   with its `-wal`/`-shm` side files, and any Step 2 spike logs); the preferences domain
   `io.github.genoma.deeptally`; `~/Library/Caches/io.github.genoma.deeptally`;
   `~/Library/Saved Application State/io.github.genoma.deeptally.savedState` when it exists; and the app
   bundle itself, which is **moved to the Trash** so it stays recoverable until you empty it. Nothing
   outside that list is touched, and the run reports each item line by line.
3. `Scripts/uninstall.sh` — and `DeepTally --uninstall` directly, the same binary headless — does exactly
   the same thing. `--print-only` prints the plan and changes nothing, `--keep-data` keeps the ledger and
   the Step 2 logs, `--keep-keychain` keeps the key. See
   [`USAGE.md`](USAGE.md#uninstalling) for the flags and the exit codes.

The same by hand, if you would rather not run either:

```sh
rm -rf "$HOME/Library/Application Support/DeepTally"   # the ledger and any Step 2 spike logs
defaults delete io.github.genoma.deeptally              # all three keys above
rm -rf "$HOME/Library/Caches/io.github.genoma.deeptally"
rm -rf "$HOME/Library/Saved Application State/io.github.genoma.deeptally.savedState"
```

Then open **Keychain Access**, search for `DeepTally`, and delete the item (service
`io.github.genoma.deeptally`, account `api-key`) — `deeptally key delete` does the same thing — and turn
**Launch at login** off (or remove DeepTally in *System Settings → General → Login Items*) before deleting
the app. That is the last piece; nothing is stored anywhere else.

## No telemetry, ever

- No analytics SDK, no crash reporter, no "anonymous usage statistics". The app has **zero third-party
  runtime dependencies** ([`../AGENTS.md`](../AGENTS.md) §1), so there is nothing to phone home.
- No advertising or affiliate identifiers.
- The update check is the only feature allowed to contact a host other than DeepSeek, and it exists only to
  tell you that a newer release exists. It is **not implemented yet** — no current build contacts
  `api.github.com`, and no step in [`PLAN.md`](PLAN.md) schedules it. When it lands, it will send no
  identifiers of ours.

Questions or corrections: open an issue, or a private advisory as described in
[`../SECURITY.md`](../SECURITY.md).
