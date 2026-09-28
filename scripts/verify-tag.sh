#!/usr/bin/env bash
# One-command independent rebuild and downloaded-release comparison.
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid release tag (expected vMAJOR.MINOR.PATCH)" >&2
  exit 2
fi
TAG="$1"
VERSION="${TAG#v}"
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO"
if [[ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" != tag ]] ||
   [[ "$(git rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null || true)" != "$(git rev-parse HEAD)" ]]; then
  echo "error: checkout the annotated public $TAG tag before verification" >&2
  exit 1
fi
python3 scripts/validate-public-source.py --tag "$TAG"

WORK="$(mktemp -d /private/tmp/toki-verify-tag.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
DMG="$WORK/Toki-${VERSION}.dmg"
APPCAST="$WORK/appcast.xml"
BASE="https://github.com/TemMax/toki/releases/download/$TAG"
curl -fsSL --retry 3 "$BASE/Toki-${VERSION}.dmg" -o "$DMG"
curl -fsSL --retry 3 "$BASE/appcast.xml" -o "$APPCAST"
bash scripts/build-unsigned.sh "$WORK/unsigned"
python3 scripts/verify-release.py \
  --dmg "$DMG" --appcast "$APPCAST" --unsigned-app "$WORK/unsigned/Toki.app"
