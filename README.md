# North Mini Code draft runtime

A thin runtime for serving North Mini Code **DFlash** and **DSpark** draft
packages, overlayed on the **official published vLLM image** so GB10 (arm64)
and x86_64 both work with no source compilation.

The image is built locally (tagged `pull_policy: never` in `compose.yaml`);
once published to a registry it can also be pulled directly.

## Base and patches

- Base: official `vllm/vllm-openai` at release **`v0.27.1`** (DFlash/DSpark
  support and MRV2 thinking budgets are stock; nothing is compiled).
- PR **#49819** — Cohere2MoE Eagle3 auxiliary hidden states (required by the
  draft).
- PR **#50937** — skip loading an empty expert bias (our checkpoints ship an
  all-zero per-expert bias; releases predate the fix).
- Runtime dependency: `cohere_melody==0.12.0`

`runtime-manifest.json` records exact digests; see
[PATCH_SCOPE.md](PATCH_SCOPE.md) for why these two are required but not
upstream.

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

## Build the local image

```bash
./scripts/build-image.sh
```

The script selects the official base by host arch, fetches the two release
files from the tagged vLLM source, applies the two patches as pure Python in a
temp staging dir (outside the git repo), and `docker build`s the thin overlay.
Nothing is compiled from source. Result example:

```
north-mini-code-runtime:v0.27.1-49819-50937-arm64
north-mini-code-runtime:v0.27.1-49819-50937-amd64
```

Set `BASE_IMAGE`, `VLLM_VERSION`, `RUNTIME_TAG`, or `RUNTIME_IMAGE` to override.

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
health checks on separate host ports. GPU memory fraction defaults to 0.75;
lower it when sharing the accelerator.

## Verify and smoke test

```bash
python3 -m unittest discover -s tests -v
./scripts/smoke.sh dflash --generate
./scripts/smoke.sh dspark --generate
```

Both DFlash K3 and DSpark K4 smoke tests have been run on NVIDIA GB10 (arm64)
against the local deployment bundles.
