#!/usr/bin/env python3
"""Fail a release build if XcodeGen, SwiftPM, and release inputs disagree."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = ROOT / "Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def verify(spec_path: Path, lock_path: Path, inputs_path: Path) -> None:
    project = json.loads(
        subprocess.check_output(
            ["xcodegen", "dump", "--type", "json", "--spec", str(spec_path)], text=True
        )
    )
    lock = json.loads(lock_path.read_text())
    inputs = json.loads(inputs_path.read_text())

    remote = {
        name: package
        for name, package in project.get("packages", {}).items()
        if "url" in package
    }
    pins = {pin["identity"].lower(): pin for pin in lock["pins"]}
    if len(pins) != len(lock["pins"]) or len(remote) != len(pins):
        raise ValueError("remote package set differs from Package.resolved")

    for name, package in remote.items():
        if set(package) != {"url", "exactVersion"}:
            raise ValueError(f"{name} requires an exactVersion pin")
        pin = pins.get(name.lower())
        if pin is None or pin.get("location") != package["url"]:
            raise ValueError(f"{name} is missing or has a different URL in Package.resolved")
        if pin.get("state", {}).get("version") != package["exactVersion"]:
            raise ValueError(f"{name} version differs from Package.resolved")
        if not pin.get("state", {}).get("revision"):
            raise ValueError(f"{name} revision is missing from Package.resolved")

    sparkle = pins.get("sparkle")
    if sparkle is None:
        raise ValueError("Sparkle is missing from Package.resolved")
    expected = inputs["sparkle"]
    if sparkle["state"] != {
        "revision": expected["revision"],
        "version": expected["version"],
    }:
        raise ValueError("Sparkle revision/version differs from build-inputs.json")
    if expected["version"] not in expected["signingToolsArchive"]:
        raise ValueError("Sparkle signing tools archive version differs from framework")
    if len(expected["signingToolsSHA256"]) != 64:
        raise ValueError("Sparkle signing tools archive SHA-256 is missing")
    print(f"Package lock verified: Sparkle {expected['version']} @ {expected['revision']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, default=ROOT / "project.yml")
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--inputs", type=Path, default=ROOT / "build-inputs.json")
    args = parser.parse_args()
    try:
        verify(args.spec, args.lock, args.inputs)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"package lock verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
