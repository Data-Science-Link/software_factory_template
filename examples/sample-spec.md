---
issue: 1
title: "Expose app greeting helper"
risk: trivial
complexity: simple
---
## Goal

Add a small `greet(name)` helper in the product app and cover it with a unit test.

## Files

- Modify: `src/app.py` (add `greet` and wire the CLI entry)
- Modify: `tests/test_app.py` (assert greeting output for a sample name)

## Bad inputs and edge cases

- Empty name → return a fixed placeholder string; test asserts behavior.
- Whitespace-only name → treated as empty.

## Verification

```bash
set -euo pipefail
python3 -m pytest tests/test_app.py -q
```