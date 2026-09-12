#!/usr/bin/env python3
"""Generate truthful, target-specific runtime capability metadata."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


SUPPORTED_IDS = {"input.mapping", "macos.window-isolation", "host.bridge"}
SUPPORTED_TARGETS = {"linux-x86_64", "macos-x86_64"}


def runtime_document(manifest: dict[str, object], target: str) -> dict[str, object]:
    if target not in SUPPORTED_TARGETS:
        raise ValueError(f"unsupported target: {target}")
    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, dict) or capabilities.get("protocol") != 1:
        raise ValueError("unsupported or missing capability protocol")
    declarations = capabilities.get("declarations")
    if not isinstance(declarations, list):
        raise ValueError("capability declarations must be an array")
    patches = manifest.get("build", {}).get("patches", [])  # type: ignore[union-attr]
    patch_targets = {
        patch["path"]: set(patch["targets"])
        for patch in patches
        if isinstance(patch, dict)
    }
    provided: list[dict[str, object]] = []
    seen: set[str] = set()
    for declaration in declarations:
        if not isinstance(declaration, dict):
            raise ValueError("capability declaration must be an object")
        capability_id = declaration.get("id")
        if capability_id not in SUPPORTED_IDS:
            raise ValueError(f"unknown capability: {capability_id}")
        if capability_id in seen:
            raise ValueError(f"duplicate capability: {capability_id}")
        seen.add(str(capability_id))
        targets = declaration.get("targets")
        if not isinstance(targets, list) or not targets:
            raise ValueError(f"capability {capability_id} has no targets")
        if declaration.get("state") != "provided" or target not in targets:
            continue
        evidence = declaration.get("evidence_patches")
        if not isinstance(evidence, list) or not evidence:
            raise ValueError(f"provided capability {capability_id} lacks patch evidence")
        for patch_path in evidence:
            if target not in patch_targets.get(patch_path, set()):
                raise ValueError(
                    f"provided capability {capability_id} patch {patch_path} "
                    f"does not apply to {target}"
                )
        provided.append(declaration)
    return {
        "schema_version": 1,
        "kind": "wineforge-engine-capabilities",
        "engine_id": manifest["id"],
        "target": target,
        "protocol": 1,
        "provided": provided,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("target", choices=sorted(SUPPORTED_TARGETS))
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    document = runtime_document(manifest, args.target)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
