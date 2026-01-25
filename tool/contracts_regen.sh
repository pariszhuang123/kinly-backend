#!/usr/bin/env bash
set -euo pipefail
# ------------------------------------------------------------------------------
# tool/contracts_regen.sh
#
# Regenerate DB → contracts artifacts + Dart registry.
#
# Safe by default:
#   - does NOT reset DB
#   - does NOT start/stop Supabase unless you pass --start
#
# Usage:
#   ./tool/contracts_regen.sh
#   ./tool/contracts_regen.sh --start          # starts supabase if needed
#   ./tool/contracts_regen.sh --start --reset  # resets DB (DANGEROUS) + regen
# ------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "tool/_supabase_lib.sh"

START_STACK=false
RESET_DB=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START_STACK=true; shift ;;
    --reset|-r) RESET_DB=true; shift ;;
    -h|--help)
      cat <<'HELP'
Usage:
  ./tool/contracts_regen.sh
  ./tool/contracts_regen.sh --start
  ./tool/contracts_regen.sh --start --reset

Notes:
  - By default, this script assumes Supabase is already running and WILL NOT reset.
  - --reset is only allowed with --start (to prevent accidental data wipes).
HELP
      exit 0
      ;;
    *)
      err "Unknown arg: $1"
      exit 2
      ;;
  esac
done

if "$RESET_DB" && ! "$START_STACK"; then
  err "--reset is only allowed together with --start (safety guard)."
  err "Use: ./tool/contracts_regen.sh --start --reset"
  exit 2
fi

# Ensure docs/contracts exists
mkdir -p docs/contracts

if "$START_STACK"; then
  log "Docker + Supabase checks..."
  require_cmd docker "docker CLI not found. Install Docker Desktop first."
  require_cmd curl "curl is required (PostgREST readiness check)"
  require_cmd awk
  require_cmd python3
  require_cmd dart

  if ! docker ps >/dev/null 2>&1; then
    err "Cannot talk to Docker. Make sure Docker Desktop is running."
    exit 1
  fi

  supabase_start

  if "$RESET_DB"; then
    warn "RESET MODE ENABLED: running 'supabase db reset --yes' (this will WIPE local DB data)."
    supabase db reset --yes
  else
    log "Skipping DB reset (safe mode)."
    log "If you want a clean DB matching CI, run: ./tool/contracts_regen.sh --start --reset"
  fi
else
  # Minimal requirements if stack is already running
  require_cmd supabase "supabase CLI is required but not found on PATH"
  require_cmd curl "curl is required (PostgREST readiness check)"
  require_cmd awk
  require_cmd python3
  require_cmd dart
fi

# Resolve REST URL + API port (after start/reset, status becomes authoritative)
IFS='|' read -r REST_URL API_PORT < <(resolve_rest_url_and_api_port)
log "Using REST_URL=${REST_URL}"
log "Using API_PORT=${API_PORT}"

# Wait for PostgREST/OpenAPI endpoint
wait_for_postgrest "${REST_URL}"

log "Dumping schema.sql (DDL only) via 'supabase db dump --local'..."
supabase db dump --local -f docs/contracts/schema.sql

log "Extracting RLS policies into docs/contracts/rls_policies.sql..."
awk '/CREATE POLICY|ENABLE ROW LEVEL SECURITY|FORCE ROW LEVEL SECURITY/ {print}' \
  docs/contracts/schema.sql > docs/contracts/rls_policies.sql

log "Dumping OpenAPI from PostgREST to docs/contracts/openapi.json..."
curl -fsS -H 'Accept: application/openapi+json' \
  "${REST_URL}" > docs/contracts/openapi.json

log "Generating TypeScript DB types to docs/contracts/types.generated.ts..."
supabase gen types typescript --local > docs/contracts/types.generated.ts

log "Generating Edge Functions manifest docs/contracts/edge_functions.json..."
python3 - <<'PY'
import os, json
base = 'supabase/functions'
manifest = {'functions': {}}
if os.path.isdir(base):
    for name in sorted(
        d for d in os.listdir(base)
        if os.path.isdir(os.path.join(base, d))
    ):
        manifest['functions'][name] = {'path': os.path.join(base, name).replace('\\\\', '/')}
os.makedirs('docs/contracts', exist_ok=True)
with open('docs/contracts/edge_functions.json', 'w') as f:
    json.dump(manifest, f, indent=2)
print('Wrote docs/contracts/edge_functions.json')
PY

log "Running Dart contracts extractor..."
dart tool/contracts_extract.dart

log "Validating registry structure..."
dart tool/validate_registry.dart docs/contracts/registry.json

echo
log "Done ✅ The following files may have changed:"
cat <<'OUT'
  - docs/contracts/schema.sql
  - docs/contracts/rls_policies.sql
  - docs/contracts/openapi.json
  - docs/contracts/types.generated.ts
  - docs/contracts/edge_functions.json
  - docs/contracts/registry.json
OUT
echo
log "Next steps:"
cat <<'NEXT'
  git status
  git diff docs/contracts/
  git add docs/contracts/*
  git commit -m "Update contract snapshots and registry"
NEXT
