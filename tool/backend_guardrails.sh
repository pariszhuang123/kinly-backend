#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_ci() {
  local v="${CI:-}"
  v="$(echo "$v" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ "$v" == "true" || "$v" == "1" || "$v" == "yes" ]]
}

require_cmd() {
  local c="$1"
  local msg="${2:-Required command not found: $c}"
  if ! have_cmd "$c"; then
    err "$msg"
    exit 1
  fi
}

# ----------------------------
# Read ports from supabase/config.toml (with fallback)
# ----------------------------
read_toml_port() {
  local section="$1"
  local key="$2"
  local fallback="$3"
  local file="supabase/config.toml"

  if [ ! -f "$file" ]; then
    echo "$fallback"
    return 0
  fi

  awk -F'=' -v sec="$section" -v k="$key" '
    BEGIN { in_sec=0 }
    $0 ~ "^[[:space:]]*\\["sec"\\][[:space:]]*$" { in_sec=1; next }
    $0 ~ "^[[:space:]]*\\[" { in_sec=0 }
    in_sec {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 == k) {
        v=$2
        gsub(/[[:space:]]+|"/, "", v)
        if (v ~ /^[0-9]+$/) { print v; exit }
      }
    }
  ' "$file" 2>/dev/null || true
}

API_PORT="$(read_toml_port api port 54321)"
DB_PORT="$(read_toml_port db  port 54322)"
API_PORT="${API_PORT:-54321}"
DB_PORT="${DB_PORT:-54322}"

