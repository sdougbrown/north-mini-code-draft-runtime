#!/usr/bin/env python3
"""Dependency-free checks for the prepared vLLM source tree."""

from __future__ import annotations

import argparse
from pathlib import Path


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"missing {label}: {needle}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--with-command4-mixed-transition", action="store_true")
    args = parser.parse_args()
    root = args.source

    cohere = (root / "vllm/model_executor/models/cohere2_moe.py").read_text()
    require(cohere, "EagleModelMixin", "Cohere Eagle mixin")
    require(cohere, "SupportsEagle3", "Cohere Eagle3 interface")
    require(cohere, "self.aux_hidden_state_layers", "auxiliary-state capture")
    require(cohere, "return hidden_states, aux_hidden_states", "auxiliary-state return")

    # These exact-checkpoint DSpark and reasoning-budget fixes are baseline
    # requirements of the pinned current-main commit, not companion patches.
    algos = (root / "vllm/transformers_utils/configs/speculators/algos.py").read_text()
    require(algos, 'pre_trained_config["sample_from_anchor"]', "DSpark anchor mapping")
    require(algos, 'pre_trained_config["target_layer_ids"]', "DSpark target-layer mapping")
    dspark = (root / "vllm/v1/worker/gpu/spec_decode/dspark/speculator.py").read_text()
    require(dspark, 'getattr(\n            self.draft_model_config.hf_config, "sample_from_anchor", True', "DSpark query layout")
    thinking = root / "vllm/v1/worker/gpu/sample/thinking_budget.py"
    if not thinking.is_file():
        raise SystemExit("pinned source is missing Model Runner V2 thinking-budget support")

    if args.with_command4_mixed_transition:
        reasoning = (root / "vllm/reasoning/cohere_command_reasoning_parser.py").read_text()
        require(reasoning, "preserve_mixed_reasoning_transition", "optional parser switch")
        require(reasoning, 'msg.content = "".join(content_parts)', "ordered mixed-transition handoff")
        test = root / "tests/reasoning/test_command4_mixed_transition.py"
        if not test.is_file():
            raise SystemExit("optional parser regression test is missing")

    print("patched source verification passed")


if __name__ == "__main__":
    main()
