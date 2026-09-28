#!/usr/bin/env python3
"""Reject private instructions/docs/symlinks anywhere in public Git history."""

import argparse
from pathlib import Path, PurePosixPath
import subprocess
import sys


def git(repo: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL)


def audit(repo: Path) -> int:
    names = git(repo, "for-each-ref", "--format=%(refname)",
                "refs/heads", "refs/remotes/origin", "refs/tags").decode().splitlines()
    refs = ["HEAD", *names]
    commits = set(git(repo, "rev-list", *refs).decode().splitlines())
    if not commits:
        raise ValueError("no public commits are available for auditing")
    for commit in sorted(commits):
        for entry in git(repo, "ls-tree", "-r", "-z", commit).split(b"\0"):
            if not entry:
                continue
            header, raw_path = entry.split(b"\t", 1)
            mode, kind, _ = header.decode().split()
            path = raw_path.decode("utf-8")
            parts = tuple(part.casefold() for part in PurePosixPath(path).parts)
            if parts[-1] in {"agents.md", "claude.md"}:
                raise ValueError(f"agent instructions in public history: {commit} {path}")
            if len(parts) > 1 and parts[0] == "docs" and parts[1] in {"research", "superpowers", "performance"}:
                raise ValueError(f"private docs in public history: {commit} {path}")
            if mode == "120000":
                raise ValueError(f"symlink in public history: {commit} {path}")
            if kind != "blob" or mode not in {"100644", "100755"}:
                raise ValueError(f"unsupported public Git entry: {commit} {path}")
    return len(commits)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        count = audit(args.repo)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"public refs audit failed: {error}", file=sys.stderr)
        return 1
    print(f"Audited all trees in {count} reachable public commits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
