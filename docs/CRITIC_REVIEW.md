# Independent Critic Review (`#41`)

Repo-agnostic operator guide for the **Independent Critic** loop: a read-only second model reviews each `/oc` build (or fix) artifact before publish merges opinion into the PR thread.

## What runs where

| Piece | Role |
| --- | --- |
| `scripts/factory-critic-context.py` | Builds `critic-context.md`, `critic-meta.txt`, and `critic-input.md` from the builder artifact dir (`changes.patch`, `spec.md`, `evidence.md`) and optional live `--repo` / `--pr`. |
| `.factory/prompts/critic-review.md` | Adversarial system prompt (load from **default branch**, never from the PR head). |
| `scripts/factory-critic-run.py` | Picks a **different** DeepInfra model than the coder, calls the chat API (or offline stub), writes `critic-review.md` + `critic-run-record.json`. |
| `docs/OWNER_WORKFLOW_SYNC.md` §5 | Owner paste for the GitHub Actions **`review`** job (fresh runner, read-only tokens). |

Security boundary summary: [`.factory/actions-security.md`](../.factory/actions-security.md) (Independent Critic section).

## CI flow (when wired)

1. **`agent`** finishes and uploads artifacts (`changes.patch`, `spec.md`, `evidence.md`).
2. **`review`** job on a **new** `ubuntu-latest` runner: `contents: read` only; checkout **default branch** for scripts + prompt; download builder artifacts; run the two Python scripts.
3. **`publish`** posts `critic-review.md` to the PR (write token stays in publish only).

The review job must **not** reuse the agent runner or carry a write `GITHUB_TOKEN` into the model step.

## Local / offline testing

Factory Python deps: `pip install -r requirements-factory.txt`

**Bundle only (no API spend):**

```bash
python3 scripts/factory-critic-context.py \
  --from-json tests/critic-context/pass.json \
  --out-dir /tmp/critic-out

# Optional live-style paths instead of --from-json:
# --artifact-dir /path/to/oc-artifacts --out-dir /tmp/critic-out
```

**Reviewer model selection (no API spend):**

```bash
python3 scripts/factory-critic-run.py --print-model \
  --coder-model <builder-model-id> \
  --input /tmp/critic-out/critic-input.md
```

**Full dry-run record (`work_type: review`, zero usage):**

```bash
python3 scripts/factory-critic-run.py --dry-run \
  --input /tmp/critic-out/critic-input.md \
  --meta /tmp/critic-out/critic-meta.txt \
  --out-dir /tmp/critic-run \
  --coder-model <builder-model-id>
```

**Fixture API response (offline integration):**

```bash
python3 scripts/factory-critic-run.py \
  --input /tmp/critic-out/critic-input.md \
  --meta /tmp/critic-out/critic-meta.txt \
  --out-dir /tmp/critic-run \
  --fixture-response tests/critic-run/chat-completion-ok.json \
  --coder-model <builder-model-id>
```

**Harness tests:**

```bash
bash scripts/test-factory-critic-context.sh
bash scripts/test-factory-critic-run.sh
```

Fixtures: `tests/critic-context/`, `tests/critic-run/`.

## Cost tracking

- `critic-run-record.json` uses `work_type: review`, real token fields when live, and `cost_method: usage_x_price_table` priced from `.factory/models.yaml`.
- Review dollars add to the same **per-issue** spend ceiling as build and fix runs (`issue_cap_usd` in `factory/budget.yml` / `models.yaml` budget block).
- Validate records offline: `python3 scripts/factory-validate-run.py /path/to/critic-run-record.json`.

## Operator checklist

1. Confirm the workflow paste in `docs/OWNER_WORKFLOW_SYNC.md` is on the default branch.
2. After a build, read the **Factory Critic review** comment: `Verdict`, harness verification line, numbered findings.
3. If `needs fixes`, route numbered items to `/oc fix` (same shape as `Factory review` fix lists in `.factory/skills/review-local-pr.md`).
4. The Factory Manager still posts an independent **`Factory review`** before merge; the Critic does not replace human or manager judgment.

## See also

- `.factory/skills/critic-review.md` — skill card for agents.
- `factory/runs/README.md` — run JSON schema (`work_type: review`, optional `steps[]`).