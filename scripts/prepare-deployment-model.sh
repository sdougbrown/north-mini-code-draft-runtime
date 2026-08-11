#!/usr/bin/env bash
# Render a local deployment bundle for a North draft package with a
# locally-resolvable verifier, so serving does not re-download the target.
#
# The release config.json embeds the verifier as a Hub ID
# (speculators_config.verifier.name_or_path). vLLM reads that field and sets
# the verifier/tokenizer to it directly; there is no --override-config hook on
# the pinned source. This script writes a deployment copy of the draft config
# with the verifier pointed at VERIFIER_MODEL, and symlinks the release weights
# into the bundle, so the bundle is a complete, self-contained model directory
# vLLM can serve. The shipped release config is never modified.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/prepare-deployment-model.sh <dflash|dspark>

Env:
  DFLASH_MODEL   draft package directory (default /models/North-Mini-Code-1.0-dflash)
  DSPARK_MODEL   draft package directory (default /models/North-Mini-Code-1.0-dspark)
  VERIFIER_MODEL verifier location (default: Hub ID embedded in the draft config).
                 Set to a local directory (e.g. /models/North-Mini-Code-1.0-w4a16)
                 to serve from local storage and skip the Hub download. Must be
                 a directory or Hub ID the model loader can resolve.

Prints the deployment bundle path on stdout. Point DFLASH_MODEL/DSPARK_MODEL at
that path (e.g. `export DFLASH_MODEL=$(scripts/prepare-deployment-model.sh dflash)`).
EOF
  exit 64
}

[[ $# -eq 1 ]] || usage
FLAVOR=$1
case "$FLAVOR" in
  dflash) MODEL_VAR="DFLASH_MODEL"; DEFAULT_MODEL="/models/North-Mini-Code-1.0-dflash" ;;
  dspark) MODEL_VAR="DSPARK_MODEL"; DEFAULT_MODEL="/models/North-Mini-Code-1.0-dspark" ;;
  *) usage ;;
esac

SOURCE_MODEL="${!MODEL_VAR:-$DEFAULT_MODEL}"
[[ -f "$SOURCE_MODEL/config.json" ]] || { echo "draft package has no config.json: $SOURCE_MODEL" >&2; exit 1; }

# Resolve the embedded verifier so we can default to it when unset and record it.
EMBEDDED_VERIFIER=$(python3 - "$SOURCE_MODEL/config.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["speculators_config"]["verifier"]["name_or_path"])
PY
)
VERIFIER_MODEL="${VERIFIER_MODEL:-$EMBEDDED_VERIFIER}"

RUNTIME_WORK="${RUNTIME_WORK:-$ROOT/.work}"
DEPLOY_DIR="$RUNTIME_WORK/deploy/$FLAVOR"
mkdir -p "$DEPLOY_DIR"

# Render the deployment config with the verifier overridden. Everything else is
# byte-identical to the release config.
python3 - "$SOURCE_MODEL/config.json" "$DEPLOY_DIR/config.json" "$VERIFIER_MODEL" <<'PY'
import json, sys
src, dst, verifier = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(src))
cfg["speculators_config"]["verifier"]["name_or_path"] = verifier
tmp = dst + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
import os
os.rename(tmp, dst)
PY

# Symlink every other release file (weights, remote config) into the bundle.
shopt -s dotglob nullglob
for f in "$SOURCE_MODEL"/*; do
  base=$(basename "$f")
  [[ "$base" == "config.json" ]] && continue
  if [[ ! -e "$DEPLOY_DIR/$base" ]]; then
    ln -s "$f" "$DEPLOY_DIR/$base"
  fi
done

echo "prepared $FLAVOR deployment bundle: $DEPLOY_DIR"
echo "  verifier: $VERIFIER_MODEL (embedded default: $EMBEDDED_VERIFIER)" >&2
