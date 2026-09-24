# Privacy

DeepTally is local-first. There is no account, no telemetry, no crash reporting and no third-party server.
This page lists exactly what it talks to, what it stores, and how to remove all of it.

## Network

DeepTally is allowed to talk to exactly two hosts ([`../AGENTS.md`](../AGENTS.md) §1) and contacts only the
first of them today:

| Host | Purpose | What is sent |
|---|---|---|
| `api.deepseek.com` | Account balance (`GET /user/balance`) and model list (`GET /models`) | Your API key as the `Authorization: Bearer …` header, and the request path. Nothing else. |
| `api.github.com` | **Reserved, not used yet** — an update check is the only thing allowed to contact it ([`../AGENTS.md`](../AGENTS.md) §1) | Nothing today: no current build makes this request. TODO: no step in [`PLAN.md`](PLAN.md) schedules the update check, so no release metadata is fetched. |

As with any HTTPS request, the host sees your IP address and the time of the request. DeepTally adds no
identifiers, and there is no other host: no analytics endpoint, no error-reporting endpoint, no CDN.

The optional usage-capture proxy (deferred to v1.1, opt-in) binds `127.0.0.1` only, so it is reachable from
your Mac and nowhere else. It records counters, timestamps and model names for the requests that pass
through it, and discards request and response bodies immediately.

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

## The opencode database

If you use opencode, DeepTally can import usage from `~/.local/share/opencode/opencode.db`. That import is:

- **read-only**;
- limited to the `message` table (plus schema feature detection);
- never touching the `credential`/`cred_*` tables, which store credentials in plaintext.

Only token counters, timestamps, model/provider names and cost fields are read. Message content is not
extracted, stored or transmitted.

## What is stored on disk

| What | Where | Notes |
|---|---|---|
| Usage ledger | `~/Library/Application Support/DeepTally/` (SQLite) | Counters, timestamps, model names and estimated costs. No prompt or completion text. Step 4. |
| Settings | `~/Library/Preferences/io.github.genoma.deeptally.plist` (`UserDefaults`), key `io.github.genoma.deeptally.settings` | One JSON blob: low-balance threshold, menu bar metric, refresh cadence, notifications on/off, notification cooldown, currency code. |
| Last balance reading | Same plist, key `io.github.genoma.deeptally.last-reading` | The last successful `/user/balance` answer — amounts, currency, availability flag — plus the instant it was fetched. It exists so a relaunch can show the amount immediately with a truthful "as of" age instead of an empty panel. |
| Last low-balance alert | Same plist, key `io.github.genoma.deeptally.last-notified` | A timestamp, so the notification cooldown survives a relaunch. |
| API key | One Keychain item: service `io.github.genoma.deeptally`, account `api-key` | Generic password, accessible while the login keychain is unlocked. Never in a file, a preference or a log. |
| Login item | Registered through `SMAppService` (system-managed) | Removed again by the uninstaller (Step 6), or by turning **Launch at login** off. |
| Launch diagnostics | `~/Library/Application Support/DeepTally/launch.log` and `last-launch.json` | Step 2 spike output only: bundle path, App Translocation, quarantine flag, and whether an API key was visible in the environment — never a key. **The shipped app never writes this file**: it exists only while the marker `~/Library/Application Support/DeepTally/spike-enabled` does ([`SPIKES.md`](SPIKES.md)). |

Never stored, anywhere: prompt or completion content, request or response bodies, message text from the
opencode database, or your DeepSeek password — DeepTally only ever uses an API key. The balance reading it
persists holds amounts and a timestamp, nothing about what you asked a model. The API key is stored once, in
the Keychain, and nowhere else.

Two things worth stating plainly:

- All spend figures are **local estimates**. DeepSeek has no historical usage API, and the ledger cannot
  see usage from other machines, from the web dashboard, or from periods when DeepTally was not running
  ([`PLAN.md`](PLAN.md) §7). That is a capability limit, not a data-collection one.
- Peak/off-peak classification needs a holiday calendar; it ships as a data file
  (`Resources/ChinaHolidays.json`) instead of being fetched from a third-party API.

## Export and delete

**Export.** CSV export is planned in Step 5 ([`PLAN.md`](PLAN.md)) and will contain ledger rows only:
counters, model names, timestamps and cost estimates. It never contains the API key. TODO (Step 5): the
exact menu and CLI command are frozen with that step; until then there is no supported export.

**Delete everything.**

1. Turn off **Launch at login** in the popover (or remove DeepTally in *System Settings → General → Login
   Items*), then **Quit** DeepTally from the popover footer.
2. Planned in Step 6: *Uninstall DeepTally…* in the app — unregisters the login item, moves the app to the
   Trash, purges app support, preferences and caches, deletes the Keychain item, and offers a last ledger
   export ([`PLAN.md`](PLAN.md) Step 6).
3. Until that lands, remove it by hand:

```sh
rm -rf "$HOME/Library/Application Support/DeepTally"   # Step 2 logs today; the ledger from Step 4 on
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
