#!/usr/bin/env bash
# Build a thin North runtime image on top of the official published vLLM base.
# The base already carries stock DFlash/DSpark support and MRV2 thinking
# budgets. Two small pure-Python upstream patches are overlayed:
#   PR #49819  Cohere2MoE Eagle3 auxiliary hidden states (needed by the draft).
#   PR #50937  Skip empty/unused expert bias on load (our checkpoint ships an
#              all-zero per-expert bias; releases predate this fix).
# Nothing is compiled from source, and the same flow works on x86_64 and
# arm64/GB10.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VLLM_VERSION="${VLLM_VERSION:-v0.27.1}"
readonly PATCH_AUX="$ROOT/patches/49819-cohere2moe-eagle3-aux-states.patch"
readonly PATCH_BIAS="$ROOT/patches/50937-skip-empty-expert-bias.patch"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-image.sh

Builds the local North runtime overlay image. Env overrides:
  BASE_IMAGE    official vLLM base to layer on (default chosen by host arch)
  VLLM_VERSION  released vLLM version (default v0.27.1)
  RUNTIME_TAG   image tag (default: <version>-49819-50937-<arch>)
  RUNTIME_IMAGE full image name (default north-mini-code-runtime:<tag>)
EOF
  exit 64
}

for cmd in git docker curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "required command not found: $cmd" >&2; exit 127; }
done

RAW_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
[ -z "$RAW_ARCH" ] || [ "$RAW_ARCH" = "unknown" ] && RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported docker architecture: $RAW_ARCH" >&2; exit 64 ;;
esac
case "$ARCH" in
  amd64)  DEFAULT_BASE="vllm/vllm-openai:${VLLM_VERSION}-cu129-ubuntu2404" ;;
  arm64)  DEFAULT_BASE="vllm/vllm-openai:${VLLM_VERSION}-aarch64-cu129-ubuntu2404" ;;
esac
BASE_IMAGE="${BASE_IMAGE:-$DEFAULT_BASE}"
RUNTIME_TAG="${RUNTIME_TAG:-${VLLM_VERSION}-49819-50937-${ARCH}}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-north-mini-code-runtime:${RUNTIME_TAG}}"

echo "Base:  $BASE_IMAGE"
echo "Arch:  $ARCH"
echo "Image: $RUNTIME_IMAGE"

# Render both patched modules in a temp dir OUTSIDE the git repo. git apply
# resolves patch paths against the repo root when run inside a working tree,
# which silently skips the files here; a non-repo staging dir applies cleanly.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/north-overlay.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/cohere-src/vllm/model_executor/models"
mkdir -p "$STAGE/cohere-src/vllm/model_executor/layers/fused_moe"

RAW_BASE="https://raw.githubusercontent.com/vllm-project/vllm/${VLLM_VERSION}"

# 1) cohere2_moe.py  <- PR #49819 (Cohere2MoE aux hidden states)
curl -fsSL "$RAW_BASE/vllm/model_executor/models/cohere2_moe.py" \
  -o "$STAGE/cohere-src/vllm/model_executor/models/cohere2_moe.py"
(
  cd "$STAGE/cohere-src"
  git apply --exclude='tests/*' --check --whitespace=error "$PATCH_AUX" >/dev/null
  git apply --exclude='tests/*' --whitespace=error "$PATCH_AUX"
)
cp "$STAGE/cohere-src/vllm/model_executor/models/cohere2_moe.py" "$STAGE/cohere2_moe.py"

# 2) routed_experts.py  <- PR #50937 (skip empty expert bias)
curl -fsSL "$RAW_BASE/vllm/model_executor/layers/fused_moe/routed_experts.py" \
  -o "$STAGE/cohere-src/vllm/model_executor/layers/fused_moe/routed_experts.py"
(
  cd "$STAGE/cohere-src"
  git apply --check --whitespace=error "$PATCH_BIAS" >/dev/null
  git apply --whitespace=error "$PATCH_BIAS"
)
cp "$STAGE/cohere-src/vllm/model_executor/layers/fused_moe/routed_experts.py" "$STAGE/routed_experts.py"

cp "$ROOT/requirements/runtime.txt" "$STAGE/runtime.txt"
cp "$ROOT/scripts/healthcheck.py" "$STAGE/healthcheck.py"

docker build \
  -f "$ROOT/Dockerfile.overlay" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --tag "$RUNTIME_IMAGE" \
  "$STAGE"

echo "Built local runtime image: $RUNTIME_IMAGE"
echo "  base $BASE_IMAGE, arch $ARCH"
