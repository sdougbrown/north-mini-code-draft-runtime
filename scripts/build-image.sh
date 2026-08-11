#!/usr/bin/env bash
# Build a local runtime image from the pinned vLLM source and recorded patches.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly VLLM_REPOSITORY="https://github.com/vllm-project/vllm.git"
readonly VLLM_COMMIT="83ad767eed3be3ee7f2df63be693bfaca5c7c922"
readonly REQUIRED_PATCH="$ROOT/patches/49819-cohere2moe-eagle3-aux-states.patch"
readonly OPTIONAL_PATCH="$ROOT/patches/optional-command4-mixed-transition.patch"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-image.sh [--with-command4-mixed-transition]

Builds a local image only. Set VLLM_SOURCE_DIR (relative to .work/),
RUNTIME_TAG, or RUNTIME_IMAGE to override local build names.
EOF
  exit 64
}

WITH_COMMAND4=0
case "${1:-}" in
  "") ;;
  --with-command4-mixed-transition) WITH_COMMAND4=1 ;;
  *) usage ;;
esac

# Keeping the checkout under ignored .work prevents a host checkout or a
# prebuilt local image from becoming an implicit build input.
SOURCE_REL=${VLLM_SOURCE_DIR:-.work/vllm}
case "$SOURCE_REL" in
  .work/*) ;;
  *) echo "VLLM_SOURCE_DIR must be relative to .work/: $SOURCE_REL" >&2; exit 64 ;;
esac
SOURCE_DIR="$ROOT/$SOURCE_REL"
RUNTIME_TAG=${RUNTIME_TAG:-"${VLLM_COMMIT}-49819"}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-"north-mini-code-runtime:${RUNTIME_TAG}"}
UPSTREAM_IMAGE="${RUNTIME_IMAGE}-vllm-openai-build"

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "required command not found: $1" >&2; exit 127; }
}
require_command git
require_command docker
require_command python3

python3 "$ROOT/scripts/verify-patches.py"
mkdir -p "$(dirname "$SOURCE_DIR")"
if [[ ! -e "$SOURCE_DIR" ]]; then
  git clone --no-checkout "$VLLM_REPOSITORY" "$SOURCE_DIR"
fi
[[ -d "$SOURCE_DIR/.git" ]] || { echo "not a vLLM checkout: $SOURCE_DIR" >&2; exit 1; }

origin_url=$(git -C "$SOURCE_DIR" remote get-url origin)
[[ "$origin_url" == "$VLLM_REPOSITORY" ]] || {
  echo "unexpected vLLM origin: $origin_url" >&2
  exit 1
}

# Fetch the exact object every time; do not silently use a local branch or tag.
git -C "$SOURCE_DIR" fetch --no-tags origin "$VLLM_COMMIT"
git -C "$SOURCE_DIR" checkout --detach "$VLLM_COMMIT"
git -C "$SOURCE_DIR" reset --hard "$VLLM_COMMIT"
git -C "$SOURCE_DIR" clean -ffdqx
[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$VLLM_COMMIT" ]] || {
  echo "checked-out vLLM commit does not match the required pin" >&2
  exit 1
}

verify_args=(--source "$SOURCE_DIR")
if [[ "$WITH_COMMAND4" -eq 1 ]]; then
  verify_args+=(--with-command4-mixed-transition)
fi
python3 "$ROOT/scripts/verify-patches.py" "${verify_args[@]}"

# --check and the real apply are both intentionally strict: no --3way, no
# fuzz, and no conflict-resolution fallback can change the reviewed delta.
git -C "$SOURCE_DIR" apply --check --whitespace=error "$REQUIRED_PATCH"
git -C "$SOURCE_DIR" apply --index --whitespace=error "$REQUIRED_PATCH"
if [[ "$WITH_COMMAND4" -eq 1 ]]; then
  git -C "$SOURCE_DIR" apply --check --whitespace=error "$OPTIONAL_PATCH"
  git -C "$SOURCE_DIR" apply --index --whitespace=error "$OPTIONAL_PATCH"
fi

source_test_args=("$SOURCE_DIR")
if [[ "$WITH_COMMAND4" -eq 1 ]]; then
  source_test_args+=(--with-command4-mixed-transition)
fi
python3 "$ROOT/scripts/verify-patched-source.py" "${source_test_args[@]}"
if [[ "${RUN_SOURCE_PYTEST:-0}" == 1 ]]; then
  "$ROOT/scripts/run-source-tests.sh" "${source_test_args[@]}"
else
  echo "Skipping optional host pytest (set RUN_SOURCE_PYTEST=1 in a source-test-capable environment)."
fi

# The first image is built from source in this invocation. Dockerfile.runtime
# only layers Python requirements over that target; it copies no native output.
docker build \
  --file "$SOURCE_DIR/docker/Dockerfile" \
  --target vllm-openai \
  --tag "$UPSTREAM_IMAGE" \
  "$SOURCE_DIR"
docker build \
  --file "$ROOT/Dockerfile.runtime" \
  --build-arg "BASE_IMAGE=$UPSTREAM_IMAGE" \
  --tag "$RUNTIME_IMAGE" \
  "$ROOT"

# Import the patched model class from the actual final image. This catches a
# stale Docker context or overlay that did not contain the reviewed source.
docker run --rm --entrypoint python3 "$RUNTIME_IMAGE" - <<'PY'
from vllm.model_executor.models.cohere2_moe import Cohere2MoeForCausalLM
from vllm.model_executor.models.interfaces import supports_eagle3
assert supports_eagle3(Cohere2MoeForCausalLM)
print("final image Cohere2MoE Eagle3 import passed")
PY

echo "Built local runtime image: $RUNTIME_IMAGE"
