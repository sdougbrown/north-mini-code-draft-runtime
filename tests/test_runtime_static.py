#!/usr/bin/env python3
"""Fast, dependency-free guardrails for the overlay runtime recipe."""

from __future__ import annotations

import hashlib
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class RuntimeRecipeStaticTests(unittest.TestCase):
    def test_manifest_hashes_and_provenance_match_files(self) -> None:
        manifest = json.loads(
            (ROOT / "runtime-manifest.json").read_text()
        )
        searches_provenance = False
        for patch in manifest["patches"]:
            data = (ROOT / patch["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), patch["sha256"])
            if patch["path"].endswith("49819-cohere2moe-eagle3-aux-states.patch"):
                searches_provenance = True
                provenance = json.loads(
                    (ROOT
                     / "patches/49819-cohere2moe-eagle3-aux-states.provenance.json")
                    .read_text()
                )
                self.assertEqual(provenance["patch_sha256"], patch["sha256"])
        self.assertTrue(searches_provenance)

    def test_shell_scripts_parse(self) -> None:
        for script in (ROOT / "scripts").glob("*.sh"):
            subprocess.run(["bash", "-n", str(script)], check=True)

    def test_overlay_uses_official_base_and_two_patches(self) -> None:
        build = (ROOT / "scripts/build-image.sh").read_text()
        self.assertIn("vllm/vllm-openai", build)
        self.assertIn("49819-cohere2moe-eagle3-aux-states.patch", build)
        self.assertIn("50937-skip-empty-expert-bias.patch", build)
        self.assertNotIn("vllm/vllm-openai-cuda", build)  # no local patched fork chain

    def test_main_scripts_referenced_and_present(self) -> None:
        for script in ("build-image.sh", "smoke.sh",
                       "prepare-deployment-model.sh", "healthcheck.py"):
            self.assertTrue((ROOT / "scripts" / script).exists())

    def test_compose_build_with_empty_context(self) -> None:
        # build-image.sh must send only a small staging dir to the daemon.
        build = (ROOT / "scripts/build-image.sh").read_text()
        self.assertIn('mktemp -d', build)
        self.assertIn('"$STAGE"', build)


if __name__ == "__main__":
    unittest.main()
