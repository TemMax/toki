#!/usr/bin/env python3
"""The release manifest covers bytes, permissions and symlink targets."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


MANIFEST = Path(__file__).with_name("app-manifest.py")


class AppManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Toki.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        executable = self.app / "Contents/MacOS/Toki"
        executable.write_bytes(b"code")
        executable.chmod(0o755)
        (self.app / "Contents/Current").symlink_to("MacOS")

    def manifest(self) -> dict:
        result = subprocess.run(
            ["python3", str(MANIFEST), str(self.app)],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_manifest_records_file_hash_mode_and_symlink(self) -> None:
        entries = {item["path"]: item for item in self.manifest()["entries"]}
        self.assertEqual(entries["Contents/MacOS/Toki"]["mode"], "0755")
        self.assertEqual(entries["Contents/MacOS/Toki"]["sha256"],
                         "5694d08a2e53ffcae0c3103e5ad6f6076abd960eb1f8a56577040bc1028f702b")
        self.assertEqual(entries["Contents/Current"]["target"], "MacOS")

    def test_changed_bytes_change_manifest_digest(self) -> None:
        initial = self.manifest()["rootSHA256"]
        (self.app / "Contents/MacOS/Toki").write_bytes(b"changed")
        self.assertNotEqual(self.manifest()["rootSHA256"], initial)


if __name__ == "__main__":
    unittest.main()
