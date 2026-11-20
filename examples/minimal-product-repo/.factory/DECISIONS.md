# Decision log

Append-only. Newest at the bottom.

## Template

```
### YYYY-MM-DD — Short title
- **Decision:** what we chose
- **Decided by:** owner (quote or link) / manager (sequencing or technical call)
- **Why:** one or two sentences
- **Alternatives:** what we rejected (optional)
- **Revisit when:** trigger to reconsider (optional)
```

## Log

### 2026-11-01 — Adopted factory as product repo
- **Decision:** Set `.factory/mode.yml` to `product` and pin thin workflow callers to a tagged template release instead of vendoring factory scripts.
- **Decided by:** owner (adoption bootstrap)
- **Why:** Keep product repos small; routing and harness logic stay on the pinned template tag.
- **Alternatives:** Copy the full template tree into the product repo on every upgrade.
- **Revisit when:** The pinned template tag changes or reusable workflow sync PRs land.

### 2026-11-02 — Default model catalog and spend caps
- **Decision:** Ship a minimal `models.yaml` with one DeepInfra default model and budget caps (`issue_cap_usd`, monthly limit) aligned with the template price table.
- **Decided by:** owner (initial config)
- **Why:** Run-start and cost predictors need a local catalog even when routing docs live on the template tag.
- **Revisit when:** This repo diverges from the template defaults or adds escalation models locally.