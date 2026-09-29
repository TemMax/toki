#!/usr/bin/env python3
"""Compare unsigned and signed app payloads, excluding signing and stapling data.

This checks payload equality after a separate authenticity check. A standalone
DMG verifier must validate Developer ID, notarization and Sparkle first.
"""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys


MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xfe\xed\xfa\xcf": (">", 32),
    b"\xfe\xed\xfa\xce": (">", 28),
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", 20),
    b"\xca\xfe\xba\xbf": (">", 32),
    b"\xbe\xba\xfe\xca": ("<", 20),
    b"\xbf\xba\xfe\xca": ("<", 32),
}


def slices(data: bytes) -> dict[tuple[int, int], bytes]:
    magic = data[:4]
    if magic in MACHO_MAGICS:
        endian, _ = MACHO_MAGICS[magic]
        cpu, subtype = struct.unpack_from(f"{endian}II", data, 4)
        return {(cpu, subtype): data}
    if magic not in FAT_MAGICS:
        raise ValueError("not a Mach-O binary")
    endian, entry_size = FAT_MAGICS[magic]
    if len(data) < 8:
        raise ValueError("short fat header")
    count = struct.unpack_from(f"{endian}I", data, 4)[0]
    if count > 32 or 8 + count * entry_size > len(data):
        raise ValueError("invalid fat architecture table")
    result = {}
    for index in range(count):
        position = 8 + index * entry_size
        cpu, subtype = struct.unpack_from(f"{endian}II", data, position)
        if entry_size == 20:
            offset, size = struct.unpack_from(f"{endian}II", data, position + 8)
        else:
            offset, size = struct.unpack_from(f"{endian}QQ", data, position + 8)
        if (cpu, subtype) in result or offset + size > len(data):
            raise ValueError("invalid fat architecture slice")
        piece = data[offset:offset + size]
        if piece[:4] not in MACHO_MAGICS:
            raise ValueError("fat architecture is not Mach-O")
        result[(cpu, subtype)] = piece
    return result


def unsigned_code_region(data: bytes) -> bytes:
    if data[:4] not in MACHO_MAGICS:
        raise ValueError("not a Mach-O slice")
    endian, header_size = MACHO_MAGICS[data[:4]]
    if len(data) < header_size:
        raise ValueError("short Mach-O header")
    command_count, command_bytes = struct.unpack_from(f"{endian}II", data, 16)
    if command_count > 4096 or header_size + command_bytes > len(data):
        raise ValueError("invalid Mach-O load commands")
    position = header_size
    signature = None
    linkedit = None
    for _ in range(command_count):
        if position + 8 > header_size + command_bytes:
            raise ValueError("short Mach-O load command")
        command, size = struct.unpack_from(f"{endian}II", data, position)
        if size < 8 or position + size > header_size + command_bytes:
            raise ValueError("invalid Mach-O load command size")
        if command == 0x1D:  # LC_CODE_SIGNATURE
            if signature is not None or size < 16:
                raise ValueError("invalid LC_CODE_SIGNATURE")
            signature = (position, *struct.unpack_from(f"{endian}II", data, position + 8))
        if command in (0x19, 0x1) and data[position + 8:position + 24].rstrip(b"\0") == b"__LINKEDIT":
            if linkedit is not None:
                raise ValueError("multiple __LINKEDIT segments")
            linkedit = (position, command, size)
        position += size
    if position != header_size + command_bytes or signature is None or linkedit is None:
        raise ValueError("missing or malformed Mach-O signing structure")
    sig_command, data_offset, data_size = signature
    if data_offset < position or data_offset + data_size != len(data):
        raise ValueError("code signature is not the final Mach-O region")
    normalized = bytearray(data[:data_offset])
    normalized[sig_command + 12:sig_command + 16] = b"\0" * 4
    segment, command, size = linkedit
    if command == 0x19:
        if size < 72:
            raise ValueError("short LC_SEGMENT_64")
        normalized[segment + 32:segment + 40] = b"\0" * 8  # vmsize
        normalized[segment + 48:segment + 56] = b"\0" * 8  # filesize
    else:
        if size < 56:
            raise ValueError("short LC_SEGMENT")
        normalized[segment + 28:segment + 32] = b"\0" * 4
        normalized[segment + 36:segment + 40] = b"\0" * 4
    return bytes(normalized)


