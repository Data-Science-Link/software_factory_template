# Skill: model-scouting

Weekly **proposal-only** check that DeepInfra list prices still match `.factory/models.yaml`. Nothing in this skill edits `models.yaml`; Michael approves any routing change.

## When to run

- After factory routing is in use on Actions (#29+) and coding quality from routed models looks sane.
- On a quiet weekly schedule (Grok Bot or owner cron). **Stay silent** when the scout finds nothing meaningful.

## Command

From the repo root, with factory Python deps installed (`pip install -r requirements-factory.txt`):

```bash
python3 scripts/factory-model-scout.py --fetch
```

Offline / CI uses a committed catalog fixture:

```bash
python3 scripts/factory-model-scout.py --catalog tests/model-scout/catalog-example.json --format json
```

## Exit behavior

| Exit | Meaning |
| --- | --- |
| `0` | No meaningful price drift or new value candidates (routine should **not** open an issue). |
| `2` | Proposal ready on stdout — open **one** GitHub issue with that body (or file a single comment on #71’s epic). |
| `1` | Catalog or `models.yaml` could not be read — fix infrastructure; do not open a proposal issue. |

## Rules (issue #71)

- Compare configured DeepInfra models in `.factory/models.yaml` to catalog list prices.
- Flag price moves above **15%** on input, cache-read, or output $/Mtok.
- Flag clearly better-value **coding** candidates only when quality is at least comparable (catalog marks `quality_tier` in fixtures; live fetch uses id/description heuristics).
- Ignore **short promos** (`promo: true` without `promo_long_lived: true`); prefer standard-tier list prices.
- Never commit changes to `.factory/models.yaml` from this routine.

## Opening an issue (only on exit 2)

1. Capture stdout: `body.md` from `--format markdown` (default).
2. Open one issue titled like `Proposed models.yaml update (YYYY-MM-DD)` with that body and `Refs #71`.
3. Do **not** open duplicate scout issues the same week.

## Verification

```bash
bash scripts/test-factory-model-scout.sh
```