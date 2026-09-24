# Step 2 — M0 spikes

Evidence for the decisions that shape the install and packaging story. Every entry records what was
**observed**, not what is documented, plus the exact command or click sequence that produced it.

Status legend: ✅ observed · ⏳ waiting on a human · ⛔ not applicable yet

| # | Spike | Question | Status | Result |
|---|---|---|---|---|
| S1 | Gatekeeper flow | What exactly does macOS 27 show for a quarantined, ad-hoc-signed DMG, and does the exception survive an app update? | ⏳ | pending |
| S2 | App Translocation | Does launching from outside `/Applications` run the app from a random read-only path, and does our detection catch it? | ⏳ | pending |
| S3 | Login item under ad-hoc | Does `SMAppService.mainApp.register()` work for an ad-hoc-signed bundle, in `/Applications` and outside it? | ✅ | **Works.** From `dist/` (outside `/Applications`) `register()` returned status `enabled` immediately, with no approval prompt, and `unregister()` returned `notRegistered`. `SMAppService` is therefore the primary login-item path; a LaunchAgent fallback is only needed if a future macOS changes this. Observed 2026-09-24. |
| S4 | Notifications under ad-hoc | Does `UNUserNotificationCenter` authorization work for an ad-hoc-signed bundle, and what happens when denied? | ⏳ | pending |
| S5 | Keychain across a rebuild | Does an "Always Allow" Keychain item survive a rebuilt bundle (new cdhash, same bundle ID)? | ⏳ | Partial: store/read/delete all returned `errSecSuccess` with no prompt from the same binary. The cross-rebuild prompt behaviour needs one human click. |
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
- **A locally built DMG carries no quarantine.** `make dmg` produces a DMG that installs silently, so it
  cannot reproduce what a downloader sees. `make dmg SIMULATE=1` sets
  `com.apple.quarantine=0081;<hex-timestamp>;Safari;` on the DMG — the same shape Safari writes — which is
  what makes the Gatekeeper spike meaningful.

## Findings that already changed the design

- **S6** made the `curl` install path the primary recommendation in `INSTALL.md`: it sidesteps
  Gatekeeper entirely because it never sets the quarantine attribute.
- **S7** confirmed there is no historical usage API, which is why the ledger is local-first.
