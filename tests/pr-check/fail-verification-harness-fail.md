Refs #161

Spec: factory/specs/issue-161.md

AI disclosure: harness opencode-actions; model deepseek-ai/DeepSeek-V4-Flash-0731

<!-- factory-run:start -->
Run ID: gha-999-2
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
Result: FAIL: 1 command(s) exited non-zero (block exit 1)
Per-command status: every command ran; any that exited non-zero is listed here (line in the block, exit code, command).
  FAILED line 3: exit 1: python3 scripts/spec-template-drift-check.py
--- output ---
Results: 1 passed, 1 failed
<!-- factory-verification:end -->