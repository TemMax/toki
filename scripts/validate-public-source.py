#!/usr/bin/env python3
"""Reject incomplete or private release snapshots before public publication."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


FEED = "https://github.com/TemMax/toki/releases/latest/download/appcast.xml"
REQUIRED = (
    "project.yml",
    "Package.swift",
    "build-inputs.json",
    "Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "LICENSE",
    "App/Resources/ThirdPartyNotices.txt",
    "App/Resources/Credits.html",
)
IGNORED_ROOTS = {".git", ".build", "build", "DerivedData", ".context", "__pycache__"}
SEMVER = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"


def field(project: str, name: str) -> str:
    matches = re.findall(rf"^\s*{re.escape(name)}:\s*([^\s#]+)", project, re.MULTILINE)
    if not matches:
        raise ValueError(f"missing {name} in project.yml")
    return matches[0].strip('"\'')


def validate_tree(root: Path, version: str, build: int) -> None:
    if build <= 43:
        raise ValueError("release build number must be greater than 43")
    for relative in REQUIRED:
        if not (root / relative).is_file():
            raise ValueError(f"missing public release input: {relative}")
    notes = root / f"docs/release-notes/v{version}.md"
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError("versioned release notes are missing or empty")
    project = (root / "project.yml").read_text()
    if field(project, "MARKETING_VERSION") != version:
        raise ValueError("MARKETING_VERSION differs from release version")
    if field(project, "CURRENT_PROJECT_VERSION") != str(build):
        raise ValueError("CURRENT_PROJECT_VERSION differs from release build number")
    if field(project, "SUFeedURL") != FEED:
        raise ValueError("SUFeedURL must use the new public Toki feed")
    for renderer in ("scripts/make-credits.sh", "scripts/notes-to-html.sh", "scripts/release-notes.sh"):
        if not (root / renderer).is_file():
            raise ValueError(f"missing public release input: {renderer}")
    try:
        # This validator runs in the private signing job too. Never execute a
        # script from the public candidate tree in a job that later gets keys.
        trusted_renderer = Path(__file__).resolve().with_name("make-credits.sh")
        expected_credits = subprocess.check_output(
            [str(trusted_renderer), version, str(notes)], stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("could not render Credits.html from versioned release notes") from error
    if (root / "App/Resources/Credits.html").read_bytes() != expected_credits:
        raise ValueError("Credits.html does not match the versioned release notes")

    for directory, dirs, files in os.walk(root, followlinks=False):
        parent = Path(directory)
        if parent == root:
            dirs[:] = [name for name in dirs if name not in IGNORED_ROOTS]
        for name in dirs + files:
            path = parent / name
            relative = path.relative_to(root)
            parts = tuple(part.casefold() for part in relative.parts)
            if name.casefold() in {"agents.md", "claude.md"}:
                raise ValueError(f"agent instructions in public source: {relative}")
            if len(parts) > 1 and parts[0] == "docs" and parts[1] in {"research", "superpowers", "performance"}:
                raise ValueError(f"private docs in public source: {relative}")
            if path.is_symlink():
                raise ValueError(f"symlink in public source: {relative}")
            if len(parts) > 2 and parts[:2] == ("docs", "release-notes") and relative != notes.relative_to(root):
                raise ValueError(f"unrelated release notes in public source: {relative}")


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True, stderr=subprocess.DEVNULL).strip()


def validate_tag(root: Path, tag: str) -> tuple[str, int]:
    if not re.fullmatch(rf"v{SEMVER}", tag):
        raise ValueError("release tag must be vMAJOR.MINOR.PATCH")
    if git(root, "cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise ValueError("release tag must be annotated")
    if git(root, "rev-parse", f"refs/tags/{tag}^{{commit}}") != git(root, "rev-parse", "HEAD"):
        raise ValueError("release tag does not point to HEAD")
    subject = git(root, "show", "-s", "--format=%s", "HEAD")
    match = re.fullmatch(rf"release: {re.escape(tag)} \((\d+)\)", subject)
    if match is None:
        raise ValueError("release snapshot commit subject must contain tag and build number")
    build = int(match.group(1))
    version_parts = tuple(map(int, tag[1:].split(".")))
    if version_parts < (1, 13, 0):
        raise ValueError("public source version must be at least 1.13.0")
    if build <= 43:
        raise ValueError("release build number must be greater than 43")
    roots = git(root, "rev-list", "--max-parents=0", "HEAD").splitlines()
    if len(roots) != 1:
        raise ValueError("HEAD ancestry must have exactly one public source root")
    root_subject = git(root, "show", "-s", "--format=%s", roots[0])
    root_match = re.fullmatch(rf"release: v({SEMVER}) \((\d+)\)", root_subject)
    if root_match is None or tuple(map(int, root_match.group(1).split("."))) < (1, 13, 0) or int(root_match.group(2)) <= 43:
        raise ValueError("HEAD ancestry root must be a valid first public source snapshot")
    for relative in ("project.yml", "Package.swift", "build-inputs.json", "LICENSE"):
        try:
            git(root, "cat-file", "-e", f"{roots[0]}:{relative}")
        except subprocess.CalledProcessError:
            raise ValueError(f"public source root is missing {relative}")
    parents = git(root, "show", "-s", "--format=%P", "HEAD").split()
    earlier = git(root, "rev-list", parents[0]).splitlines() if parents else []
    for commit in earlier:
        previous = re.fullmatch(r"release: v\d+\.\d+\.\d+ \((\d+)\)", git(root, "show", "-s", "--format=%s", commit))
        if previous and build <= int(previous.group(1)):
            raise ValueError("release build number must increase across releases")
    if git(root, "status", "--porcelain"):
        raise ValueError("release source checkout is not clean")
    return tag[1:], build


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    release = parser.add_mutually_exclusive_group(required=True)
    release.add_argument("--tag")
    release.add_argument("--version")
    parser.add_argument("--build", type=int)
    args = parser.parse_args()
    try:
        if args.tag:
            version, build = validate_tag(args.root, args.tag)
        else:
            if args.build is None or args.build < 1:
                raise ValueError("--version requires a positive --build")
            version, build = args.version, args.build
        validate_tree(args.root, version, build)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"public release source invalid: {error}", file=sys.stderr)
        return 1
    print(f"Validated public source for v{version} ({build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
