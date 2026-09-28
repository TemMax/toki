#!/usr/bin/env python3
"""Verify the public Ed25519 boundary with RFC 8032's first test vector."""

import base64
from pathlib import Path
import subprocess
import tempfile
import unittest


VERIFY = Path(__file__).with_name("verify-sparkle-signature.swift")
PUBLIC_KEY = bytes.fromhex(
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
)
SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
    "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
)


class SparkleSignatureTests(unittest.TestCase):
    def verify(self, contents: bytes) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(contents)
            return subprocess.run(
                ["swift", str(VERIFY), str(archive),
                 base64.b64encode(SIGNATURE).decode(), base64.b64encode(PUBLIC_KEY).decode()],
                text=True, capture_output=True, check=False,
            )

    def test_valid_signature_is_accepted(self) -> None:
        result = self.verify(b"")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_modified_archive_is_rejected(self) -> None:
        result = self.verify(b"x")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
