---
issue: 148
title: Masked verification pipe tail
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
bash scripts/test-example.sh | tail -20
```