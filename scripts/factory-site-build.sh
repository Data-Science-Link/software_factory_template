#!/usr/bin/env bash
# One-command build of the static factory site.
#
# Usage:
#   scripts/factory-site-build.sh                      # live build (collect, dbt, export, render)
#   scripts/factory-site-build.sh --sample             # offline build from committed fixtures
#   scripts/factory-site-build.sh --offline --runs-dir examples/sample-runs
#   scripts/factory-site-build.sh --dry-run            # print stages without executing (for tests)
#
# Stages, in order:
#   1. collect runs  -> scripts/factory-collect-runs.py      (SKIPPED in --sample / --offline)
#   2. seeds         -> factory/dbt/runs_to_seeds.py
#   3. budget vars + dbt build
#   4. dbt export    -> scripts/factory-site-dbt-export.py (live only)
#   4b. normalize    -> scripts/factory-site-data.py
#   4c. backlog      -> scripts/factory-backlog.py            (fixture when offline)
#   5. render        -> scripts/factory-site.py
#
# With --sample or --offline, committed fixtures and/or --runs-dir stand in for live
# data; scripts/factory-collect-runs.py is never invoked and no network call is made
# unless explicitly requested for backlog (live mode only). A stage whose script does
# not exist is skipped with a printed note. Live dbt build/dbt run is never run in
# --sample or --offline.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PYTHON="${FACTORY_PYTHON:-python3}"
SAMPLE=0
OFFLINE=0
DRY_RUN=0
RUNS_DIR=""
PINNED_NOW=""
AS_OF_DATE=""
WORK_DIR=""

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
  --runs-dir)
      RUNS_DIR="$2"
      shift 2
      ;;
    --now)
      PINNED_NOW="$2"
      AS_OF_DATE="${2:0:10}"
      shift 2
      ;;
    --as-of-date)
      AS_OF_DATE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$OFFLINE" = 1 ] && [ -z "$RUNS_DIR" ] && [ "$SAMPLE" != 1 ]; then
  SAMPLE=1
fi

REPO_ROOT="$(pwd)"
DBT_DIR="$REPO_ROOT/factory/dbt"
DBT_DB="$DBT_DIR/target/factory.duckdb"
DBT_MARTS="site-data/dbt-marts"
NO_NETWORK=0
if [ "$SAMPLE" = 1 ] || [ "$OFFLINE" = 1 ]; then
  NO_NETWORK=1
fi

WORK_DIR="$(mktemp -d)"

run_cmd() {
  local name="$1"
  shift
  if [ "$DRY_RUN" = 1 ]; then
    echo "RUN   $name (dry-run)"
    printf '        '; printf '%q ' "$@"; printf '\n'
    return 0
  fi
  echo "RUN   $name"
  "$@"
}

run_script() {
  local name="$1"
  local script="$2"
  shift 2
  if [ "$NO_NETWORK" = 1 ]; then
    echo "SKIP  $name (offline/sample build)"
    return 0
  fi
  if [ ! -e "$script" ]; then
    echo "SKIP  $name (script not present: $script)"
    return 0
  fi
  run_cmd "$name" "$@"
}

run_py() {
  local name="$1"
  local script="$2"
  shift 2
  if [ "$NO_NETWORK" = 1 ]; then
    echo "SKIP  $name (offline/sample build)"
    return 0
  fi
  if [ ! -e "$script" ]; then
    echo "SKIP  $name (script not present: $script)"
    return 0
  fi
  run_cmd "$name" "$PYTHON" "$script" "$@"
}

# 1. collect runs
if [ "$NO_NETWORK" = 1 ]; then
  echo "SKIP  collect runs (offline/sample never invokes scripts/factory-collect-runs.py)"
else
  run_py "collect runs" scripts/factory-collect-runs.py
fi

# 2. seeds (live: from collected site-data/runs/)
if [ "$NO_NETWORK" = 1 ]; then
  echo "SKIP  seeds (offline/sample uses committed fixtures or --runs-dir)"
else
  run_py "seeds" factory/dbt/runs_to_seeds.py --runs 'site-data/runs/*.json'
fi

# 3. budget vars + dbt build (live only; never offline/sample)
if [ "$NO_NETWORK" = 1 ]; then
  echo "SKIP  dbt build (offline/sample never runs live dbt)"
  echo "SKIP  dbt docs (offline/sample offline build)"
elif ! command -v dbt >/dev/null 2>&1; then
  echo "SKIP  dbt build (dbt not installed)"
  echo "SKIP  dbt docs (dbt not installed)"
elif ! "$PYTHON" -c "import dbt" >/dev/null 2>&1; then
  echo "SKIP  dbt build (dbt Python package not installed)"
  echo "SKIP  dbt docs (dbt Python package not installed)"
