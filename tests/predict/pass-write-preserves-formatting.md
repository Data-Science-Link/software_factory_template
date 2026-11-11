# predict-expect: model=deepseek-ai/DeepSeek-V4-Flash-0731 cost=0.0108 rule=3
Note above the marker (a spec comment body may carry one).
<!-- factory-spec v1 -->
---
# a full-line comment that must stay
title: "Quoted title with → arrow and a long long long long long long long long long long long long value that a YAML dump would wrap onto the next line"
spec_version: 1
issue: 9060
status: draft
complexity: simple
complexity_reason: fixture  # inline comment stays
risk: trivial
work_type: code
approved_by: null
approved_at: null
custom_note: keep this unowned key and its position
model:
model_reason:
predicted_tokens_in: 0
predicted_tokens_cached: 0
predicted_tokens_out: 0
predicted_cost_usd: 0
budget_cap_usd: 1.00
price_table_version: 2026-11-02
---
## Outcome
Body must stay byte-for-byte, including Unicode → and this HTML comment:
<!-- end factory-spec -->
