---
issue: 148
title: Masked verification pipe grep
risk: normal
complexity: standard
---
## Context
x

## Files
- Read: `README.md`

## Bad inputs and edge cases
- N/A for fixture.

## Verification
```bash
bash scripts/test-example.sh | grep PASS
```