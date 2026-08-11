#!/usr/bin/env bash
# Run only the source regressions carried by this runtime recipe.
set -euo pipefail

usage() {
  echo "Usage: $0 <vllm-source-dir> [--with-command4-mixed-transition]" >&2
  exit 64
}

[[ $# -ge 1 ]] || usage
SOURCE_DIR=$1
shift
WITH_COMMAND4=0
case "${1:-}" in
  "") ;;
  --with-command4-mixed-transition) WITH_COMMAND4=1 ;;
  *) usage ;;
esac

[[ -d "$SOURCE_DIR" ]] || { echo "source directory does not exist: $SOURCE_DIR" >&2; exit 1; }
cd "$SOURCE_DIR"

TESTS=(
  tests/model_executor/test_cohere2_moe_eagle.py
  tests/v1/spec_decode/test_dflash_causality.py
)
if [[ "$WITH_COMMAND4" -eq 1 ]]; then
  TESTS+=(tests/reasoning/test_command4_mixed_transition.py)
fi

for test_file in "${TESTS[@]}"; do
  [[ -f "$test_file" ]] || { echo "missing patched source test: $test_file" >&2; exit 1; }
done

exec python3 -m pytest -q "${TESTS[@]}"
