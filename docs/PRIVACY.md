# Privacy

DeepTally is local-first. There is no account, no telemetry, no crash reporting and no third-party server.
This page lists exactly what it talks to, what it stores, and how to remove all of it.

## Network

DeepTally is allowed to talk to exactly two hosts ([`../AGENTS.md`](../AGENTS.md) §1) and contacts only the
first of them today:

| Host | Purpose | What is sent |
|---|---|---|
| `api.deepseek.com` | Account balance (`GET /user/balance`) — the only request any build makes. The client also implements the model list (`GET /models`), but nothing calls it itself. | Your API key as the `Authorization: Bearer …` header, and the request path. There is no request body and nothing else. |
| `api.github.com` | **Reserved, not used yet** — an update check is the only thing allowed to contact it ([`../AGENTS.md`](../AGENTS.md) §1) | Nothing today: no current build makes this request. TODO: no step in [`PLAN.md`](PLAN.md) schedules the update check, so no release metadata is fetched. |

As with any HTTPS request, the host sees your IP address and the time of the request. DeepTally adds no
identifiers, and there is no other host: no analytics endpoint, no error-reporting endpoint, no CDN.

Nothing listens on a port, local or otherwise. The app has no proxy mode and captures no network traffic:
its own balance request is the only thing that touches the network, and it is never recorded beyond the last
reading's own amounts ([What is stored on disk](#what-is-stored-on-disk)).

## API key

- The key lives in a single macOS Keychain item — generic password, service `io.github.genoma.deeptally`,
  account `api-key`, readable while the login keychain is unlocked — and is sent only to `api.deepseek.com`,
  as the `Authorization: Bearer …` header.
- It is never written to preferences, logs, a crash report or any export, and it is never committed to the
  repository.
- In any diagnostic output it is masked (`sk-…1234`). DeepTally has no text field for a key: the only way in
  is the import from your own login shell ([`USAGE.md`](USAGE.md)).
- The `deeptally` CLI resolves the key the same way the app does — **Keychain first, then
  `DEEPSEEK_API_KEY`** — so importing it once makes both halves use the same key. `DEEPSEEK_API_KEY` remains
  your shell's environment; DeepTally never writes it anywhere.
- A Keychain read that fails (locked keychain, denied item ACL) does not block the environment key: the app
  reports the problem as a *"Keychain read problem: …"* banner and, when `DEEPSEEK_API_KEY` is set, keeps
  working with it — and `deeptally key status` prints the same failure as a `keychain:` line. No diagnostic
  can carry the key itself.

## What is stored on disk

| What | Where | Notes |
|---|---|---|
| Settings | `~/Library/Preferences/io.github.genoma.deeptally.plist` (`UserDefaults`), key `io.github.genoma.deeptally.settings` | One JSON blob: refresh cadence, low-balance threshold, notifications on/off and the notification cooldown. No currency is stored: the account currency is shown exactly as the API reports it. Keys a removed setting left behind in an older blob (`menuBarMetric`, `proxyEnabled`, `proxyPort`, `showSecondaryMetric`) are ignored on read and not written again. |
| Last balance reading | Same plist, key `io.github.genoma.deeptally.last-reading` | The last successful `/user/balance` answer — amounts, currency, availability flag — plus the instant it was fetched. It exists so a relaunch can show the amount immediately with a truthful "as of" age instead of an empty panel. |
| Last low-balance alert | Same plist, key `io.github.genoma.deeptally.last-notified` | A timestamp, written only after macOS accepted the alert, so the cooldown survives a relaunch — while a denied or failed post is retried instead of being recorded as delivered. |
| API key | One Keychain item: service `io.github.genoma.deeptally`, account `api-key` | Generic password, accessible while the login keychain is unlocked. Never in a file, a preference or a log. |
| Login item | Registered through `SMAppService` (system-managed) | Removed by the uninstaller, or by turning **Launch at login** off. |
| Saved window state | `~/Library/Saved Application State/io.github.genoma.deeptally.savedState` | Written by macOS, not by DeepTally: AppKit's window restoration, which remembers window placement. DeepTally has one popover and no documents, so this folder often never exists; it holds no usage data. Removed by the uninstaller when it does. |
| Older app data | `~/Library/Application Support/DeepTally` | **Not written by the current app.** An older version may have left a usage ledger (`ledger.sqlite` and its side files) and Step 2 launch logs there. The current app never reads or writes the directory; the uninstaller removes it whole, and you can delete it by hand at any time. |

Never stored, anywhere: prompt or completion content, request or response bodies, or your DeepSeek password
— DeepTally only ever uses an API key. The balance reading it persists holds amounts and a timestamp, nothing
about what you asked a model. The API key is stored once, in the Keychain, and nowhere else.

Two things worth stating plainly:

- **There is no usage history to store.** DeepSeek has no usage or spend endpoint, and DeepTally captures
  nothing locally, so there are no token counters, costs or per-model tables anywhere on disk that this app
  wrote. [`USAGE.md`](USAGE.md) describes what the app shows instead.
- Peak/off-peak classification needs a holiday calendar; it ships as a data file
  (`Sources/DeepTallyCore/Resources/ChinaHolidays.json`) instead of being fetched from a third-party API.

## Retention and delete

**Retention.** There is no history to prune: the settings, the last reading and the last alert time are
overwritten as they change, and the Keychain item stays until you replace or delete it. An older version's
application-support directory is the one leftover that may exist, and only the uninstaller (or you) removes
it.

**Delete everything.**

1. Open the popover and click **Uninstall DeepTally…** (footer, next to **Quit**). It asks first, and the
   alert lists what it will remove.
2. That removes exactly seven things: the login item; the Keychain item (service
   `io.github.genoma.deeptally`, account `api-key`); `~/Library/Application Support/DeepTally` (including
   anything an older version left there); the preferences domain `io.github.genoma.deeptally`;
   `~/Library/Caches/io.github.genoma.deeptally`;
   `~/Library/Saved Application State/io.github.genoma.deeptally.savedState` when it exists; and the app
   bundle itself, which is **moved to the Trash** so it stays recoverable until you empty it. Nothing
   outside that list is touched, and the run reports each item line by line.
3. `Scripts/uninstall.sh` — and `DeepTally --uninstall` directly, the same binary headless — does exactly
   the same thing. `--print-only` prints the plan and changes nothing, `--keep-data` keeps the
   application-support directory, `--keep-keychain` keeps the key. See
   [`USAGE.md`](USAGE.md#uninstalling) for the flags and the exit codes.

The same by hand, if you would rather not run either:

```sh
rm -rf "$HOME/Library/Application Support/DeepTally"   # only if an older version left data there
defaults delete io.github.genoma.deeptally              # settings, last reading, last alert
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
