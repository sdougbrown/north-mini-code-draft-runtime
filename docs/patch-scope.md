# Runtime patch scope

| Item | Classification | Included? | Rationale |
| --- | --- | --- | --- |
| vLLM PR #49819 / `b7998e5…` | **Required local patch** | Yes | North drafts need Cohere2MoE Eagle3 auxiliary states. The exact patch applies to `83ad767…`. |
| DSpark support: #47093, #47745, #48113/#48524, #48639 | **Current-main baseline** | No backport | The pin includes all listed DSpark support. |
| MRV2 thinking budgets: #46727 | **Current-main baseline** | No backport | Already present at the pin; `VLLM_USE_V2_MODEL_RUNNER=1` remains the selected North path. |
| Command 4 mixed structural-token transition | **Optional correctness patch** | Opt-in only | A mixed speculative batch can lose its post-`END_THINKING` suffix. This patch preserves the suffix and adds a source-level regression test. It is not upstream or end-to-end validated on this pin. |
| Deterministic Marlin #48032 | **Training reproducibility** | No | It is not required to build or serve this minimal image. |
| `qwen3-dspark-top-level-dflash-config` | **Obsolete overlay** | No | Current main natively recognizes speculators-format DFlash/DSpark configuration. |
| Local MRV2 budget patch | **Obsolete overlay** | No | Superseded by current main #46727. |
| Zero Cohere expert-bias filter | **Obsolete compatibility overlay** | No | This was a v0.25.1-era workaround. No current-main evidence shows it is needed. Filtering future nonzero bias would be unsafe. |

The optional Command 4 patch does not prove merged behavior. Validate it before public deployment:

1. Run the parser regression.
2. Run a real speculative stream with `return_token_ids=true`.
3. Capture the mixed batch.
4. Run a sequential tool-call canary.
