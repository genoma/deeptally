# Security policy

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on `genoma/deeptally`: open the repository's **Security**
tab, choose **Advisories**, then **Report a vulnerability**. That creates a private draft advisory only the
maintainer can see.

Please do not open a public issue for a vulnerability. There is no security email address.

Include: affected version, macOS version, what you observed, and a minimal reproduction. If the report
involves the API key or the opencode database, **do not attach the key, the database, or any real prompt or
completion text**.

## Supported versions

DeepTally is pre-1.0 and no version has been released yet. Until v0.1.0 ships, fixes land on `develop` and go
out with the next release; there are no backports. TODO (Step 7): replace this section with a version table
once v0.1.0 is published.

## Threat model

What is worth protecting:

- your DeepSeek API key (a single Keychain item);
- your usage ledger — token counters, timestamps, model names and estimated costs, with no prompt or
  completion content ([`docs/PRIVACY.md`](docs/PRIVACY.md));
- the integrity of the file you download and install.

What the design assumes:

- **Unsigned, not notarized.** The app is ad-hoc signed (`codesign --sign -`), not Developer ID signed and
  not notarized ([`docs/UNSIGNED.md`](docs/UNSIGNED.md)). The ad-hoc CDHash is content-derived, so it is not
  a statement about *who* built a binary. The SHA-256 checksums published with each release are the
  integrity anchor you can actually verify.
- **No sandbox.** The app is not sandboxed — App Store distribution is incompatible with GPL-3.0-or-later by
  design ([`docs/PLAN.md`](docs/PLAN.md) §1). It runs with your user privileges; there is no reason to ever
  run it as root.
- **Local attacker.** Anything already running as your user can attempt to reach the Keychain item; macOS
  prompts for consent (one prompt per app update — see [`docs/UNSIGNED.md`](docs/UNSIGNED.md)). Malware
  running as you is outside what DeepTally can defend against.
- **Network attacker.** All requests are HTTPS to the two hosts listed in [`docs/PRIVACY.md`](docs/PRIVACY.md).
  DeepTally does not pin certificates and does not install a custom CA.
- **MDM-managed Macs.** Management policy may refuse unsigned apps entirely. That is a deployment policy,
  not a vulnerability in DeepTally.
- **opencode database.** The import is read-only and limited to the `message` table; the
  `credential`/`cred_*` tables are never read.

Out of scope: vulnerabilities in macOS itself, in the DeepSeek API, in opencode, or in third-party tools you
point at the loopback proxy (v1.1).

## What this project will never do

- Store or transmit prompt or completion content — counters, timestamps, model names and status codes only.
- Upload telemetry or crash reports. There are no analytics or crash-reporting SDKs, and no third-party
  runtime dependencies at all ([`AGENTS.md`](AGENTS.md) §1).
- Call DeepSeek's private dashboard endpoints, or contact any host beyond the two documented.
- Read the opencode credential tables.
- Print, log or export the API key; diagnostics mask it as `sk-…1234`.
