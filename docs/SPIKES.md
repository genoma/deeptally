# Step 2 — M0 spikes

Evidence for the decisions that shape the install and packaging story. Every entry records what was
**observed**, not what is documented, plus the exact command or click sequence that produced it.

Status legend: ✅ observed · ⏳ waiting on a human · ⛔ not applicable yet

| # | Spike | Question | Status | Result |
|---|---|---|---|---|
| S1 | Gatekeeper flow | What exactly does macOS 27 show for a quarantined, ad-hoc-signed DMG, and does the exception survive an app update? | ✅ | Quarantined copy: **killed by the kernel** (`Killed: 9`, exit 137) until approved; the same build without quarantine runs normally. After approval it ran from `/Applications` (log: `quarantined=true translocated=false hasEnvAPIKey=false`). A `0181` flag does **not** mean approved (disproved). **The exception is per-build:** the next build with a different code hash was killed again, so every browser-downloaded update costs a new approval. Dialog screenshots still pending. |
| S2 | App Translocation | Does launching from outside `/Applications` run the app from a random read-only path, and does our detection catch it? | ✅ | **Confirmed by two real launches.** A quarantined copy launched from outside `/Applications` ran from `/private/var/folders/…/T/AppTranslocation/<UUID>/d/DeepTally.app` (2026-09-24 20:30:16Z and 20:32:17Z, `quarantined=true translocated=true`), while the `/Applications` copy ran untranslocated. Consequence: a translocated copy must never register a login item (it would point at a read-only temporary path) — the app has to detect this and tell the user to move it. |
| S3 | Login item under ad-hoc | Does `SMAppService.mainApp.register()` work for an ad-hoc-signed bundle, in `/Applications` and outside it? | ✅ | **Works.** From `dist/` (outside `/Applications`) `register()` returned status `enabled` immediately, with no approval prompt, and `unregister()` returned `notRegistered`. `SMAppService` is therefore the primary login-item path; a LaunchAgent fallback is only needed if a future macOS changes this. Observed 2026-09-24. |
| S4 | Notifications under ad-hoc | Does `UNUserNotificationCenter` authorization work for an ad-hoc-signed bundle, and what happens when denied? | ✅ | **Works.** `--spike notifications` from the ad-hoc bundle raised the system prompt and returned `{"granted":true}` (observed 2026-09-24). Denial is still untested; the app degrades to a menu-bar badge, so a denial is not fatal. |
| S5 | Keychain across a rebuild | Does an "Always Allow" Keychain item survive a rebuilt bundle (new cdhash, same bundle ID)? | ✅ | **No prompt, no friction.** Build 1 (`cdhash a7759218…`) created the item; build 2 (`cdhash 1370f937…`) read it back silently (`errSecSuccess`, value returned). `SecItemAdd` without an explicit ACL creates a permissive item, so ad-hoc updates do not break Keychain access. Trade-off documented in `UNSIGNED.md`: any process running as the user can read it without a dialog. |
| S6 | `curl` vs quarantine | Does a `curl`-downloaded file carry `com.apple.quarantine`? | ✅ | Only `com.apple.provenance` is set; no quarantine, so no Gatekeeper dialog. Verified 2026-09-24. |
| S7 | Live DeepSeek API | Which models exist, what does the balance response look like, which usage fields come back? | ✅ | `deepseek-flash` and `deepseek-v4-pro`; balance amounts are strings with no timestamp; usage carries `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` plus nested reasoning tokens. Verified 2026-09-24. |

## How to run the spikes

```sh
# automated: prints one JSON line each
make bundle
dist/DeepTally.app/Contents/MacOS/DeepTally --spike identity
dist/DeepTally.app/Contents/MacOS/DeepTally --spike login-item-register
dist/DeepTally.app/Contents/MacOS/DeepTally --spike login-item-status
dist/DeepTally.app/Contents/MacOS/DeepTally --spike keychain-store
dist/DeepTally.app/Contents/MacOS/DeepTally --spike keychain-read

# human-assisted: S1/S2 need a Gatekeeper dialog, S4 needs one Allow click
make dmg SIMULATE=1     # quarantines the DMG the way a browser download would
touch "$HOME/Library/Application Support/DeepTally/spike-enabled"   # enables the launch log
```

The launch log records bundle path, translocation, quarantine state and whether the GUI process
inherited `DEEPSEEK_API_KEY`, one line per launch, in
`~/Library/Application Support/DeepTally/launch.log`. It only writes while that `spike-enabled`
marker file exists — the shipped app never creates it.

## Additional findings

- **Shell environment does not reach a GUI launch.** `env -i /usr/bin/open dist/DeepTally.app` recorded
  `hasEnvAPIKey=false`, while launching the same binary from a terminal that exports `DEEPSEEK_API_KEY`
  recorded `true`. This is measured evidence for the Keychain-first design: the app cannot rely on
  `~/.zshrc` and must import the key once, then read it from the Keychain.
- **App Translocation is not hypothetical.** Two real launches ran from a temporary read-only path, so the
  in-app warning that `INSTALL.md` and the plan promised is a requirement, not polish: a login item or a
  settings write from a translocated copy would silently behave as if the app had amnesia.
- **Gatekeeper exceptions are per-build, so updates are the real friction — not the first install.**
  Approving one build does not approve the next (measured). This makes the `curl` install path more than a
  convenience: a script-installed update is never quarantined, so it never needs a System Settings trip.
- **A locally built DMG carries no quarantine.** `make dmg` produces a DMG that installs silently, so it
  cannot reproduce what a downloader sees. `make dmg SIMULATE=1` sets
  `com.apple.quarantine=0081;<hex-timestamp>;Safari;` on the DMG — the same shape Safari writes — which is
  what makes the Gatekeeper spike meaningful.

- **A quarantined bundle is killed, not merely warned about.** Direct execution of the quarantined
  `/Applications/DeepTally.app` binary returned exit 137 (`Killed: 9`); the identical build in `dist/`,
  with no quarantine attribute, ran normally. Nothing about this depends on the ad-hoc signature.
- **The `0x0100` bit in the quarantine value is not an approval marker.** A copy showing
  `0181;…;Safari;` was still blocked, so the flag cannot be used to detect "already approved".

## Findings that already changed the design

- **S6** made the `curl` install path the primary recommendation in `INSTALL.md`: it sidesteps
  Gatekeeper entirely because it never sets the quarantine attribute.
- **S7** confirmed there is no historical usage API, which is why the ledger is local-first.
