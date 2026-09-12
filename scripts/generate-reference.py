#!/usr/bin/env python3
"""Generate a portable reference record without embedding engine bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def canonical_digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", type=Path)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    stage = args.stage.resolve(strict=True)
    artifact = args.artifact.resolve(strict=True)
    build_info_path = stage / "share/wineforge/build-info.json"
    build_info = json.loads(build_info_path.read_text())
    inventory: list[dict[str, object]] = []
    for path in sorted(stage.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(stage).as_posix()
        if relative == "share/wineforge/build-info.json":
            continue
        stat = path.lstat()
        item: dict[str, object] = {"path": relative, "mode": stat.st_mode & 0o7777}
        if path.is_symlink():
            item.update(type="symlink", target=os.readlink(path))
        elif path.is_file():
            item.update(type="file", size=stat.st_size, sha256=digest(path))
        elif path.is_dir():
            item.update(type="directory")
        else:
            raise SystemExit(f"unsupported staged entry: {path}")
        inventory.append(item)

    inputs = {
        "capabilities": build_info["capabilities"],
        "source": build_info["source"],
        "source_patches": build_info["source_patches"],
        "configure": build_info["configure"],
        "target": build_info["target"],
        "version": build_info["version"],
    }
    reference = {
        "schema_version": 1,
        "kind": "wineforge-engine-build-reference",
        "id": f'crossover-{build_info["version"]}-{build_info["target"]}',
        "inputs": inputs,
        "inputs_sha256": canonical_digest(inputs),
        "artifact_sha256": digest(artifact),
        "content_manifest_sha256": canonical_digest(inventory),
        "file_count": len(inventory),
        "builder": build_info["builder"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(reference, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
