# Factory doctor

One command to scan a factory template or product repo for the guardrails that matter before you merge or stamp a new product fork.

## Usage

```bash
python3 scripts/factory-doctor.py
python3 scripts/factory-doctor.py --repo-dir /path/to/repo
python3 scripts/factory-doctor.py --json
python3 scripts/factory-doctor.py --strict
python3 scripts/factory-doctor.py --live
```

| Flag | Meaning |
| --- | --- |
| `--repo-dir` | Repository root to inspect (default: repo containing `scripts/factory-doctor.py`). |
| `--json` | Machine-readable scorecard on stdout. |
| `--strict` | Exit `1` when any check fails (default: always exit `0`, report only). |
| `--live` | Optional online checks (never runs unless you pass this). |

Offline tests: `bash scripts/test-factory-doctor.sh`

## Checks

| Category | What it verifies |
| --- | --- |
| **factory_mode** | `.factory/mode.yml` exists and `mode` is `template` or `product`. Missing or invalid mode fails closed for product workflows. |
| **core_artifacts** | `AGENTS.md`, `.factory/FACTORY.md`, `.factory/DECISIONS.md`, `LICENSE`, and `SECURITY.md` are present. |
| **models_yaml** | `.factory/models.yaml` parses, lists models, and has positive `budget` caps (`issue_cap_usd`, `issue_target_usd`, `deepinfra_monthly_limit_usd`). |
| **python_dbt** | Current `python3` version (warn on 3.14+ for dbt) and whether `python3.12` or `python3.13` is on `PATH`. |
| **protected_scripts** | `scripts/opencode-artifact-scan.sh --list-protected` paths exist on disk and match the mirrored list in `.factory/FACTORY.md` when present. |
| **workflow_hygiene** | When `scripts/factory-audit-workflows.py` exists, runs it with `--json` and summarizes pass/fail counts (no duplicate workflow rules in the doctor). |
| **live** | Only with `--live`: if `gh` is available and `scripts/protect-main.sh` supports `--verify`, runs that verify mode. Skipped otherwise. |

Related issues: [#178](https://github.com/Data-Science-Link/software_factory_template/issues/178), [#38](https://github.com/Data-Science-Link/software_factory_template/issues/38).