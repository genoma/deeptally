# Research: DeepTally refresh precedent + "balance changed" semantics

Lane: precedent + change-detection semantics (one of three lanes). Repo not touched.
Access date: this run. Repository artifacts I fetched carry dates 2025-05 → 2026-08; this project's own
`AGENTS.md` states machine facts verified 2026-09-24 and an API-only decision dated 2026-09-26, so the run is
on/after 2026-09-26. I did not have today's exact date, so I avoid claiming one.

Labels used throughout: **VERIFIED** (the cited source says it), **INFERRED** (my reasoning, not the source's
claim), **UNKNOWN** (could not settle).

---

## Summary

Precedent is consistent and boring: DeepSeek balance tools poll on a wall-clock timer with a manual refresh,
defaults of 30 s (least careful), 5 min (most common), 10–30 min (the careful end), and *none* of them does
anything clever about change detection beyond comparing the new snapshot to the previous one. The only
well-architected monitor in the sample (CodexBar, which covers 15+ providers including DeepSeek) explicitly
abandoned value-triggered cadence in favour of a 2–30 min adaptive policy keyed on **user interaction, local
agent activity and power/thermal state**, plus staleness dimming, last-snapshot retention with its original
timestamp, refresh coalescing and per-window alert rate limiting.

For DeepTally the defensible semantics are: `changed` = the per-currency, per-field **Decimal value differs from
the last confirmed snapshot** (never a double, never an epsilon across money); `unchanged` = identical values
**and** the observation is fresh; `unknown` = no successful observation since the last confirmed one, or that
observation is older than a freshness threshold (≈2× the interval). "Unchanged" must be phrased as "no change
observed between t1 and t2" — never "no spend", because DeepSeek's docs define `granted_balance` as the
"total not expired granted balance", so a *decrease* can be expiry, not spend, and no vendor endpoint reports
spend to an API key.

---

## PART 1 — Precedent table

Quality caveat (important): all DeepSeek-specific tools I found are hobby repos created 2026-05/06 with
0–1 stars. They are evidence of *convention*, not of correctness. The load-bearing precedents are Apple,
Prometheus, Google and CodexBar.

