# Development

Everything needed to build, test and change DeepTally. [`../AGENTS.md`](../AGENTS.md) is the operating
contract; [`PLAN.md`](PLAN.md) is the step-by-step plan of record.

## Prerequisites

| Requirement | Check |
|---|---|
| macOS 15.0 or later, Apple silicon | `sw_vers`, `uname -m` |
| Xcode **Command Line Tools** | `xcode-select -p` → `/Library/Developer/CommandLineTools` |
| Swift 6.4 or later | `swift --version` |
| Xcode | **not required and not used** — no `xcodebuild`, no `actool` |

The project has **zero third-party dependencies** and no sandbox; it links system frameworks plus
`libsqlite3` only. Don't add a package without a decision recorded in [`PLAN.md`](PLAN.md).

## Make targets

```sh
make help        # list the targets
make build       # release build, arm64 (app + CLI)
make test        # swift test
make lint        # swift format lint --recursive Sources Tests
make bundle      # assemble dist/DeepTally.app and ad-hoc sign it
make run         # bundle and launch the app
make dmg         # build dist/DeepTally-<version>.dmg (SIMULATE=1 fakes a browser download)
make kill        # stop a running DeepTally instance
make smoke       # launch the bundled app and fail if it does not stay alive
make screenshots # render the real popover to dist/popover*.png
make verify      # build + test + lint + bundle + codesign --verify
make clean       # remove .build and dist
```

`make verify` is the gate a PR has to pass. Still planned in Step 6, and therefore not in the
[`../Makefile`](../Makefile) yet: `make install`, `make uninstall` and `make release-check`.

## Visual checks

Two targets exist because a UI change is not reviewable from a passing test.

**`make smoke`** bundles, kills any previous instance, launches the app and fails if the process is not alive
four seconds later — then kills it again. It deliberately launches **without** a key, so it also covers "a
missing key must not stop the app from starting".

**`make screenshots`** renders the shipping views to `dist/popover.png`, `dist/popover-dark.png` and
`dist/popover-settings.png` (the committed copies live in `docs/assets/`). Those come from the same binary,
through the **real** composition root and the real key precedence:

```sh
make bundle
dist/DeepTally.app/Contents/MacOS/DeepTally --spike render-popover dist/popover [height]
```

The optional `height` defaults to 420 pt, the real popover size; pass a taller value to capture the part of
the body that scrolls. The command waits for a settled state before drawing, because a persisted reading
would otherwise bake a permanent *"Refreshing…"* into the screenshot. It needs a key (Keychain or
`DEEPSEEK_API_KEY`) to show an amount — which makes a successful run a live check that the Keychain import
works.

Two traps, both learned the hard way (2026-09-24):

1. **Offscreen hosting has no window**, so it has no appearance and no material behind it. Without an
   explicit `.environment(\.colorScheme, …)` **and** an explicit background, the render resolves
   dark-on-nothing — white text on white. Every `writePNG` caller in `Spikes.swift` sets both.
2. **Never write `#Preview`** in this repo. The macro expands through the `PreviewsMacros` plugin, which ships
   with Xcode; with Command Line Tools the build fails with *"external macro implementation type
   'PreviewsMacros.SwiftUIView' could not be found"* ([`../AGENTS.md`](../AGENTS.md) §9.13). Use a
   `PreviewProvider` struct instead — it still renders in Xcode's canvas. `@State` (a `SwiftUIMacros` macro)
   is unavailable to a CLT build for the same reason, which is why the previews use constant bindings.

The other `--spike` commands (`identity`, `keychain-store`, `login-item-register`, `notifications`, …) are the
Step 2 measurement tools. Protocol, commands and recorded output: [`SPIKES.md`](SPIKES.md). They exit before
any UI exists and are not part of the shipped app path.

## Tests

Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest. Run them with
`make test` or `swift test`. They must never touch the network and never open your real opencode database —
inject clients, use fixture databases.

Two platform traps are already handled in the build, but you will meet them the moment you touch
`Package.swift` or add a target:

1. **APFS is case-insensitive.** Two SwiftPM target names (or source directories) that differ only by case
   collide: their products overwrite each other in `.build`, and a second target without an explicit `path`
   reuses the same directory. `DeepTally` and `deeptally` collided exactly this way. Hence the app target
   `DeepTallyApp`, and the CLI target `deeptally` with `path: Sources/DeepTallyCLI`. Never add targets or
   directories that differ only in case.
2. **The Command Line Tools put swift-testing's macro plugin where the compiler does not look by
default.** CLT has it under `usr/lib/swift/host/plugins/testing/`, which the compiler driver does not
search by default (Xcode installs it under `plugins/`). The test target passes
   `-plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`; without it, the
   `@Test`/`@Suite` macros fail to expand. The extra path is harmless on machines where it does not exist.

## Style

- `make lint` must pass. The config is [`../.swift-format`](../.swift-format): 2-space indent, 100-column
  lines, ordered imports, no semicolons, one case per line. To apply the formatter:
  `swift format --in-place --recursive Sources Tests`.
- Every source file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- No `try!`, no force unwraps in `Sources/`, no `fatalError()` in shipped code paths. Use typed `enum`
  errors; keep user-facing strings separate from diagnostics.
- UI runs on `@MainActor`; I/O lives in actors. Strict concurrency is on (Swift 6 language mode).
- SQLite: WAL journal, `synchronous=NORMAL`, one connection, prepared statements, `raw_hash` unique for
  dedupe.
- Never print, log or commit secrets. The API key is masked as `sk-…1234` in any diagnostic; `launchctl
  setenv` is forbidden.
- Money is a JSON **string** everywhere (`Decimal.parse`), and every monetary value comes from data, never
  from Swift: prices and model IDs load from `Resources/PriceTable.json` ([`../AGENTS.md`](../AGENTS.md)
  §9.11).

## Branches, commits, versions

Git flow ([`../AGENTS.md`](../AGENTS.md) §7):

- `main` = released code only; `develop` = integration (the GitHub default branch, and the base for PRs).
- `feature/*` branches from `develop`; `release/x.y.z` from `develop`; `hotfix/*` from `main`.
- Merge with `--no-ff`; tag releases `vX.Y.Z` on `main`.

Commits are **Conventional Commits** (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, `ci:`), with a
body that explains *why* when it is not obvious. They drive the CHANGELOG.

Versioning is **SemVer**, `0.y.z` until the first stable release; while pre-1.0 a breaking change bumps the
MINOR version. The CHANGELOG ([`../CHANGELOG.md`](../CHANGELOG.md), Keep a Changelog) is frozen when a
`release/*` branch is cut — see [`RELEASING.md`](RELEASING.md).

## Where things live

- [`USAGE.md`](USAGE.md) — the user's page: key import, the CLI, the popover and settings.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — targets, composition root, data flow, ledger schema, rate-now math.
- [`PRIVACY.md`](PRIVACY.md) — hosts, stored data, deletion.
- [`INSTALL.md`](INSTALL.md) / [`UNSIGNED.md`](UNSIGNED.md) — install paths and the signing trade-offs.
- [`../SECURITY.md`](../SECURITY.md) — reporting and threat model.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — PR expectations.
