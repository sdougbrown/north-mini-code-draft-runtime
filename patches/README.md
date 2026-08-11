# Patch provenance

`49819-cohere2moe-eagle3-aux-states.patch` is required. Its provenance JSON pins
both the upstream PR head and the locally verified clean cherry-pick result.
`runtime-manifest.json` records its SHA-256.

`optional-command4-mixed-transition.patch` is deliberately **not** enabled by
default. It is a current-main port of the old Command 4 mixed-token phase-handoff
repair plus a focused parser regression. Enable it only with
`./scripts/build-image.sh --with-command4-mixed-transition` after reviewing its
source-level test; it has not received an end-to-end speculative-serving run on
this pin.
