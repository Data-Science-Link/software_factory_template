# Skill: critic-review

Lightweight adversarial review for the independent reviewer in **#41**. No multi-agent swarm: one builder, one Critic with the harness test log, then `/oc fix` if needed.

## Artifacts (this issue, #121)

| Piece | Path |
| --- | --- |
| Critic system prompt (load from **main**) | `.factory/prompts/critic-review.md` |
| Input bundle builder | `scripts/factory-critic-context.py` |
| Offline tests | `scripts/test-factory-critic-context.sh` |

## How the review job should use them (#41, future workflow)

1. After the builder job finishes, on a **fresh read-only runner**, run `factory-critic-context.py` with the builder artifact dir (`changes.patch`, `spec.md`, `evidence.md`) and the PR number.
2. Send `critic-input.md` (prompt + context) to a **different** model than the builder, with no write token.
3. Post the model's reply as a PR comment. If the verdict is `needs fixes`, the owner or manager triggers `/oc fix` with the numbered findings (same shape as `review-local-pr.md` fix items).

## Local / offline check

```bash
bash scripts/test-factory-critic-context.sh
```

Fixtures live under `tests/critic-context/`.