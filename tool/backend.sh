#!/usr/bin/env bash
set -euo pipefail
# ------------------------------------------------------------------------------
# tool/backend.sh
#
# Optional single entrypoint wrapper (developer-friendly).
# Keeps safe defaults while still letting you run CI-like flow locally.
#
# Usage:
#   ./tool/backend.sh regen            # regen snapshots (assumes supabase running)
#   ./tool/backend.sh regen --start    # start supabase, then regen (no reset)
#   ./tool/backend.sh reset+regen      # start + reset + regen (matches CI locally)
#   ./tool/backend.sh guardrails       # full guardrails (starts + resets + tests)
# ------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cmd="${1:-}"
shift || true

case "$cmd" in
  regen)
    chmod +x tool/contracts_regen.sh
    ./tool/contracts_regen.sh "$@"
    ;;
  reset+regen)
    chmod +x tool/contracts_regen.sh
    ./tool/contracts_regen.sh --start --reset
    ;;
  guardrails|ci)
    chmod +x tool/backend_guardrails.sh
    ./tool/backend_guardrails.sh
    ;;
  -h|--help|"")
    cat <<'HELP'
Usage:
  ./tool/backend.sh regen [--start] [--reset]
  ./tool/backend.sh reset+regen
  ./tool/backend.sh guardrails

Commands:
  regen         Regenerate contract snapshots (safe by default).
  reset+regen   Start Supabase, reset DB, then regen snapshots (CI-like locally).
  guardrails    Full CI guardrails: start+reset, tests, regen, git clean check.
HELP
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    echo "Run: ./tool/backend.sh --help" >&2
    exit 2
    ;;
esac
