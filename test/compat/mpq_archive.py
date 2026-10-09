#!/usr/bin/env python3
"""Test-only MPQ read/write bridge using the repository's real StormLib.

This Linux helper is separate from the Windows application's FFI. It lets the
compatibility tests extract and rebuild actual .w3x archives without mocking MPQ
compression. It is not a game or World Editor validation tool.

Build the pinned submodule (or a checkout of that exact commit) without installing:
  python3 test/compat/mpq_archive.py build 3rd/stormlib /tmp/mpq-runtime
List/extract/repack using the resulting library:
  python3 test/compat/mpq_archive.py --library /tmp/mpq-runtime/libstorm.so list map.w3x
  python3 test/compat/mpq_archive.py --library /tmp/mpq-runtime/libstorm.so extract map.w3x extracted
  python3 test/compat/mpq_archive.py --library /tmp/mpq-runtime/libstorm.so pack extracted rebuilt.w3x

The pack command regenerates MPQ bookkeeping files, preserving the filenames and
bytes of map content. Extraction refuses path traversal and duplicate names;
localized duplicate MPQ entries must be handled explicitly with the Python API.
"""

from __future__ import annotations

import argparse
import ctypes as C
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import importlib.util


STORMLIB_COMMIT = "6bb1882bd00ddbc3729cac5dac0fda81a61e5514"
STORMLIB_SOURCE = "https://github.com/ladislav-zezula/StormLib"
INTERNAL_FILES = {"(listfile)", "(attributes)", "(signature)"}
DWORD, HANDLE = C.c_uint32, C.c_void_p


