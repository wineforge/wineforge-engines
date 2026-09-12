#!/usr/bin/env python3
"""Read capability metadata from an unpacked Wineforge engine."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("engine_root", type=Path)
    parser.add_argument("--id", dest="capability_id")
    args = parser.parse_args()
    metadata = args.engine_root / "share/wineforge/capabilities.json"
    document = json.loads(metadata.read_text())
    if document.get("schema_version") != 1 or document.get("kind") != "wineforge-engine-capabilities":
        raise SystemExit("unsupported engine capability metadata")
    provided = document.get("provided")
    if not isinstance(provided, list):
        raise SystemExit("invalid engine capability metadata")
    seen: set[str] = set()
    for item in provided:
        if not isinstance(item, dict):
            raise SystemExit("invalid engine capability declaration")
        item_id = item.get("id")
        if item_id not in {"input.mapping", "macos.window-isolation", "host.bridge"}:
            raise SystemExit(f"unknown engine capability: {item_id}")
        if item_id in seen:
            raise SystemExit(f"duplicate engine capability: {item_id}")
        seen.add(str(item_id))
        if item.get("version") != 1 or item.get("state") != "provided":
            raise SystemExit(f"invalid engine capability declaration: {item_id}")
        targets = item.get("targets")
        if not isinstance(targets, list) or document.get("target") not in targets:
            raise SystemExit(f"capability does not apply to engine target: {item_id}")
    if args.capability_id is None:
        print(json.dumps(document, indent=2, sort_keys=True))
        return
    matches = [item for item in provided if item.get("id") == args.capability_id]
    if not matches:
        raise SystemExit(1)
    print(json.dumps(matches[0], indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
