# Using DeepTally

DeepTally is a menu bar app: the status item shows your DeepSeek account balance, and clicking it opens a
popover with the balance, the peak/off-peak rate in force right now, the login-item switch, every setting
and a way out. Everything it stores is on your Mac ([`PRIVACY.md`](PRIVACY.md)).

![The DeepTally popover](assets/popover.png)

**Status: pre-alpha (development build `0.1.0`).** This page describes what the shipping code does: the
balance, the current rate, the key, the settings, the login item and the uninstaller. Where a feature does
not exist, this page says so rather than describing an intention.

---

## What DeepTally shows — and what it cannot

Two numbers, from two different kinds of source:

| Thing | Source | What it measures |
|---|---|---|
| **Balance** | `GET /user/balance` | The account's own figure, in the account's own currency, as of the last fetch. |
| **Current rate** | The shipped, versioned price table, computed locally | The peak/off-peak window in force right now and the effective price of every model in it. |

**There is no usage or spend history, and DeepTally does not pretend otherwise.** DeepSeek publishes no
endpoint that answers "what did I spend last Tuesday". The API returns a balance, a model list, and each
completion's own `usage` counters — to the caller of that one request, only at the moment it is made.
DeepTally makes no completion calls and captures nothing locally, so spend history is not a feature of this
app ([`PLAN.md`](PLAN.md) §3, [`SPIKES.md`](SPIKES.md) S7). The DeepSeek web platform is where account
spend reporting lives; nothing here reproduces it.

- The balance is **eventually consistent**: the "as of" time is when it was fetched, not a claim that the
  server figure is live.
- The rates are **estimates of what a request would cost**, not what you paid. Prices and model IDs come
  from the versioned `Sources/DeepTallyCore/Resources/PriceTable.json`, the line-up and prices changed three
  times in 2026, and DeepSeek's own billing is the only authoritative figure.
- Nothing is converted between currencies. The balance is shown in the account's currency exactly as the
  API reports it; prices are shown in the price table's own currency.

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
- Never in a file, never in `UserDefaults`, never in a log.
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
`swift run deeptally <command>` (already in [`INSTALL.md`](INSTALL.md)), or use the binary from a release
once one is published.

```sh
deeptally balance                        # the account balance
deeptally rate                           # the peak/off-peak window in force, with prices
deeptally key status                     # which store supplies the key, and any Keychain problem
deeptally key import [--shell zsh|bash]  # import from the login shell into the Keychain (default: zsh)
deeptally key delete                     # remove the stored key
deeptally --version | --help
```

`deeptally --help` prints exactly this list; it is the source of truth for the command surface.

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
  window ends:  03:00 local, 39h 6m left
  next change:  Mon 03:00
  prices:       USD per 1M tokens, price table 2026-09-24
    deepseek-flash    cache hit 0.003   cache miss 0.15   output 0.6
    deepseek-v4-pro   cache hit 0.022   cache miss 0.66   output 1.98
