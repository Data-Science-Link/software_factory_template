# Security

## Reporting a vulnerability

**Do not** open a public GitHub issue for security problems.

- **Preferred:** [GitHub private vulnerability reporting](https://github.com/Data-Science-Link/software_factory_template/security/advisories/new) (when enabled on the repo).
- **Otherwise:** contact the repository owner through your existing private channel with the org.

Include steps to reproduce, impact, and any suggested fix. We aim to acknowledge reports within a few business days.

## Supported versions

Security fixes land on the default branch through the normal factory PR process (`pr-check`, `gitleaks`, and human review for normal/high risk).

## Factory baseline

See [`.factory/repo-security-baseline.md`](.factory/repo-security-baseline.md) for the full checklist (Dependabot, secret scanning, workflow hardening, and the one-time `scripts/harden-repo.sh` owner step).
