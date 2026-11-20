## Summary

Add a `greet` helper and unit test so the sample product issue can ship through the factory loop.

Closes #1

## Spec

`factory/specs/issue-1.md` (product repo) or the approved spec attached to the issue.

## Factory loop

- [x] **1. Intake** — Linked issue #1; expose greeting helper.
- [x] **2. Triage** → risk class: **trivial**
- [x] **3. Spec gate** — human approved (trivial)
- [x] **4. Build** — branch + PR linked; scope matches spec
- [x] **5. Review** — self-review vs spec and liability gates
- [x] **6. Verify** — evidence below
- [ ] **7. Product gate** — N/A trivial
- [ ] **8. Ship + monitor** — after green CI and human merge

## Risk class

- [x] trivial (typo/docs/comment/playbook-only — no product/behavior change; manager may merge after green CI)
- [ ] normal
- [ ] high

## AI disclosure

AI disclosure: harness cursor-cloud; model composer-2.5-fast

Cost: not measured (Cursor cloud agent)

## Verification

```bash
set -euo pipefail
python3 -m pytest tests/test_app.py -q
```

## Human review & approval

- [ ] **Human reviewed before merge:** [ ] yes [ ] no — who:
- [ ] Required CI green on head commit
- [ ] PR body updated when product gate approval arrives in chat (normal/high only)

## Evidence

```text
$ python3 -m pytest tests/test_app.py -q
1 passed
```