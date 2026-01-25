#!/usr/bin/env bash
set -euo pipefail
# ------------------------------------------------------------------------------
# tool/backend_guardrails.sh
#
# CI-oriented backend guardrails:
# - optional Deno checks (if Edge Functions exist)
# - start local Supabase
# - ALWAYS reset DB (authoritative CI behavior)
# - wait for PostgREST
# - run pgTap (if any SQL tests exist)
# - regenerate snapshots (via contracts_regen.sh, pure regen)
# - verify snapshots exist
# - verify snapshots are committed clean
#
# NOTE: This script starts Supabase and stops it on exit.
# ------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "tool/_supabase_lib.sh"

# ----------------------------
# Ensure Supabase stopped on exit
# ----------------------------
SUPABASE_STARTED="false"
cleanup() {
  if [[ "$SUPABASE_STARTED" == "true" ]]; then
    supabase_stop
  fi
}
trap cleanup EXIT

# ----------------------------
# Detect if there is any Deno code to test
# ----------------------------
has_edge_functions() {
  [[ -d "supabase/functions" ]] || return 1
  find supabase/functions -mindepth 1 -maxdepth 2 -not -path '*/.*' -print -quit | grep -q .
}

run_deno_checks_if_needed() {
  if ! has_edge_functions; then
    warn "No Edge Functions found under supabase/functions; skipping Deno checks"
    return 0
  fi

  require_cmd deno "deno is required (Edge Functions present) but not found on PATH"

  if [[ ! -f ".denoversion" ]]; then
    err ".denoversion not found (Edge Functions present => pinned Deno required)"
    exit 1
  fi

  local expected actual
  expected="$(tr -d ' \t\r\n' < .denoversion)"
  actual="$(deno --version | head -n 1 | awk '{print $2}')"
  log "Expected Deno: $expected"
  log "Actual Deno:   $actual"
  if [[ "$expected" != "$actual" ]]; then
    err "Installed Deno $actual does not match pinned version $expected"
    exit 1
  fi

  local DENO_CFG="supabase/deno.json"
  local DENO_LOCK="supabase/deno.lock"

  [[ -f "$DENO_LOCK" ]] || { err "$DENO_LOCK not found (frozen lock required)"; exit 1; }
  [[ -f "$DENO_CFG"  ]] || { err "$DENO_CFG not found (Deno config required)"; exit 1; }

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
# pgTap (only if there are SQL tests)
# ----------------------------
run_pgtap_if_needed() {
  shopt -s nullglob
  local files=(supabase/tests/*.sql)
  if [[ ${#files[@]} -eq 0 ]]; then
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

  local db_port
  db_port="$(read_toml_port db port 54322)"
  db_port="${db_port:-54322}"
  local uri="postgresql://postgres:postgres@127.0.0.1:${db_port}/postgres"

  log "Running pgTap suites against ${uri}..."
  for file in "${files[@]}"; do
    echo "::group::pgTap $file"
    psql "$uri" -v ON_ERROR_STOP=1 -f "$file"
    echo "::endgroup::"
  done
}

regen_snapshots() {
  [[ -f "tool/contracts_regen.sh" ]] || { err "tool/contracts_regen.sh not found"; exit 1; }
  chmod +x tool/contracts_regen.sh

  # IMPORTANT: guardrails already started + reset the stack.
  # Regen should NOT re-start or reset; keep it pure.
  log "Regenerating contract snapshots from local DB..."
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
    if [[ ! -f "$f" ]]; then
      err "Missing expected snapshot: $f"
      missing=1
    fi
  done

  [[ "$missing" -eq 0 ]] || exit 1
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
  if [[ -n "$changed" ]]; then
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

require_cmd supabase "supabase CLI is required but not found on PATH"
require_cmd docker "docker is required (local Supabase runs in containers)"
require_cmd curl "curl is required (PostgREST readiness check)"
require_cmd awk
require_cmd tr
require_cmd head
require_cmd python3
require_cmd dart

run_deno_checks_if_needed

supabase_start
SUPABASE_STARTED="true"

log "Resetting DB (authoritative): supabase db reset --yes"
supabase db reset --yes

IFS='|' read -r REST_URL API_PORT < <(resolve_rest_url_and_api_port)
log "Using REST_URL=${REST_URL}"
log "Using API_PORT=${API_PORT}"

wait_for_postgrest "${REST_URL}"
run_pgtap_if_needed
regen_snapshots
verify_snapshots_exist
verify_snapshots_committed_clean

log "All backend guardrails passed ✅"
