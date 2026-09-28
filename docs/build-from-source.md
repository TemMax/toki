# Build Toki from source

Toki supports macOS 14 or later on Apple Silicon. The release build recipe needs the exact macOS, Xcode, Swift SDK, XcodeGen and Sparkle inputs listed in the release tag's [`build-inputs.json`](../build-inputs.json). Check that file before building: a different toolchain may produce different bytes.

## Build a release tag

```sh
git clone https://github.com/TemMax/toki.git
cd toki
git checkout vX.Y.Z  # replace with a new source-backed release tag
bash scripts/build-unsigned.sh build/unsigned
```

The script checks the pinned tools and package lock, creates a clean build at the documented canonical paths, and writes `Toki.app`, `app-manifest.json`, `toolchain-actual.json` and a copy of `build-inputs.json` to `build/unsigned`. This app is unsigned; the public repository does not contain the Developer ID or Sparkle signing keys.

To compare your independent build with the published signed DMG, follow [Verify a Toki release](verify-release.md) or run `bash scripts/verify-tag.sh vX.Y.Z` from that tag's clean checkout. Matching a source build with the signed app payload is a narrower claim than reproducing the DMG file byte for byte.

## Work on the code

The logic lives in the Swift package and the menu-bar app is an XcodeGen project. On a development checkout:

```sh
swift test
xcodegen generate
xcodebuild -scheme Toki -destination 'platform=macOS' -configuration Debug build
```

The release recipe above is the one used for source-to-binary checks. For contribution guidelines and the public release-snapshot workflow, see [CONTRIBUTING.md](../CONTRIBUTING.md).