else
  if [ "$DRY_RUN" = 1 ]; then
    run_cmd "dbt build" bash -c \
      "cd \"$DBT_DIR\" && dbt build --profiles-dir . --vars \"\$($PYTHON \"$REPO_ROOT/scripts/factory-budget-vars.py\")\""
    run_cmd "dbt docs (static)" bash -c \
      "cd \"$DBT_DIR\" && dbt docs generate --static --profiles-dir ."
  else
    echo "RUN   dbt build"
    export DBT_SEND_ANONYMOUS_USAGE_STATS=false
    (
      cd "$DBT_DIR"
      dbt build --profiles-dir . --vars "$("$PYTHON" "$REPO_ROOT/scripts/factory-budget-vars.py")"
    )
    echo "RUN   dbt docs (static)"
    DBT_DOCS_OK=0
    if (
      cd "$DBT_DIR"
      dbt docs generate --static --profiles-dir .
    ); then
      DBT_DOCS_OK=1
    else
      echo "NOTE  dbt docs generate --static failed (dbt version may lack --static); skipping dbt-docs.html"
    fi
    if [ "$DBT_DOCS_OK" = 1 ]; then
      if [ -f "$DBT_DIR/target/static_index.html" ]; then
        mkdir -p site
        cp "$DBT_DIR/target/static_index.html" site/dbt-docs.html
        echo "RUN   copy static dbt docs -> site/dbt-docs.html"
      else
        echo "NOTE  static_index.html not found after dbt docs generate"
      fi
    fi
  fi
fi

# 4. export from DuckDB or synthesize from runs, then normalize for the site
SITE_DATA_ARGS=()
if [ -n "$AS_OF_DATE" ]; then
  SITE_DATA_ARGS+=(--as-of-date "$AS_OF_DATE")
fi

if [ -n "$RUNS_DIR" ]; then
  echo "RUN   site-data synthesize (--runs-dir)"
  if [ "$DRY_RUN" = 1 ]; then
    run_cmd "site-data synthesize" "$PYTHON" scripts/factory-site-data.py \
      --runs-dir "$RUNS_DIR" \
      --out site-data/marts \
      "${SITE_DATA_ARGS[@]}"
  else
    "$PYTHON" scripts/factory-site-data.py \
      --runs-dir "$RUNS_DIR" \
      --out site-data/marts \
      "${SITE_DATA_ARGS[@]}"
  fi
elif [ "$SAMPLE" = 1 ] || [ "$OFFLINE" = 1 ]; then
  echo "RUN   export (--sample/offline fixtures)"
  if [ "$DRY_RUN" = 1 ]; then
    run_cmd "export (fixtures)" "$PYTHON" scripts/factory-site-data.py \
      --source tests/site-data/sample-marts \
      --out site-data/marts
  else
    "$PYTHON" scripts/factory-site-data.py \
      --source tests/site-data/sample-marts \
      --out site-data/marts
  fi
else
  run_py "dbt mart export" scripts/factory-site-dbt-export.py \
    --db "$DBT_DB" \
    --out "$DBT_MARTS"
  run_py "site-data export" scripts/factory-site-data.py \
    --source "$DBT_MARTS" \
    --out site-data/marts
fi

# 4b. backlog
if [ "$NO_NETWORK" = 1 ]; then
  echo "RUN   backlog (offline, from fixture)"
  if [ "$DRY_RUN" = 1 ]; then
    run_cmd "backlog (offline)" "$PYTHON" scripts/factory-backlog.py \
      --from-json tests/site/fixtures/issues.json \
      --out site-data/backlog.json
  else
    "$PYTHON" scripts/factory-backlog.py \
      --from-json tests/site/fixtures/issues.json \
      --out site-data/backlog.json
  fi
else
  run_py "backlog (live gh issue list)" scripts/factory-backlog.py \
    --out site-data/backlog.json
fi

# Offline manifest fixture for dbt tab (--sample / --offline)
if [ "$NO_NETWORK" = 1 ]; then
  echo "RUN   dbt manifest fixture (offline)"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p factory/dbt/target
    cp tests/site/fixtures/manifest.json factory/dbt/target/manifest.json
  else
    echo "        cp tests/site/fixtures/manifest.json factory/dbt/target/manifest.json"
  fi
  echo "SKIP  dbt static docs (offline; dbt-docs.html not produced offline)"
fi

# 5. render (always)
RENDER_ARGS=(--out site --data site-data --repo-root .)
if [ -n "$PINNED_NOW" ]; then
  RENDER_ARGS+=(--now "$PINNED_NOW")
fi
run_cmd "render" "$PYTHON" scripts/factory-site.py "${RENDER_ARGS[@]}"

echo "RUN   copy static assets"
if [ "$DRY_RUN" != 1 ]; then
  cp factory/site/style.css site/style.css
else
  echo "        cp factory/site/style.css site/style.css"
fi

echo "Built site/ offline"