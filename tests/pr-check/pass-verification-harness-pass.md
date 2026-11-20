Refs #161

Spec: factory/specs/issue-161.md

AI disclosure: harness opencode-actions; model deepseek-ai/DeepSeek-V4-Flash-0731

<!-- factory-run:start -->
Run ID: gha-999-1
Tokens in / cached / out: 100 / 50 / 25
Predicted cost: $0.01
Actual cost: $0.01
Gate: pass
<!-- factory-run:end -->

Cost: not measured

## Evidence

Verification output (run by the harness in a sandbox, not by the model; capped):

<!-- factory-verification:start -->
Verification run by the harness (scripts/opencode-verify.sh), not by the model.
Result: PASS: every command exited 0
```text
+ bash scripts/test-spec-template-drift.sh
Results: 2 passed, 0 failed
```
<!-- factory-verification:end -->