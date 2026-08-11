# Patch scope on the pinned current-main snapshot

See [docs/patch-scope.md](docs/patch-scope.md) for the detailed change-by-change table.

The runtime pins vLLM at `83ad767eed3be3ee7f2df63be693bfaca5c7c922`.
Basic North DFlash/DSpark support needs **PR #49819** on this pin. The patch adds Cohere2MoE auxiliary hidden-state export at the layer boundaries required by Eagle3 draft packages.

DSpark compatibility and the MRV2 thinking budget are already upstream on this
pin. The zero-bias v0.25.1 overlay and the old DSpark bridge are obsolete on
this pin and are intentionally not carried. Deterministic Marlin #48032 is omitted because it affects training reproducibility, not serving.

The optional Command 4 repair currently has only source-level regression-test coverage. Enable it with
`--with-command4-mixed-transition`. End-to-end speculative-serving validation
remains pending.

PR #49819 cherry-picks cleanly. Host pytest did not run because the environment lacked CUDA flash-attention extensions. No GPU image build has occurred.
