# Contributing

Portable sketch — copy to repo root as `CONTRIBUTING.md` and fill bracketed bits. Not legal advice.

## How this repo ships work

We use a lightweight **software factory** (see `.factory/FACTORY.md`):

1. Work is a **GitHub issue** (not a chat thread).
2. Hard work gets short product + technical specs; a human approves.
3. Changes land via **PR** with CI evidence.
4. Humans keep judgment gates (“is this useful?” / high-risk paths).

Agents (or humans) follow `.factory/skills/` — especially `factory-loop.md` and `liability-gates.md`.

## AI-assisted contributions

AI tools may draft code and docs. Requirements:

- Disclose AI use on the PR (tool + rough scope).
- Do not submit secrets or paste credentials.
- Do not change `LICENSE` / `NOTICE` without maintainer approval.
- You (or the maintaining human) remain accountable for what merges.

## Developer Certificate of Origin (DCO)

By contributing, you certify the [DCO](https://developercertificate.org/) and sign off commits:

```text
Signed-off-by: Your Name <you@example.com>
```

(`git commit -s`). Factory/agent commits should still receive a **human** sign-off or explicit maintainer approval on the PR before merge.

## High-risk paths (human review required)

Maintainer review is required for changes under (adapt in CODEOWNERS):

- `LICENSE`, `NOTICE`, `.factory/`
- `.github/workflows/`, CODEOWNERS, Dependabot config
- Auth, crypto, payments, PII, or safety-related code/docs

## Security reports

See `SECURITY.md`. Do not open public issues for undisclosed vulnerabilities.

## Questions

Open a GitHub issue. Chat with a project coordinator is intake only — they will file an issue.
