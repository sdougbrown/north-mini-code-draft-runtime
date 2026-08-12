#!/usr/bin/env python3
"""Dependency-free recipe checks for the overlay runtime (no model download,
Docker build, or GPU use)."""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = "v0.27.1"
PR49819 = "b7998e5bb3549883c015d12dbe073e72166feb83"
PR50937 = "70456e5e6fb4ee86b8ffd985f918e44ba632d925"


class OverlayRecipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ROOT / "runtime-manifest.json").read_text())
        cls.compose = (ROOT / "compose.yaml").read_text()
        cls.build = (ROOT / "scripts/build-image.sh").read_text()
        cls.dockerfile = (ROOT / "Dockerfile.overlay").read_text()

    def test_official_released_base(self):
        self.assertEqual(self.manifest["base"]["release"], RELEASE)
        self.assertEqual(self.manifest["build"]["final_overlay"], "Dockerfile.overlay")
        self.assertIn(vllm_image := self.manifest["base"]["image"], self.build)
        self.assertIn("${VLLM_VERSION}", self.build)
        self.assertIn("DEFAULT_BASE=", self.build)

    def test_two_required_patches_with_matching_hashes(self):
        required = [p for p in self.manifest["patches"] if p["required"]]
        self.assertEqual(len(required), 2)
        by_pr = {p["upstream_pr"].rsplit("/", 1)[-1]: p for p in required}
        self.assertEqual(by_pr["49819"]["pr_commit"], PR49819)
        self.assertEqual(by_pr["50937"]["pr_commit"], PR50937)
        for patch in required:
            data = (ROOT / patch["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), patch["sha256"])
            self.assertTrue(data.startswith(b"diff --git"))
        # Both must be applied by build-image.sh
        for p in required:
            self.assertIn(p["path"].split("/")[-1], self.build)
            self.assertIn((ROOT / p["path"]).name, self.build)

    def test_no_from_source_compile(self):
        # No pinned-main clone, no manylinux docker build, no wheel compile.
        for forbidden in (
            "docker/Dockerfile",
            "--target vllm-openai",
            "fetch --no-tags origin",
            "VLLM_SOURCE_DIR",
            "manylinux",
            "RUNTIME_SOURCE_PYTEST" if False else "__never__",
        ):
            self.assertNotIn(forbidden, self.build)
        self.assertNotIn("git clone", self.build)

    def test_build_renders_and_applies_both_patches(self):
        # Render outside the repo, then apply with git apply (no index/am).
        self.assertIn("mktemp -d", self.build)
        self.assertIn("cohere2_moe.py", self.build)
        self.assertIn("routed_experts.py", self.build)
        self.assertIn("git apply --exclude='tests/*'", self.build)
        self.assertIn("--check --whitespace=error", self.build)
        self.assertNotIn("git am", self.build)

    def test_overlay_copies_patched_modules_only(self):
        self.assertIn("ARG BASE_IMAGE", self.dockerfile)
        self.assertIn("COPY cohere2_moe.py", self.dockerfile)
        self.assertIn("COPY routed_experts.py", self.dockerfile)
        self.assertIn("model_executor/models/cohere2_moe.py", self.dockerfile)
        self.assertIn("model_executor/layers/fused_moe/routed_experts.py", self.dockerfile)
        self.assertNotIn("COPY --from=", self.dockerfile)
        self.assertNotIn(".so", self.dockerfile)
        self.assertNotIn(".whl", self.dockerfile)

    def test_compose_profiles_are_opt_in_and_models_top_level(self):
        self.assertIn("profiles: [dflash]", self.compose)
        self.assertIn("profiles: [dspark]", self.compose)
        self.assertIn("pull_policy: never", self.compose)
        self.assertIn("gpus: all", self.compose)
        self.assertIn("ipc: host", self.compose)
        self.assertIn("VLLM_USE_V2_MODEL_RUNNER", self.compose)
        self.assertIn("${DFLASH_MODEL:?", self.compose)
        self.assertIn("${DSPARK_MODEL:?", self.compose)
        self.assertEqual(self.compose.count("--tool-call-parser"), 2)
        self.assertEqual(self.compose.count("--reasoning-parser"), 2)
        self.assertIn("${GPU_MEMORY_UTILIZATION:-0.75}", self.compose)
        self.assertNotIn("--speculative-config", self.compose)

    def test_required_parser_dependency_and_no_external_speculators(self):
        self.assertEqual(
            (ROOT / "requirements/runtime.txt").read_text().strip(),
            "# Required by vLLM's Cohere Command 4 reasoning and tool parsers.\n"
            "cohere_melody==0.12.0",
        )
        self.assertIn("does not import the external package", json.dumps(self.manifest))

    def test_model_defaults_are_configuration_only(self):
        env_example = (ROOT / ".env.example").read_text()
        self.assertIn("DFLASH_MODEL=/models/North-Mini-Code-1.0-dflash", env_example)
        self.assertIn("DSPARK_MODEL=/models/North-Mini-Code-1.0-dspark", env_example)
        self.assertIn("Hub IDs also work", env_example)

    def test_no_weights_or_optimizer_state_in_recipe(self):
        forbidden = re.compile(r"(\.safetensors(?:\.index\.json)?$|\.(?:bin|pt|pth|ckpt)$|optimizer|trainer_state)", re.I)
        offenders = [
            p.relative_to(ROOT).as_posix()
            for p in ROOT.rglob("*")
            if p.is_file() and ".git" not in p.parts and forbidden.search(p.name)
        ]
        self.assertEqual(offenders, [])

    def test_scope_records_known_limits(self):
        scope = " ".join((ROOT / "PATCH_SCOPE.md").read_text().lower().split())
        for phrase in (
            "pr #49819",
            "pr #50937",
            "compiled from source",
            "official",
        ):
            self.assertIn(phrase, scope)


if __name__ == "__main__":
    unittest.main(verbosity=2)
