#!/usr/bin/env python3
"""Fail-closed native build manifest and ABI guard tests (no compiler needed)."""
from __future__ import annotations

import copy
import importlib.util
import json
import re
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("native_runtime", ROOT / "make/native_runtime.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def probe_fixture():
    # Independent representation of the ABI required by the retained x86 application.
    return {
        "schema_version": 1, "status": "passed",
        "versions": {"stormlib": "9.40", "zlib": "1.3.2"},
        "pointer_size": 4, "dword_size": 4,
        "sizes": {"SFILE_CREATE_MPQ": 48, "SFILE_FIND_DATA": 296},
        "offsets": {
            "create": {"cbSize": 0, "dwMpqVersion": 4, "pvUserData": 8, "cbUserData": 12,
                       "dwStreamFlags": 16, "dwFileFlags1": 20, "dwFileFlags2": 24,
                       "dwFileFlags3": 28, "dwAttrFlags": 32, "dwSectorSize": 36,
                       "dwRawChunkSize": 40, "dwMaxFileCount": 44},
            "find": {"cFileName": 0, "szPlainName": 260, "dwHashIndex": 264,
                     "dwBlockIndex": 268, "dwFileSize": 272, "dwFileFlags": 276,
                     "dwCompSize": 280, "dwFileTimeLo": 284, "dwFileTimeHi": 288,
                     "lcLocale": 292}},
        "constants": {"SFileMpqNumberOfFiles": 36, "SFileMpqFlags": 39,
                      "SFileInfoLocale": 47, "SFileInfoFileIndex": 48,
                      "SFileInfoByteOffset": 49, "SFileInfoFileTime": 50,
                      "SFileInfoFileSize": 51, "SFileInfoCompressedSize": 52,
                      "SFileInfoFlags": 53, "MPQ_COMPRESSION_ZLIB": 2},
        "exports": [
            "SFileCreateArchive2", "SFileOpenArchive", "SFileCompactArchive", "SFileCloseArchive",
            "SFileAddFileEx", "SFileExtractFile", "SFileHasFile", "SFileSetMaxFileCount",
            "SFileCreateFile", "SFileWriteFile", "SFileFinishFile", "SFileOpenFileEx",
            "SFileReadFile", "SFileGetFileSize", "SFileCloseFile", "SFileRemoveFile",
            "SFileGetFileInfo", "SFileGetLocale", "SCompCompress", "SCompDecompress",
            "SFileFindFirstFile", "SFileFindNextFile", "SFileFindClose", "SFileEnumLocales",
            "SFileGetFileChecksums", "SFileVerifyFile",
        ],
        "smoke": {"attempted_sector_sizes": [512, 4096, 65536],
                  "sector_sizes": [4096, 65536], "unsupported_sector_sizes": [512],
                  "sector_rejections": [{"sector_size": 512, "error": 11,
                                         "reason": "StormLib 9.40 rejects zero sector shift"}],
                  "payloads_equal": True,
                  "empty_file": True, "unicode_member": True, "zlib_roundtrip": True},
    }


def pe_fixture(machine=0x14c, magic=0x10b, dll=True):
    data = bytearray(256)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\0\0"
    struct.pack_into("<H", data, 132, machine)
    struct.pack_into("<H", data, 150, 0x2000 if dll else 0)
    struct.pack_into("<H", data, 152, magic)
    return data


class NativeRuntimeTests(unittest.TestCase):
    def test_retained_runtime_abi_accepted(self):
        native.validate_probe(probe_fixture(), "windows-x86")

    def test_sector_rejection_uses_each_platform_error_code(self):
        windows = probe_fixture()
        native.validate_probe(windows, "windows-x86")
        linux = probe_fixture()
        linux.update(pointer_size=8)
        linux["sizes"] = {"SFILE_CREATE_MPQ": 56, "SFILE_FIND_DATA": 1064}
        linux["offsets"]["create"] = dict(zip(native.CREATE_OFFSETS_X86,
                                              (0, 4, 8, 16, 20, 24, 28, 32, 36, 40, 44, 48)))
        linux["offsets"]["find"] = dict(zip(native.FIND_OFFSETS_X86,
                                            (0, 1024, 1032, 1036, 1040, 1044, 1048, 1052, 1056, 1060)))
        linux["smoke"]["sector_rejections"][0]["error"] = 1000
        native.validate_probe(linux, "linux-x64")
        for target, probe, incorrect in (("linux-x64", linux, 11),
                                         ("windows-x86", windows, 1000)):
            with self.subTest(target=target):
                probe["smoke"]["sector_rejections"][0]["error"] = incorrect
                with self.assertRaisesRegex(ValueError, "sector capability/rejection"):
                    native.validate_probe(probe, target)

    def test_wrong_version_width_layout_or_api_rejected(self):
        original = probe_fixture()
        mutations = [
            lambda p: p["versions"].update(zlib="1.2.5"),
            lambda p: p.update(pointer_size=8),
            lambda p: p.update(dword_size=8),
            lambda p: p["offsets"]["create"].update(dwAttrFlags=36),
            lambda p: p["offsets"]["find"].update(lcLocale=296),
            lambda p: p["constants"].update(SFileMpqNumberOfFiles=35),
            lambda p: p["exports"].remove("SCompCompress"),
            lambda p: p["exports"].remove("SFileEnumLocales"),
            lambda p: p["exports"].remove("SFileWriteFile"),
            lambda p: p["exports"].remove("SFileCompactArchive"),
            lambda p: p["smoke"].update(payloads_equal=False),
            lambda p: p["smoke"].update(sector_sizes=[4096]),
            lambda p: p["smoke"].update(attempted_sector_sizes=[4096, 65536]),
            lambda p: p["smoke"]["sector_rejections"][0].update(error=0),
        ]
        for mutate in mutations:
            probe = copy.deepcopy(original)
            mutate(probe)
            with self.subTest(probe=probe), self.assertRaises(ValueError):
                native.validate_probe(probe, "windows-x86")

    def test_export_guard_covers_production_ffi_and_compiled_probe(self):
        ffi_source = (ROOT / "script/ffi/stormlib.lua").read_text()
        declared = set(re.findall(r"__stdcall\s+((?:SFile|SComp)\w+)\s*\(", ffi_source))
        self.assertGreaterEqual(len(declared), 20)
        self.assertLessEqual(declared, native.REQUIRED_EXPORTS)
        probe_source = (ROOT / "make/native/probe.cpp").read_text()
        macro = probe_source.split("#define ARCHIVE_EXPORTS(X)", 1)[1].split("#define FIELD", 1)[0]
        references = set(re.findall(r"X\((\w+)\)", macro))
        self.assertEqual(references, native.REQUIRED_EXPORTS)

    def test_manifest_binds_bytes_and_source_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            component = Path(directory) / "stormlib.dll"
            component.write_bytes(pe_fixture())
            manifest = native.make_manifest("a" * 40, "b" * 40, "windows-x86",
                                            component, probe_fixture(), "MSVC 19.42", "cmake 3.31")
            entry = manifest["components"][0]
            self.assertEqual(entry["path"], "bin/stormlib.dll")
            self.assertEqual(entry["origin"], "rebuilt")
            self.assertEqual(entry["sources"], {
                "stormlib": "6bb1882bd00ddbc3729cac5dac0fda81a61e5514",
                "zlib": "da607da739fa6047df13e66a2af6b8bec7c2a498"})
            self.assertTrue(entry["build"]["unicode"] and entry["build"]["static_zlib"])
            self.assertEqual(entry["probe"]["status"], "passed")
            self.assertEqual(manifest["source_commit"], "a" * 40)
            first_hash = entry["sha256"]
            component.write_bytes(bytes(pe_fixture()) + b"changed")
            changed = native.make_manifest("a" * 40, "b" * 40, "windows-x86",
                                           component, probe_fixture(), "MSVC 19.42", "cmake 3.31")
            self.assertNotEqual(first_hash, changed["components"][0]["sha256"])
            self.assertEqual(json.loads(json.dumps(manifest)), manifest)

    def test_pe_checks_real_machine_not_target_label(self):
        self.assertEqual(native.validate_pe_x86_dll(pe_fixture())["machine"], "x86")
        for content in (pe_fixture(0x8664, 0x20b), pe_fixture(dll=False), b"not a DLL",
                        pe_fixture()[:140]):
            with self.subTest(content=content), self.assertRaises(ValueError):
                native.validate_pe_x86_dll(content)

    def test_source_verifier_rejects_wrong_or_dirty_checkout(self):
        with patch.object(native, "git", side_effect=["wrong"]):
            with self.assertRaisesRegex(ValueError, "revision"):
                native.verify_source(ROOT / "3rd/stormlib", native.STORMLIB_COMMIT)
        with patch.object(native, "git", side_effect=[native.STORMLIB_COMMIT, " M src/StormLib.h"]):
            with self.assertRaisesRegex(ValueError, "clean"):
                native.verify_source(ROOT / "3rd/stormlib", native.STORMLIB_COMMIT)
        with patch.object(native, "git", side_effect=[native.STORMLIB_COMMIT, "?? injected.cpp"]):
            with self.assertRaisesRegex(ValueError, "clean"):
                native.verify_source(ROOT / "3rd/stormlib", native.STORMLIB_COMMIT)

    def test_real_pinned_dependency_revisions_and_clean_sources(self):
        self.assertEqual(native.verify_source(ROOT / "3rd/stormlib", native.STORMLIB_COMMIT),
                         (ROOT / "3rd/stormlib").resolve())
        self.assertEqual(native.verify_source(ROOT / "3rd/zlib", native.ZLIB_COMMIT),
                         (ROOT / "3rd/zlib").resolve())


if __name__ == "__main__":
    unittest.main()
