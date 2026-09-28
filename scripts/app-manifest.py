#!/usr/bin/env python3
"""Produce a deterministic digest manifest for every entry in an app bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def manifest(root: Path) -> dict:
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"app bundle is not a directory: {root}")
    entries = []

    def visit(directory: Path) -> None:
        for entry in os.scandir(directory):
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            mode = stat.S_IMODE(entry.stat(follow_symlinks=False).st_mode)
            item = {"path": relative, "mode": f"{mode:04o}"}
            if entry.is_symlink():
                item.update(type="symlink", target=os.readlink(path))
            elif entry.is_dir(follow_symlinks=False):
                item["type"] = "directory"
                visit(path)
            elif entry.is_file(follow_symlinks=False):
                item.update(type="file", sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            else:
                raise ValueError(f"unsupported app entry: {relative}")
            entries.append(item)

    visit(root)
    entries.sort(key=lambda item: item["path"])
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return {"schema": 1, "rootSHA256": hashlib.sha256(encoded).hexdigest(), "entries": entries}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        result = manifest(args.app)
    except (OSError, ValueError) as error:
        print(f"app manifest failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
