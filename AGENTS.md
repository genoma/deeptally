# AGENTS.md — operating contract for this repository

For AI agents and humans changing this repo. Intentionally boring and specific.
All machine facts below were **verified on the development machine on 2026-09-24** unless marked otherwise.

---

## 0. What this project is

**DeepTally** — a native, ARM-only macOS menu bar app (plus a small CLI) showing the DeepSeek account
balance and the peak/off-peak rate in force. **API-only by owner decision (2026-09-26):** DeepSeek exposes
no usage or spend endpoint, so usage history is not a feature of this product. GPL-3.0-or-later. Distributed
as an **ad-hoc signed** DMG from GitHub Releases (no Apple Developer Program, no notarization, no Homebrew
cask).

- App name: `DeepTally` · Bundle ID: `io.github.genoma.deeptally` · CLI: `deeptally` · Repo: `deeptally`
- **The plan of record is [`docs/PLAN.md`](docs/PLAN.md).** Work proceeds step by step; flip the
  checkboxes in the same commit that completes them and add a line to its progress log.

## 1. Hard constraints — do not violate

- **macOS 15.0 minimum** deployment target. **arm64 only.** No Intel, no universal binaries, no Rosetta.
- **Zero third-party runtime dependencies.** No SwiftData, no Sparkle, no analytics SDKs, no SPM packages
  without explicit approval. System frameworks only.
- **Network access to exactly two hosts:** `api.deepseek.com` and (update check only) `api.github.com`.
  No loopback listener, no proxy, no local capture.
- **No App Sandbox, no App Store, no Homebrew cask.** (Casks now require Gatekeeper-passing apps and
  `--no-quarantine` no longer exists — this is why there is no cask.)
- **No telemetry, no crash reporting.** The app never sees prompt or completion *content* — it makes no
  completion calls, and it persists only the balance, the settings and alert timestamps.
- **Xcode is NOT installed.** Never invoke `xcodebuild` or `actool`. Build with SwiftPM via the `Makefile`.
- The API key never enters the repo, a log, a crash report, a preference, or an export of any kind.
- No `try!`, no force-unwraps in `Sources/`, no `fatalError()` in shipped code paths.

## 2. Toolchain on the development machine (verified)

| Thing | State |
|---|---|
| macOS | 27.0 "Golden Gate", build 26A428, arm64 (Apple M5) |
| Swift | 6.4 (`swift-driver 1.168.6`), target `arm64-apple-macosx27.0.0` |
| Xcode | **absent**; only Command Line Tools at `/Library/Developer/CommandLineTools`, SDK 27.0 |
| `xcodebuild`, `actool` | **unavailable** — do not use |
| `iconutil`, `sips` | `/usr/bin/iconutil`, `/usr/bin/sips` — present, this is the `.icns` path |
| `notarytool`, `stapler` | present under CLT (unused: we do not notarize) |
| Signing identities | **none** (0 Developer ID, 0 Apple Development) → signing is always `--sign -` (ad-hoc) |
| Formatter | `swift format` (bundled). `swiftlint` / `swiftformat` / `xcodebuild` are NOT installed |
| Homebrew | 7.0.6, prefix `/opt/homebrew` |
| GitHub CLI | `gh` 2.101.0, authenticated as `genoma` with `repo` + `workflow` scopes |
| Git identity | `Alessandro Vioni <jenoma@gmail.com>` |

## 3. Environment: GNU utilities present (the important part)

`~/.zshrc` line 4 (and `~/.bashrc`) prepend Homebrew's `gnubin` directories, so **GNU** versions win in
both interactive shells. Verified: `sed` → gnu-sed, `awk` → gawk, `sort`/`head`/`date`/`stat` → coreutils.

| Available (Homebrew) | Version | Notes |
|---|---|---|
| bash | 5.3.20 | `/opt/homebrew/bin/bash`. **`/bin/bash` is still 3.2** — see rules below |
| coreutils | 9.12 | via `.../coreutils/libexec/gnubin` |
| gnu-sed | 4.10 | `sed` on PATH is GNU |
| gawk | 5.4.1 | `awk` on PATH is GNU (with MPFR) |
| gettext | 1.0 | |
| git | 2.55.0 | |
| gh | 2.101.0 | |
| ripgrep | 15.2.0 | prefer `rg` over `grep` |
| jq | **Apple's 1.7.1 at `/usr/bin/jq`** | not installed via brew; do not assume a newer jq |
| node / python3 / go | 24.x era / 3.14 / present | not part of the build path |

