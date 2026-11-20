# Weekly model scouting (`#71`)

Repo-agnostic operator guide for **proposal-only** checks that DeepInfra list prices and candidate models still match `.factory/models.yaml`. The scout **never** writes `models.yaml`; the **owner** approves and applies routing changes.

## Components

| Piece | Role |
| --- | --- |
| `scripts/factory-model-scout.py` | Compare configured DeepInfra models to a catalog; emit a proposal or stay quiet. |
| `.factory/skills/model-scouting.md` | Factory Manager skill: exit codes, weekly cadence, issue-opening rules. |
| `.factory/models.yaml` | Source of truth for prices and routing (edited only by the owner). |

## Commands

From the repository root (after `pip install -r requirements-factory.txt`):

**Live catalog (scheduled weekly):**

```bash
python3 scripts/factory-model-scout.py --fetch
```

**Offline / CI fixture:**

```bash
python3 scripts/factory-model-scout.py \
  --catalog tests/model-scout/catalog-example.json \
  --format json
```

Optional flags: `--models <path>`, `--format markdown|json` (default `markdown`), `--checked-at YYYY-MM-DD`.

## Exit behavior

| Exit | Meaning | Manager action |
| --- | --- | --- |
| `0` | No meaningful price drift or new value candidates | **Stay silent** — do not open an issue. |
| `2` | Proposal ready on stdout | Open **one** GitHub issue with the markdown body (title like `Proposed models.yaml update (YYYY-MM-DD)`). Reference the scouting epic in the body if your process uses one. Do not duplicate the same week. |
| `1` | Catalog or `models.yaml` unreadable | Fix infrastructure or YAML; **no** proposal issue. |

## What “meaningful” means

Aligned with `model-scouting.md` and issue `#71`:

- Price moves above **15%** on `price_in_per_mtok`, `price_cached_per_mtok`, or `price_out_per_mtok`.
- Better-value **coding** candidates only when quality is at least comparable (catalog `quality_tier` in fixtures; live fetch uses id/description heuristics).
- **Short promos** ignored (`promo: true` without `promo_long_lived: true`); prefer standard-tier list prices.
- When nothing qualifies, stderr may say `model-scout: no meaningful changes` and the process exits `0`.

## Owner approval workflow

1. Factory Manager (or scheduled automation) runs the scout.
2. On exit `2`, capture stdout to a file and open a single tracking issue with that body.
3. Owner reviews the proposed price table / candidate ids; if accepted, the owner edits `.factory/models.yaml` in a normal PR (human merge, `pr-check` green).
4. The scout does not commit, branch, or open auto-PRs for routing.

## Offline verification

```bash
bash scripts/test-factory-model-scout.sh
```

Fixtures under `tests/model-scout/` (`catalog-no-change.json`, `catalog-price-drop.json`, `catalog-example.json`, etc.).

## See also

- `.factory/MODEL_ROUTING.md` — how rules consume `models.yaml`.
- `scripts/factory-models-check.py` — schema validation after owner edits.
- `scripts/factory-routing-report.py` — post-change routing quality slices.