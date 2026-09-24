# Contributing

Short version: small PRs against `develop`, Conventional Commit titles, tests for behaviour changes,
`make verify` before you push, GPL-3.0-or-later in, GPL-3.0-or-later out.

## Workflow

1. Branch from `develop` (`feature/…`, `fix/…`, `docs/…`).
2. Make one coherent change; keep unrelated cleanups out of the PR.
3. Add or update tests for behaviour changes — `make test`.
4. Run `make verify` (build + test + lint + bundle + signature check). This is the gate CI will run
   (`.github/workflows/ci.yml`, Step 6).
5. Open the PR against `develop` and reference the plan step it completes.

`main` is released code only; `hotfix/*` is the only branch taken from it ([`AGENTS.md`](AGENTS.md) §7).

## Commits

Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, `ci:`. The subject says what
changed; the body explains why when that is not obvious. Merge with `--no-ff`.

## Style

- `make lint` must pass. Config: [`.swift-format`](.swift-format) — 2-space indent, 100-column lines, ordered
  imports. Apply with `swift format --in-place --recursive Sources Tests`.
- Every source file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- No `try!`, no force unwraps in `Sources/`, no `fatalError()` in shipped paths. Typed errors; user-facing
  strings separate from diagnostics.
- Tests never touch the network and never open the real opencode database — inject clients, use fixture
  databases.
- Zero third-party runtime dependencies. Propose a package before adding one; the default answer is no.

## Docs

Claims in `README.md`, `AGENTS.md` and `docs/` must be traceable to the verified evidence in
[`docs/PLAN.md`](docs/PLAN.md) §3 or to a recorded spike. If a claim cannot be traced, mark it as a TODO
naming the step that will resolve it instead of guessing.

## License

DeepTally is GPL-3.0-or-later ([`LICENSE`](LICENSE)). By contributing you license your work under the same
terms — inbound equals outbound. There is no CLA and no copyright assignment.
