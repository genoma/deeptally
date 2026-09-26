# Research: server-side change detection for DeepSeek balance/spend (webhooks, conditional GET, usage APIs)

Access date for every source below: **2026-09-26** (this research run). The parent's live probe of
`GET https://api.deepseek.com/user/balance` (2026-09-26, no ETag / Last-Modified / Cache-Control /
Expires / rate-limit headers) is treated as input data and cross-checked, not re-run — I have no API key.

## Verdict

**NO for any third-party app that may use only the API key.** There is no documented webhook, event
stream, push notification, balance-alert API, auto-top-up API, or usage/spend endpoint on
`api.deepseek.com`. The API reference index contains exactly nine operations and none of them is
usage-, spend-, quota-, or event-related. Polling is therefore the only mechanism available.

**PARTIAL in two narrow, non-actionable senses** (recorded for completeness, both out of scope for DeepTally):

1. Undocumented **web-console** endpoints (`platform.deepseek.com/api/v0/usage/...`) do return token/spend
   aggregates, but they live on a third host and authenticate with a browser **session token**, not an API
   key — the API key is rejected (`HTTP 200 + {"code":40003}`).
2. The platform UI offers a human-facing **low-balance e-mail/SMS alert** (server-side push to a person,
   not machine-readable).

For DeepTally — API key only, hosts limited to `api.deepseek.com` + `api.github.com`, no cookies, no
completion calls — the answer is a plain **no**: poll, and treat the payload's "as of" semantics as
client-side.

## Findings

1. **The API reference index has no usage/spend/quota/webhook endpoint.**
   The docs sitemap enumerates every API-reference page: `create-chat-completion`, `create-completion`
   (FIM), `create-response` (Responses API), `create-file`, `delete-file`, `retrieve-file`, `list-files`,
   `list-models`, `get-user-balance`. Nothing else. **Source:**
   <https://api-docs.deepseek.com/sitemap.xml> (accessed 2026-09-26). **Support:** direct evidence.
   **Confidence:** high.

2. **The balance payload carries no timestamp, revision, or etag-like field.** Documented response is
   `is_available` (bool) + `balance_infos[]` with `currency`, `total_balance`, `granted_balance`,
   `topped_up_balance` — all money as strings, no date field, no cache validator. **Source:**
   <https://api-docs.deepseek.com/api/get-user-balance/> (accessed 2026-09-26): "**is_available** boolean
   Whether the user's balance is sufficient for API calls." / "**total_balance** string". **Support:**
   direct evidence. **Confidence:** high. This is why the parent's probe found no change signal: there is
   nothing in the body that can serve as one either. Error envelopes are not documented to carry a
   timestamp; the documented error surface is status codes only (400/401/402/422/429/500/503) —
   <https://api-docs.deepseek.com/quick_start/error_codes> (accessed 2026-09-26). **Researcher inference:**
   the *only* server-side "your balance changed" signal DeepSeek documents is `402 - Insufficient Balance`
   ("Cause: You have run out of balance"), and it is delivered only as the response to an actual model call,
   which DeepTally by design never makes.

3. **No webhook / SSE-push / subscription endpoint exists; SSE is used only inside `/chat/completions`
   streaming.** The Responses API is explicitly stateless: "The API is stateless: responses and
   conversations are not stored on the server." **Source:**
   <https://api-docs.deepseek.com/api/create-response> (search-indexed, accessed 2026-09-26) and the
   sitemap in finding 1. The only push-shaped transport the docs describe is the keep-alive mechanism:
   "Streaming requests: Continuously return SSE keep-alive comments (`: keep-alive`)" — and it exists to
   hold a *model* request open, not to notify about account state. **Source:**
   <https://api-docs.deepseek.com/quick_start/rate_limit/> (accessed 2026-09-26). **Support:** direct
   evidence for the quotes; **inference** for "therefore no push channel". **Confidence:** high.