### Still BSD — scripts must assume these

`find` (BSD) · `tar` (bsdtar 3.5.3) · `make` (GNU Make **3.81**) · `grep` (BSD 2.6.0-FreeBSD) · `diff` (Apple)

### Not installed (do not reference)

`findutils` · `diffutils` · `gnu-tar` · `gnu-time` · GNU `grep` · `wget` · `cmake` · `rust`/`cargo` ·
`shellcheck` · `swiftlint` · `swiftformat` · `xcbeautify` · `create-dmg`

### Shell-scripting rules derived from the above

1. Shebang `#!/usr/bin/env bash` and keep scripts **bash 3.2 compatible** (macOS `/bin/bash`), or shebang
   `/opt/homebrew/bin/bash` explicitly — never assume 5.x features by accident.
2. No `find -printf`, no `readlink -f`, no GNU-only `tar --transform`, no `grep -P` / `--include` chains.
3. Prefer `rg`, `sed`, `awk`; if GNU behaviour is required, say so in a comment and fail loudly rather than
   silently degrading.
4. `make` is 3.81: no `.ONESHELL`, no `$(file ...)`, no secondary expansion tricks.
5. Every script must be `set -euo pipefail` and must not print secrets (see §5).

## 4. Build & test commands

```sh
make build        # swift build -c release --arch arm64 (app + CLI)
make test         # swift test
make lint         # swift format --lint
make bundle       # assemble dist/DeepTally.app (ad-hoc signed)
make run          # launch the bundled app
make dmg          # dist/DeepTally-<version>.dmg via hdiutil
make verify       # build + test + lint + codesign --verify + bundle launch smoke test
make clean
```

The release targets `install`, `uninstall`, `release-assets` and `release-check` exist; their policy is in
`docs/PLAN.md` §8 and `docs/RELEASING.md`.

## 5. Secrets policy

- The API key is `DEEPSEEK_API_KEY`, exported from the developer's shell rc files; the **app** obtains it
  through the Keychain import flow, never by reading rc files at runtime.
- **Never** print, echo, commit, log, or include a key in an error message. Mask as `sk-…1234`.
- `launchctl setenv` is forbidden — it leaks the secret into every GUI process's environment.
- `.env`, `*.pem`, `secrets/` are git-ignored. If a secret is ever committed, stop and report it.

## 6. Data sources and paths

| Source | Path / endpoint | Rules |
|---|---|---|
| DeepSeek balance | `GET https://api.deepseek.com/user/balance` (Bearer) | string amounts, `balance_infos[]`, no timestamp — display "as of" |
| DeepSeek models | `GET https://api.deepseek.com/models` | `deepseek-flash`, `deepseek-v4-pro`; the client implements it, nothing calls it on its own |
| Prices | `Sources/DeepTallyCore/Resources/PriceTable.json` | versioned data, not code; user-overridable via `~/.config/deeptally/PriceTable.json` |
| Holidays | `Sources/DeepTallyCore/Resources/ChinaHolidays.json` | official 2026 Chinese State Council dates; data, not code |
| API key | Keychain, service `io.github.genoma.deeptally`, account `api-key`; `DEEPSEEK_API_KEY` as fallback | never written anywhere else |
| Preferences | `~/Library/Preferences/io.github.genoma.deeptally.plist` | settings, last balance reading, last alert time; the app writes no usage data |

An older version kept a usage ledger at `~/Library/Application Support/DeepTally/ledger.sqlite`. The current
app never reads or writes that directory; the uninstaller removes it whole (see `docs/PRIVACY.md`).

## 7. Git flow and versioning

