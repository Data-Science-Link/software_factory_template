#!/usr/bin/env bash
# One-command build of the static factory site.
#
# Usage:
#   scripts/factory-site-build.sh            # live build (collect, dbt, export, render)
#   scripts/factory-site-build.sh --sample   # offline build from committed fixtures
#
# Stages, in order:
#   1. collect runs  -> scripts/factory-collect-runs.py      (SKIPPED in --sample)
#   2. seeds         -> factory/dbt/runs_to_seeds.py
#   3. budget vars + dbt build
#   4. export        -> scripts/factory-site-data.py
#   5. render        -> scripts/factory-site.py
#
# With --sample, committed fixtures under tests/site/fixtures/ and
# tests/site-data/sample-marts/ stand in for live data; scripts/factory-collect-runs.py
# is never invoked and no network call is made. A stage whose script does not exist
# is skipped with a printed note. Live dbt build/dbt run is never run here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
SAMPLE=0
if [ "${1:-}" = "--sample" ]; then
  SAMPLE=1
fi

run_stage() {
  local name="$1"
  shift
  if [ "$SAMPLE" = 1 ]; then
    echo "SKIP  $name (--sample uses committed fixtures)"
    return 0
  fi
  if [ ! -e "$1" ]; then
    echo "SKIP  $name (script not present: $1)"
    return 0
  fi
  echo "RUN   $name"
  "$@"
}

# 1. collect runs
if [ "$SAMPLE" = 1 ]; then
  echo "SKIP  collect runs (--sample never invokes scripts/factory-collect-runs.py)"
else
  run_stage "collect runs" scripts/factory-collect-runs.py
fi

# 2. seeds
run_stage "seeds" "$PYTHON" factory/dbt/runs_to_seeds.py

# 3. budget vars + dbt build (never run live dbt here)
if [ "$SAMPLE" = 1 ]; then
  echo "SKIP  dbt build (never run live dbt in --sample)"
else
  echo "SKIP  dbt build (live dbt build is run outside the sandbox)"
fi

# 4. export
if [ "$SAMPLE" = 1 ]; then
  echo "RUN   export (--sample)"
  "$PYTHON" scripts/factory-site-data.py \
    --source tests/site-data/sample-marts \
    --out site-data/marts
else
  run_stage "export" "$PYTHON" scripts/factory-site-data.py
fi

# 5. render
echo "RUN   render"
"$PYTHON" scripts/factory-site.py --out site --data site-data --repo-root .

# Copy the site stylesheet (and other static assets) into site/ so the pages
# render with their styling when served or inspected from site/.
echo "RUN   copy static assets"
cp factory/site/style.css site/style.css

echo "Built site/ offline"
