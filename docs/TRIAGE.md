# Backlog triage (Factory Manager)

`scripts/factory-issue-triage.py` supports a short weekly or daily triage pass: label gaps, stale-looking issues, epic progress, and one **Recommendation** with **Why** (#130) for what to run next.

## Commands

**Offline (fixtures or a saved `gh issue list` export):**

```bash
python3 scripts/factory-issue-triage.py \
  --issues-json tests/factory-triage/backlog.json \
  --repo owner/name \
  --repo-dir .
```

**Live backlog:**

```bash
python3 scripts/factory-issue-triage.py --repo owner/name --repo-dir .
```

**JSON for dashboards or the factory site:**

```bash
python3 scripts/factory-issue-triage.py --issues-json path/to/issues.json --json
```

## Triage session (≈5 minutes)

1. Run the script from the repo root (`--repo-dir .` so `scripts/…` paths in issues resolve correctly).
2. **Label hygiene** — For each listed issue, confirm priority/risk, then run the suggested `gh issue edit` commands or set better labels by hand.
3. **Possibly implemented** — For each hit, open the issue: if the file on disk satisfies the outcome, close the issue; otherwise update the scope.
4. **Epic rollup** — Check open vs closed sub-issues; nudge or re-scope epics that stall.
5. **Next up** — Paste the **Recommendation** / **Why** block into the factory room or use it when the owner asks what to run. Only issues with both `priority:*` and `risk:*`, not `epic` or `owner-action`, and not blocked, are ranked (high priority first, lower risk first; `factory:selected` breaks ties).

## Tests

```bash
bash scripts/test-factory-issue-triage.sh
```

Fixtures live under `tests/factory-triage/`.