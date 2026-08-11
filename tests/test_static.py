#!/usr/bin/env python3
"""Dependency-free recipe checks; no model download, Docker build, or GPU use."""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PIN = "83ad767eed3be3ee7f2df63be693bfaca5c7c922"
PR_COMMIT = "b7998e5bb3549883c015d12dbe073e72166feb83"


class StaticRecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / "runtime-manifest.json").read_text())
        cls.compose = (ROOT / "compose.yaml").read_text()

    def test_pin_and_required_pr_are_exact(self):
        self.assertEqual(self.manifest["upstream"]["commit"], PIN)
        required = next(p for p in self.manifest["patches"] if p["required"])
        self.assertEqual(required["pr_commit"], PR_COMMIT)
        self.assertEqual(required["local_cherry_pick_commit"][:9], "1fb63b52f")

    def test_manifest_patch_hashes_match_files(self):
        for patch in self.manifest["patches"]:
            data = (ROOT / patch["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), patch["sha256"])
            self.assertTrue(data.startswith(b"diff --git"))

    def test_required_parser_dependency_and_no_external_speculators(self):
        self.assertEqual(
            (ROOT / "requirements/runtime.txt").read_text().strip(),
            "# Required by vLLM's Cohere Command 4 reasoning and tool parsers.\n"
            "cohere_melody==0.12.0",
        )
        self.assertIn("Current vLLM reads speculators-format config natively", json.dumps(self.manifest))

    def test_model_defaults_are_configuration_only(self):
        # A static recipe must not inspect a developer's local model directory.
        env_example = (ROOT / ".env.example").read_text()
        self.assertIn("DFLASH_MODEL=/models/North-Mini-Code-1.0-dflash", env_example)
        self.assertIn("DSPARK_MODEL=/models/North-Mini-Code-1.0-dspark", env_example)
        self.assertIn("Hub IDs also work", env_example)

    def test_compose_profiles_and_interpolation_are_explicit(self):
        for profile, model, port in (
            ("dflash", "DFLASH_MODEL", "DFLASH_HOST_PORT"),
            ("dspark", "DSPARK_MODEL", "DSPARK_HOST_PORT"),
        ):
            block = re.search(rf"  {profile}:\n(.*?)(?=\n  \w+:|\nvolumes:)", self.compose, re.S)
            self.assertIsNotNone(block)
            text = block.group(1)
            self.assertIn(f"profiles: [{profile}]", text)
            self.assertIn(f"${{{model}:?", text)
            self.assertIn(f"${{{port}:-", text)
        # Shared settings live in the Compose extension anchor, then are merged
        # into each opt-in service.
        self.assertIn("VLLM_USE_V2_MODEL_RUNNER: ${VLLM_USE_V2_MODEL_RUNNER:-1}", self.compose)
        self.assertIn("gpus: all", self.compose)
        self.assertIn("ipc: host", self.compose)
        self.assertIn("healthcheck:", self.compose)
        self.assertEqual(self.compose.count("--tool-call-parser"), 2)
        self.assertEqual(self.compose.count("--reasoning-parser"), 2)
        self.assertIn("${GPU_MEMORY_UTILIZATION:-0.75}", self.compose)
        self.assertNotIn("--speculative_config", self.compose)

    def test_no_weights_or_optimizer_state_in_recipe(self):
        forbidden = re.compile(r"(\.safetensors(?:\.index\.json)?$|\.(?:bin|pt|pth|ckpt)$|optimizer|trainer_state)", re.I)
        offenders = [
            p.relative_to(ROOT).as_posix()
            for p in ROOT.rglob("*")
            if p.is_file() and ".git" not in p.parts and forbidden.search(p.name)
        ]
        self.assertEqual(offenders, [])

    def test_optional_patch_has_a_focused_regression(self):
        patch = (ROOT / "patches/optional-command4-mixed-transition.patch").read_text()
        self.assertIn("test_cmd4_preserves_structural_suffix", patch)
        self.assertIn("delta_token_ids=[18, 2, 4]", patch)
        self.assertIn("preserve_mixed_reasoning_transition=True", patch)
        self.assertIn('msg.content = "".join(content_parts)', patch)

    def test_reference_patch_chain_if_requested(self):
        reference = os.environ.get("VLLM_REFERENCE_REPO")
        if not reference:
            self.skipTest("set VLLM_REFERENCE_REPO to run source patch applicability check")
        result = subprocess.run(
            [str(ROOT / "scripts/verify-patches-against-reference.sh"), reference],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
