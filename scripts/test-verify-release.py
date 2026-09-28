#!/usr/bin/env python3
"""Check appcast metadata before a release DMG is accepted."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("verify-release.py")
SPEC = importlib.util.spec_from_file_location("verify_release", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

SIGNATURE = "XRxF9T8Hii91o4FJ2071asz9BD2IYeqNLzzXDXmMcdFhh3+MyxSokuXCSxCVHLkdN0R3y7N2fwkvlSKzVZlOAw=="


def appcast(version: str = "1.13.0", build: str = "44", length: str = "123", signature: str = SIGNATURE) -> bytes:
    return f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <enclosure url="https://github.com/TemMax/toki/releases/download/v1.13.0/Toki-1.13.0.dmg"
        sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream" />
    </item></channel></rss>'''.encode()


class AppcastTests(unittest.TestCase):
    def test_matching_release_metadata_yields_signature(self) -> None:
        self.assertEqual(MODULE.parse_appcast(appcast(), "1.13.0", "44", "Toki-1.13.0.dmg", 123), SIGNATURE)

    def test_wrong_build_number_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "build"):
            MODULE.parse_appcast(appcast(build="43"), "1.13.0", "44", "Toki-1.13.0.dmg", 123)

    def test_wrong_archive_length_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "length"):
            MODULE.parse_appcast(appcast(length="124"), "1.13.0", "44", "Toki-1.13.0.dmg", 123)

    def test_missing_signature_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "signature"):
            MODULE.parse_appcast(appcast(signature=""), "1.13.0", "44", "Toki-1.13.0.dmg", 123)

    def test_malformed_signature_is_rejected_with_clear_error(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid base64"):
            MODULE.parse_appcast(appcast(signature="not base64!"), "1.13.0", "44", "Toki-1.13.0.dmg", 123)


class CodeSigningScopeTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "Toki.app"
        self.main = self.app / "Contents/MacOS/Toki"
        self.helper = self.app / "Contents/Frameworks/Helper"
        for path in (self.main, self.helper):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\xcf\xfa\xed\xfe" + b"fake executable")
        entitlements = self.root / "App/Toki.entitlements"
        entitlements.parent.mkdir(parents=True)
        entitlements.write_bytes(plistlib.dumps({}))

    def codesign(self, nested_entitlements: dict | None = None, wrong_team: bool = False):
        def fake_run(*command: str) -> subprocess.CompletedProcess[str]:
            is_main = command[-1] == str(self.main)
            if "--entitlements" in command:
                value = {} if is_main else nested_entitlements
                return subprocess.CompletedProcess(command, 0,
                    stdout=plistlib.dumps(value).decode() if value is not None else "", stderr="")
            team = "WRONGTEAM" if wrong_team and not is_main else MODULE.TEAM_ID
            return subprocess.CompletedProcess(command, 0, stdout="", stderr=f"TeamIdentifier={team}\n")
        return fake_run

    def test_expected_team_and_entitlements_on_all_code_pass(self) -> None:
        with patch.object(MODULE, "run", side_effect=self.codesign()):
            MODULE.verify_code_signing_scope(self.app, self.root)

    def test_helper_with_extra_entitlement_fails(self) -> None:
        with patch.object(MODULE, "run", side_effect=self.codesign({"com.apple.security.get-task-allow": True})):
            with self.assertRaisesRegex(ValueError, "entitlements"):
                MODULE.verify_code_signing_scope(self.app, self.root)

    def test_helper_signed_by_another_team_fails(self) -> None:
        with patch.object(MODULE, "run", side_effect=self.codesign(wrong_team=True)):
            with self.assertRaisesRegex(ValueError, "Developer ID team"):
                MODULE.verify_code_signing_scope(self.app, self.root)

    def test_dmg_signed_by_another_team_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "DMG"):
            MODULE.require_team("TeamIdentifier=WRONGTEAM\n", "DMG")


if __name__ == "__main__":
    unittest.main()