```

(That output is real, from 2026-09-26 — a Chinese public holiday, hence off-peak on a weekend. The window,
the countdown and the prices move; only the shape is fixed.) Prices and model IDs come from the versioned
table the app and the CLI share, which you can override per user — see [`ARCHITECTURE.md`](ARCHITECTURE.md).

`deeptally key import` is the only command that runs a shell. `deeptally key status` reports the origin
(`source: keychain`, `source: environment` or `source: none`), a `keychain: <problem>` line when the
Keychain read failed, and the key's shape (`shape: <n> chars, starts with sk-`) — never the key itself: the
length is the only number it will tell you, and only the constant `sk-` prefix is ever echoed. It exits `0`
whenever a key resolved, including a Keychain read that failed while `DEEPSEEK_API_KEY` supplied one, and
`2` only when there is no key at all.

### Exit codes

Exit codes are contractual for scripts, and `--help` prints the same table: `0` success · `2` no usable key
· `1` a usage error or any other failure. Two cases are worth spelling out: `key status` exits `0` whenever
it can name a key; `balance` exits `2` both when there is no key and when the `/user/balance` request was
rejected as an authentication or permission failure (HTTP 401 or 403). An offline laptop, a rate limit or a
server error is `1`, because the key was never the problem. Errors go to stderr; stdout stays parseable.

---

## What the popover shows

The popover is a fixed 320 × 420 pt panel that scrolls; the settings block is taller than the window. It is
laid out top to bottom as follows.

### The menu bar title

The status item shows the gauge glyph plus the account balance, e.g. `$11.99` — or `—` before the first
reading. A number the app does not have is never shown: an em dash is honest, a fabricated zero is not.

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
| A price-override problem sentence | Your `~/.config/deeptally/PriceTable.json` is present but invalid. Prices still show, from the bundled table, and the sentence says why your edits had no effect. |
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
  reading exists you get *"Not loaded yet"*.
- **Refresh** fetches immediately; while a request is in flight you get a spinner and *"Refreshing…"*.
  Refreshes never stack, and they also happen automatically — see the settings table below.

### 3. Current rate

*"Current rate"*, then the window in force:

- **Peak** (full price) or **Off-peak** (displayed as *"50% off"* — the discount is read from the price
  table, not assumed).
- *"Ends 03:00 · 39h 6m left"* — the end of the window in **your local time**, plus a countdown floored to
  whole minutes. Hovering the line shows the same instant with the local weekday (*"Next transition: Mon
  03:00"*).
- *"CN public holiday"* when off-peak is in force because of one.
- A **`<currency>` per 1M tokens** table — the label is the price table's own currency (`USD per 1M tokens`
  for the shipped table), never converted — with the columns Model / Cache-hit / Cache-miss / Output and the
  effective price of each model for the window that is in force. Two decimals, and up to two more for
  three-decimal cache-hit rates.

The classification is computed in UTC (peak is 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding
Chinese public holidays); only the presentation is local. If the bundled price table cannot be read, this
section says *"Rate information is not available yet."* and a banner above names the problem; an invalid user
override falls back to the bundled table instead, so prices stay on screen.

### 4. Startup

**Startup** holds one switch, **Launch at login**. It registers DeepTally through macOS
`SMAppService.mainApp` — no helper bundle, no LaunchAgent (that was measured as unnecessary,
[`SPIKES.md`](SPIKES.md) S3). The switch is disabled while the app runs from a translocated copy. If macOS
wants something from you, a line below the switch says so: *"Waiting for approval in System Settings →
General → Login Items."*, *"macOS has no login item for DeepTally; registration works best from
/Applications."*, or an unknown-status report.

### 5. Settings

The settings block — refresh cadence, threshold, notifications and the key row. It sits below the popover's
fold (scroll the popover to reach it), and it is all in the reference below.

### 6. Footer

Two compact lines. The first is the version from the bundle (`0.1.0` for a local `make bundle`, `dev` for a
bare binary), *"local-only"* and a **Quit** button. The second is the key-store line described above and
**Uninstall DeepTally…**, described in [Uninstalling](#uninstalling) below.

---

## Settings reference

| Setting | Control | Default | What it does |
|---|---|---|---|
| **Refresh every** | stepper | 20 min | 5–240 minutes between balance refreshes. The wait doubles after each consecutive failure, capped at 1 hour, and up to 60 s of jitter is added so installs do not poll in lockstep. A refresh also runs on wake from sleep, when the network comes back, and whenever you press Refresh. |
| **Low-balance threshold** | number field | 2 | Compared **strictly** with the account amount: `1.99 < 2` is low, `2.00` is not. Compared as reported — never converted. Valid range 0–1000. |
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

There is no other step: to remove DeepTally as well, use the uninstaller below.

---

## Uninstalling

**Uninstall DeepTally…** sits in the popover footer, next to **Quit**. It asks first, and the alert lists
exactly what is about to go:

1. the **login item** (Launch at login), so nothing tries to start DeepTally again;
2. the **API key** — the Keychain item behind *API key: Keychain* in the footer;
3. `~/Library/Application Support/DeepTally` — the app's data directory, removed whole. The current app
   never writes it; an older version may have left a usage ledger and its side files there, and this is what
   removes them;
4. the preferences domain `io.github.genoma.deeptally` (the settings, the last balance reading and the last
   alert time);
5. `~/Library/Caches/io.github.genoma.deeptally`;
6. `~/Library/Saved Application State/io.github.genoma.deeptally.savedState`, if macOS wrote one;
7. **the app itself**, moved to the Trash — the last step, and the reversible one: *Put Back* in the Finder
   is enough to change your mind.

Nothing outside that list is touched. The run prints one line per item and a summary, and, when everything
was removed, quits DeepTally (the bundle is in the Trash by then).

A translocated copy refuses the move: macOS runs a quarantined app from a random read-only directory, so
there is no `DeepTally.app` to move. The data is purged anyway, the report says the bundle was refused, and
`/Applications/DeepTally.app` has to go to the Trash by hand.

### The same uninstaller from a shell

`Scripts/uninstall.sh` drives the app binary instead of the button, and the flag is public:

```sh
"/Applications/DeepTally.app/Contents/MacOS/DeepTally" --uninstall
```

| Flag | What it does |
|---|---|
| `--yes` | The caller has already asked the user: this command never prompts |
| `--print-only` | Print the plan and change nothing (always exits 0) |
| `--home PATH` | Treat `PATH` as the home directory (tests and the release gate) |
| `--keep-data` | Keep `~/Library/Application Support/DeepTally`, remove everything else |
| `--keep-keychain` | Keep the API key in the Keychain |
| `--keep-login-item` | Leave the macOS login item registered (the release gate uses this so it cannot unregister one on the machine running it) |
| `--trash-dir PATH` | Move the app bundle into `PATH` instead of the user's Trash |
| `--help` | Every flag, and what the exit codes mean |

It prints one line per item — `removed`, `trashed`, `planned`, `absent`, `skipped`, `refused`, `failed` —
plus a final summary, and exits `0` on success, `1` when an item was refused or failed, `2` on a usage
error. It is the same code the button runs, and the same list.

---

## Troubleshooting

| Symptom | What it means, and what to do |
|---|---|
| *"Running from a temporary read-only copy…"* | macOS put the app through App Translocation because it was launched from outside `/Applications` (measured twice, [`SPIKES.md`](SPIKES.md) S2). Quit it, drag `DeepTally.app` into `/Applications`, relaunch. **Launch at login** is disabled in this state, because a login item pointing into a temporary directory is worse than none. |
| *"No API key yet."*, or `deeptally balance` exits `2` with *"No API key: the Keychain has none and DEEPSEEK_API_KEY is not set."* | Import the key (above). For the CLI: `deeptally key import --shell zsh`. |
| *"Keychain read problem: …"* | The stored item could not be read — a locked keychain or a denied item ACL, which is not the same as no key. If `DEEPSEEK_API_KEY` is exported, the banner says *"Using DEEPSEEK_API_KEY instead."*, the footer reads `API key: DEEPSEEK_API_KEY`, and the app keeps working; if it is not, the no-key banner is above it and you need to import again. `deeptally key status` prints the same failure as a `keychain:` line. |
| *"No DEEPSEEK_API_KEY in your zsh login shell. Export it in ~/.zprofile or ~/.zshrc and try again."* | The login shell never printed the variable. Check the rc file for the shell you clicked, export it there, then import again. *"The zsh login shell did not finish in time."* means the shell took longer than 8 s (something in your rc file is interactive); *"exited with status 1"* means the shell itself failed. |
| The key imports but nothing refreshes | A network failure is reported as its own banner and backed off — not retried in a loop. The last good reading, with its honest age, stays on screen. |
| Balance looks stale | A reading over 60 minutes old gets the line *"3h 12m old"* and the status *"Balance is not up to date."* DeepTally keeps showing it instead of an empty panel. Press **Refresh**, or wait: after a failure the next attempt is at most 1 hour + 60 s away, and a wake from sleep or a returning network triggers one immediately. DeepSeek's balance is eventually consistent — the "as of" time is when it was fetched, not a claim about the server. |
| No low-balance notifications | macOS asks for permission once, at launch, when the switch is on. If it was denied, the switch keeps its state and the app keeps working: the fallback is the **menu-bar warning glyph** — while the balance is low the gauge is replaced by a warning triangle whose tooltip names the amount — and Settings states once that alerts are not delivered. Re-allow DeepTally in **System Settings → Notifications** to get the notification too. An alert macOS refused is retried, because only an accepted one counts as sent. |
| *"Pricing data problem: …"* / *"Holiday data problem: …"* | The bundled price table (`Sources/DeepTallyCore/Resources/PriceTable.json`) or the holiday list (`Sources/DeepTallyCore/Resources/ChinaHolidays.json`) could not be read. Prices are data, so the app suppresses the rate panel instead of inventing numbers. Your override at `~/.config/deeptally/PriceTable.json` is different: it wins when it is valid, and an invalid override is ignored in favour of the bundled table rather than suppressing prices. |
| The rate looks wrong on a holiday | The shipped calendar holds the official 2026 Chinese State Council dates; other years are not included. Extra dates can be merged in through the `holidays` array of your `~/.config/deeptally/PriceTable.json`. |
| What does *"estimated"* mean? | The rates are **estimates of what a request would cost**: prices are computed locally from the versioned price table with the peak/off-peak windows. Model line-ups and prices changed three times in 2026, and the app cannot see what any other client actually sent. DeepSeek's own billing is the only authoritative figure, and there is no API for it. The balance is not an estimate — it comes straight from `GET /user/balance`. |
| Where has my usage history gone? | There never was an API-only source for it, and this app does not keep one. An older version may have left a usage ledger in `~/Library/Application Support/DeepTally`; the current app never reads or writes it. If you want a copy, copy the directory before running the uninstaller — which is what deletes it. |

---

## Screenshots

The screenshots in this documentation are rendered **from the shipping views**, not drawn by hand —
`make screenshots` runs the real composition root and the real key precedence (`--spike render-popover`) and
writes the PNGs to `dist/`; the copies committed under `docs/assets/` come from that same command:

| File | What it is | Generated as |
|---|---|---|
| [`assets/popover.png`](assets/popover.png) | the popover, light appearance | `dist/popover.png` |
| [`assets/popover-dark.png`](assets/popover-dark.png) | the same popover, dark appearance | `dist/popover-dark.png` |

![The DeepTally popover in dark appearance](assets/popover-dark.png)

`make screenshots` also renders the settings block, which sits below the popover's 420 pt fold, to
`dist/popover-settings.png`. Because the render waits for a settled state and uses the same key resolution
as the app, a successful `make screenshots` without `DEEPSEEK_API_KEY` set is also a live check that the
Keychain import works. The offscreen-rendering details (why a colorScheme and a background must be set
explicitly) are in [`DEVELOPMENT.md`](DEVELOPMENT.md).
