#!/usr/bin/env python3
"""Verify a downloaded Toki DMG against an independent unsigned build."""

import argparse
import base64
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
TEAM_ID = "93FFKDMA3D"
BUNDLE_ID = "dev.komar.toki"
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca",
}


def parse_appcast(xml: bytes, version: str, build: str, dmg_name: str, size: int) -> str:
    root = ET.fromstring(xml)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("appcast must contain exactly one release item")
    item = items[0]
    if item.findtext(f"{SPARKLE}shortVersionString") != version:
        raise ValueError("appcast version differs from the rebuilt app")
    if item.findtext(f"{SPARKLE}version") != build:
        raise ValueError("appcast build number differs from the rebuilt app")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError("appcast must contain exactly one DMG enclosure")
    enclosure = enclosures[0]
    expected_url = f"https://github.com/TemMax/toki/releases/download/v{version}/{dmg_name}"
    if enclosure.get("url") != expected_url or enclosure.get("type") != "application/octet-stream":
        raise ValueError("appcast DMG URL or media type differs from the release")
    if enclosure.get("length") != str(size):
        raise ValueError("appcast DMG length differs from the downloaded file")
    signature = enclosure.get(f"{SPARKLE}edSignature", "")
    try:
        decoded = base64.b64decode(signature, validate=True)
    except ValueError as error:
        raise ValueError("appcast Sparkle signature has invalid base64") from error
    if len(decoded) != 64:
        raise ValueError("appcast Sparkle signature is missing or invalid")
    return signature


def run(*command: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result


def app_info(app: Path) -> dict:
    with (app / "Contents/Info.plist").open("rb") as file:
        return plistlib.load(file)


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as file:
        return file.read(4) in MACHO_MAGICS


def require_team(details: str, subject: str) -> None:
    if f"TeamIdentifier={TEAM_ID}" not in details.splitlines():
        raise ValueError(f"unexpected Developer ID team for {subject}")


def verify_code_signing_scope(app: Path, source_root: Path) -> None:
    with (source_root / "App/Toki.entitlements").open("rb") as file:
        public_entitlements = plistlib.load(file)
    main_binary = app / "Contents/MacOS/Toki"
    binaries = [path for path in app.rglob("*") if is_macho(path)]
    if main_binary not in binaries:
        raise ValueError("signed app has no Toki executable")
    for binary in binaries:
        details = run("codesign", "--display", "--verbose=4", str(binary)).stderr
        require_team(details, str(binary.relative_to(app)))
        encoded = run("codesign", "--display", "--entitlements", ":-", str(binary)).stdout
        actual = plistlib.loads(encoded.encode()) if encoded.strip() else {}
        expected = public_entitlements if binary == main_binary else {}
        if actual != expected:
            raise ValueError(f"signed entitlements differ from public source for {binary.relative_to(app)}")


def verify(dmg: Path, appcast: Path, unsigned_app: Path, expected_sha: str | None,
           source_root: Path = ROOT) -> None:
    if not dmg.is_file() or not appcast.is_file() or not unsigned_app.is_dir():
        raise ValueError("DMG, appcast, or independently built app is missing")
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    if expected_sha and digest.lower() != expected_sha.lower():
        raise ValueError("DMG SHA-256 differs from the expected release digest")
    info = app_info(unsigned_app)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not version or not build or info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("rebuilt app has an unexpected version, build, or bundle ID")
    if info.get("SUFeedURL") != "https://github.com/TemMax/toki/releases/latest/download/appcast.xml":
        raise ValueError("rebuilt app does not use the public Toki update feed")
    public_key = info.get("SUPublicEDKey")
    if not isinstance(public_key, str) or len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("rebuilt app lacks a valid Sparkle public key")
    signature = parse_appcast(appcast.read_bytes(), version, build, dmg.name, dmg.stat().st_size)

    run("swift", str(ROOT / "scripts/verify-sparkle-signature.swift"), str(dmg), signature, public_key)
    run("codesign", "--verify", "--verbose=2", str(dmg))
    require_team(run("codesign", "--display", "--verbose=4", str(dmg)).stderr, "DMG")
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(dmg))
    run("xcrun", "stapler", "validate", str(dmg))

    with tempfile.TemporaryDirectory(prefix="toki-release-verify-") as directory:
        mount = Path(directory) / "mount"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg))
        try:
            signed_app = mount / "Toki.app"
            if not signed_app.is_dir() or signed_app.is_symlink():
                raise ValueError("DMG contains no regular Toki.app bundle")
            run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(signed_app))
            verify_code_signing_scope(signed_app, source_root)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", str(signed_app))
            run("xcrun", "stapler", "validate", str(signed_app))
            run("python3", str(ROOT / "scripts/compare-app-payload.py"), str(unsigned_app), str(signed_app))
        finally:
            run("hdiutil", "detach", str(mount))

    print(f"Verified Toki {version} ({build}) against the downloaded DMG.")
    print(f"DMG SHA-256: {digest}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--unsigned-app", type=Path, required=True)
    parser.add_argument("--dmg-sha256", type=str)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        verify(args.dmg, args.appcast, args.unsigned_app, args.dmg_sha256, args.source_root)
    except (OSError, ValueError, plistlib.InvalidFileException, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"release verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
