#!/usr/bin/env python3
"""Candidate promotion must reject changed signed bytes or an unrelated source."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


VERIFY = Path(__file__).with_name("verify-candidate-manifest.py")


class CandidateManifestTests(unittest.TestCase):
    def test_exact_candidate_passes_and_tampering_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            assets = Path(directory) / "assets"
            root.mkdir()
            assets.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.invalid"], check=True)
            (root / "project.yml").write_text(
                "MARKETING_VERSION: 1.13.0\nCURRENT_PROJECT_VERSION: 44\n"
                "Debug:\n  CURRENT_PROJECT_VERSION: 2147483647\n"
            )
            (root / "build-inputs.json").write_text('{"xcode":{"version":"26.6"}}\n')
            lock = root / "Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            lock.parent.mkdir(parents=True)
            lock.write_text('{"pins":[]}\n')
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture"], check=True)
            source_sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            zip_file = assets / "Toki-v1.13.0-unsigned.zip"
            dmg = assets / "Toki-1.13.0.dmg"
            appcast = assets / "appcast.xml"
            zip_file.write_bytes(b"unsigned")
            dmg.write_bytes(b"signed")
            appcast.write_bytes(b"appcast")
            toolchain = {"sourceSHA": source_sha, "packageLockSHA256": hashlib.sha256(lock.read_bytes()).hexdigest()}
            (assets / "toolchain-actual.json").write_text(json.dumps(toolchain))
            (assets / "build-inputs.json").write_bytes((root / "build-inputs.json").read_bytes())
            manifest = {
                "tag": "v1.13.0", "buildNumber": 44, "sourceSHA": source_sha,
                "unsignedSHA256": hashlib.sha256(zip_file.read_bytes()).hexdigest(),
                "signedDMGSHA256": hashlib.sha256(dmg.read_bytes()).hexdigest(),
                "appcastSHA256": hashlib.sha256(appcast.read_bytes()).hexdigest(),
                "buildInputs": json.loads((root / "build-inputs.json").read_text()),
                "actualToolchain": toolchain,
            }
            (assets / "release-manifest.json").write_text(json.dumps(manifest))
            command = ["python3", str(VERIFY), "--root", str(root), "--assets", str(assets),
                       "--tag", "v1.13.0"]
            good = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(good.returncode, 0, good.stderr)
            dmg.write_bytes(b"tampered")
            bad = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("DMG", bad.stderr)
            dmg.write_bytes(b"signed")
            manifest["sourceSHA"] = "f" * 40
            (assets / "release-manifest.json").write_text(json.dumps(manifest))
            bad_source = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(bad_source.returncode, 0)
            self.assertIn("source", bad_source.stderr.lower())


if __name__ == "__main__":
    unittest.main()
