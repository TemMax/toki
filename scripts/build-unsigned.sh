#!/usr/bin/env bash
# Rebuild a committed release source tree at the same absolute paths used in CI.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/build-unsigned.sh <new-output-directory>" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
OUTPUT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$1")"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  echo "error: output already exists: $OUTPUT" >&2
  exit 1
fi
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
  echo "error: build from a clean committed checkout" >&2
  exit 1
fi

SOURCE_SHA="$(git -C "$REPO" rev-parse HEAD)"
CANONICAL_PARENT="/private/tmp/toki-release-build"
CANONICAL_ROOT="$CANONICAL_PARENT/$SOURCE_SHA"
case "$OUTPUT" in
  "$CANONICAL_ROOT"|"$CANONICAL_ROOT"/*)
    echo "error: output must be outside the canonical build directory" >&2
    exit 1 ;;
esac
mkdir -p "$CANONICAL_PARENT"
if [[ "$(stat -f '%u' "$CANONICAL_PARENT")" != "$(id -u)" ]]; then
  echo "error: canonical build parent belongs to a different user" >&2
  exit 1
fi
if ! mkdir -m 700 "$CANONICAL_ROOT"; then
  echo "error: canonical build directory already exists: $CANONICAL_ROOT" >&2
  exit 1
fi
printf '%s\n' "$SOURCE_SHA" > "$CANONICAL_ROOT/.toki-build-owner"
STAGE=""
cleanup() {
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf "$STAGE"; fi
  if [[ -f "$CANONICAL_ROOT/.toki-build-owner" ]] &&
     [[ "$(cat "$CANONICAL_ROOT/.toki-build-owner")" == "$SOURCE_SHA" ]] &&
     [[ "$(stat -f '%u' "$CANONICAL_ROOT")" == "$(id -u)" ]]; then
    rm -rf "$CANONICAL_ROOT"
  fi
}
trap cleanup EXIT

SOURCE="$CANONICAL_ROOT/source"
DERIVED="$CANONICAL_ROOT/DerivedData"
TOOLS="$CANONICAL_ROOT/tools"
mkdir "$SOURCE" "$TOOLS"
git -C "$REPO" archive --format=tar "$SOURCE_SHA" | tar -xf - -C "$SOURCE"

input() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' \
    "$SOURCE/build-inputs.json" "$1" "$2"
}

EXPECTED_XCODE="$(input xcode version)"
EXPECTED_BUILD="$(input xcode build)"
EXPECTED_SDK="$(input xcode sdk)"
EXPECTED_SWIFT="$(input xcode swift)"
test "$(xcodebuild -version)" = "$(printf 'Xcode %s\nBuild version %s' "$EXPECTED_XCODE" "$EXPECTED_BUILD")"
test "$(xcrun --sdk macosx --show-sdk-version)" = "$EXPECTED_SDK"
[[ "$(swift --version)" == *"Apple Swift version ${EXPECTED_SWIFT}"* ]]
test "$(uname -m)" = arm64

XCODEGEN_URL="$(input xcodegen archive)"
XCODEGEN_SHA="$(input xcodegen sha256)"
XCODEGEN_VERSION="$(input xcodegen version)"
curl -fsSL --retry 3 "$XCODEGEN_URL" -o "$TOOLS/xcodegen.zip"
printf '%s  %s\n' "$XCODEGEN_SHA" "$TOOLS/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$TOOLS/xcodegen.zip" -d "$TOOLS"
export PATH="$TOOLS/xcodegen/bin:$PATH"
test "$(xcodegen --version)" = "Version: $XCODEGEN_VERSION"

cd "$SOURCE"
xcodegen generate >/dev/null
python3 scripts/verify-package-lock.py
LOCK="Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
LOCK_BEFORE="$(shasum -a 256 "$LOCK" | awk '{print $1}')"
xcodebuild -project Toki.xcodeproj -scheme Toki -derivedDataPath "$DERIVED" \
  -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile >/dev/null
xcodebuild -project Toki.xcodeproj -scheme Toki -destination 'platform=macOS' \
  -configuration Release -derivedDataPath "$DERIVED" \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build -quiet
LOCK_AFTER="$(shasum -a 256 "$LOCK" | awk '{print $1}')"
if [[ "$LOCK_AFTER" != "$LOCK_BEFORE" ]]; then
  echo "error: SwiftPM changed Package.resolved during the build" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Release/Toki.app"
test -d "$APP"
scripts/verify-no-debug-channel.sh "$APP"
mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp -d "${OUTPUT}.tmp.XXXXXXXX")"
ditto "$APP" "$STAGE/Toki.app"
python3 scripts/app-manifest.py "$STAGE/Toki.app" > "$STAGE/app-manifest.json"
cp build-inputs.json "$STAGE/build-inputs.json"
python3 - "$STAGE/toolchain-actual.json" "$SOURCE_SHA" "$SOURCE" "$DERIVED" "$LOCK_BEFORE" <<'PY'
import json, os, subprocess, sys
path, source_sha, source_path, derived_path, lock_sha = sys.argv[1:]
def output(*command):
    return subprocess.check_output(command, text=True).strip()
actual = {
    "sourceSHA": source_sha,
    "sourcePath": source_path,
    "derivedDataPath": derived_path,
    "packageLockSHA256": lock_sha,
    "macOS": output("sw_vers", "-productVersion"),
    "runnerImage": os.environ.get("ImageVersion"),
    "xcode": output("xcodebuild", "-version"),
    "sdk": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
    "swift": output("swift", "--version").splitlines()[0],
    "xcodegen": output("xcodegen", "--version"),
}
with open(path, "w") as file:
    json.dump(actual, file, indent=2, sort_keys=True)
    file.write("\n")
PY
mv "$STAGE" "$OUTPUT"
STAGE=""
echo "Unsigned app, manifest, and toolchain record: $OUTPUT"
