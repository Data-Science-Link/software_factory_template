Closes #28

Spec: factory/specs/issue-28.md

AI disclosure: harness opencode-actions; model deepseek-ai/DeepSeek-V4-Flash-0731

<!-- factory-run:start -->
Run ID: 11873450021
Tokens in / cached / out: 412000 / 350000 / 18200
Predicted cost: $0.011
Actual cost: $0.0122
Gate: risk normal: owner product gate required (Michael approves before merge)
<!-- factory-run:end -->

Verification output (run by the harness):

```text
+ echo 'Gate:'
Gate:
+ dbt build
Done. PASS=33 WARN=0 ERROR=0
```

Cost: $0.0122 on DeepInfra
