#!/usr/bin/env bash
# Read-only source verification: export the pin into a temporary directory.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REFERENCE=${1:?usage: $0 /path/to/vllm-reference-repository}
PIN=$(python3 - "$ROOT/runtime-manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['upstream']['commit'])
PY
)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git -C "$REFERENCE" cat-file -e "$PIN^{commit}"
git -C "$REFERENCE" archive "$PIN" | tar -x -C "$tmp"
git -C "$tmp" init -q

apply_exact() {
  local patch=$1 output
  output=$(git -C "$tmp" apply --check --verbose "$patch" 2>&1) || {
    printf '%s\n' "$output" >&2; return 1;
  }
  printf '%s\n' "$output"
  ! grep -Eqi 'offset|fuzz' <<<"$output"
  git -C "$tmp" apply "$patch"
}

apply_exact "$ROOT/patches/49819-cohere2moe-eagle3-aux-states.patch"
apply_exact "$ROOT/patches/optional-command4-mixed-transition.patch"
git -C "$tmp" diff --check
echo "patch chain applies exactly to $PIN"
