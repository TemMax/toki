#!/usr/bin/env python3
"""Verify a downloaded candidate manifest against source and asset bytes."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


LOCK = "Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def field(source: str, name: str) -> str:
    matches = re.findall(rf"^\s*{re.escape(name)}:\s*([^\s#]+)", source, re.MULTILINE)
    # The first value is the base release setting; Debug deliberately overrides
    # CURRENT_PROJECT_VERSION later with Int32.max for local development.
    if not matches:
        raise ValueError(f"missing {name} in project.yml")
    return matches[0].strip('"\'')


def verify(root: Path, assets: Path, tag: str) -> None:
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("invalid tag")
    version = tag[1:]
    source_sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    project = (root / "project.yml").read_text()
    if field(project, "MARKETING_VERSION") != version:
        raise ValueError("source version differs from tag")
    build = int(field(project, "CURRENT_PROJECT_VERSION"))
    if build <= 43:
        raise ValueError("release build number is not newer than v1.12.1")
    manifest = json.loads((assets / "release-manifest.json").read_text())
    expected = {
        "tag": tag,
        "buildNumber": build,
        "sourceSHA": source_sha,
        "unsignedSHA256": digest(assets / f"Toki-{tag}-unsigned.zip"),
        "signedDMGSHA256": digest(assets / f"Toki-{version}.dmg"),
        "appcastSHA256": digest(assets / "appcast.xml"),
        "buildInputs": json.loads((root / "build-inputs.json").read_text()),
        "actualToolchain": json.loads((assets / "toolchain-actual.json").read_text()),
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            name = "DMG" if key == "signedDMGSHA256" else key
            raise ValueError(f"candidate {name} mismatch")
    if (assets / "build-inputs.json").read_bytes() != (root / "build-inputs.json").read_bytes():
        raise ValueError("candidate build inputs differ from source")
    toolchain = expected["actualToolchain"]
    if toolchain.get("sourceSHA") != source_sha:
        raise ValueError("candidate toolchain source SHA mismatch")
    if toolchain.get("packageLockSHA256") != digest(root / LOCK):
        raise ValueError("candidate package lock SHA mismatch")
    print(f"Verified candidate manifest: {tag} ({build}), {source_sha}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--assets", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    try:
        verify(args.root, args.assets, args.tag)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"candidate manifest invalid: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
