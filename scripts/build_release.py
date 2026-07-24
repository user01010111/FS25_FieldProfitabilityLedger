#!/usr/bin/env python3
"""Build or verify the deterministic Field Profitability Ledger release ZIP."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tempfile
import xml.etree.ElementTree as ElementTree
import zipfile


ARCHIVE_NAME = "FS25_FieldProfitabilityLedger.zip"
FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
FILE_MODE = stat.S_IFREG | 0o644
MAX_ENTRY_SIZE = 64 * 1024 * 1024


class ReleaseValidationError(Exception):
    """A release source or archive did not satisfy the build contract."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def fail(code: str, detail: str) -> None:
    raise ReleaseValidationError(code, detail)


def validate_entry_name(name: str) -> None:
    if not name or name != name.strip() or "\\" in name or "\x00" in name:
        fail("entry_unsafe", f"unsafe archive entry: {name!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        fail("entry_unsafe", f"archive entry contains a control byte: {name!r}")
    parts = name.split("/")
    path = PurePosixPath(name)
    if (
        path.is_absolute()
        or any(part in ("", ".", "..") for part in parts)
        or ":" in parts[0]
        or str(path) != name
    ):
        fail("entry_unsafe", f"unsafe archive entry: {name!r}")


def manifest_entries(root: Path) -> tuple[str, ...]:
    manifest = root / "runtime-manifest.txt"
    try:
        data = manifest.read_bytes()
        entries = tuple(data.decode("ascii").splitlines())
    except (OSError, UnicodeError) as error:
        fail("manifest_read", f"cannot read {manifest}: {error}")
    if not entries:
        fail("manifest_entries", "runtime manifest must list the playable files")
    if len(entries) != len(set(entries)):
        fail("manifest_entries", "manifest entries must be unique")
    for entry in entries:
        validate_entry_name(entry)
    return entries


def source_payloads(root: Path, entries: tuple[str, ...]) -> dict[str, bytes]:
    payloads: dict[str, bytes] = {}
    for entry in entries:
        path = root / entry
        try:
            metadata = path.lstat()
        except OSError as error:
            fail("source_read", f"cannot inspect {path}: {error}")
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            fail("source_type", f"release source must be a regular file: {entry}")
        if metadata.st_size > MAX_ENTRY_SIZE:
            fail("source_size", f"release source exceeds size limit: {entry}")
        try:
            data = path.read_bytes()
        except OSError as error:
            fail("source_read", f"cannot read {path}: {error}")
        if len(data) != metadata.st_size:
            fail("source_changed", f"release source changed while reading: {entry}")
        payloads[entry] = data
    return payloads


def mod_metadata(root: Path) -> tuple[str, bool]:
    path = root / "modDesc.xml"
    try:
        document = ElementTree.parse(path)
    except (OSError, ElementTree.ParseError) as error:
        fail("moddesc_read", f"cannot parse {path}: {error}")
    root_element = document.getroot()
    version = root_element.findtext("version")
    multiplayer = root_element.find("multiplayer")
    supported = multiplayer.get("supported") if multiplayer is not None else None
    if root_element.tag != "modDesc" or version is None or not version.strip():
        fail("moddesc_metadata", "modDesc.xml has no valid version")
    if supported not in ("true", "false"):
        fail("moddesc_metadata", "modDesc.xml has no valid multiplayer flag")
    return version.strip(), supported == "true"


def zip_info(entry: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(entry, date_time=FIXED_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = FILE_MODE << 16
    info.internal_attr = 0
    info.flag_bits = 0
    info.extra = b""
    info.comment = b""
    return info


def write_archive(
    destination: Path,
    entries: tuple[str, ...],
    payloads: dict[str, bytes],
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and (
        destination.is_symlink() or not destination.is_file()
    ):
        fail("output_type", f"release output is not a regular file: {destination}")

    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w+b",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            with zipfile.ZipFile(
                temporary,
                mode="w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=9,
                allowZip64=True,
                strict_timestamps=True,
            ) as archive:
                archive.comment = b""
                for entry in entries:
                    archive.writestr(
                        zip_info(entry),
                        payloads[entry],
                        compress_type=zipfile.ZIP_DEFLATED,
                        compresslevel=9,
                    )
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, destination)
        temporary_path = None
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        fail("archive_write", f"cannot build {destination}: {error}")
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def verify_archive(root: Path | str, archive_path: Path | str) -> dict[str, object]:
    project_root = Path(root).resolve()
    archive_file = Path(archive_path).resolve()
    entries = manifest_entries(project_root)
    payloads = source_payloads(project_root, entries)
    version, multiplayer = mod_metadata(project_root)

    try:
        with zipfile.ZipFile(archive_file, mode="r") as archive:
            infos = archive.infolist()
            names = tuple(info.filename for info in infos)
            if names != entries:
                fail("archive_entries", "archive entries/order differ from manifest")
            if len(names) != len(set(names)):
                fail("archive_duplicate", "archive contains duplicate entries")
            if archive.comment:
                fail("archive_comment", "archive comment must be empty")
            for info in infos:
                validate_entry_name(info.filename)
                if info.is_dir():
                    fail("archive_type", f"directory entry is forbidden: {info.filename}")
                if info.date_time != FIXED_TIMESTAMP:
                    fail("archive_timestamp", f"unexpected timestamp: {info.filename}")
                if info.compress_type != zipfile.ZIP_DEFLATED:
                    fail("archive_compression", f"unexpected compression: {info.filename}")
                if info.create_system != 3 or (info.external_attr >> 16) != FILE_MODE:
                    fail("archive_mode", f"unexpected file mode: {info.filename}")
                if info.extra or info.comment:
                    fail("archive_metadata", f"unexpected metadata: {info.filename}")
                if info.file_size > MAX_ENTRY_SIZE:
                    fail("archive_size", f"archive entry is too large: {info.filename}")
                if archive.read(info) != payloads[info.filename]:
                    fail("payload_mismatch", f"source/archive mismatch: {info.filename}")
            corrupt = archive.testzip()
            if corrupt is not None:
                fail("archive_crc", f"CRC failure: {corrupt}")
    except ReleaseValidationError:
        raise
    except (OSError, KeyError, RuntimeError, zipfile.BadZipFile) as error:
        fail("archive_read", f"cannot verify {archive_file}: {error}")

    try:
        archive_bytes = archive_file.read_bytes()
    except OSError as error:
        fail("archive_read", f"cannot hash {archive_file}: {error}")
    return {
        "archive": str(archive_file),
        "entry_count": len(entries),
        "multiplayer": multiplayer,
        "sha256": hashlib.sha256(archive_bytes).hexdigest(),
        "size": len(archive_bytes),
        "version": version,
    }


def build_release(root: Path | str, output: Path | str) -> dict[str, object]:
    project_root = Path(root).resolve()
    destination = Path(output).expanduser().absolute()
    entries = manifest_entries(project_root)
    payloads = source_payloads(project_root, entries)
    write_archive(destination, entries, payloads)
    return verify_archive(project_root, destination)


def default_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", type=Path, help="verify an existing ZIP only")
    arguments = parser.parse_args(argv)
    root = arguments.root.resolve()
    output = arguments.output or root / "build" / ARCHIVE_NAME
    try:
        result = (
            verify_archive(root, arguments.verify)
            if arguments.verify is not None
            else build_release(root, output)
        )
    except ReleaseValidationError as error:
        print(f"FAIL release [{error.code}] {error.detail}", file=sys.stderr)
        return 1
    print(
        "PASS release "
        f"version={result['version']} "
        f"multiplayer={'enabled' if result['multiplayer'] else 'disabled'} "
        f"entries={result['entry_count']} "
        f"bytes={result['size']} "
        f"sha256={result['sha256']} "
        f"archive={result['archive']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
