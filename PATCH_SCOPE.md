# Patch scope for the official-base runtime overlay

The runtime is a **thin overlay on the official published `vllm/vllm-openai`
image at release `v0.27.1`**. The base already carries stock DFlash/DSpark
support and Model Runner V2 thinking budgets upstream, so nothing is compiled
from source.

Two small pure-Python patches are copied over the installed modules by
`scripts/build-image.sh` (see `runtime-manifest.json` for digests):

- **PR #49819** — Cohere2MoE Eagle3 auxiliary hidden states. Required: the North
  DFlash/DSpark speculator reads verifier hidden states that stock Cohere2MoE
  never exposes.
- **PR #50937** — Skip loading an empty/unused expert bias when the model has no
  bias param. North checkpoints ship an all-zero per-expert bias; every released
  vLLM predates this fix, so without it target weight loading raises
  `AttributeError: 'RoutedExperts' object has no attribute 'w2_bias'`.

Both are absent from released vLLM purely by timing (our own open PR, and a
post-release bugfix respectively). They are pure Python, render against the
release files cleanly, and work identically on x86_64 and arm64/GB10.

The deterministic-Marlin repro concern (#48032) affects training
reproducibility, not serving, and is intentionally not carried. The former
Command 4 source patch and the v0.25.1 local overlay are obsolete on this base
and removed.
