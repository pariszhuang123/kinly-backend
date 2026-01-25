#!/usr/bin/env bash
set -euo pipefail
# ------------------------------------------------------------------------------
# tool/_supabase_lib.sh
#
# Shared helpers for local Supabase orchestration + readiness checks.
# Intended to be "sourced" by other scripts:
#   source "$(dirname "$0")/_supabase_lib.sh"
# ------------------------------------------------------------------------------

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local c="$1"
  local msg="${2:-Required command not found: $c}"
  if ! have_cmd "$c"; then
    err "$msg"
    exit 1
  fi
}

# read_toml_port <section> <key> <fallback>
read_toml_port() {
  local section="$1"
  local key="$2"
  local fallback="$3"
  local file="supabase/config.toml"

  if [[ ! -f "$file" ]]; then
    echo "$fallback"
    return 0
  fi

  awk -F'=' -v sec="$section" -v k="$key" '
    BEGIN { in_sec=0 }
    $0 ~ "^[[:space:]]*\\["sec"\\][[:space:]]*$" { in_sec=1; next }
    $0 ~ "^[[:space:]]*\\[[^]]+\\][[:space:]]*$" { in_sec=0 }
    in_sec {
      # trim key side
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 == k) {
        v=$2
        # trim + remove quotes
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        print v
        exit
      }
    }
  ' "$file" 2>/dev/null || echo "$fallback"
}

# Try to get REST base URL from `supabase status`, else empty.
read_rest_url_from_status() {
  supabase status 2>/dev/null | awk '$1=="REST"{print $3; exit}'
}

# Extract port from http(s)://host:PORT/...
port_from_url() {
  local url="$1"
  local hostport="${url#*://}"   # host:port/path
  hostport="${hostport%%/*}"     # host:port
  echo "${hostport##*:}"         # port
}

# Wait for PostgREST OpenAPI endpoint.
# wait_for_postgrest <rest_url>
wait_for_postgrest() {
  local rest_url="$1" # should end with /rest/v1/ or include it
  # Normalize: ensure trailing slash
  rest_url="${rest_url%/}/"

  log "Waiting for PostgREST/OpenAPI endpoint on ${rest_url} ..."
  for _ in {1..60}; do
    if curl -fsS -H 'Accept: application/openapi+json' "${rest_url}" >/dev/null 2>&1; then
      log "PostgREST reachable ✅"
      return 0
    fi
    sleep 2
  done

  err "PostgREST not reachable at ${rest_url}"
  echo "---- supabase status ----"
  supabase status || true
  echo "---- docker ps ----"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  return 1
}

# Start local Supabase stack (idempotent)
supabase_start() {
  require_cmd supabase "supabase CLI is required but not found on PATH"
  require_cmd docker "docker is required (local Supabase runs in containers)"

  unset DOCKER_HOST || true

  if ! docker ps >/dev/null 2>&1; then
    err "Cannot talk to Docker. Start Docker Desktop, then retry."
    exit 1
  fi

  log "Starting Supabase local stack (if not already running)..."
  supabase start >/dev/null 2>&1 || supabase start
}

# Stop local Supabase stack
supabase_stop() {
  if have_cmd supabase; then
    log "Stopping local Supabase..."
    supabase stop >/dev/null 2>&1 || true
  fi
}

# Determine REST URL + API port (prefers `supabase status`, else TOML fallback)
# echoes: "<REST_URL>|<API_PORT>"
resolve_rest_url_and_api_port() {
  local rest_url
  rest_url="$(read_rest_url_from_status || true)"
  if [[ -n "${rest_url:-}" ]]; then
    rest_url="${rest_url%/}/"
    echo "${rest_url}|$(port_from_url "${rest_url}")"
    return 0
  fi

  local api_port
  api_port="${SUPABASE_LOCAL_API_PORT:-$(read_toml_port api port 54321)}"
  api_port="${api_port:-54321}"
  echo "http://127.0.0.1:${api_port}/rest/v1/|${api_port}"
}
