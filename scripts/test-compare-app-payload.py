#!/usr/bin/env python3
"""A valid re-signing may change signatures, never application payload."""

from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


COMPARE = Path(__file__).with_name("compare-app-payload.py")


def macho(code: bytes, signature: bytes) -> bytes:
    offset = 32 + 72 + 16 + len(code)
    size = offset + len(signature)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2, 88, 0, 0)
    linkedit = struct.pack(
        "<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT".ljust(16, b"\0"),
        0, size, 0, size, 0, 0, 0, 0,
    )
    code_signature = struct.pack("<IIII", 0x1D, 16, offset, len(signature))
    return header + linkedit + code_signature + code + signature


class CompareAppPayloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.unsigned = base / "unsigned.app"
        self.signed = base / "signed.app"
        for app in (self.unsigned, self.signed):
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Frameworks").mkdir(parents=True)
            (app / "Contents/Resources").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(b"same metadata")
            (app / "Contents/Frameworks/Current").symlink_to("VersionB")
        (self.unsigned / "Contents/MacOS/Toki").write_bytes(macho(b"actual code", b"old-sig"))
        (self.signed / "Contents/MacOS/Toki").write_bytes(macho(b"actual code", b"new-signature-longer"))
        for app in (self.unsigned, self.signed):
            (app / "Contents/MacOS/Toki").chmod(0o755)
        signature = self.signed / "Contents/_CodeSignature"
        signature.mkdir()
        (signature / "CodeResources").write_bytes(b"Apple resource seal")

    def compare(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(COMPARE), str(self.unsigned), str(self.signed)],
            text=True, capture_output=True, check=False,
        )

    def test_signing_only_changes_are_accepted(self) -> None:
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_stapled_notarization_ticket_is_accepted(self) -> None:
        (self.signed / "Contents/CodeResources").write_bytes(
            b"s8ch\x01\x00\x00\x00" + b"\x00" * 8
        )
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_ticket_contents_code_resources_is_rejected(self) -> None:
        (self.signed / "Contents/CodeResources").write_bytes(b"unexpected payload")
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CodeResources", result.stderr)

    def test_unsigned_only_contents_code_resources_is_rejected(self) -> None:
        (self.unsigned / "Contents/CodeResources").write_bytes(
            b"s8ch\x01\x00\x00\x00" + b"\x00" * 8
        )
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CodeResources", result.stderr)

    def test_resigned_code_change_is_rejected(self) -> None:
        (self.signed / "Contents/MacOS/Toki").write_bytes(macho(b"altered code", b"new-signature-longer"))
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MacOS/Toki", result.stderr)

    def test_resource_change_is_rejected(self) -> None:
        (self.signed / "Contents/Info.plist").write_bytes(b"different metadata")
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Info.plist", result.stderr)

    def test_mode_change_is_rejected(self) -> None:
        (self.signed / "Contents/MacOS/Toki").chmod(0o644)
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mode", result.stderr)

    def test_symlink_change_is_rejected(self) -> None:
        link = self.signed / "Contents/Frameworks/Current"
        link.unlink()
        link.symlink_to("VersionA")
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)

    def test_extra_file_in_signature_directory_is_rejected(self) -> None:
        (self.signed / "Contents/_CodeSignature/payload").write_bytes(b"hidden")
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("payload", result.stderr)

    def test_fake_signature_directory_under_resources_is_rejected(self) -> None:
        directory = self.signed / "Contents/Resources/_CodeSignature"
        directory.mkdir(parents=True)
        (directory / "CodeResources").write_bytes(b"hidden payload")
        result = self.compare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Resources", result.stderr)


if __name__ == "__main__":
    unittest.main()