def native_builder():
    spec = importlib.util.spec_from_file_location(
        "w2l_native_runtime", Path(__file__).resolve().parents[2] / "make/native_runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_stormlib(source: Path, output: Path) -> Path:
    """Use the same pinned CMake recipe and compiled ABI probe as Windows."""
    module = native_builder()
    library = module.build("linux-x64", output, source=source)
    manifest = json.loads((output / "manifest.json").read_text())
    (output / "provenance.json").write_text(json.dumps({
        "source": STORMLIB_SOURCE, "commit": STORMLIB_COMMIT,
        "dependencies": manifest["components"][0]["sources"],
        "sha256": module.sha256(library),
        "manifest": "manifest.json", "abi": "abi.json",
        "purpose": "Linux test-only MPQ bridge; not the Windows application DLL",
    }, indent=2) + "\n")
    return library


class FindData(C.Structure):
    # MAX_PATH is 1024 in the pinned StormPort.h on non-Windows platforms.
    _fields_ = [("filename", C.c_char * 1024), ("plain_name", C.c_void_p),
                ("hash_index", DWORD), ("block_index", DWORD), ("size", DWORD),
                ("flags", DWORD), ("compressed_size", DWORD),
                ("time_lo", DWORD), ("time_hi", DWORD), ("locale", DWORD)]


@dataclass(frozen=True)
class Member:
    name: str
    size: int
    compressed_size: int
    flags: int
    locale: int
    block_index: int


class StormLib:
    def __init__(self, library: str | Path):
        if os.name == "nt":
            raise RuntimeError("This test bridge targets the pinned Linux ABI, not Windows DLLs")
        library = Path(library).resolve()
        module = native_builder()
        manifest = json.loads((library.parent / "manifest.json").read_text())
        probe = json.loads((library.parent / "abi.json").read_text())
        module.validate_probe(probe, "linux-x64")
        component = manifest["components"][0]
        if (manifest.get("schema_version") != 1 or manifest.get("target") != "linux-x64"
                or component.get("path") != "libstorm.so" or component.get("origin") != "rebuilt"
                or component.get("sources") != module.PINS
                or component.get("sha256") != module.sha256(library)
                or component.get("probe", {}).get("status") != "passed"
                or component.get("probe", {}).get("data") != probe
                or component.get("probe", {}).get("abi_sha256") != module.sha256(library.parent / "abi.json")):
            raise ValueError("Linux native bridge provenance mismatch")
        fields = ("cFileName", "szPlainName", "dwHashIndex", "dwBlockIndex", "dwFileSize",
                  "dwFileFlags", "dwCompSize", "dwFileTimeLo", "dwFileTimeHi", "lcLocale")
        expected = {native: getattr(FindData, python).offset
                    for native, (python, _) in zip(fields, FindData._fields_)}
        if (probe["sizes"]["SFILE_FIND_DATA"] != C.sizeof(FindData)
                or probe["offsets"]["find"] != expected):
            raise ValueError("Linux ctypes layout differs from compiled StormLib headers")
        self.lib = C.CDLL(str(library))
        signatures = {
            "SErrGetLastError": (DWORD, []),
            "SFileSetLocale": (DWORD, [DWORD]),
            "SFileOpenArchive": (C.c_bool, [C.c_char_p, DWORD, DWORD, C.POINTER(HANDLE)]),
            "SFileCreateArchive": (C.c_bool, [C.c_char_p, DWORD, DWORD, C.POINTER(HANDLE)]),
            "SFileCloseArchive": (C.c_bool, [HANDLE]),
            "SFileFindFirstFile": (HANDLE, [HANDLE, C.c_char_p, C.POINTER(FindData), C.c_char_p]),
            "SFileFindNextFile": (C.c_bool, [HANDLE, C.POINTER(FindData)]),
            "SFileFindClose": (C.c_bool, [HANDLE]),
            "SFileHasFile": (C.c_bool, [HANDLE, C.c_char_p]),
            "SFileOpenFileEx": (C.c_bool, [HANDLE, C.c_char_p, DWORD, C.POINTER(HANDLE)]),
            "SFileGetFileSize": (DWORD, [HANDLE, C.POINTER(DWORD)]),
            "SFileReadFile": (C.c_bool, [HANDLE, C.c_void_p, DWORD, C.POINTER(DWORD), C.c_void_p]),
            "SFileCloseFile": (C.c_bool, [HANDLE]),
            "SFileCreateFile": (C.c_bool, [HANDLE, C.c_char_p, C.c_uint64, DWORD, DWORD, DWORD, C.POINTER(HANDLE)]),
            "SFileWriteFile": (C.c_bool, [HANDLE, C.c_void_p, DWORD, DWORD]),
            "SFileFinishFile": (C.c_bool, [HANDLE]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = result, arguments

    def check(self, ok, operation):
        if not ok:
            raise OSError(int(self.lib.SErrGetLastError()), operation)

    def open(self, path: str | Path) -> "Archive":
        handle = HANDLE()
        self.check(self.lib.SFileOpenArchive(os.fsencode(path), 0, 0x100, C.byref(handle)),
                   f"SFileOpenArchive: {path}")
        return Archive(self, handle, False)

    def create(self, path: str | Path, max_files: int = 1024) -> "Archive":
        path = Path(path)
        if path.exists():
            raise FileExistsError(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = HANDLE()
        self.check(self.lib.SFileCreateArchive(os.fsencode(path), 0x00300000, max_files, C.byref(handle)),
                   f"SFileCreateArchive: {path}")
        return Archive(self, handle, True)


class Archive:
    def __init__(self, storm: StormLib, handle: HANDLE, writable: bool):
        self.storm, self.handle, self.writable = storm, handle, writable

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close()

    def close(self):
        if self.handle:
            handle, self.handle = self.handle, None
            self.storm.check(self.storm.lib.SFileCloseArchive(handle), "SFileCloseArchive")

    @staticmethod
    def name_bytes(name: str) -> bytes:
        return name.replace("/", "\\").encode("utf-8", "surrogateescape")

    def has(self, name: str) -> bool:
        return bool(self.storm.lib.SFileHasFile(self.handle, self.name_bytes(name)))

    def members(self) -> list[Member]:
        data = FindData()
        handle = self.storm.lib.SFileFindFirstFile(self.handle, b"*", C.byref(data), None)
        if not handle:
            code = self.storm.lib.SErrGetLastError()
            if code in (2, 1001):
                return []
            raise OSError(code, "SFileFindFirstFile")
        found = []
        try:
            while True:
                found.append(Member(data.filename.decode("utf-8", "surrogateescape"), data.size,
                                    data.compressed_size, data.flags, data.locale, data.block_index))
                if not self.storm.lib.SFileFindNextFile(handle, C.byref(data)):
                    code = self.storm.lib.SErrGetLastError()
                    if code != 1001:
                        raise OSError(code, "SFileFindNextFile")
                    break
        finally:
            self.storm.check(self.storm.lib.SFileFindClose(handle), "SFileFindClose")
        return found

    def read(self, name: str, locale: int = 0) -> bytes:
        # StormLib's selected locale is global, so this helper is not thread-safe.
        lib = self.storm.lib
        previous = lib.SFileSetLocale(locale)
        handle = HANDLE()
        try:
            self.storm.check(lib.SFileOpenFileEx(self.handle, self.name_bytes(name), 0, C.byref(handle)),
                             f"SFileOpenFileEx: {name}")
            high = DWORD()
            low = lib.SFileGetFileSize(handle, C.byref(high))
            if low == 0xFFFFFFFF or high.value:
                raise ValueError(f"Unsupported or unreadable member size: {name}")
            result = C.create_string_buffer(low)
            count = DWORD()
            if low:
                self.storm.check(lib.SFileReadFile(handle, result, low, C.byref(count), None),
                                 f"SFileReadFile: {name}")
                if count.value != low:
                    raise IOError(f"Short MPQ read: {name}: {count.value}/{low}")
            return result.raw
        finally:
            if handle:
                self.storm.check(lib.SFileCloseFile(handle), "SFileCloseFile")
            lib.SFileSetLocale(previous)

    def write(self, name: str, data: bytes, locale: int = 0):
        if not self.writable:
            raise ValueError("Archive is read-only")
        if name.lower() in INTERNAL_FILES:
            raise ValueError("StormLib regenerates MPQ bookkeeping; do not write reserved members")
        lib, handle = self.storm.lib, HANDLE()
        self.storm.check(lib.SFileCreateFile(self.handle, self.name_bytes(name), 0, len(data), locale,
                                             0x80000200, C.byref(handle)), f"SFileCreateFile: {name}")
        try:
            if data:
                buffer = C.create_string_buffer(data, len(data))
                self.storm.check(lib.SFileWriteFile(handle, buffer, len(data), 0x02), f"SFileWriteFile: {name}")
        finally:
            self.storm.check(lib.SFileFinishFile(handle), f"SFileFinishFile: {name}")


def safe_relative(name: str) -> Path:
    normalized = name.replace("\\", "/")
    path = PurePosixPath(normalized)
    if (not normalized or path.is_absolute() or ".." in path.parts
            or any(":" in part for part in path.parts) or "\0" in normalized):
        raise ValueError(f"Unsafe archive filename: {name!r}")
    return Path(*path.parts)


def extract(storm: StormLib, archive_path: Path, destination: Path) -> list[dict]:
    destination.mkdir(parents=True, exist_ok=True)
    inventory, seen = [], set()
    with storm.open(archive_path) as archive:
        for member in archive.members():
            relative = safe_relative(member.name)
            key = str(relative).casefold()
            if key in seen:
                raise ValueError(f"Duplicate member name or localized variant: {member.name}")
            seen.add(key)
            target = destination / relative
            if target.exists():
                raise FileExistsError(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError(f"Destination symlink escapes extraction directory: {target}")
            data = archive.read(member.name, member.locale)
            if len(data) != member.size:
                raise ValueError(f"Inventory size mismatch: {member.name}")
            target.write_bytes(data)
            inventory.append({**asdict(member), "sha256": hashlib.sha256(data).hexdigest()})
    return inventory


def pack(storm: StormLib, directory: Path, output: Path):
    directory = directory.resolve()
    if output.resolve().is_relative_to(directory):
        raise ValueError("Output archive must be outside its input directory")
    files = sorted(path for path in directory.rglob("*") if path.is_file()
                   and path.relative_to(directory).as_posix().lower() not in INTERNAL_FILES)
    seen = set()
    with storm.create(output, max(64, len(files) + 8)) as archive:
        for path in files:
            if path.is_symlink():
                raise ValueError(f"Refusing input symlink: {path}")
            name = path.relative_to(directory).as_posix()
            safe_relative(name)
            if name.casefold() in seen:
                raise ValueError(f"Case-insensitive duplicate filename: {name}")
            seen.add(name.casefold())
            archive.write(name, path.read_bytes())
    with storm.open(output) as archive:
        for path in files:
            name = path.relative_to(directory).as_posix()
            if archive.read(name) != path.read_bytes():
                raise ValueError(f"Rebuilt archive verification failed: {name}")
    return {"path": str(output), "content_members": len(files), "verified": True,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    build.add_argument("source", type=Path)
    build.add_argument("output", type=Path)
    for name in ("list", "extract"):
        command = commands.add_parser(name)
        command.add_argument("archive", type=Path)
        if name == "extract":
            command.add_argument("destination", type=Path)
    command = commands.add_parser("pack")
    command.add_argument("directory", type=Path)
    command.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "build":
        print(json.dumps({"library": str(build_stormlib(args.source, args.output)), "commit": STORMLIB_COMMIT}))
        return
    if not args.library:
        parser.error("--library is required for archive operations")
    storm = StormLib(args.library)
    if args.command == "list":
        with storm.open(args.archive) as archive:
            result = [asdict(member) for member in archive.members()]
    elif args.command == "extract":
        result = extract(storm, args.archive, args.destination)
    else:
        result = pack(storm, args.directory, args.output)
    print(json.dumps(result, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
