# Verify a Toki release

Use an Apple Silicon Mac with Xcode 26.6 (17F113), its macOS 26.5 SDK and Swift 6.3.3. The release's [`build-inputs.json`](../build-inputs.json) records the exact Sparkle source revision, XcodeGen archive, Sparkle signing-tool archive and expected toolchain. The GitHub runner image and macOS version used for the published unsigned artifact are recorded there and in the artifact's `toolchain-actual.json`. A different host OS may produce different bytes; the verifier reports a mismatch rather than silently accepting one.

## One-command check

```sh
git clone https://github.com/TemMax/toki.git
cd toki
git checkout vX.Y.Z                 # replace with the release tag
bash scripts/verify-tag.sh "$(git describe --tags --exact-match HEAD)"
```

The command accepts only an annotated release tag pointing to the checked-out commit. It downloads that tag's DMG and `appcast.xml` from `TemMax/toki`, then calls `build-unsigned.sh` and `verify-release.py`. It needs `git`, `curl`, `python3`, `swift`, `xcodebuild`, `xcrun`, `codesign`, `spctl` and `hdiutil`, all available with Xcode/macOS except Git and curl where provided by the host. It downloads XcodeGen 2.46.0 and checks the committed archive digest; SwiftPM must use the committed `Package.resolved` without changing it.

The build recipe archives only the checked-out commit into `/private/tmp/toki-release-build/<full-commit-SHA>/source` and uses the sibling `DerivedData` path. It refuses an occupied canonical directory and removes only the directory it created. The output files are outside that temporary tree.

## What each check establishes

1. `appcast.xml` must name the same version, build number, DMG URL and byte length as the independently built app and downloaded DMG. The DMG must pass the Ed25519 signature using the public key embedded in the source-built app.
2. macOS must accept the DMG and the extracted app as signed and notarized Developer ID software from Team `93FFKDMA3D`; stapled tickets and bundle ID `dev.komar.toki` are checked. Every Mach-O executable must have that Team ID, the main app's entitlements must match the public `App/Toki.entitlements`, and embedded helpers must have no extra entitlements.
3. Every app entry is compared: file bytes, executable modes, directories and symlink targets. For Mach-O files, only the code-signature blob, its `LC_CODE_SIGNATURE` size and the signing-related `__LINKEDIT` size fields are normalized. Apple-generated `_CodeSignature/CodeResources` seals are excluded after signature verification. Any other difference fails. This includes code inside Sparkle.
4. The tool prints the SHA-256 of the downloaded DMG. Compare it with the release page's digest and inspect the public unsigned build's manifest, provenance attestation and `verification-result.json` for the tag/SHA. The result record links to the independent promotion run. A checksum or attestation alone does not prove source-to-binary equality; the independent build and payload comparison establish the narrower claim.

The signed DMG is not expected to match an independently created DMG byte for byte. Apple certificates, signatures, timestamps, notarization tickets and DMG packaging alter its bytes. A verification failure means the release is **not verified** on that machine; keep the complete output and report the tag and macOS/Xcode versions without sharing tokens or private transcript data.