| Tool | Interval (verified) | Triggers | Verified how |
|---|---|---|---|
| CodexBar (steipete) — multi-provider incl. DeepSeek | Fixed 1/2/5/15/30 min + Manual; **Adaptive is fresh-install default**, bounded 2–30 min | Timer; menu open recency; local coding-agent activity (agent-aware mode only); Low Power Mode / thermal `.serious`/`.critical` → 30 min | Source doc `docs/refresh-loop.md`: policy table "Low Power Mode … 30 min", "Menu opened at most 5 min ago … 2 min", "No recorded menu open, or opened 4+ h ago … 30 min", "Every decision falls in the 2–30 min range by construction", "Deliberately excludes quota, latency, error, account, and time-of-day signals" |
| CodexBar — failure/stale behaviour | n/a | Refresh failure **keeps last snapshot and its original measurement time**; stale/error dims icon | Same doc: "Recognized temporary network failures keep the last successful snapshot and its original measurement time"; "Stale/error states dim the icon and surface status in-menu" |
| CodexBar — alert limiting | 600 s suppression window | "allow the first matching attempt immediately, then drop further attempts for the same provider/account/window for 600 seconds" | `docs/configuration.md` (hooks section) |
| guancn/deepseek-balance | **300 s default**, user-configurable 60 s–1 h | Timer (`BalanceService.start(interval:)`) + "Refresh Now" (⌘R) | `AppDelegate.swift`: `private var refreshInterval: TimeInterval = 300 // 5 min default`, `if stored >= 60 { // at least 1 minute`; `MenuBarController.swift`: menu item "Refresh Now" |
| Iristack/deepseek-statusbar | **1800 s default (30 min)**, configurable 60–3600 s | Timer ("点击应用后…重置定时器": applying settings resets the timer) + manual refresh row | README (zh): "自动刷新 — 可配置 60–3600 秒轮询间隔，默认 30 分钟"; FAQ: 高频调用建议 600 秒; FAQ on network errors: "网络错误不会清空已有的余额数据。菜单栏中过期的数据总好过没有数据" (stale data beats no data) |
| pj-workspace/DS-Fathom | **300 s default**; options 10 s,1 m,5 m,15 m,30 m,1 h | Timer + explicit value-compare; history row only when value differs; low-balance latch | `BalanceViewModel.swift`: `static var 'default': RefreshIntervalOption { .fiveMin }`; `if let prev = previousBalance, abs(current - prev) > 0.001`; `lastEntry.totalBalance != info.totalBalance`; `hasNotifiedLowBalance` reset only when "Balance recovered" |
| jlaiii/deepseek-balance-widget | 30 s | auto-refresh + "just now / 3s ago" relative timestamp ticking every 1 s | README |
| adoreQ/deepseek-balance (DSH plugin) | 30 s (configurable) | timer + manual refresh button | README: "polls the balance every 30 s (configurable) plus a manual refresh button" |
| LemCAE/dsh-balance | 15 s … 5 min, or custom | auto-refresh toggle + click-to-refresh chip, 500 ms hover tooltip | README |
| frederick-wang/pi-deepseek-balance | not stated for polling; exposes burn rate + "snapshot count" | thresholds `20,5`; labels derived quantities | README: "DeepSeek provides no token-usage or spend-history API (a community request has been open since 2026-06); everything beyond the raw balance is derived client-side and labeled as such" |
| JayHome137/DeepSeekMonitor | unknown (README not fetched) | widget deep links, local CSV/ZIP usage import "当官方用量接口不可用时" | search-result summary only — **not verified in source** |
| meduzkin/claude-usage-bar | **5/10/15/20/30 min, default 10 min** | Timer; **on menu open, throttled by a 30 s cooldown**; right-click = refresh without opening | `main.swift`: `let INTERVAL_OPTIONS: [Int] = [5, 10, 15, 20, 30] // minutes`, `DEFAULT_INTERVAL_MINUTES: Int = 10`, `ON_OPEN_COOLDOWN: TimeInterval = 30`, `if Date().timeIntervalSince(lastRefreshAt) >= ON_OPEN_COOLDOWN { refresh() }` |
| meduzkin — staleness rendering | dims when data older than **2.5× the interval** | computed per render | `let isStale = lastSuccessfulRefreshAt != .distantPast && Date().timeIntervalSince(lastSuccessfulRefreshAt) > Double(refreshIntervalMinutes * 60) * 2.5` |
| meduzkin — alert latching | once per window per tier | `alertedWindowResetsAt`, `firedTiersInWindow: Set<Int>` | same file |
| meduzkin — update check | daily, with initial delay | "First fire is delayed slightly so launch isn't slowed and so simultaneous login-time launches across machines don't stampede the API" | same file |
| meduzkin — stated rate-limit rationale | — | — | comment: "The endpoint is rate-limited fairly aggressively // (429s within a few requests/minute) … Default 10 min keeps us well clear of the throttle" |
| kittizz/OpenRouterCreditMenuBar | **code default 300 s** (`interval > 0 ? interval : 300 // default 5 minutes`); README claims "30 seconds default" | Timer; timer rebuilt when interval changes; no wake handling | `OpenRouterCreditManager.swift`; README — **contradiction, see Contradictions** |
| WoojinAhn/CursorMeter | Settings refresh interval (default not quoted) | Shared in-flight refresh; "minimum 3-second interval between accepted starts"; tiered "usage-jump" flash (⚡/🚀) and notification on tier-2 jumps; last snapshot survives restart "with its original cache date and time" | README |
| dmelo/claude-code-stats | every 5 min | auto-refresh | search summary only — **not verified in source** |
| mntrspace/claude-bar | opt-in auto-poll + interval picker | menu toggle | search summary only |
| tansdf/cursor-usage-meter | every 5 min | auto + click-to-refresh | search summary only |
| shadeov/cursor-costs-raycast | 1–30 min configurable | auto refresh | search summary only |
| Stock Ticker (Almost Good Enough ApS, Mac App Store) | 60 s | — | listing: "This is NOT: o a realtime ticker, quotes are updated every 60 seconds" |
| CryptoTicker (1secspeed.com) | 10 s or 5 min, user's call | — | vendor page (search snippet): "Refresh every 10 seconds, or every 5 minutes. Your call." |
| moimz/iCoinTicker | 10 s–1 h | auto + manual refresh | search summary only |
| SwiftBar (menu-bar plugin host) | interval encoded in filename (`date.1m.sh`), or a **cron** schedule tag | plugin re-run on interval; `<swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>` refreshes before presenting the menu; `refresh` action on click; `SWIFTBAR_PLUGIN_REFRESH_REASON` exposes the trigger; `OS_LAST_SLEEP_TIME`/`OS_LAST_WAKE_TIME` (ISO8601, empty if no sleep since launch) are passed to plugins | SwiftBar README |
| xbar Yahoo stock plugin | 10 m (filename `.10m.py`) | — | xbar plugin docs page |
| Apple Weather-class widget (WidgetKit) | **typical 15–60 min**; floor ~5 min | app requests; **system decides** and coalesces | Apple: "For a widget the user frequently views, a daily budget typically includes from 40 to 70 refreshes. This rate roughly translates to widget reloads every 15 to 60 minutes"; "Your timeline provider should create timeline entries that are at least about 5 minutes apart. WidgetKit may coalesce reloads across multiple widgets" |
| iStat Menus | no published interval on the product page | — | not verifiable from the page I fetched |

