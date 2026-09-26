# Refresh-policy research — 2026-09-26

Evidence behind Step 6.7 of [`../../PLAN.md`](../../PLAN.md): how a menu bar balance meter should refresh
when the server offers no way to announce a change. The question was raised by the owner ("refresh either
detecting that the budget changed, if there is a way, or every x amount of time — the most correct solution,
not the cheapest"), and answered with three independent research lanes plus an evidence audit, all run by
`deepseek-flash` researcher/auditor subagents with web access.

## Verdict

**No API-key-reachable change signal exists.** DeepSeek's documented API surface is nine operations with no
usage, spend, quota, webhook or event endpoint; the complete changelog (2024-06-14 → 2026-09-10) announces
none; the live `/user/balance` response carries no `ETag`, `Last-Modified` or `Cache-Control` (so RFC 9110
conditional GET has nothing to validate) and no timestamp or revision in the body. The undocumented
`platform.deepseek.com/api/v0/usage/*` console endpoints return aggregates but authenticate with a browser
session token, not `sk-`. Poll-and-compare is therefore the only mechanism.

The correct design follows from that: **user intent first** (refresh when the popover opens), **events as
recovery checks** (wake, display wake, session switch, network return, power change), and a **deferrable
backstop timer** that is never treated as a freshness guarantee. Faster polling buys almost nothing: it
shortens the exposure of a stale reading but cannot reveal *when* the server-side value changed.

## Files

| File | Lane | What it settles |
|---|---|---|
| [`api.md`](api.md) | DeepSeek server-side detection | No webhook/SSE/push, no usage endpoint for API keys, no validators, no documented polling budget; the only server-side balance signal is `402` on a model call, which DeepTally never makes |
| [`macos.md`](macos.md) | macOS platform design | Apple's timer/App-Nap/energy semantics; the trigger matrix; the one-shot wall-clock dispatch timer with `leeway`; the rejected and accepted APIs |
| [`precedent.md`](precedent.md) | Comparable tools + change semantics | What balance/usage meters actually do (intervals 15 s–30 min, most 5–30 min; only CodexBar is well-architected); the `changed`/`unchanged`/`unknown` semantics and why "unchanged" must never be worded "no spend" |
| [`audit.md`](audit.md) | Evidence audit | Independent re-check of ~40 load-bearing claims; what may be trusted and what may not |

## What the audit changed

- The DeepSeek negative is **supported** (independently reproduced sitemap and changelog checks).
- "Balance has a seconds-to-minutes ingestion delay" is **third-party only and self-contradictory** — do not
  treat it as a fact.
- The console usage endpoints are reported by a community contributor, not by DeepSeek — the brief's
  "DeepSeek's own org states" was over-read.
- "A status-item `LSUIElement` app is App-Napped, so its timer is deferred" is **plausible but not
  Apple-documented**. The design does not depend on it: that premise is exactly why the timer is a backstop
  and the user-intent path is primary.
- The three lanes proposed three different interval numbers. They are **judgment, not findings**; the parent
  reconciled them into the single policy in Step 6.7 (30 min default on the adapter, ≥1 h on battery or Low
  Power Mode, 5–240 range kept by owner decision, stale = 2× the effective interval, tolerance ≥10%).

## Known limits carried into the code

- The specific intervals have no vendor or Apple recommendation behind them; they follow from the platform
  guidance plus the measured absence of a change signal.
- DeepSeek's balance consistency lag is unmeasured, so the app claims "as of HH:MM" and never real-time.
- The screen-unlock notification is undocumented (`com.apple.screenIsUnlocked`); the app uses
  `screensDidWakeNotification` as the supported proxy.