def same_macho_payload(unsigned: bytes, signed: bytes) -> bool:
    left, right = slices(unsigned), slices(signed)
    return left.keys() == right.keys() and all(
        unsigned_code_region(left[arch]) == unsigned_code_region(right[arch])
        for arch in left
    )


def is_code_signature_directory(relative: str) -> bool:
    parts = PurePosixPath(relative).parts
    if not parts or parts[-1] != "_CodeSignature":
        return False
    parent = parts[:-1]
    if parent == ("Contents",):
        return True
    if len(parent) >= 2 and parent[-1] == "Contents" and parent[-2].endswith((".app", ".xpc")):
        return True
    if len(parent) >= 3 and parent[-2] == "Versions" and parent[-3].endswith(".framework"):
        return True
    return False


def inventory(root: Path, *, allow_stapled_ticket: bool = False) -> dict[str, tuple[str, int, str | bytes]]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"app path is not a directory: {root}")
    items = {}

    def visit(directory: Path) -> None:
        for entry in os.scandir(directory):
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            metadata = entry.stat(follow_symlinks=False)
            mode = stat.S_IMODE(metadata.st_mode)
            if entry.is_symlink():
                items[relative] = ("symlink", mode, os.readlink(path))
            elif entry.is_dir(follow_symlinks=False):
                if not is_code_signature_directory(relative):
                    items[relative] = ("directory", mode, "")
                visit(path)
            elif entry.is_file(follow_symlinks=False):
                if relative == "Contents/CodeResources" and allow_stapled_ticket:
                    # stapler adds this ticket outside _CodeSignature. The caller
                    # must validate the ticket and Developer ID signature first.
                    ticket = path.read_bytes()
                    if len(ticket) < 16 or not ticket.startswith(b"s8ch"):
                        raise ValueError("unexpected Contents/CodeResources payload")
                    continue
                if path.name == "CodeResources" and is_code_signature_directory(
                    path.parent.relative_to(root).as_posix()
                ):
                    continue
                items[relative] = ("file", mode, path.read_bytes())
            else:
                raise ValueError(f"unsupported app entry: {relative}")

    visit(root)
    return items


def compare(unsigned_app: Path, signed_app: Path) -> None:
    unsigned = inventory(unsigned_app)
    signed = inventory(signed_app, allow_stapled_ticket=True)
    if unsigned.keys() != signed.keys():
        only_unsigned = sorted(unsigned.keys() - signed.keys())
        only_signed = sorted(signed.keys() - unsigned.keys())
        raise ValueError(f"app entry mismatch: unsigned-only={only_unsigned}, signed-only={only_signed}")
    for path in sorted(unsigned):
        left_type, left_mode, left_data = unsigned[path]
        right_type, right_mode, right_data = signed[path]
        if left_type != right_type or left_mode != right_mode:
            raise ValueError(f"type or mode differs: {path}")
        if left_type == "symlink" and left_data != right_data:
            raise ValueError(f"symlink target differs: {path}")
        if left_type != "file" or left_data == right_data:
            continue
        assert isinstance(left_data, bytes) and isinstance(right_data, bytes)
        if left_data[:4] in MACHO_MAGICS | FAT_MAGICS and right_data[:4] in MACHO_MAGICS | FAT_MAGICS:
            if same_macho_payload(left_data, right_data):
                continue
        raise ValueError(f"file payload differs: {path} (unsigned SHA-256 {hashlib.sha256(left_data).hexdigest()})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("unsigned_app", type=Path)
    parser.add_argument("signed_app", type=Path)
    args = parser.parse_args()
    try:
        compare(args.unsigned_app, args.signed_app)
    except (OSError, ValueError, struct.error) as error:
        print(f"app payload comparison failed: {error}", file=sys.stderr)
        return 1
    print("App code, resources, modes and symlinks match after code-signature normalization.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