Sleep/wake handling in the sample: none of the DeepSeek/Claude/OpenRouter apps I read implement wake handling
(searched their sources/READMEs for sleep/wake: no matches). Two things do exist: Apple's
`NSWorkspace.didWakeNotification` ("A notification that the workspace posts when the device wakes from sleep")
and SwiftBar passing `OS_LAST_SLEEP_TIME`/`OS_LAST_WAKE_TIME` into plugins — i.e. the *host* makes wake/sleep
known to the refresh logic. **INFERRED:** for a menu-bar accessory app whose timer is not guaranteed to fire
during sleep, the practical design is "treat the interval as a floor, re-fetch on wake and on menu open, and
compute staleness from the wall-clock timestamp of the last successful fetch" — which is what CodexBar's
"recompute the delay after the previous refresh completes" plus its menu-open rule effectively achieves.

---

## PART 2 — What "the balance changed" should mean for DeepTally

### Why there is no cheap alternative to poll-and-compare here

- Conditional GET needs a validator. RFC 9110: "A recipient MUST ignore the If-Modified-Since header field if
  the resource does not have a modification date available", and `If-None-Match` compares entity tags.
  With neither ETag nor Last-Modified (the parent's header probe — **inherited premise, not re-verified by me**)
  there is nothing to revalidate against, so each check must retrieve and compare.
- Long polling needs the server to hold the request (RFC 6202 defines it that way) and is explicitly *not*
  free: the same RFC notes that with short polling "If the acceptable latency is low (e.g., on the order of
  seconds), then the polling frequency can cause an unacceptable burden on the server, the network, or both".
  DeepSeek exposes no long-poll or webhook for balance.
- Incremental sync needs a sync token. Google's Calendar docs show the pattern ("the client provides the
  previous sync token it obtained from the server"): the payoff only exists when the server can enumerate
  changes. DeepSeek's `/user/balance` cannot.
- Therefore: poll-and-compare is the only mechanism available, and "changed" can only ever mean
  "differs from what I observed last time", never "an event happened at time T".

### Recommended rules (exact)

Definitions. A *check* yields either an **Observation** (HTTP 200, parsed, with `observedAt` = local wall-clock
time at response receipt, plus the raw strings per currency row) or a **CheckFailure** (transport, auth, parse,
schema). A **confirmed snapshot** is the most recent Observation that passed validation.

1. `changed` — for any currency row present in both the new Observation and the confirmed snapshot, at least one
   of `total_balance`, `granted_balance`, `topped_up_balance` differs **as a Decimal value**. Compare Decimals
   (`Decimal(string:)`), not the raw strings and not `Double`. Rationale: string equality is fragile against
   formatting churn ("1.0" vs "1.00"); `Double` equality invites epsilon hacks — DS-Fathom's
   `abs(current - prev) > 0.001` silently classifies real sub-0.001 movements as "no change" and can never be
   exact for money. Parse failure ⇒ UNKNOWN, never "unchanged".
2. Direction and cause are attributes of a change, not new kinds of change:
   - `total_balance` ↓ with `topped_up_balance` and `granted_balance` both ↓ ⇒ unknown mix; report only the
     total delta.
   - `granted_balance` ↓ with `topped_up_balance` unchanged ⇒ **grant expiry**, not spend (DeepSeek documents
     `granted_balance` as "The total not expired granted balance").
   - `topped_up_balance` ↑ or new grant ⇒ top-up/grant, i.e. recovery.
   Increases must never be discarded: they are the events that must reset a low-balance latch.
