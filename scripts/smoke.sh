#!/usr/bin/env bash
# Start exactly one selected profile and verify its OpenAI endpoint is ready.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/smoke.sh <dflash|dspark> [--generate]

The default smoke checks /health and /v1/models only. --generate additionally
submits a minimal completion request. This script never enables both profiles.
EOF
  exit 64
}

[[ $# -ge 1 ]] || usage
SERVICE=$1
shift
case "$SERVICE" in
  dflash) PORT=${DFLASH_HOST_PORT:-8001}; MODEL=north-mini-code-dflash ;;
  dspark) PORT=${DSPARK_HOST_PORT:-8002}; MODEL=north-mini-code-dspark ;;
  *) usage ;;
esac
GENERATE=0
case "${1:-}" in
  "") ;;
  --generate) GENERATE=1 ;;
  *) usage ;;
esac

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose)
else
  echo "Docker Compose is required" >&2
  exit 127
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 127; }

"${compose[@]}" --profile "$SERVICE" up -d "$SERVICE"
base_url="http://127.0.0.1:$PORT"
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error "$base_url/health" >/dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent --show-error "$base_url/health" >/dev/null
curl --fail --silent --show-error "$base_url/v1/models" >/dev/null

if [[ "$GENERATE" -eq 1 ]]; then
  curl --fail --silent --show-error \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with OK.\",\"max_tokens\":4}" \
    "$base_url/v1/completions" >/dev/null
fi

echo "$SERVICE smoke passed on $base_url"