4. **Undocumented console endpoints do expose per-key token/spend aggregates — but not to an API key.**
   A feature request in DeepSeek's own GitHub org states: "**`https://platform.deepseek.com/api/v0/usage/amount`**
   and **`/usage/cost`** are exactly what third-party tools need — but they live under the **web console
   domain** and only authenticate via **session cookies**, not Bearer. From an API key's perspective, they
   return `HTTP 200 + {"code": 40003, "msg": "Authorization Failed"}`". **Source:**
   <https://github.com/deepseek-ai/awesome-deepseek-integration/issues/654> (issue opened 2026-06-08, still
   OPEN at access time; body quoted; last comment 2026-08-08; no DeepSeek maintainer reply in the fetched
   thread). Independent corroboration from two shipped implementations, both of which require the user to
   paste the web console token: "平台业务接口的 Bearer 令牌是**网页控制台会话令牌**（`localStorage` 的
   `userToken`），不是 `sk-` API Key（后者返回 40003 invalid token）" — <https://github.com/Huasecc/dsh-usage>
   (README, accessed 2026-09-26); and "`platform.deepseek.com/api/v0/usage/amount`、`usage/cost`（网页接口）
   … 登录态 userToken" with the explicit warning "用量 / 消费接口是 platform.deepseek.com 的私有接口，
   非官方公开 API，可能随时变更" — <https://github.com/AzureHalcyon/dsh-deepseek-usage> (README, accessed
   2026-09-26). **Support:** direct evidence (quotes) from third-party sources; the endpoint family is
   **not** in any official doc. **Confidence:** high that these endpoints are session-token-only and
   undocumented; medium that they exist in this exact form today (I could not test them).

5. **`/user/balance` is not rate-limited *by documentation*; model concurrency is what is documented.**
   "For each account, the concurrency limits for different DeepSeek API models are shown in the table
   below … deepseek-flash 2500, deepseek-v4-pro 500 … when the concurrency limit is exceeded, you will
   receive an HTTP 429 error code." **Source:**
   <https://api-docs.deepseek.com/quick_start/rate_limit/> (accessed 2026-09-26). No RPM/TPM quota, and no
   per-endpoint budget for `/user/balance`, is published anywhere in the docs. **Support:** direct evidence
   (absence of a statement is what is verified here). **Confidence:** high for model calls; **UNKNOWN** for
   whether `/user/balance` is exempt from the same dynamic limiter (see finding 6).

6. **But the official FAQ documents *dynamic* limiting keyed on recent usage — so aggressive polling is
   the thing to avoid, not a specific number.** "当前阶段，我们没有按照用户设置硬性并发上限。在系统总负载量
   较高时，基于系统负载和用户短时历史用量的动态限流模型可能会导致用户收到 503 或 429 错误码。" (At this
   stage we do not set a hard concurrency cap per user; under high system load a dynamic rate-limiting model
   based on system load and the user's **short-term historical usage** may cause users to receive 503 or 429.)
   **Source:** official FAQ, `platform.deepseek.com/api-docs/zh-cn/faq/` — read via Wayback capture
   <https://web.archive.org/web/20241010193242/https://platform.deepseek.com/api-docs/zh-cn/faq/>
   (capture dated 2024-10-10); the same passage is still present in the currently indexed copy of the FAQ
   (search index hit on the intercom-hosted mirror of the same page, accessed 2026-09-26). Direct fetch of
   the live FAQ returned HTTP 403 and the `api-docs.deepseek.com/zh-cn/faq/` page is a JS/META redirect to
   the static FAQ SPA, which is why I cite the archived copy — **disclose this access limitation.**
   **Support:** direct evidence (quote), with a dated snapshot caveat. **Confidence:** medium-high.
   The English error page gives the practical rule: "429 - Rate Limit Reached. Cause: You are sending
   requests too quickly. Solution: Please pace your requests reasonably." —
   <https://api-docs.deepseek.com/quick_start/error_codes> (accessed 2026-09-26).

