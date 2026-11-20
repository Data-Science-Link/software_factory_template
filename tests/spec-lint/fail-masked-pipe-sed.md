---
issue: 148
title: Masked verification pipe sed
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
bash scripts/test-example.sh | sed -n '1,5p'
```