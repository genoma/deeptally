# Privacy

DeepTally is local-first. There is no account, no telemetry, no crash reporting and no third-party server.
This page lists exactly what it talks to, what it stores, and how to remove all of it.

## Network

DeepTally talks to exactly two hosts ([`../AGENTS.md`](../AGENTS.md) §1):

| Host | Purpose | What is sent |
|---|---|---|
| `api.deepseek.com` | Account balance (`GET /user/balance`) and model list (`GET /models`) | Your API key as the `Authorization: Bearer …` header, and the request path. Nothing else. |
| `api.github.com` | Update check only | An HTTPS request for release metadata. No identifiers of ours are added. |

As with any HTTPS request, both hosts see your IP address and the time of the request. DeepTally adds no
identifiers, and there is no other host: no analytics endpoint, no error-reporting endpoint, no CDN.

The optional usage-capture proxy (deferred to v1.1, opt-in) binds `127.0.0.1` only, so it is reachable from
your Mac and nowhere else. It records counters, timestamps and model names for the requests that pass
through it, and discards request and response bodies immediately.

## API key

- The key lives in a single macOS Keychain item and is sent only to `api.deepseek.com`, as the
  `Authorization: Bearer …` header.
- It is never written to the ledger, preferences, logs, CSV exports or a crash report, and it is never
  committed to the repository.
- In any diagnostic output it is masked (`sk-…1234`).
- The `deeptally` CLI reads `DEEPSEEK_API_KEY` from its environment instead of the Keychain. That is your
  shell's environment; DeepTally does not persist it.

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
| Preferences | `~/Library/Preferences/io.github.genoma.deeptally.plist` (`UserDefaults`) | Alert threshold, menu bar metric, refresh cadence, currency display. Step 3. |
| API key | One Keychain item, in your login Keychain | Never in a file. |
| Login item | Registered through `SMAppService` (system-managed) | Step 3; removed again by the uninstaller (Step 6). |

Never stored, anywhere: prompt or completion content, request or response bodies, message text from the
opencode database, or your DeepSeek password — DeepTally only ever uses an API key.

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

1. Quit DeepTally from its menu, and turn off launch-at-login in its settings (Step 3).
2. Planned in Step 6: *Uninstall DeepTally…* in the app — unregisters the login item, moves the app to the
   Trash, purges app support, preferences and caches, deletes the Keychain item, and offers a last ledger
   export ([`PLAN.md`](PLAN.md) Step 6).
3. Until that lands, remove it by hand:

```sh
rm -rf "$HOME/Library/Application Support/DeepTally"
rm -rf "$HOME/Library/Caches/io.github.genoma.deeptally"
defaults delete io.github.genoma.deeptally
```

Then open **Keychain Access**, search for `DeepTally`, and delete the item (or items). That is the last
piece; nothing is stored anywhere else.

## No telemetry, ever

- No analytics SDK, no crash reporter, no "anonymous usage statistics". The app has **zero third-party
  runtime dependencies** ([`../AGENTS.md`](../AGENTS.md) §1), so there is nothing to phone home.
- No advertising or affiliate identifiers.
- The update check is the single feature that contacts a host other than DeepSeek, and it exists only to
  tell you that a newer release exists.

Questions or corrections: open an issue, or a private advisory as described in
[`../SECURITY.md`](../SECURITY.md).