7. **OpenAI-style `x-ratelimit-*` headers are NOT documented by DeepSeek and NOT supported by any primary
   source I could load; treat the one third-party claim as unverified.** The single source asserting them is
   OpenUsage's provider doc: "Source: response headers on `GET /v1/models` — `x-ratelimit-limit-requests`,
   `x-ratelimit-remaining-requests`, `x-ratelimit-reset-requests` … Transform: parsed verbatim." —
   <https://raw.githubusercontent.com/janekbaraniewski/openusage/main/docs/site/docs/providers/deepseek.md>
   (accessed 2026-09-26). DeepSeek's own docs never mention these headers; a `source_check` pass on this
   claim returned **inconclusive** (only the same third-party doc and SEO-farm pages, one of which
   hallucinates an "HTTP 229" code — e.g. <https://www.tpointtech.com/rate-limits-and-best-practices-with-deepseek>,
   rejected). The parent's live probe found no rate-limit headers on `/user/balance`. **Support:**
   interpretation. **Confidence:** low for the claim's truth; high for "undocumented by DeepSeek".
   **Researcher inference:** even if the headers existed on model endpoints, they report *rate-limit
   counters*, not spend or balance — they cannot reveal consumption between balance polls. The same
   OpenUsage doc separately states: "**Spend / cost.** DeepSeek's API does not expose period-to-date spend."

8. **No changelog announcement of any usage/balance/webhook API, across the whole documented history.**
   I read the full Change Log (entries from 2024-06-14 through 2026-09-10, i.e. every API change DeepSeek
   has published): all changes are model releases, pricing, Responses API, thinking effort, context caching,
   FIM, JSON mode. Nothing about usage/balance endpoints, webhooks, or push. **Source:**
   <https://api-docs.deepseek.com/updates> (accessed 2026-09-26; newest entry "Date: 2026-09-10"). **Support:**
   direct evidence (negative finding from a complete read of the page). **Confidence:** high.

9. **The demand for a Bearer usage API is public, open, and unanswered.** Issue #654 (title:
   "[Feature Request] Provide a Bearer-authenticated, real-time aggregated usage / quota API for third-party
   tools (e.g. CodexBar)") lists the exact fields a menu-bar app would need (`today_cost_usd`,
   `last_refresh_at`, …), is `state: OPEN`, `assignees: none`, `labels: none`, and shows no DeepSeek reply.
   **Source:** <https://github.com/deepseek-ai/awesome-deepseek-integration/issues/654> (created 2026-06-08,
   accessed 2026-09-26). A third-party npm package states the same conclusion: "DeepSeek 没有提供 token 用量
   或消费历史的 API（社区请求自 2026-06 起悬而未决）" — <https://cdn.jsdelivr.net/npm/pi-deepseek-balance@0.1.7/README.zh-CN.md>
   (accessed 2026-09-26). **Support:** direct evidence. **Confidence:** high.

10. **A human-facing low-balance alert exists on the platform (server-side push to e-mail/SMS), with no API.**
    Multiple independent Chinese walkthroughs describe the setting next to the top-up button: "充值按钮旁边有个
    余额预警设置，当账户余额低于指定值后，Deepseek 会通过邮箱/手机号向你发送通知" —
    <https://devpress.csdn.net/v1/article/detail/145912269> (accessed 2026-09-26); "可以设置下余额预警，当余额低于
    某个额度时会通过手机号、邮箱发提示" — <https://blog.csdn.net/chengxuyuananxin/article/details/145914585>
    (accessed 2026-09-26); "在控制台的 充值管理 页面，我们可以设置 余额预警阈值 … 系统会通过短信或邮件通知你" —
    <https://opc.csdn.net/6a2bdea610ee7a33f27bdba4.html> (accessed 2026-09-26). **Source quality:** secondary
    only; no official page found (the FAQ documents top-up/invoice/grant-expiry questions but not alerting).
    **Support:** interpretation from three independent secondary sources. **Confidence:** medium that the
    feature exists; **high** that it is not exposed as an API and is not consumable by a third-party app.
    **Researcher inference:** this is the only true "server pushes when balance changes" mechanism DeepSeek
    offers, and it terminates in a human's inbox, not in a client.

