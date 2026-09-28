#!/usr/bin/env bash
# The committed versioned file is the only source of public release notes.
set -euo pipefail

TAG="${1:?usage: release-notes.sh vX.Y.Z}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: invalid release tag: $TAG" >&2; exit 1;
}
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NOTES="$ROOT/docs/release-notes/$TAG.md"
[[ -s "$NOTES" ]] || {
  echo "error: missing reviewed release notes: $NOTES" >&2; exit 1;
}
cat "$NOTES"