- `main` = released code only. `develop` = integration (GitHub default branch).
- Branches: `feature/*` off `develop`, `release/x.y.z` off `develop`, `hotfix/*` off `main`.
- Merge via `--no-ff`; tag releases `vX.Y.Z` on `main`.
- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, `ci:`).
- **SemVer**: `0.y.z` until first stable; breaking changes bump MINOR while pre-1.0.
- `CHANGELOG.md` (Keep a Changelog) is updated when a `release/*` branch is cut.
- Every source file carries `// SPDX-License-Identifier: GPL-3.0-or-later`.

## 8. Code conventions

- Swift 6 language mode, strict concurrency. UI on `@MainActor`; I/O in actors.
- `NSStatusItem` + `NSPopover` hosting SwiftUI — **not** `MenuBarExtra`-only (macOS 26 bug: the process
  exits silently when the user disables the item in Control Center → Menu Bar).
- Money is `Decimal` and comes from data: prices load from `Resources/PriceTable.json`, never from Swift.
- Errors: typed `enum` errors, user-facing strings separate from diagnostics.
- Tests never touch the network and never read the real Keychain from a state they cannot restore — inject
  clients and document the seams they use.

## 9. Known gotchas

1. `MenuBarExtra`-only accessory apps can be killed by a Control Center setting — hence `NSStatusItem`.
2. `/bin/bash` is 3.2 while brew `bash` is 5.3 — scripts silently break on macOS defaults.
3. No `actool` → commit a prebuilt `Resources/AppIcon.icns` built with `iconutil`; no `.xcassets`.
4. Ad-hoc identity is content-derived: a rebuilt bundle has a new code hash, so (a) a Gatekeeper exception
   does **not** carry over to the next build — each browser-downloaded update needs Open Anyway again
   (verified: `Killed: 9` after the previous build had been approved), and (b) Keychain is unaffected — an item
   written by one build reads back silently in the next (verified), because the default item ACL is permissive.
5. Quarantine is the Gatekeeper gate: browser downloads are blocked, `curl` downloads are not.
6. App Translocation: launching a quarantined app from outside `/Applications` runs it from a random
   read-only path and breaks login items/Keychain. Always move it first; detect and warn in-app.
7. macOS 27 hides menu-item symbol images by default in `NSMenu`; use `labelStyle(.titleOnly)` / set
   `preferredImageVisibility` explicitly.
8. Peak/off-peak *classification* is computed in UTC against `Resources/ChinaHolidays.json`, but always
   *displayed* in the user's local timezone, with the next transition and a countdown. Never show a
   window label that was derived from local-time arithmetic.
9. **SwiftPM target names must differ by more than letter case, and so must their directories** —
   APFS is case-insensitive, so `DeepTally` and `deeptally` map to the same `.build` products *and* the
   same `Sources/` directory (the second target's files silently overwrite the first's). Hence:
   app target/dir `DeepTallyApp`, CLI target `deeptally` with explicit `path: Sources/DeepTallyCLI`,
   and the shipped bundle is still `DeepTally.app`.
10. DeepSeek pricing is volatile (model retirements and renames happened three times in 2026) — never
    hardcode model IDs or prices in Swift; load them from the versioned table.
11. `UserDefaults(suiteName:)` leaves a 42-byte empty plist in `~/Library/Preferences` for every domain a
    process has seen, and deleting the file does not help — `cfprefsd` writes it back. Test suites must use
    **one stable domain** (see `Tests/DeepTallyCoreTests/SettingsTests.swift`) rather than a UUID per test,
    or a run leaves residue that accumulates forever. That suite is marked `.serialized` so a single shared
    domain is safe.
12. **Never write `#Preview` in this repo.** It expands via the `PreviewsMacros` plugin, which ships with
    Xcode; Command Line Tools has no copy of it, so `swift build` fails with "external macro implementation
    type 'PreviewsMacros.SwiftUIView' could not be found". Use `PreviewProvider` structs instead — they still
    render in Xcode's canvas. Do not "fix" this with `#if canImport(PreviewsMacros)`: `canImport` resolves
    importable modules, not macro plugin dylibs, so that condition is false on every toolchain and would just
    hide dead code.

## 10. Definition of done

A step is done only when: it builds (`make build`), tests pass (`make test`), lint passes
(`make lint`), the step's acceptance gate in `docs/PLAN.md` is satisfied, the checkboxes are flipped,
and the progress log has a dated line. Commit with a Conventional Commit message referencing the step.
