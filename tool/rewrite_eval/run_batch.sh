#!/usr/bin/env bash
set -euo pipefail
if [ $# -ne 1 ]; then
  echo "Usage: $0 <provider_outputs.jsonl>" >&2
  exit 1
fi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FILE=$1
deno run --allow-read --allow-env --allow-net "$SCRIPT_DIR/batch_runner.ts" "$FILE"
