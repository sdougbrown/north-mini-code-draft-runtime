#!/usr/bin/env python3
"""Verify the recorded patch digests and, optionally, their base-source applicability."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "runtime-manifest.json"


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="clean vLLM checkout at the manifest commit")
    parser.add_argument(
        "--with-command4-mixed-transition",
        action="store_true",
        help="also check the optional parser patch against --source",
    )
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text())
    if "TO_BE_FILLED" in MANIFEST_PATH.read_text():
        raise SystemExit("runtime-manifest.json contains an unfilled value")

    selected_patches: list[Path] = []
    for patch in manifest["patches"]:
        path = ROOT / patch["path"]
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != patch["sha256"]:
            raise SystemExit(f"SHA-256 mismatch for {patch['path']}: {digest}")
        if patch["required"] or args.with_command4_mixed_transition:
            selected_patches.append(path)
        print(f"verified digest: {patch['path']}")

    provenance_path = ROOT / "patches/49819-cohere2moe-eagle3-aux-states.provenance.json"
    provenance = json.loads(provenance_path.read_text())
    required_digest = manifest["patches"][0]["sha256"]
    if provenance["patch_sha256"] != required_digest:
        raise SystemExit("required patch digest differs from its provenance record")

    if args.source is None:
        return 0
    source = args.source.resolve()
    if not (source / ".git").exists():
        raise SystemExit(f"not a git checkout: {source}")
    expected_commit = manifest["upstream"]["commit"]
    actual_commit = run("git", "rev-parse", "HEAD", cwd=source)
    if actual_commit != expected_commit:
        raise SystemExit(f"source is {actual_commit}, expected {expected_commit}")
    if run("git", "status", "--porcelain", cwd=source):
        raise SystemExit("source checkout is not clean")

    for patch in selected_patches:
        # Deliberately no --3way: a context mismatch must stop the build.
        run("git", "apply", "--check", "--whitespace=error", str(patch), cwd=source)
        print(f"verified applicability: {patch.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.output)
        raise SystemExit(error.returncode)
