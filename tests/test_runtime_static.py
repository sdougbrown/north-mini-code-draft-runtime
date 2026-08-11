#!/usr/bin/env python3
"""Fast, dependency-free guardrails for this source-built runtime recipe."""

from __future__ import annotations

import hashlib
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class RuntimeRecipeStaticTests(unittest.TestCase):
    def test_manifest_hashes_and_provenance_match_files(self) -> None:
        manifest_text = (ROOT / "runtime-manifest.json").read_text()
        self.assertNotIn("TO_BE_FILLED", manifest_text)
        manifest = json.loads(manifest_text)
        for patch in manifest["patches"]:
            data = (ROOT / patch["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), patch["sha256"])
        provenance = json.loads(
            (ROOT / "patches/49819-cohere2moe-eagle3-aux-states.provenance.json").read_text()
        )
        self.assertEqual(provenance["patch_sha256"], manifest["patches"][0]["sha256"])

    def test_shell_scripts_parse(self) -> None:
        for script in (ROOT / "scripts").glob("*.sh"):
            subprocess.run(["bash", "-n", str(script)], check=True)

    def test_build_is_pinned_strict_and_source_built(self) -> None:
        script = (ROOT / "scripts/build-image.sh").read_text()
        self.assertIn("83ad767eed3be3ee7f2df63be693bfaca5c7c922", script)
        self.assertIn('fetch --no-tags origin "$VLLM_COMMIT"', script)
        self.assertIn('apply --check --whitespace=error "$REQUIRED_PATCH"', script)
        self.assertIn('apply --index --whitespace=error "$REQUIRED_PATCH"', script)
        self.assertNotIn("git am", script)
        self.assertIn("--target vllm-openai", script)
        self.assertIn("Dockerfile.runtime", script)
        self.assertIn("verify-patched-source.py", script)
        self.assertIn("RUN_SOURCE_PYTEST", script)
        self.assertIn("final image Cohere2MoE Eagle3 import passed", script)
        self.assertIn('SOURCE_REL=${VLLM_SOURCE_DIR:-.work/vllm}', script)

    def test_overlay_does_not_copy_native_artifacts(self) -> None:
        dockerfile = (ROOT / "Dockerfile.runtime").read_text()
        self.assertIn("ARG BASE_IMAGE", dockerfile)
        self.assertNotIn("COPY --from=", dockerfile)
        self.assertNotIn(".so", dockerfile)
        self.assertNotIn(".whl", dockerfile)

    def test_compose_profiles_are_opt_in_and_models_are_top_level(self) -> None:
        compose = (ROOT / "compose.yaml").read_text()
        self.assertIn("profiles: [dflash]", compose)
        self.assertIn("profiles: [dspark]", compose)
        self.assertIn("pull_policy: never", compose)
        self.assertIn("gpus: all", compose)
        self.assertIn("ipc: host", compose)
        self.assertIn("VLLM_USE_V2_MODEL_RUNNER", compose)
        self.assertIn("${DFLASH_MODEL:?", compose)
        self.assertIn("${DSPARK_MODEL:?", compose)
        self.assertEqual(compose.count("--tool-call-parser"), 2)
        self.assertEqual(compose.count("--reasoning-parser"), 2)
        self.assertIn("${GPU_MEMORY_UTILIZATION:-0.75}", compose)
        self.assertNotIn("--speculative-config", compose)

    def test_scope_records_known_limits(self) -> None:
        scope = " ".join((ROOT / "PATCH_SCOPE.md").read_text().lower().split())
        for phrase in (
            "pr #49819",
            "already upstream",
            "obsolete",
            "affects training reproducibility, not serving",
            "source-level regression-test coverage",
            "lacked cuda flash-attention extensions",
            "no gpu image build has occurred",
        ):
            self.assertIn(phrase, scope)


if __name__ == "__main__":
    unittest.main()
