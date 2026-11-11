# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/Data-Science-Link/software_factory_template/security/advisories/new)
for this repository. Do not open a public issue, pull request, or discussion for a suspected vulnerability.

Helpful details:

- what is affected (file, workflow, or script) and on which commit or tag
- steps to reproduce, or a proof of concept
- what an attacker could do with it

You should get an acknowledgement within 7 days. Fixes land on `main` and are noted in [CHANGELOG.md](CHANGELOG.md).

## Scope

In scope:

- the GitHub Actions workflows, scripts, and harness in this repository
- ways an outside account could start a paid model run, read a secret, or write to the repository

Out of scope:

- vulnerabilities in third-party tools this template calls (OpenCode, DeepInfra, GitHub Actions itself); report those upstream
- product repositories that copied or adopted this template; report to their owners

## Supported versions

Only the latest `main` is supported until the first tagged release. After that, the latest tag is supported.

## If you find a leaked secret

Report it the same private way. Do not post or test the value.