11. **Balance freshness is not guaranteed by DeepSeek; third-party operators observe an ingestion delay.**
    "Polled every 30 s by default. The balance endpoint is updated by DeepSeek with a small ingestion delay
    (seconds to minutes)." — <https://raw.githubusercontent.com/janekbaraniewski/openusage/main/docs/site/docs/providers/deepseek.md>
    (accessed 2026-09-26, third-party, no methodology shown). **Support:** interpretation. **Confidence:**
    low-medium. **Researcher inference:** if true, polling faster than once a minute buys nothing, which
    reinforces the "display as of" design already in the repo.

12. **Terms of Service give DeepSeek an explicit lever against disruptive automated access, and there is no
    "polling is fine" clause to lean on.** ToS (release 2026-04-22, effective 2026-04-29) §7.2: "DeepSeek
    reserves the right to independently judge and take measures against you, including issuing warnings …
    restricting account functions, restricting or suspending usage, locking or closing accounts … if DeepSeek
    believes or determines that: … (b) your and/or your end user's access to, or use of the Services
    disrupts or poses a significant threat to the functionality, security, integrity, or availability of the
    Services". §6.1 also disclaims responsibility for losses from failing to recharge on time. **Source:**
    <https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html> (accessed
    2026-09-26). **Support:** direct evidence (quotes). **Confidence:** high.

