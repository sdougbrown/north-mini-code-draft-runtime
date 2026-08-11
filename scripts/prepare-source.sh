#!/usr/bin/env bash
# Fetch an exact vLLM source revision and apply this recipe's patches.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/runtime-manifest.json"
SOURCE_DIR="${VLLM_SOURCE_DIR:-$ROOT/.work/vllm}"
WITH_COMMAND4=0

usage() {
  echo "usage: $0 [--source DIR] [--with-command4-mixed-transition]" >&2
  exit 2
}
while (($#)); do
  case "$1" in
    --source) SOURCE_DIR=${2:?missing source directory}; shift 2 ;;
    --with-command4-mixed-transition) WITH_COMMAND4=1; shift ;;
    *) usage ;;
  esac
done
if [[ "$SOURCE_DIR" != /* ]]; then
  SOURCE_DIR="$ROOT/$SOURCE_DIR"
fi

read_manifest() {
  python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
value = m
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}
UPSTREAM_URL=$(read_manifest upstream.repository)
PIN=$(read_manifest upstream.commit)

if [[ -e "$SOURCE_DIR" && ! -d "$SOURCE_DIR/.git" ]]; then
  echo "refusing non-git source directory: $SOURCE_DIR" >&2
  exit 1
fi
if [[ ! -e "$SOURCE_DIR" ]]; then
  mkdir -p "$(dirname "$SOURCE_DIR")"
  git clone "$UPSTREAM_URL" "$SOURCE_DIR"
fi

actual_remote=$(git -C "$SOURCE_DIR" remote get-url origin)
if [[ "$actual_remote" != "$UPSTREAM_URL" && "$actual_remote" != "git@github.com:vllm-project/vllm.git" ]]; then
  echo "refusing unexpected origin: $actual_remote" >&2
  exit 1
fi
git -C "$SOURCE_DIR" fetch --no-tags origin "$PIN"
resolved=$(git -C "$SOURCE_DIR" rev-parse "$PIN^{commit}")
[[ "$resolved" == "$PIN" ]] || { echo "pinned commit resolution mismatch" >&2; exit 1; }
git -C "$SOURCE_DIR" checkout --detach "$PIN"
git -C "$SOURCE_DIR" reset --hard "$PIN"
git -C "$SOURCE_DIR" clean -ffdqx

patches=("patches/49819-cohere2moe-eagle3-aux-states.patch")
if ((WITH_COMMAND4)); then
  patches+=("patches/optional-command4-mixed-transition.patch")
fi

for relative in "${patches[@]}"; do
  patch="$ROOT/$relative"
  expected=$(python3 - "$MANIFEST" "$relative" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for patch in m['patches']:
    if patch['path'] == sys.argv[2]:
        print(patch['sha256'])
        break
else:
    raise SystemExit('patch missing from manifest')
PY
)
  actual=$(sha256sum "$patch" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { echo "patch hash mismatch: $relative" >&2; exit 1; }
  output=$(git -C "$SOURCE_DIR" apply --check --verbose "$patch" 2>&1) || {
    printf '%s\n' "$output" >&2; exit 1;
  }
  printf '%s\n' "$output"
  if grep -Eqi 'offset|fuzz' <<<"$output"; then
    echo "refusing non-exact patch application: $relative" >&2; exit 1
  fi
  output=$(git -C "$SOURCE_DIR" apply --verbose "$patch" 2>&1) || {
    printf '%s\n' "$output" >&2; exit 1;
  }
  printf '%s\n' "$output"
  if grep -Eqi 'offset|fuzz' <<<"$output"; then
    echo "refusing non-exact patch application: $relative" >&2; exit 1
  fi
done

git -C "$SOURCE_DIR" diff --check
echo "prepared $SOURCE_DIR at $PIN"