3. `unchanged` — every field of every currency row equals the confirmed snapshot **and** the Observation is
   fresh (age ≤ freshness threshold). Copy must include both endpoints: "No change observed between 13:02 and
   13:32". Do not render a bare "unchanged" as if it were an interval-wide fact, and never word it "no spend".
4. `unknown` — no successful check since the confirmed snapshot, or the confirmed snapshot is older than the
   freshness threshold (recommend **2× the configured interval**; SwiftBar-adjacent precedent: meduzkin dims at
   2.5×, Prometheus stales series and returns *no value* rather than the last one forever: "If a query is
   evaluated at a sampling timestamp after a time series is marked as stale, then no value is returned for that
   time series"). Rendering rule: show the last confirmed value **with its own timestamp** plus an explicit
   unknown/stale marker — keep the number (users prefer stale data to a blank: Iristack's FAQ says exactly
   that) but never style it as current (CodexBar dims the icon; meduzkin tints the bar tertiary).
5. Currency rows are compared independently; never sum USD and CNY; `is_available` transitions are their own
   event (e.g. `false` with non-zero balance → "balance not usable for API calls").
6. Low-balance alerts must be **level-triggered with latch + hysteresis**, not "changed"-triggered:
   fire once when the confirmed value crosses below the floor; re-arm only when it rises above floor + margin
   (or on a detected top-up observation). DS-Fathom does exactly this latch (`hasNotifiedLowBalance`, cleared on
   recovery); Prometheus/Alertmanager supply the general shape — level expression, optional `for:`/`keep_firing_for:`
   to stop flapping, and "another layer is needed to add summarization, notification rate limiting, silencing",
   with CodexBar's 600 s per-window suppression as a concrete example.
7. Never claim more precision than the mechanism has: the detection latency for a crossing that happens mid-interval
   is up to one interval (expected ≈ Δ/2 under a uniform hazard assumption — my arithmetic, **INFERRED**). So the
   UI's "as of" timestamp is not decoration; it is the honest boundary of the claim.

### Adaptive cadence — what the evidence actually supports

- No authoritative source I found endorses "poll faster right after a detected change". Prometheus scrapes on a
  fixed interval (default 1 m; `scrape_timeout` default 10 s and "cannot be greater than the scrape interval")
  and stores every sample; adaptation is absent by design. (UNKNOWN: any vendor/standard recommending
  value-triggered cadence — none found.)
- What real implementations *do* key on: user-visible signals. CodexBar's adaptive policy uses menu-open recency,
  optional local agent activity, Low Power Mode and thermal state, bounded 2–30 min. So the honest recommendation
  is: **adapt on triggers, not on values** — refresh on app launch, on wake, on menu open (throttled, e.g. a 30 s
  cooldown after meduzkin), on manual request, and on a user-configurable interval floor.
- If a burst policy is still wanted, bound it explicitly: *K* fast checks (e.g. 3 checks at 60 s) after a
  user-visible trigger or after a detected crossing of the low-balance floor, then return to the floor interval.
  Failure mode to avoid: value-triggered fast polling cannot de-escalate while spend is ongoing — every poll
  returns "changed", so the app never returns to the slow cadence and pays the burst cost forever.
- Jitter matters more than adaptivity: Google's quota guidance is "If you need to perform an operation on a
  regular basis, vary the interval +/- 25%. This will distribute the traffic more evenly"; AWS's jitter article
  is the canonical treatment ("Full Jitter" vs "Equal Jitter" vs "Decorrelated Jitter" — "The return on
  implementation complexity of using jittered backoff is huge"). For a desktop app the herd risk is small but
  non-zero (many installs, launch-at-login, same :00/:30 boundary) — CodexBar and meduzkin both fight it
  (spread-out launch delays, initial delay before the first update check).
- Coalescing is non-negotiable: one in-flight balance check at a time (CodexBar: "only one provider-batch refresh
  runs at a time regardless of cadence mode"; CursorMeter: "minimum 3-second interval between accepted starts").
- Energy reality on macOS: Apple's Mac energy guide says timers that "poll for state changes when they should
  respond to events instead" are a named anti-pattern, recommends `NSBackgroundActivityScheduler`, and for
  repeating timers "set the tolerance to at least 10 percent of the interval"; App Nap will additionally throttle
  timer frequency for an app doing no user-visible work ("Timer throttling, which reduces the frequency with which
  the app's timers are fired"). So a 15 s default is both wasteful and *unreliable* — the OS may coalesce it.

### Strongest argument against frequent polling

Every poll is a capped-information transaction with a real, non-monetary cost. The endpoint returns a snapshot
with no server clock, so polling faster does not reveal *when* spend happened or whether spend happened between
polls — it only shortens the exposure of a stale reading, from "≤ interval" to "≤ interval'". The exchange rate
is terrible: at 5 min the worst-case staleness is 5 min; at 15 s it is 15 s, and DeepTally can act on neither
(the app makes no completion calls, cannot stop spend, and its other value-add — peak/off-peak classification —
needs zero network I/O). Meanwhile each check is a wakeup Apple's own guidance prices as energy, further coalesced
by App Nap, and there is no published request-rate budget for `/user/balance` to consume — DeepSeek's docs
publish *concurrency* limits and a 429 rule, which is a warning about politeness, not a licence to poll hard. Add
the honesty cost: a fast timer implies continuous coverage the product does not have; a 15 s poll that misses a
crossing for 14 s is still a miss, and the app will still have to say "as of 13:02".

### What would change the recommendation

- **A server-side freshness signal**: `lastUpdated` in the body, or `ETag`/`Last-Modified` on the response →
  conditional/cheap checks, and a 1–5 min cadence becomes defensible.
- **A Bearer usage/spend counter endpoint** (even coarse daily buckets) → deltas become attributable, at which
  point Prometheus-style scrape-and-store on a shorter interval is the right model.
- **Published polling guidance or rate-limit headers** (`Retry-After`, `X-RateLimit-*`) → adopt them verbatim.
- **Empirical evidence that DeepSeek's balance lags materially** (e.g. a completion's cost appears 10+ min later)
  would *weaken* the case for any fast polling; if instead the balance updates instantly and users demonstrably
  run out between polls (agentic burn), a documented opt-in "watch mode" with bounded burst is justified.
- Push/webhook support from DeepSeek — not offered today.

---

## Evidence (quotes and where I got them)

DeepSeek's own surface:
- `/user/balance` schema: `is_available`, `balance_infos[]` = `currency` (CNY|USD), `total_balance`
  ("The total available balance, including the granted balance and the topped-up balance"), `granted_balance`
  ("The total not expired granted balance"), `topped_up_balance` — `https://api-docs.deepseek.com/api/get-user-balance`.
  No timestamp field. **VERIFIED.**
- Rate limits are concurrency-based ("Concurrency Limit 2500 / 500", "when the concurrency limit is exceeded, you
  will receive an HTTP 429 error code") — `https://api-docs.deepseek.com/quick_start/rate_limit`. No published
  request-rate or polling budget for the balance endpoint. **VERIFIED (absence by inspection of that page).**
- Third-party confirmation that usage data is not API-key-reachable: `deepseek-ai/awesome-deepseek-integration`
  issue #654 (open, created 2026-06-08, last comment 2026-08-08): `/user/balance` "only returns the cash balance";
  `platform.deepseek.com/api/v0/usage/amount` and `/usage/cost` "only authenticate via session cookies, not
  Bearer … they return HTTP 200 + {code: 40003, msg: Authorization Failed}". **VERIFIED (issue text).**
- CodexBar's DeepSeek doc says the same and adds the private endpoints it uses with a browser session token
  (`platform.deepseek.com/api/v0/usage/by_api_key/amount?start=&end=&tz=`), noting "an API key cannot authenticate
  the private dashboard endpoints" and that these are "private dashboard endpoints rather than documented public
  API endpoints and may change without notice"; also "There is no session or weekly window — DeepSeek does not
  expose per-window quota via API." **VERIFIED.**
  This slightly reframes (but does not overturn) the project's "DeepSeek exposes no usage or spend endpoint"
  premise: usage *exists* behind a signed-in web session; it is unreachable with an API key, which is the only
  credential the product is allowed to use.

Monitoring / polling engineering:
- Prometheus config: `scrape_interval` default `1m`, `scrape_timeout` default `10s`,
  "It cannot be greater than the scrape interval" — `https://prometheus.io/docs/prometheus/latest/configuration/configuration/`. **VERIFIED.**
- Prometheus staleness: "The lookback period is 5 minutes by default … If a target scrape or rule evaluation no
  longer returns a sample for a time series that was previously present, this time series will be marked as stale
  … If a query is evaluated at a sampling timestamp after a time series is marked as stale, then no value is
  returned for that time series." — `https://prometheus.io/docs/prometheus/latest/querying/basics/`. **VERIFIED.**
- Prometheus alerting: `for:` = "wait for a certain duration between first encountering a new expression output
  vector element and counting an alert as firing"; `keep_firing_for:` "can be used to prevent situations such as
  flapping alerts, false resolutions due to lack of data loss"; alerting rules figure out "what is broken right
  now, but they are not a fully-fledged notification solution. Another layer is needed to add summarization,
  notification rate limiting, silencing" — `https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/`. **VERIFIED.**
- Google Calendar (quota doc): "An anti-pattern here is to repeatedly poll every calendar of interest. This will
  very quickly use up all your quota…"; "If you need to perform an operation on a regular basis, vary the interval
  +/- 25%." — `https://developers.google.com/calendar/api/guides/quota`. **VERIFIED.**
- Google Calendar (sync doc): incremental sync requires the client to hold a server-issued `nextSyncToken`;
  `410` means "trigger a full wipe of the client's store and a new full sync" — `https://developers.google.com/workspace/calendar/api/guides/sync`. **VERIFIED.**
- AWS SQS: long polling is a *queue capability* (server waits, "The maximum long polling wait time is 20
  seconds"), chosen to "reduce the number of empty responses" — `https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html`. **VERIFIED.**
- AWS jitter: "Full Jitter" / "Equal Jitter" / "Decorrelated Jitter", "The return on implementation complexity of
  using jittered backoff is huge" — `https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/`. **VERIFIED.**
- RFC 6202 §2.1: with short polling "If the acceptable latency is low (e.g., on the order of seconds), then the
  polling frequency can cause an unacceptable burden on the server, the network, or both." — `https://www.rfc-editor.org/rfc/rfc6202.txt`. **VERIFIED.**
- RFC 9110: `If-Modified-Since` — "A recipient MUST ignore the If-Modified-Since header field if the resource does
  not have a modification date available"; `If-None-Match` compares entity tags — `https://www.rfc-editor.org/rfc/rfc9110.txt`. **VERIFIED.**

Apple platform behaviour:
- WidgetKit budget: "a daily budget typically includes from 40 to 70 refreshes. This rate roughly translates to
  widget reloads every 15 to 60 minutes"; "Your timeline provider should create timeline entries that are at least
  about 5 minutes apart. WidgetKit may coalesce reloads across multiple widgets"; "Reloading widgets consumes
  system resources and causes battery drain" — `https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date` (read via Apple's docs JSON endpoint). **VERIFIED.**
- Mac energy guide, Minimize Timer Usage: "some apps use timers to poll for state changes when they should respond
  to events instead"; "Waking the system from an idle state incurs an energy cost"; "A general guideline is to set
  the tolerance to at least 10 percent of the interval for a repeating timer"; `NSBackgroundActivityScheduler` is
  recommended instead of timers; "If your app has more than one wakeup per second when it should be idle,
  investigate why" — `https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html`. **VERIFIED.**
- App Nap: "App Nap conserves battery life by regulating the app's CPU usage and by reducing the frequency with
  which its timers are fired"; measures include "Timer throttling, which reduces the frequency with which the
  app's timers are fired" — `.../power_efficiency_guidelines_osx/AppNap.html`. **VERIFIED.**
- `NSWorkspace.didWakeNotification`: "A notification that the workspace posts when the device wakes from sleep."
  **VERIFIED.** `ProcessInfo.systemUptime`: "The amount of time the system has been awake since the last time it
  was restarted." **VERIFIED** — so uptime deltas are not wall-clock deltas across sleep (**INFERRED**; the page
  does not state the sleep semantics explicitly).

---

## Contradictions

1. **kittizz/OpenRouterCreditMenuBar**: README advertises "Configurable refresh intervals (30 seconds default)",
   while the code defaults to 300 s (`interval > 0 ? interval : 300 // default 5 minutes`). Recorded, not
   resolved — a reminder that README claims about intervals must be checked against source.
2. **DS-Fathom internally inconsistent change semantics**: the change indicator uses an epsilon
   (`abs(current - prev) > 0.001` on `Double`), while history rows are skipped only on exact string inequality
   (`lastEntry.totalBalance != info.totalBalance`). Two different definitions of "changed" in one app.
3. **Usage-endpoint framing**: this project's premise says DeepSeek exposes no usage/spend endpoint; CodexBar
   and issue #654 show usage *is* fetchable from undocumented `platform.deepseek.com` dashboard endpoints — but
   only with a browser session token, never with an API key. Both statements can be true; the premise is precise
   only if scoped to API-key-accessible endpoints.
4. **No real disagreement found** between the authoritative sources on the substance: everyone who has a "did it
   change" question and no validator ends up polling and comparing, and nobody recommends value-triggered cadence.

## Missing evidence / UNKNOWN

- Independent verification of the header probe: I could not issue an HTTP request, so "no ETag/Last-Modified on
  `/user/balance`" is **inherited from the parent**, not re-verified here. Also unknown: whether the response
  carries `Cache-Control`/`Age` (would hint at a CDN sitting in front and at real freshness).
- Whether `/user/balance` is *eventually consistent* with respect to a completion's cost, and with what lag. No
  source states it; it determines whether a fast cadence has any informational value at all.
- Documented power-nap timer semantics for a repeating `Timer`/`DispatchSourceTimer` across system sleep on
  macOS 27 — no Apple page found that states what happens to the missed ticks. `source_check` on the
  "snapshot with no validator" claim returned status *unclear, confidence 0.30* ("automated semantic support or
  contradiction assessment is unavailable"), so that claim rests on the API-docs page plus the parent's probe,
  and I disclose this validation limitation.
- Default intervals for several tools (CursorMeter, coin_monitor, cryptoticker, dmelo/claude-code-stats,
  tansdf/cursor-usage-meter, mntrspace/claude-bar) — search-result summaries only, READMEs not fetched.
- Precedent quality: the DeepSeek-specific tools are 0–1 star repos created 2026-05/06 (guancn 0★ pushed
  2026-06-17; DS-Fathom 0★ pushed 2026-06-22; Iristack 1★ pushed 2026-05-22; meduzkin 3★ pushed 2026-05-25;
  kittizz 23★ pushed 2025-05-24) — treat as convention, not validation. No DeepSeek-official guidance on client
  polling cadence exists to cite.

---

## Recommendation summary (one paragraph)

Default to a modest floor interval (10–30 min is inside both Apple's widget budget and the careful end of the
DeepSeek precedent; 5 min is the precedent mode if a snappier default is wanted), plus refresh on launch, on
wake, on menu open with a ~30 s cooldown, on manual request, and optionally a 3-check burst at ~60 s after a
low-balance crossing or a user-visible trigger — with ±25% jitter on the timer, a tolerance of ≥10% of the
interval, a single in-flight check, and the last confirmed value always carrying its own observation timestamp.
Define `changed` = exact per-currency per-field Decimal difference from the last confirmed snapshot (classified by
direction and by which field moved, so grant expiry is never reported as spend), `unchanged` = identical values
*and* fresh ("no change observed between t1 and t2"), `unknown` = no fresh observation (age > 2× interval, or a
failed check) rendered as the stale value plus its timestamp and a marker. Never say "no spend"; never present a
stale value as current; never let "an increase" suppress the change event, only any alert.

## Confidence

- Change-detection semantics (the `changed`/`unchanged`/`unknown` definitions and the non-claim about spend):
  **high** — it follows directly from the documented response schema (no timestamp; granted balance expires) and
  from RFC/Prometheus precedent.
- Recommended cadence and trigger set: **medium** — well-supported by Apple/Google/Prometheus guidance and by
  CodexBar, but the DeepSeek-specific optimal interval is unmeasurable without knowing the endpoint's
  consistency lag and any unpublished rate budget.
- Precedent generalisations ("this is what similar tools do"): **low-to-medium** — the sample is small, young and
  low-adoption; only CodexBar is a mature, widely distributed implementation.

### What would falsify my main conclusion

- Evidence that `/user/balance` reflects spend instantly *and* that users act on sub-minute freshness (e.g. an
  agent that must be stopped before it drains the account) would falsify "frequent polling is not worth it".
- Evidence of a long consistency lag (cost visible only minutes/hours later) would falsify "polling faster
  shortens detection latency" and push the default interval up, not down.
- A `Last-Modified`/`ETag` or an `updated_at` body field would falsify the "poll-and-compare is the only option"
  premise, which is the load-bearing assumption behind the recommended cadence.
- Demonstrated evidence that DeepSeek returns unstable Decimal formatting across identical balances would
  falsify nothing in the recommendation (Decimal comparison absorbs it) but *would* falsify any string-equality
  implementation — including the one DS-Fathom uses for history.

### Open questions I could not settle

1. What is the real freshness/consistency lag of `GET /user/balance` after a completion is billed?
2. Are there undisclosed rate limits for that endpoint (429 thresholds, `Retry-After`, `X-RateLimit-*`)?
3. Does the response carry `Cache-Control`/`ETag` behind a CDN, and does that vary by region?
4. What happens on macOS 27 to missed ticks of a repeating timer that spans system sleep (and does the app need
   `didWakeNotification` specifically, or is a wall-clock staleness check sufficient)?
5. Would DeepSeek accept or publish a client-side polling cadence expectation for third-party monitors (issue #654
   is the closest thing to a channel, and it is about usage APIs, not cadence)?

## Sources

Kept (primary or directly relevant, each actually inspected):
- DeepSeek API docs — Get User Balance (`/user/balance` schema, no timestamp): decisive for what "changed" can mean.
- DeepSeek API docs — Rate Limit & Isolation: the only vendor statement on request-side limits (concurrency + 429).
- CodexBar `docs/refresh-loop.md`, `docs/deepseek.md`, `docs/configuration.md`, `docs/status.md`: the only mature,
  multi-provider monitor with a published cadence policy, staleness model, coalescing and alert rate limiting.
- meduzkin/claude-usage-bar `main.swift`: best-in-sample example of interval options, on-open cooldown, 2.5×
  staleness rendering, alert latching, and an explicitly documented throttle rationale.
- pj-workspace/DS-Fathom `BalanceViewModel.swift` + README: DeepSeek-specific change indicator, history-on-change,
  low-balance latch (also the source of the epsilon anti-pattern).
- guancn/deepseek-balance `AppDelegate.swift`/`MenuBarController.swift`, Iristack/deepseek-statusbar README,
  frederick-wang/pi-deepseek-balance README, kittizz `OpenRouterCreditManager.swift`, CursorMeter README:
  concrete interval + trigger evidence, plus the "derived and labeled as such" practice.
- SwiftBar README: plugin interval/cron semantics, refreshOnOpen, refresh reason, OS sleep/wake env vars.
- Apple: WidgetKit "Keeping a widget up to date"; Energy Efficiency Guide for Mac Apps (Timers, App Nap);
  `NSWorkspace.didWakeNotification`; `ProcessInfo.systemUptime`.
- Prometheus: configuration, querying basics (staleness), alerting rules.
- Google Calendar: quota guidance (randomize ±25%, anti-pattern of polling every calendar), sync-tokens guide.
- RFC 6202 (long polling/bidirectional HTTP), RFC 9110 (validators, If-Modified-Since), RFC 6202/9110 fetched as
  raw text for exact wording.
- AWS: SQS short/long polling; "Exponential Backoff And Jitter".
- Stock Ticker Mac App Store listing (60 s, "NOT a realtime ticker"); xbar 10 m plugin filename.
- `deepseek-ai/awesome-deepseek-integration` issue #654 (opened 2026-06-08, still open).

Rejected / deprioritized:
- SessionWatcher, Tick Cat, Market Bar, NowCoiner, CryptoTicker, various Raycast/VS Code extensions — marketing
  pages whose interval claims could not be tied to source; used only where the claim was the point (e.g. Stock
  Ticker's "not realtime, 60 s") and marked accordingly.
- Reddit/App-Store-snippet aggregations of OpenRouter apps — redundant with the two OpenRouter repos I inspected.
- Apple's `NSBackgroundActivityScheduler` and WidgetKit docs pages as HTML — JavaScript-rendered, unreadable via
  the available fetchers; the older archive energy guide and the docs JSON endpoint carried the same claims.
- iStat Menus product page — no interval/update-frequency statement to cite.

## Next steps (only the most useful)

1. Two-sided empirical probe of `/user/balance` (needs an API key, out of scope for this lane): fetch twice 60 s
   apart during known activity and record response headers, whether amounts move, and with what lag. This settles
   the consistency-lag question that decides default-interval, and re-tests the "no validator" premise.
2. Decide the freshness threshold in code terms (2× interval vs a fixed 2× cap) and make it a test fixture: the
   `unknown` state is what a menu-bar meter is most likely to get wrong by rendering a stale number as current.
3. If a burst policy is adopted, specify it as a bounded counter (e.g. 3 checks @ 60 s) with a documented
   anti-oscillation rule, because "poll faster while it keeps changing" has no supporting precedent and cannot
   de-escalate under steady spend.
