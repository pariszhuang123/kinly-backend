#!/usr/bin/env bash
set -euo pipefail
# ------------------------------------------------------------------------------
# tool/backend_guardrails.sh
#
# CI-oriented backend guardrails:
# - Deno checks (if Edge Functions exist)
#   - Enforce pinned Deno via .denoversion
#   - Enforce frozen lockfile supabase/deno.lock
#   - Enforce import hygiene (no random remote imports / no unpinned deps drift)
#   - fmt/lint/check always
#   - deno test only if *_test.ts exists (avoids “no tests / scan everything” gotcha)
# - start local Supabase
# - ALWAYS reset DB (authoritative CI behavior)
# - wait for PostgREST
# - run pgTap (if any SQL tests exist)
# - regenerate snapshots (via contracts_regen.sh, pure regen)
# - verify snapshots exist
# - verify snapshots are committed clean
# ------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "tool/_supabase_lib.sh"

SUPABASE_STARTED="false"
cleanup() {
  if [[ "$SUPABASE_STARTED" == "true" ]]; then
    supabase_stop
  fi
}
trap cleanup EXIT

# ----------------------------
# Edge Function detection (real functions only)
# supabase/functions/<name>/index.ts
# ----------------------------
has_edge_functions() {
  [[ -d "supabase/functions" ]] || return 1
  find supabase/functions -mindepth 2 -maxdepth 2 -type f -name "index.ts" -not -path '*/.*' -print -quit | grep -q .
}

has_deno_tests() {
  find supabase/functions -type f \( -name "*_test.ts" -o -name "*.test.ts" \) -not -path '*/.*' -print -quit | grep -q .
}

# ----------------------------
# Import hygiene (prevents “silent drift” gotchas)
#
# Philosophy:
# - Allow your known pinned sources:
#   - jsr:@std/http@0.224.0 (or other @std/* if you add them later, but pinned)
#   - npm:@supabase/supabase-js@2.48.0 (pinned)
#   - npm:@types/node@24 (or pinned, depending on how you import it)
# - Disallow:
#   - https://... imports
#   - jsr:... without @version
#   - npm:... without @version (except the special "@types/node@24" shorthand you already use)
# - This is intentionally conservative; expand allow-list as you need.
# ----------------------------
enforce_import_hygiene() {
  require_cmd grep
  require_cmd awk
  require_cmd sed

  # Gather TS files (skip dot dirs)
  mapfile -t tsfiles < <(find supabase/functions -type f -name "*.ts" -not -path '*/.*' | sort)
  if [[ ${#tsfiles[@]} -eq 0 ]]; then
    warn "No TypeScript files found under supabase/functions; skipping import hygiene"
    return 0
  fi

  local bad=0

  # 1) Ban https imports completely
  if grep -RInE --exclude-dir='.*' --include='*.ts' 'from\s+["'\'']https?://|import\s+["'\'']https?://' supabase/functions >/dev/null 2>&1; then
    err "Disallowed remote https:// import found in supabase/functions (use jsr:/npm: pinned imports instead)."
    grep -RInE --exclude-dir='.*' --include='*.ts' 'from\s+["'\'']https?://|import\s+["'\'']https?://' supabase/functions || true
    bad=1
  fi

  # 2) Require jsr: imports to include an explicit @version
  #    Example allowed: jsr:@std/http@0.224.0
  #    Example disallowed: jsr:@std/http
  if grep -RInE --exclude-dir='.*' --include='*.ts' '["'\'']jsr:[^"'\'' ]+["'\'']' supabase/functions >/dev/null 2>&1; then
    # Find jsr imports missing @<version>
    local jsr_unpinned
    jsr_unpinned="$(grep -RInE --exclude-dir='.*' --include='*.ts' '["'\'']jsr:[^"'\'' ]+["'\'']' supabase/functions \
      | grep -Ev 'jsr:[^"'\'' ]+@[^"'\'' ]+' || true)"
    if [[ -n "$jsr_unpinned" ]]; then
      err "Unpinned jsr: import(s) found. Pin versions like jsr:@std/http@0.224.0"
      echo "$jsr_unpinned"
      bad=1
    fi
  fi

  # 3) Require npm: imports to be pinned with @version
  #    Allowlist:
  #    - npm:@supabase/supabase-js@2.48.0
  #    - npm:@types/node@24 (your chosen shorthand) OR npm:@types/node@24.2.0
  #    Everything else must be pinned with @x.y.z
  if grep -RInE --exclude-dir='.*' --include='*.ts' '["'\'']npm:[^"'\'' ]+["'\'']' supabase/functions >/dev/null 2>&1; then
    local npm_lines
    npm_lines="$(grep -RInE --exclude-dir='.*' --include='*.ts' '["'\'']npm:[^"'\'' ]+["'\'']' supabase/functions || true)"

    # Remove allowlisted patterns; what remains must be pinned correctly
    local npm_unallowed
    npm_unallowed="$(echo "$npm_lines" \
      | grep -Ev 'npm:@supabase/supabase-js@2\.48\.0' \
      | grep -Ev 'npm:@types/node@24([^0-9]|$)|npm:@types/node@24\.' \
      || true)"

    if [[ -n "$npm_unallowed" ]]; then
      # Now check if any remaining npm imports are unpinned (missing @<version>)
      local npm_unpinned
      npm_unpinned="$(echo "$npm_unallowed" | grep -Ev 'npm:[^"'\'' ]+@[^"'\'' ]+' || true)"
      if [[ -n "$npm_unpinned" ]]; then
        err "Unpinned npm: import(s) found (must include @version, except npm:@types/node@24)."
        echo "$npm_unpinned"
        bad=1
      fi
    fi
  fi

  [[ "$bad" -eq 0 ]] || exit 1
  log "Import hygiene checks passed."
}

# ----------------------------
# Deno checks
# ----------------------------
run_deno_checks_if_needed() {
  if ! has_edge_functions; then
    warn "No Edge Functions found under supabase/functions/<fn>/index.ts; skipping Deno checks"
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

  # Import hygiene before we do anything else
  enforce_import_hygiene

  # Real function entrypoints for check/test
  mapfile -t entrypoints < <(find supabase/functions -mindepth 2 -maxdepth 2 -type f -name "index.ts" -not -path '*/.*' | sort)
  if [[ ${#entrypoints[@]} -eq 0 ]]; then
    warn "Edge Functions directory exists but no supabase/functions/<fn>/index.ts found; skipping Deno checks"
    return 0
  fi

  echo "::group::Deno fmt (check)"
  deno fmt --check --config "$DENO_CFG" supabase/functions
  echo "::endgroup::"

  echo "::group::Deno lint"
  deno lint --config "$DENO_CFG" supabase/functions
  echo "::endgroup::"

  echo "::group::Deno check (typecheck, frozen lock)"
  deno check \
    --config "$DENO_CFG" \
    --lock="$DENO_LOCK" \
    --frozen \
    "${entrypoints[@]}"
  echo "::endgroup::"

  if has_deno_tests; then
    echo "::group::Deno test (frozen lock)"
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
    echo "::endgroup::"
  else
    warn "No Deno tests (*_test.ts / *.test.ts) found; skipping deno test"
  fi
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
