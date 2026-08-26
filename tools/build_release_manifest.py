#!/usr/bin/env python3
"""Create the fixed, hash-addressed GitHub release manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024): value.update(chunk)
    return value.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_directory", type=Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    root = args.artifact_directory.resolve()
    names = {
        "rootfs": "opti-temporary-worker-rootfs.tar.gz",
        "bootstrap": "Install-OptiTemporaryWorker.ps1",
        "uninstaller": "Remove-OptiTemporaryWorker.ps1",
    }
    missing = [name for name in names.values() if not (root / name).is_file()]
    if missing: raise SystemExit("release assets missing: " + ", ".join(missing))
    manifest = {
        "format": "opti-temporary-worker-release-v1",
        "version": str(args.version),
        "assets": {
            key: {"name": name, "sha256": digest(root / name), "size": (root / name).stat().st_size}
            for key, name in names.items()
        },
    }
    destination = root / "release-manifest.json"
    destination.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")), encoding="utf-8")
    for path in (root / names["bootstrap"], destination):
        (root / f"{path.name}.sha256").write_text(f"{digest(path)}  {path.name}\n", encoding="ascii")
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

