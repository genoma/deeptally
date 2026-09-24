# Releasing

The release policy lives in [`PLAN.md`](PLAN.md) §8; the machinery is built in Step 6 and first used in
Step 7 (v0.1.0). Commands marked **planned** do not exist in the repository yet — they are frozen together
with the step named next to them.

## Preconditions

- `develop` is green: `make verify`.
- Every checkbox of the current plan step is flipped, and that step's gate passed.
- `gh` is authenticated (`gh auth status`) and the version number is decided per SemVer — `0.y.z` until
  the first stable release; a breaking change bumps MINOR while pre-1.0.
- Signing is unchanged and deliberate: **ad-hoc, not notarized** ([`PLAN.md`](PLAN.md) §1).

## 1. Cut the release branch

```sh
git switch -c release/X.Y.Z develop
```

## 2. Freeze the CHANGELOG

Move the `[Unreleased]` entries in [`../CHANGELOG.md`](../CHANGELOG.md) under a new `[X.Y.Z] - YYYY-MM-DD`
heading, keeping the Keep a Changelog grouping (Added / Changed / Fixed / …). Then commit:

```sh
git commit -m "chore(release): freeze CHANGELOG for X.Y.Z"
```

## 3. Run the gate

```sh
make verify
```

Planned (Step 6): `make release-check` adds the release-specific checks (DMG, checksums, bundle contents).

## 4. Build the DMG

Planned (Step 6): `make dmg` → `dist/DeepTally-X.Y.Z.dmg`, via `Scripts/dmg.sh` and `hdiutil`
([`../AGENTS.md`](../AGENTS.md) §4 documents the target; `Scripts/dmg.sh` is the Step 6 deliverable).

## 5. Generate checksums

Every release publishes `SHA256SUMS` beside the DMG ([`PLAN.md`](PLAN.md) §8). Planned (Step 6): the release
workflow generates it. The local equivalent is:

```sh
shasum -a 256 dist/DeepTally-X.Y.Z.dmg > SHA256SUMS
```

## 6. Merge to main

```sh
git switch main
git merge --no-ff release/X.Y.Z
```

Merge the release branch back into `develop` as well if it carries commits `develop` does not have yet
(the CHANGELOG freeze is one).

## 7. Tag

```sh
git tag -a vX.Y.Z -m "DeepTally vX.Y.Z"
```

Tags live on `main`. Push the branch and the tag.

## 8. Publish

Planned (Step 6): `.github/workflows/release.yml` — tag → DMG + `SHA256SUMS` + GitHub Release. The manual
equivalent, with release notes taken from the frozen CHANGELOG entry:

```sh
gh release create vX.Y.Z dist/DeepTally-X.Y.Z.dmg SHA256SUMS
```

Then enable **Immutable Releases** on the repository ([`PLAN.md`](PLAN.md) §8) so a published tag and its
artifacts cannot be replaced. TODO (Step 6): record the exact repository setting and confirm it in the
release checklist.

## 9. Update the tap formula

The CLI ships as a Homebrew **formula** (`deeptally`) in the personal tap — never a cask, because casks now
require Gatekeeper-passing apps ([`PLAN.md`](PLAN.md) §9, [`../AGENTS.md`](../AGENTS.md) §1). Bump the
formula's version and SHA-256 to the new tag. TODO (Step 6): tap location and formula name.

## 10. Smoke-test on a clean machine

Step 7's gate: install on a fresh macOS 15+, 26 or 27 machine using only the published instructions in
[`INSTALL.md`](INSTALL.md), then confirm the app launches, the status item appears, and the CLI runs. Also
verify `SHA256SUMS` as described in [`UNSIGNED.md`](UNSIGNED.md).

## Hotfixes

`hotfix/*` branches from `main`, gets the smallest possible fix, and is merged `--no-ff` into both `main`
and `develop`. Tag a patch version and republish the DMG; never re-upload artifacts for an existing tag.
