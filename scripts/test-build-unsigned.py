#!/usr/bin/env python3
"""Build the committed source with the public recipe and inspect its artifact."""

import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "scripts/build-unsigned.sh"


class UnsignedBuildTests(unittest.TestCase):
    def test_clean_commit_produces_unsigned_app_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result"
            result = subprocess.run(
                ["bash", str(BUILD), str(output)], cwd=ROOT,
                text=True, capture_output=True, check=False, timeout=600,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            app = output / "Toki.app"
            with (app / "Contents/Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info["CFBundleIdentifier"], "dev.komar.toki")
            manifest = json.loads((output / "app-manifest.json").read_text())
            self.assertTrue(any(item["path"] == "Contents/MacOS/Toki" for item in manifest["entries"]))
            actual = json.loads((output / "toolchain-actual.json").read_text())
            self.assertEqual(actual["sourceSHA"], subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip())


if __name__ == "__main__":
    unittest.main()
