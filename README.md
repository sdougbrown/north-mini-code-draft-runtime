# North Mini Code draft runtime

A source-built, local runtime recipe for North Mini Code DFlash and DSpark
draft packages. It is **not** a published image. `compose.yaml` uses a local
image tag and `pull_policy: never`. Compose therefore cannot fetch an
unpublished image from a registry.

## What is pinned

- vLLM: `83ad767eed3be3ee7f2df63be693bfaca5c7c922`
- Required patch: PR #49819 (`49819-cohere2moe-eagle3-aux-states.patch`)
- Optional, source-regression-only patch: Command 4 mixed transition
- Runtime Python dependency: `cohere_melody==0.12.0`

`runtime-manifest.json` records the exact patch digests. See
[PATCH_SCOPE.md](PATCH_SCOPE.md) for upstream/obsolete-overlay boundaries and
validation limits.

## Configure

```bash
cp .env.example .env
# Edit MODEL_ROOT and either keep /models/... values or replace each model
# value with a Hugging Face Hub ID. Set HF_TOKEN if the Hub model requires it.
```

The draft package itself is the top-level `vllm serve` model. Its embedded
speculators-format configuration is used natively; no external `Speculators`
package, bridge, or separate target-model command is installed.

### Serve from local verifier storage

The release draft `config.json` embeds the verifier as a Hub ID
(`speculators_config.verifier.name_or_path`), so vLLM re-downloads the target
from the Hub on first load even when it is already local. To serve from a local
directory instead, render a deployment bundle that overrides only that field:

```bash
# Point the verifier at a local copy of the target (must include its tokenizer).
VERIFIER_MODEL=/models/North-Mini-Code-1.0-w4a16 RUNTIME_WORK="$MODEL_ROOT/.deploy" \
  ./scripts/prepare-deployment-model.sh dflash
# Set DFLASH_MODEL to the printed bundle path, e.g.:
#   DFLASH_MODEL=/models/.deploy/dflash
```

The script writes a self-contained model directory (override `config.json` plus
symlinked weights) under `RUNTIME_WORK/deploy/<flavor>`; it never modifies the
release config. Leave `VERIFIER_MODEL` unset to keep the embedded Hub ID.

## Build a local image

```bash
./scripts/build-image.sh
# Only if deliberately evaluating the source-only parser regression:
./scripts/build-image.sh --with-command4-mixed-transition
```

The build script clones and fetches only into ignored `.work/vllm`. It verifies
the commit and patch hashes, then applies patches without 3-way or fuzz
fallback. Next, it runs dependency-free source checks and builds vLLM's
`vllm-openai` target. It layers `Dockerfile.runtime` and verifies the patched
model interface in the final image. It does not copy host native binaries or
use a prebuilt local vLLM image. Set `RUN_SOURCE_PYTEST=1` only on a host that
can run the focused upstream pytest files before the build.

The result is a local tag such as
`north-mini-code-runtime:83ad767eed3be3ee7f2df63be693bfaca5c7c922-49819`.
Set `RUNTIME_IMAGE` in `.env` if a different local tag is used.

## Run one draft flavor

Profiles are opt-in: plain `docker compose up` starts neither service. Start
one profile, or explicitly name both profiles if that is intentional.

```bash
docker compose --profile dflash up -d dflash
docker compose --profile dspark up -d dspark
# Explicitly opt into both only when resources allow it:
docker compose --profile dflash --profile dspark up -d
```

Both services default to TP=1, `VLLM_USE_V2_MODEL_RUNNER=1`, and the Cohere
Command 4 reasoning/tool parsers. They mount the configured model root
read-only and persist caches in named volumes. They use all GPUs, host IPC, and
health checks on separate host ports. The default GPU memory fraction is 0.75.
This leaves unified-memory headroom on GB10; raise it only after a local startup
gate.

## Verify and smoke test

```bash
python3 scripts/verify-patches.py
python3 -m unittest tests/test_runtime_static.py
./scripts/smoke.sh dflash
# Add --generate to submit one minimal completion after readiness.
```

For source applicability, point verification at a clean checkout exactly at
the pin:

```bash
python3 scripts/verify-patches.py --source .work/vllm
```

No GPU image build has occurred for this repository snapshot. As recorded in
`PATCH_SCOPE.md`, unavailable CUDA flash-attention extensions blocked host
pytest. This result is not end-to-end serving validation.
