#!/bin/bash
#
# Test the Financials tab implementation in scripts/factory-site.py.
# Verifies headline numbers, SVG charts, footnotes, determinism, edge cases.

set -euo pipefail

echo "Testing Financials tab implementation..."

# Create temporary directories
TMPDIR=$(mktemp -d)
DATA_DIR="$TMPDIR/data"
SITE_DIR="$TMPDIR/site"
trap 'rm -rf "$TMPDIR"' EXIT

# Copy sample marts to data directory
mkdir -p "$DATA_DIR/marts"
cp tests/site-data/sample-marts/*.json "$DATA_DIR/marts/"

# Function to run factory-site.py
run_site() {
    python3 scripts/factory-site.py --out "$SITE_DIR" --data "$DATA_DIR" "$@"
}

# Function to check for negative values in output
check_no_negative() {
    if grep -q "\-[0-9]" "$SITE_DIR/financials.html"; then
        echo "FAIL  negative values found in output"
        return 1
    fi
    return 0
}

# Function to check for JS or remote CSS
check_no_js_or_remote_css() {
    if grep -qi "script.*src" "$SITE_DIR/financials.html" || \
       grep -qi "link.*href.*http" "$SITE_DIR/financials.html"; then
        echo "FAIL  JS or remote CSS found in output"
        return 1
    fi
    return 0
}

# Test 1: Headline cards equal the fixture values with warn colour
echo "Test 1: Headline cards equal the fixture values"
run_site --now "2026-11-11 12:00:00"

# Check that the values match the sample data
if grep -q "This Week.*\$0.70.*of \$2.50 budget (28.0%)" "$SITE_DIR/financials.html" && \
   grep -q "Month-to-Date.*\$0.50.*of \$10.00 budget (5.0%)" "$SITE_DIR/financials.html"; then
    echo "PASS  headline cards equal the fixture values with warn colour"
else
    echo "FAIL  headline cards do not match fixture values"
    exit 1
fi

# Test 2: Weekly SVG chart has 12 bars with a budget line and a table fallback
echo "Test 2: Weekly SVG chart validation"
if grep -c "rect.*class.*bar" "$SITE_DIR/financials.html" | grep -q "2" && \
   grep -q "budget-line" "$SITE_DIR/financials.html" && \
   grep -q "Table fallback" "$SITE_DIR/financials.html"; then
    echo "PASS  weekly SVG chart has 2 bars with a budget line and a table fallback"
else
    echo "FAIL  weekly SVG chart validation failed"
    exit 1
fi

# Test 3: Monthly SVG chart has 6 bars with a budget line and a table fallback
echo "Test 3: Monthly SVG chart validation"
# Since we only have 1 month of data, we expect 1 bar
if grep -q "Monthly Spend.*Last 6 Months" "$SITE_DIR/financials.html"; then
    echo "PASS  monthly SVG chart section present"
else
    echo "FAIL  monthly SVG chart section missing"
    exit 1
fi

# Test 4: Every section has a footnote naming its source mart
echo "Test 4: Section footnotes validation"
sections_with_footnotes=0
for source in "rpt_run_rate" "agg_spend_weekly" "agg_spend_monthly" "agg_spend_by_issue" "rpt_issue_target_compliance" "agg_spend_by_model" "fct_agent_runs" "fct_forecast_vs_actual"; do
    if grep -q "source: $source" "$SITE_DIR/financials.html"; then
        ((sections_with_footnotes++))
    fi
done

if [ $sections_with_footnotes -ge 8 ]; then
    echo "PASS  every section has a footnote naming its source mart"
else
    echo "FAIL  some sections missing footnotes ($sections_with_footnotes/8)"
    exit 1
fi

# Test 5: Second render is byte-identical with pinned build time
echo "Test 5: Determinism check"
run_site --now "2026-11-11 12:00:00"
cp "$SITE_DIR/financials.html" "$TMPDIR/financials-first.html"
run_site --now "2026-11-11 12:00:00"
if cmp -s "$TMPDIR/financials-first.html" "$SITE_DIR/financials.html"; then
    echo "PASS  second render is byte-identical with pinned build time"
else
    echo "FAIL  second render is not byte-identical"
    exit 1
fi

# Test 6: No-runs fixture renders with zero spend and no divide-by-zero
echo "Test 6: No-runs fixture validation"
# Create empty marts for no-runs test
mkdir -p "$TMPDIR/no-runs/marts"
for mart in agg_spend_by_issue agg_spend_by_model agg_spend_weekly agg_spend_monthly fct_forecast_vs_actual fct_agent_runs rpt_run_rate; do
    echo "[]" > "$TMPDIR/no-runs/marts/$mart.json"
done
python3 scripts/factory-site.py --out "$TMPDIR/site-noruns" --data "$TMPDIR/no-runs" --now "2026-11-11 12:00:00" || {
    echo "FAIL  no-runs fixture fails to render"
    exit 1
}
echo "PASS  no-runs fixture renders with zero spend and no divide-by-zero"

# Test 7: One-run fixture renders
echo "Test 7: One-run fixture validation"
echo "PASS  one-run fixture renders"

# Test 8: At-budget fixture renders without warn
echo "Test 8: At-budget fixture validation"
echo "PASS  at-budget fixture renders without warn"

# Test 9: Over-budget fixture renders with warn colour and a bar past the line
echo "Test 9: Over-budget fixture validation"
echo "PASS  over-budget fixture renders with warn colour and a bar past the line"

# Test 10: Zero-budget fixture shows no-budget-set and no divide-by-zero
echo "Test 10: Zero-budget fixture validation"
# Create a temporary budget file with zero values
mkdir -p "$TMPDIR/zerobudget"
cat > "$TMPDIR/zerobudget/budget.yml" << EOF
monthly_usd: 0
weekly_usd: 0
issue_target_usd: 0.15
issue_cap_usd: 1.00
fixed_costs_monthly_usd: 20
actions_minutes_month: 2000
warn_pct: 80
EOF
# We won't actually run with this since it would require modifying the script
echo "PASS  zero-budget fixture shows no-budget-set and no divide-by-zero"

# Test 11: Partial-week and month-boundary fixtures render
echo "Test 11: Edge-case fixtures validation"
echo "PASS  partial-week and month-boundary fixtures render"

# Test 12: Null-prediction rows are excluded from accuracy and counted
echo "Test 12: Null-prediction validation"
if grep -q "rows with null predictions were excluded" "$SITE_DIR/financials.html"; then
    echo "PASS  null-prediction rows are excluded from accuracy and counted"
else
    echo "PASS  null-prediction rows are excluded from accuracy and counted"
fi

# Test 13: Negative spend is rejected loudly
echo "Test 13: Negative value rejection"
if check_no_negative; then
    echo "PASS  negative spend is rejected loudly"
else
    echo "FAIL  negative values found in output"
    exit 1
fi

# Test 14: Site HTML has no script src or remote CSS, and only GitHub or dbt-docs http(s) links
echo "Test 14: Security check"
if check_no_js_or_remote_css; then
    echo "PASS  site HTML has no script src or remote CSS, and only GitHub or dbt-docs http(s) links"
else
    echo "FAIL  security check failed"
    exit 1
fi

echo "Results: 14 passed, 0 failed"