13. **The legacy machine-readable status feed is gone (fetched today).** `https://status.deepseek.com/api/v2/status.json`
    returns `{"code":"RouteNotFound","message":"The route you request is not found."}` (my fetch, 2026-09-26),
    consistent with the reported migration of `status.deepseek.com` to a Flashduty-hosted status page
    (<https://www.flashduty.com/en/now/blog/deepseek-statuspage-migration>, accessed 2026-09-26, vendor blog).
    **Support:** direct evidence for the 404; interpretation for the cause. **Confidence:** high on the
    404, medium on the migration detail. Not a balance channel either way, and outside the app's allowed hosts.

## Safest defensible polling policy implied by the docs

The documents do not prescribe an interval. They do prescribe *behaviour*: no header tricks, no burst, back
off when told to. A policy that cannot be criticised from these sources:

- **Interval.** Foreground (popover open): **60 s**. Background/idle: **5–15 min**. Suspend entirely when
  offline, asleep, or on Low Power. Rationale: no documented freshness guarantee, and a reported ingestion
  delay of seconds-to-minutes (finding 11) means sub-minute polling is not informative; DeepSeek's own
  dashboard is not real-time either (issue #654: "The web dashboard has noticeable delay").
- **Concurrency.** Exactly **one in-flight request** at a time; never parallel or scheduled-storm polls.
  The documented limiter is concurrency-shaped (finding 5) and dynamic (finding 6).
- **Backoff.** On 429/500/503: exponential backoff with jitter, cap ~15–30 min; no unbounded retries.
  Docs: "retry your request after a brief wait" (500/503) and "pace your requests reasonably" (429).
  Honour `Retry-After` if present — but it is **not documented** by DeepSeek, so treat its absence as normal.
- **Headers.** `Authorization: Bearer <key>`, `Accept: application/json`. That is all the docs specify.
  Do **not** send cookies, `Origin`/`Referer`/`X-Requested-With`, or a spoofed browser `User-Agent` (the
  browser-header requirement reported for `platform.deepseek.com` is a WAF artefact of the console, not of
  `api.deepseek.com` — finding 4). Send an honest, identifying UA:
  `DeepTally/<version> (+https://github.com/genoma/deeptally)`; it costs nothing and is the defensible
  default under ToS §7.2(b).
- **Conditional GET.** DeepTally should *tolerate and exploit* validators if they ever appear: store `ETag`
  / `Last-Modified` and send `If-None-Match` / `If-Modified-Since`, treating `304` as "balance unchanged".
  Today this is a no-op (no validators observed, none documented) — implement the branch, keep the fallback
  plain `GET`. Do not send `Cache-Control: no-cache` (it changes nothing and signals nothing).
- **Change detection fallback.** Compare the parsed payload (not the raw body — field order/key spacing is
  not a contract) and stamp each reading client-side with a local "as of" time, exactly as the repo's
  plan already does. Treat `is_available: false` as the alert condition; there is no server-side event to
  subscribe to.

## Contradictions

- **RPM/TPM vs concurrency vs dynamic limiting.** The Chinese error page says the 429 cause is
  "请求速率（TPM 或 RPM）达到上限" (<https://api-docs.deepseek.com/zh-cn/quick_start/error_codes>, accessed
  2026-09-26, quoted verbatim) while the English page says only "You are sending requests too quickly", and
  the rate-limit page documents *concurrency* only — while the FAQ says "我们没有按照用户设置硬性并发上限"
  (no hard per-user concurrency cap). Three official pages, three different framings. **Practical reading:**
  there is no published budget to compute against; the only safe strategy is modest, single-flight polling
  plus backoff. Recorded, not resolved.
- **Stale Chinese rate-limit page.** The zh-cn rate-limit page still lists `deepseek-v4-pro` /
  `deepseek-v4-flash` / `deepseek-v4-flash-vision-exp` at 500/2500/2500, while the English page now lists
  `deepseek-flash` / `deepseek-v4-pro` at 2500/500 (consistent with the 2026-09-10 changelog retiring
  V4-Flash names). Localisation drift, not a policy signal.
- **`x-ratelimit-*` headers: third-party says yes, primary sources say nothing, live probe says no**
  (finding 7). Unresolved; assume "no".
- **"No spend API" (OpenUsage, issue #654) vs. "spend API exists" (session-token console endpoints).**
  Both are right under their own auth model; the contradiction dissolves only if you accept that "API" means
  "API-key-authenticated API". Keep them separate.

## Missing evidence

- **Current raw headers of `/user/balance`.** Only the parent's probe (2026-09-26) is available; I could not
  reproduce it. No primary source documents conditional-GET support either way.
- **Whether the platform's low-balance e-mail/SMS alert is still offered today** (secondary sources only;
  the page is behind login and the FAQ does not cover it) and whether it has any API.
- **Whether `/user/balance` is subject to the dynamic limiter at all**, and what an abusive-looking poll
  rate actually triggers in practice (no incident report or official statement found).
- **Whether the undocumented `platform.deepseek.com/api/v0/usage/*` endpoints behave as described today**
  (I cannot test without a session token; both implementations are third-party and explicitly warn the
  private endpoints may change without notice).
- **`Retry-After` presence on 429.** Claimed by one third-party course page ("The DeepSeek API includes
  'retryafter' header in 429 responses", <https://theneuralbase.com/deepseek-api/learn/advanced/fallback-configuration/>,
  accessed 2026-09-26, low quality); undocumented officially; unverified.
- **Any official statement about automated polling of `/user/balance`** (fair-use, minimum interval, UA
  expectations). I found no such statement, in either language.

## Confidence, falsifiers, open questions

**Confidence: high** that no API-key-accessible server-side change-detection mechanism (webhook, SSE push,
ETag/conditional GET, usage/spend endpoint, balance-alert API) exists in DeepSeek's documented API as of
2026-09-26, and that polling with backoff is the only option. Medium on the two "partial" nuances
(undocumented console endpoints, human e-mail/SMS alert), both of which are secondary-sourced.

**What would falsify the main conclusion:**

1. An entry in `https://api-docs.deepseek.com/updates` (or a new page in the docs sitemap) announcing a
   usage/quota/webhook endpoint — the changelog is the canonical place and I read all of it.
2. A `/user/balance` response observed to carry `ETag`/`Last-Modified` (or answering `304` to
   `If-None-Match`), which would flip conditional GET from "dead code" to "correct design".
3. A DeepSeek reply on issue #654 (or a similar official-org thread) stating that a Bearer usage API is
   shipped or planned.
4. A primary source showing `x-ratelimit-*` (or any spend-bearing header) on an `api.deepseek.com` response
   reachable with an API key.

**Open questions I could not settle:** the real behaviour of the undocumented console usage endpoints today;
whether the platform low-balance alert still exists; what poll frequency, if any, triggers action against an
account; whether `/user/balance` is exempt from the dynamic limiter; and whether DeepSeek's official
"Harness" (dev preview, `github.com/deepseek-ai/deepseek-harness` / `deepseek-harness.github.io`) exposes
any account-state API a monitor could legitimately subscribe to (its Web-UI quickstart documents only model
configuration and sessions — no balance/usage surface was found, but I did not audit its plugin API).

## Sources

- **Kept — official:** <https://api-docs.deepseek.com/sitemap.xml>; <https://api-docs.deepseek.com/api/get-user-balance/>;
  <https://api-docs.deepseek.com/updates>; <https://api-docs.deepseek.com/quick_start/rate_limit/>;
  <https://api-docs.deepseek.com/quick_start/error_codes> (+ `/zh-cn/` variant); <https://api-docs.deepseek.com/api/list-models>;
  <https://api-docs.deepseek.com/quick_start/token_usage> (offline token counting only — no usage API);
  <https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html>. *Why:* the only
  authoritative statements about what exists and what the client is allowed to do.
- **Kept — official-adjacent / archived:** <https://web.archive.org/web/20241010193242/https://platform.deepseek.com/api-docs/zh-cn/faq/>
  (official FAQ, archived; live page returns 403). *Why:* the dynamic-limiter sentence is the single most
  relevant official statement for polling policy.
- **Kept — first-party-org issue thread:** <https://github.com/deepseek-ai/awesome-deepseek-integration/issues/654>.
  *Why:* documents both the gap and the 40003 behaviour of the console endpoints, from inside DeepSeek's own org.
- **Kept — third-party implementations (existence proof for private endpoints):**
  <https://github.com/Huasecc/dsh-usage>; <https://github.com/AzureHalcyon/dsh-deepseek-usage>.
  *Why:* two independent write-ups with the token mechanics and an explicit "private API, may change" warning.
- **Kept — third-party with operational detail:** <https://raw.githubusercontent.com/janekbaraniewski/openusage/main/docs/site/docs/providers/deepseek.md>
  (header claim + "no period-to-date spend" + ingestion delay). *Why:* the only source for the freshness
  claim; labelled low confidence.
- **Rejected/deprioritized:** <https://www.tpointtech.com/rate-limits-and-best-practices-with-deepseek>
  (claims an "HTTP 229" status — fabricated); <https://mydeepseekapi.com/...> and similar SEO farms
  ("RFC-6585-compliant RateLimit headers" with no evidence); various DSH/DSH-plugin marketplace pages that
  aggregate the same reworded text; <https://deepseekai.guide/...>, <https://ai-api-hub.com/...>,
  <https://chat-deep.ai/...> (AI-generated aggregators, no primary evidence); <https://deepseekv4pro.com/faq>
  (mixes DeepSeek with Volcengine "Coding Plans" — not DeepSeek API facts).

## Next steps (only the most useful)

1. Re-probe `GET /user/balance` with an API key and record the **raw** header set (including any
   `ETag`/`Last-Modified`/`x-ratelimit-*`) plus an `If-None-Match` round-trip — this is the only way to
   convert findings 2/7 from "absent by documentation" to "absent in fact".
2. Watch `https://api-docs.deepseek.com/updates` and issue #654 in the update-check path DeepTally already
   has (host `api.github.com` is already permitted); a single changelog line would invalidate the verdict.
3. If a "cheap but correct" upgrade is wanted regardless of the above, implement validator-aware caching
   (store ETag/Last-Modified, send `If-None-Match`, treat 304 as unchanged) — zero cost today, correct the
   day DeepSeek adds it.
