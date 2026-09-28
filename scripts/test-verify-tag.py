#!/usr/bin/env python3
"""The one-command verifier refuses ambiguous or wrong source tags."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / "scripts/verify-tag.sh"


class VerifyTagTests(unittest.TestCase):
    def invoke(self, tag: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(VERIFY), tag], cwd=ROOT,
                              text=True, capture_output=True, check=False)

    def test_bad_tag_is_rejected_before_download(self) -> None:
        result = self.invoke("v1.13.0/../../other")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid release tag", result.stderr.lower())

    def test_checkout_at_another_commit_is_rejected_before_download(self) -> None:
        result = self.invoke("v1.13.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checkout", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
