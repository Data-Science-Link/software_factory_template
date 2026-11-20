# Golden examples (live-validated)

Copy-paste references for **product** repos adopting the Software Factory. Each file is checked by `bash scripts/test-examples.sh` against the same offline validators CI uses.

| Path | Purpose |
| --- | --- |
| `minimal-product-repo/` | Minimal adopted layout: `mode.yml`, `models.yaml`, `DECISIONS.md`, `AGENTS.md` |
| `sample-spec.md` | Product spec shape (`src/` + `tests/`, not `scripts/`) |
| `sample-pr-body.md` | PR body with issue link, AI disclosure, cost, verification, human review checklist |

Run the drift test after editing any golden file: `bash scripts/test-examples.sh`.