# ----------------------------
# Ensure Supabase is stopped on exit
# ----------------------------
SUPABASE_STARTED="false"
cleanup() {
  if [ "$SUPABASE_STARTED" == "true" ]; then
    log "Stopping local Supabase..."
    supabase stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ----------------------------
# Detect if there is any Deno code to test
# ----------------------------
has_edge_functions() {
  # Consider "exists and not empty" as "has deno code"
  if [ ! -d "supabase/functions" ]; then
    return 1
  fi

  # Any non-hidden file/dir inside counts
  if find supabase/functions -mindepth 1 -maxdepth 2 \
      -not -path '*/.*' \
      -print -quit | grep -q .; then
    return 0
  fi

  return 1
}

# ----------------------------
# 1) Deno edge function checks (only if there are edge functions)
# ----------------------------
run_deno_checks_if_needed() {
  if ! has_edge_functions; then
    warn "No Edge Functions found under supabase/functions; skipping Deno tests"
    return 0
  fi

  require_cmd deno "deno is required (Edge Functions present) but not found on PATH"

  if [ ! -f ".denoversion" ]; then
    err ".denoversion not found (Edge Functions present => pinned Deno required)"
    exit 1
  fi

  local expected actual
  expected="$(tr -d ' \t\r\n' < .denoversion)"
  actual="$(deno --version | head -n 1 | awk '{print $2}')"
  log "Expected Deno: $expected"
  log "Actual Deno:   $actual"
  if [ "$expected" != "$actual" ]; then
    err "Installed Deno $actual does not match pinned version $expected"
    exit 1
  fi

  # Align paths with your repo layout:
  local DENO_CFG="supabase/deno.json"
  local DENO_LOCK="supabase/deno.lock"

  if [ ! -f "$DENO_LOCK" ]; then
    err "$DENO_LOCK not found (Edge Functions present => frozen lock required)"
    exit 1
  fi

  if [ ! -f "$DENO_CFG" ]; then
    err "$DENO_CFG not found (Edge Functions present => Deno config required)"
    exit 1
  fi

  log "Running Deno tests (edge functions) with frozen lock..."
  deno test -A \
    --config "$DENO_CFG" \
    --lock="$DENO_LOCK" \
    --frozen \
    supabase/functions || {
      err "Deno tests failed OR lockfile out of date. Fix locally then commit supabase/deno.lock."
      echo "Run locally:"
      echo "  deno test -A --config $DENO_CFG --lock=$DENO_LOCK --frozen=false supabase/functions"
      exit 1
    }
}

# ----------------------------
# 2) Local Supabase start + reset (robust against transient 502s)
# ----------------------------
start_and_reset_supabase() {
  require_cmd supabase "supabase CLI is required but not found on PATH"
  require_cmd curl "curl is required (PostgREST readiness check)"
  require_cmd docker "docker is required (local Supabase runs in containers)"

  # Avoid Docker-over-TCP surprises that can break some containers.
  unset DOCKER_HOST || true

  log "Starting local Supabase..."
  supabase start
  SUPABASE_STARTED="true"

  log "Resetting DB (apply migrations + seed)..."
  local attempt=1
  local max_attempts=3

  while true; do
    if supabase db reset --yes; then
      log "supabase db reset succeeded (attempt ${attempt}/${max_attempts})"
      break
    fi

    warn "supabase db reset failed (attempt ${attempt}/${max_attempts})"

    # Print quick, actionable diagnostics (helps when reset flakes during restarts)
    echo "::group::docker supabase services (kinly-local)"
    docker ps -a --filter "name=supabase_.*_kinly-local" --format "table {{.Names}}\t{{.Status}}" || true
    echo "::endgroup::"

    echo "::group::logs kong (tail)"
    docker logs --tail 160 supabase_kong_kinly-local 2>/dev/null || true
    echo "::endgroup::"

    echo "::group::logs rest (tail)"
    docker logs --tail 160 supabase_rest_kinly-local 2>/dev/null || true
    echo "::endgroup::"

    echo "::group::logs auth (tail)"
    docker logs --tail 160 supabase_auth_kinly-local 2>/dev/null || true
    echo "::endgroup::"

    # Optional services may exist depending on config; print if present
    echo "::group::logs storage (tail)"
    docker logs --tail 160 supabase_storage_kinly-local 2>/dev/null || true
    echo "::endgroup::"

    if [ "$attempt" -ge "$max_attempts" ]; then
      err "supabase db reset failed after ${max_attempts} attempts"
      err "Tip: run 'supabase db reset --yes --debug' to see upstream URL + more details."
      exit 1
    fi

    attempt=$((attempt + 1))
    log "Waiting briefly before retry..."
    sleep 8
  done
}

# ----------------------------
# 3) Wait for PostgREST
# ----------------------------
wait_for_postgrest() {
  local port="$1"
  log "Waiting for PostgREST on port ${port}..."
  for i in {1..60}; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/openapi+json' \
      "http://127.0.0.1:${port}/rest/v1/" || true)"
    code="$(echo "$code" | tr -d '\r\n' | xargs)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      log "PostgREST reachable (HTTP ${code})"
      return 0
    fi
    sleep 2
  done
  err "PostgREST did not become ready on port ${port}"
  exit 1
}

# ----------------------------
# 4) pgTap (only if there are SQL tests)
# ----------------------------
run_pgtap_if_needed() {
  shopt -s nullglob
  local files=(supabase/tests/*.sql)

  if [ ${#files[@]} -eq 0 ]; then
    warn "No pgTap test files found in supabase/tests/*.sql; skipping pgTap"
    return 0
  fi

  if ! have_cmd psql; then
    log "Installing postgresql-client for pgTap..."
    if have_cmd sudo; then
      sudo apt-get update
      sudo apt-get install -y postgresql-client
    else
      err "psql not found and sudo not available to install postgresql-client"
      exit 1
    fi
  fi

  local uri="postgresql://postgres:postgres@127.0.0.1:${DB_PORT}/postgres"
  log "Running pgTap suites against ${uri}..."

  for file in "${files[@]}"; do
    echo "::group::pgTap $file"
    psql "$uri" -v ON_ERROR_STOP=1 -f "$file"
    echo "::endgroup::"
  done
}

# ----------------------------
# 5) Regenerate + verify snapshots (always)
# ----------------------------
regen_snapshots() {
  if [ ! -f "tool/contracts_regen.sh" ]; then
    err "tool/contracts_regen.sh not found (backend must generate authoritative snapshots)"
    exit 1
  fi
  log "Regenerating contract snapshots from local DB..."
  chmod +x tool/contracts_regen.sh
  ./tool/contracts_regen.sh
}

verify_snapshots_exist() {
  local expected=(
    docs/contracts/schema.sql
    docs/contracts/rls_policies.sql
    docs/contracts/openapi.json
    docs/contracts/types.generated.ts
    docs/contracts/edge_functions.json
    docs/contracts/registry.json
    docs/contracts/registry.schema.json
  )

  local missing=0
  for f in "${expected[@]}"; do
    if [ ! -f "$f" ]; then
      err "Missing expected snapshot: $f"
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

verify_snapshots_committed_clean() {
  require_cmd git "git is required to verify snapshot cleanliness"
  local expected=(
    docs/contracts/schema.sql
    docs/contracts/rls_policies.sql
    docs/contracts/openapi.json
    docs/contracts/types.generated.ts
    docs/contracts/edge_functions.json
    docs/contracts/registry.json
    docs/contracts/registry.schema.json
  )

  local changed
  changed="$(git status --porcelain "${expected[@]}" || true)"
  if [ -n "$changed" ]; then
    err "Contract snapshots are out of date. Run ./tool/contracts_regen.sh and commit."
    git --no-pager diff -- "${expected[@]}" || true
    exit 1
  fi

  log "Snapshots are committed and clean."
}

# ==========================================
# Execute
# ==========================================
log "Backend guardrails starting..."
log "CI mode: ${CI:-false}"
log "Using Supabase API port: ${API_PORT}"
log "Using Supabase DB port:  ${DB_PORT}"

run_deno_checks_if_needed
start_and_reset_supabase
wait_for_postgrest "$API_PORT"
run_pgtap_if_needed
regen_snapshots
verify_snapshots_exist
verify_snapshots_committed_clean

log "All backend guardrails passed ✅"
