#!/usr/bin/env bash
# Build a thin North runtime image on top of the official published vLLM base.
# The base already carries stock DFlash/DSpark support and MRV2 thinking
# budgets. The only non-upstream change is PR #49819 (a pure-Python addition of
# Cohere2MoE Eagle3 auxiliary hidden states), which is rendered and copied over
# the installed module. Nothing is compiled from source, and the same flow works
# on x86_64 and arm64/GB10.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VLLM_VERSION="${VLLM_VERSION:-0.27.1}"
readonly REQUIRED_PATCH="$ROOT/patches/49819-cohere2moe-eagle3-aux-states.patch"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-image.sh

Builds the local North runtime overlay image. Env overrides:
  BASE_IMAGE    official vLLM base to layer on (default chosen by host arch)
  VLLM_VERSION  released vLLM version (default 0.27.1)
  RUNTIME_TAG   image tag (default: <version>-49819-<arch>)
  RUNTIME_IMAGE full image name (default north-mini-code-runtime:<tag>)
EOF
  exit 64
}

for cmd in git docker curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "required command not found: $cmd" >&2; exit 127; }
done

ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
case "$ARCH" in
  amd64)  DEFAULT_BASE="vllm/vllm-openai:${VLLM_VERSION}-cu129-ubuntu2404" ;;
  arm64)  DEFAULT_BASE="vllm/vllm-openai:${VLLM_VERSION}-aarch64-cu129-ubuntu2404" ;;
  *) echo "unsupported docker architecture: $ARCH" >&2; exit 64 ;;
esac
BASE_IMAGE="${BASE_IMAGE:-$DEFAULT_BASE}"
RUNTIME_TAG="${RUNTIME_TAG:-${VLLM_VERSION}-49819-${ARCH}}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-north-mini-code-runtime:${RUNTIME_TAG}}"

echo "Base:  $BASE_IMAGE"
echo "Arch:  $ARCH"
echo "Image: $RUNTIME_IMAGE"

STAGE="$ROOT/.work/overlay"
rm -rf "$STAGE"
mkdir -p "$STAGE/cohere-src/vllm/model_executor/models"

# Fetch the released cohere2_moe.py and apply PR #49819 (functional change only;
# the bundled unit tests have no effect at runtime).
RAW="https://raw.githubusercontent.com/vllm-project/vllm/${VLLM_VERSION}/vllm/model_executor/models/cohere2_moe.py"
curl -fsSL "$RAW" -o "$STAGE/cohere-src/vllm/model_executor/models/cohere2_moe.py"
(
  cd "$STAGE/cohere-src"
  git apply --exclude='tests/*' --check --whitespace=error "$REQUIRED_PATCH"
  git apply --exclude='tests/*' --whitespace=error "$REQUIRED_PATCH"
)
cp "$STAGE/cohere-src/vllm/model_executor/models/cohere2_moe.py" "$STAGE/cohere2_moe.py"

cp "$ROOT/requirements/runtime.txt" "$STAGE/runtime.txt"
cp "$ROOT/scripts/healthcheck.py" "$STAGE/healthcheck.py"

docker build \
  -f "$ROOT/Dockerfile.overlay" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --tag "$RUNTIME_IMAGE" \
  "$STAGE"

echo "Built local runtime image: $RUNTIME_IMAGE"
echo "  base $BASE_IMAGE, arch $ARCH"
