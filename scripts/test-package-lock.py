#!/usr/bin/env python3
"""Exercise the release guard against real XcodeGen specs and SwiftPM locks."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "scripts/verify-package-lock.py"
SPEC = ROOT / "project.yml"
LOCK = ROOT / "Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


class ReleasePackageLockTests(unittest.TestCase):
    def run_guard(self, spec_text: str, lock: dict) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            spec_path = Path(directory) / "project.yml"
            lock_path = Path(directory) / "Package.resolved"
            spec_path.write_text(spec_text)
            lock_path.write_text(json.dumps(lock))
            return subprocess.run(
                ["python3", str(GUARD), "--spec", str(spec_path), "--lock", str(lock_path)],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_exact_sparkle_pin_matching_lock_is_accepted(self) -> None:
        result = self.run_guard(SPEC.read_text(), json.loads(LOCK.read_text()))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_range_pin_is_rejected_even_when_lock_has_a_version(self) -> None:
        original = SPEC.read_text()
        self.assertIn('exactVersion: "2.10.0"', original)
        spec = original.replace('exactVersion: "2.10.0"', 'from: "2.9.0"')
        result = self.run_guard(spec, json.loads(LOCK.read_text()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact", result.stderr.lower())

    def test_lock_revision_drift_is_rejected(self) -> None:
        lock = json.loads(LOCK.read_text())
        sparkle = next(pin for pin in lock["pins"] if pin["identity"] == "sparkle")
        sparkle["state"]["revision"] = "0" * 40
        result = self.run_guard(SPEC.read_text(), lock)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("revision", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
