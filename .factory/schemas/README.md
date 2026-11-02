# Factory JSON schemas

## Run record (`run-record.schema.json`)

The required top-level fields match **vision §8** (`.factory/VISION.md`) field for field: same names, types, and enums as the run record table in that section.

### Extensions beyond vision §8

These were added so later issues (#30 cost capture, #41 independent reviewer) do not need a breaking schema change. Vision §8 will be updated to match when those issues land.

| Extension | Why | Validator behavior |
|---|---|---|
| `cost_method`: `provider_reported` | DeepInfra may expose per-request cost in session data (#30); sum as primary when present | Same enum as other methods; cost recompute applies only when method is `usage_x_price_table` |
| Optional `steps[]` | Separate harness vs **review** token/cost lines on one run (#41) | Each step includes its own `price_*_per_mtok` for its `model`; step cost is checked against **step** prices, not the run-level prices |

Authoritative definitions: [run-record.schema.json](./run-record.schema.json). Human-oriented field notes: [factory/runs/README.md](../../factory/runs/README.md).
