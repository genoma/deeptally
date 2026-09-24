# Privacy

DeepTally is local-first. There is no account, no telemetry, no crash reporting and no third-party server.
This page lists exactly what it talks to, what it stores, and how to remove all of it.

## Network

DeepTally is allowed to talk to exactly two hosts ([`../AGENTS.md`](../AGENTS.md) §1) and contacts only the
first of them today:

| Host | Purpose | What is sent |
|---|---|---|
| `api.deepseek.com` | Account balance (`GET /user/balance`) — the only request any build makes today. The client also implements the model list (`GET /models`), but nothing calls it yet. | Your API key as the `Authorization: Bearer …` header, and the request path. Nothing else. |
| `api.github.com` | **Reserved, not used yet** — an update check is the only thing allowed to contact it ([`../AGENTS.md`](../AGENTS.md) §1) | Nothing today: no current build makes this request. TODO: no step in [`PLAN.md`](PLAN.md) schedules the update check, so no release metadata is fetched. |

As with any HTTPS request, the host sees your IP address and the time of the request. DeepTally adds no
identifiers, and there is no other host: no analytics endpoint, no error-reporting endpoint, no CDN.

The optional usage-capture proxy is **deferred to v1.1 and does not exist in any current build** — nothing
listens on a port today. When it lands it will be opt-in and bind `127.0.0.1` only, so it is reachable from
your Mac and nowhere else; it will record counters, timestamps and model names for the requests that pass
through it, and discard request and response bodies immediately.

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

## What is stored on disk

| What | Where | Notes |
|---|---|---|
| Usage ledger | `~/Library/Application Support/DeepTally/ledger.sqlite` (SQLite; `-wal` and `-shm` side files while it is open) | One row per imported request: token counters (prompt / cache-read / cache-miss / completion / reasoning), the instant, `source`, `provider`, model id, the estimated cost, the opaque opencode `session_id` and the dedupe `raw_hash`. A `daily` rollup and a `meta` table (schema version, import watermark, last price-table version) live in the same file. No prompt or completion text, ever. |
| Settings | `~/Library/Preferences/io.github.genoma.deeptally.plist` (`UserDefaults`), key `io.github.genoma.deeptally.settings` | One JSON blob: refresh cadence, low-balance threshold, menu bar metric, notifications on/off and the notification cooldown. It also carries `showSecondaryMetric`, an unused flag that no build reads. No currency is stored: the account currency is shown exactly as the API reports it. |
| Last balance reading | Same plist, key `io.github.genoma.deeptally.last-reading` | The last successful `/user/balance` answer — amounts, currency, availability flag — plus the instant it was fetched. It exists so a relaunch can show the amount immediately with a truthful "as of" age instead of an empty panel. |
| Last low-balance alert | Same plist, key `io.github.genoma.deeptally.last-notified` | A timestamp, written only after macOS accepted the alert, so the cooldown survives a relaunch — while a denied or failed post is retried instead of being recorded as delivered. |
| API key | One Keychain item: service `io.github.genoma.deeptally`, account `api-key` | Generic password, accessible while the login keychain is unlocked. Never in a file, a preference or a log. |
| Login item | Registered through `SMAppService` (system-managed) | Removed again by the uninstaller (Step 6), or by turning **Launch at login** off. |
| Launch diagnostics | `~/Library/Application Support/DeepTally/launch.log` (capped at 200 lines) and `last-launch.json` | Step 2 spike output only: bundle path, App Translocation, quarantine flag, and whether `DEEPSEEK_API_KEY` was visible in the environment — a boolean, never the key's value. **The shipped app never writes these files**: they exist only while the marker `~/Library/Application Support/DeepTally/spike-enabled` does ([`SPIKES.md`](SPIKES.md)). |

Never stored, anywhere: prompt or completion content, request or response bodies, message text from the
opencode database, or your DeepSeek password — DeepTally only ever uses an API key. The balance reading it
persists holds amounts and a timestamp, nothing about what you asked a model. The API key is stored once, in
the Keychain, and nowhere else.

Two things worth stating plainly:

- All spend figures are **local estimates**. DeepSeek has no historical usage API, and the ledger cannot see
  usage from other machines, from the web dashboard, or anything opencode itself did not record. It does
  catch up on rows that were recorded while DeepTally was closed: the next import reads them
  ([`PLAN.md`](PLAN.md) §7). That is a capability limit, not a data-collection one.
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

1. Turn off **Launch at login** in the popover (or remove DeepTally in *System Settings → General → Login
   Items*), then **Quit** DeepTally from the popover footer.
2. Planned in Step 6: *Uninstall DeepTally…* in the app — unregisters the login item, moves the app to the
   Trash, purges app support, preferences and caches, deletes the Keychain item, and offers a last ledger
   export ([`PLAN.md`](PLAN.md) Step 6).
3. Until that lands, remove it by hand:

```sh
rm -rf "$HOME/Library/Application Support/DeepTally"   # the ledger and any Step 2 spike logs
defaults delete io.github.genoma.deeptally              # all three keys above
rm -rf "$HOME/Library/Caches/io.github.genoma.deeptally"
```

Then open **Keychain Access**, search for `DeepTally`, and delete the item (service
`io.github.genoma.deeptally`, account `api-key`) — `deeptally key delete` does the same thing. That is the
last piece; nothing is stored anywhere else.

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
