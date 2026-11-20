---
issue: 148
title: Pipe with pipefail still masks via head
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
set -o pipefail
bash scripts/test-example.sh | head -20
```