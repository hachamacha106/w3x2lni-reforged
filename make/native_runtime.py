#!/usr/bin/env python3
"""Build and probe the pinned native archive component, never package arbitrary DLLs.

Windows: python -B make/native_runtime.py build --target windows-x86 --output build/native
Linux:   python3 -B make/native_runtime.py build --target linux-x64 --output build/mpq-runtime
Only StormLib is rebuilt. Other application DLLs retain their upstream provenance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STORMLIB_COMMIT = "6bb1882bd00ddbc3729cac5dac0fda81a61e5514"
ZLIB_COMMIT = "da607da739fa6047df13e66a2af6b8bec7c2a498"
PINS = {"stormlib": STORMLIB_COMMIT, "zlib": ZLIB_COMMIT}
REQUIRED_EXPORTS = {
    "SFileCreateArchive2", "SFileOpenArchive", "SFileCompactArchive", "SFileCloseArchive",
    "SFileAddFileEx", "SFileExtractFile", "SFileHasFile", "SFileSetMaxFileCount",
    "SFileCreateFile", "SFileWriteFile", "SFileFinishFile", "SFileOpenFileEx",
    "SFileReadFile", "SFileGetFileSize", "SFileCloseFile", "SFileRemoveFile",
    "SFileGetFileInfo", "SFileGetLocale", "SCompCompress", "SCompDecompress",
    "SFileFindFirstFile", "SFileFindNextFile", "SFileFindClose", "SFileEnumLocales",
    "SFileGetFileChecksums", "SFileVerifyFile",
}
FIND_OFFSETS_X86 = dict(zip(
    ("cFileName", "szPlainName", "dwHashIndex", "dwBlockIndex", "dwFileSize",
     "dwFileFlags", "dwCompSize", "dwFileTimeLo", "dwFileTimeHi", "lcLocale"),
    (0, 260, 264, 268, 272, 276, 280, 284, 288, 292)))
CREATE_OFFSETS_X86 = dict(zip(
    ("cbSize", "dwMpqVersion", "pvUserData", "cbUserData", "dwStreamFlags",
     "dwFileFlags1", "dwFileFlags2", "dwFileFlags3", "dwAttrFlags", "dwSectorSize",
     "dwRawChunkSize", "dwMaxFileCount"), range(0, 48, 4)))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], text=True).strip()


def verify_source(path, expected):
    path = Path(path).resolve()
    if git(path, "rev-parse", "HEAD") != expected:
        raise ValueError("Unexpected dependency revision: " + str(path))
    if git(path, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Native dependency source must be clean: " + str(path))
    return path


def validate_probe(probe, target):
    if probe.get("schema_version") != 1 or probe.get("status") != "passed":
        raise ValueError("Native probe did not pass")
    if probe.get("versions") != {"stormlib": "9.40", "zlib": "1.3.2"}:
        raise ValueError("Probe used different dependency versions")
    if probe.get("dword_size") != 4:
        raise ValueError("Native DWORD does not match the FFI")
    constants = probe.get("constants", {})
    expected = {"SFileMpqNumberOfFiles": 36, "SFileMpqFlags": 39,
                "SFileInfoLocale": 47, "SFileInfoFileIndex": 48,
                "SFileInfoByteOffset": 49, "SFileInfoFileTime": 50,
                "SFileInfoFileSize": 51, "SFileInfoCompressedSize": 52,
                "SFileInfoFlags": 53, "MPQ_COMPRESSION_ZLIB": 2}
    if any(constants.get(name) != value for name, value in expected.items()):
        raise ValueError("StormLib header constants do not match the FFI")
    if not REQUIRED_EXPORTS.issubset(set(probe.get("exports", []))):
        raise ValueError("Missing native archive APIs")
    smoke = probe.get("smoke", {})
    if (smoke.get("attempted_sector_sizes") != [512, 4096, 65536]
            or smoke.get("sector_sizes") != [4096, 65536]
            or smoke.get("unsupported_sector_sizes") != [512]
            or smoke.get("sector_rejections") != [
                {"sector_size": 512, "error": 11,
                 "reason": "StormLib 9.40 rejects zero sector shift"}]):
        raise ValueError("Native sector capability/rejection checks incomplete")
    if not all(
            smoke.get(name) is True for name in
            ("payloads_equal", "empty_file", "unicode_member", "zlib_roundtrip")):
        raise ValueError("Native archive payload checks incomplete")
    if target == "windows-x86":
        if probe.get("pointer_size") != 4 or probe.get("sizes", {}).get("SFILE_CREATE_MPQ") != 48:
            raise ValueError("Windows DLL is not the required x86 ABI")
        if probe.get("offsets", {}).get("create") != CREATE_OFFSETS_X86:
            raise ValueError("Windows archive-create layout changed")
        if (probe.get("sizes", {}).get("SFILE_FIND_DATA") != 296 or
                probe.get("offsets", {}).get("find") != FIND_OFFSETS_X86):
            raise ValueError("Windows archive-enumeration layout changed")
    elif target == "linux-x64":
        if probe.get("pointer_size") != 8:
            raise ValueError("Linux bridge must use its probed x64 ABI")
    else:
        raise ValueError("Unsupported native target: " + target)


def validate_pe_x86_dll(content):
    """Independent target check; do not trust the build target's label."""
    if content[:2] != b"MZ" or len(content) < 64:
        raise ValueError("Native output is not PE")
    offset = struct.unpack_from("<I", content, 60)[0]
    if offset + 26 > len(content) or content[offset:offset + 4] != b"PE\0\0":
        raise ValueError("Invalid native PE header")
    machine, = struct.unpack_from("<H", content, offset + 4)
    characteristics, = struct.unpack_from("<H", content, offset + 22)
    magic, = struct.unpack_from("<H", content, offset + 24)
    if machine != 0x14c or magic != 0x10b or not characteristics & 0x2000:
        raise ValueError("Native output must be a Windows x86 DLL")
    return {"machine": "x86", "optional_header": "PE32", "dll": True}


def make_manifest(source_commit, source_tree, target, component, probe, compiler, cmake_version):
    validate_probe(probe, target)
    return {
        "schema_version": 1, "source_commit": source_commit, "source_tree": source_tree,
        "target": target,
        "components": [{
            "path": "bin/stormlib.dll" if target == "windows-x86" else "libstorm.so",
            "origin": "rebuilt", "sha256": sha256(component), "sources": dict(PINS),
            "build": {"configuration": "Release", "arch": "x86" if target == "windows-x86" else "x64",
                      "unicode": target == "windows-x86", "static_zlib": True,
                      "compiler": compiler, "crt": "static" if target == "windows-x86" else "system",
                      "cmake_version": cmake_version, "other_dependencies": "bundled at StormLib pin"},
            "probe": {"status": "passed", "abi_file": "abi.json", "data": probe},
        }],
    }


def build(target, output, cmake="cmake", source=None, zlib_source=None):
    if target == "windows-x86" and os.name != "nt":
        raise ValueError("Windows x86 builds require a native Windows runner")
    if target == "linux-x64" and (os.name == "nt" or platform.machine().lower() not in ("x86_64", "amd64")):
        raise ValueError("Linux bridge builds require a native x64 Linux runner")
    output = Path(output).resolve()
    source = verify_source(source or ROOT / "3rd/stormlib", STORMLIB_COMMIT)
    zlib_source = verify_source(zlib_source or ROOT / "3rd/zlib", ZLIB_COMMIT)
    if output == ROOT or (ROOT in output.parents and output.parts[len(ROOT.parts)] != "build"):
        raise ValueError("Repository native outputs belong under build/")
    output.mkdir(parents=True, exist_ok=True)
    # A stale passing manifest must never survive a failed build.
    manifest = output / "manifest.json"
    if manifest.exists():
        manifest.unlink()
    log_path = output / "build.log"
    with log_path.open("w", encoding="utf-8") as log:
        def run(arguments, capture=False):
            log.write("COMMAND: " + json.dumps(list(map(str, arguments))) + "\n")
            log.flush()
            result = subprocess.run(list(map(str, arguments)), text=True, encoding="utf-8",
                                    errors="replace", stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
            log.write(result.stdout)
            log.flush()
            if result.returncode:
                raise RuntimeError("Native command failed; see " + str(log_path) + "\n" + result.stdout[-6000:])
            return result.stdout
        cmake_version = run([cmake, "--version"]).splitlines()[0]
        generator = ["-G", "Visual Studio 17 2022", "-A", "Win32"] if target == "windows-x86" else ["-G", "Unix Makefiles"]
        prefix = output / "zlib-prefix"
        zbuild = output / "zlib-build"
        run([cmake, "-S", zlib_source, "-B", zbuild, *generator,
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
             "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
             "-DZLIB_BUILD_SHARED=OFF", "-DZLIB_BUILD_STATIC=ON", "-DZLIB_BUILD_TESTING=ON",
             "-DZLIB_INSTALL=ON",
             "-DCMAKE_INSTALL_PREFIX=" + prefix.as_posix(),
             "-DCMAKE_INSTALL_LIBDIR=lib"])
        run([cmake, "--build", zbuild, "--config", "Release", "--parallel", str(min(4, os.cpu_count() or 1))])
        ctest = str(Path(cmake).with_name("ctest.exe" if os.name == "nt" else "ctest")) if Path(cmake).parent != Path(".") else "ctest"
        run([ctest, "--test-dir", zbuild, "-C", "Release", "--output-on-failure"])
        run([cmake, "--install", zbuild, "--config", "Release"])
        libraries = list((prefix / "lib").glob("zs.lib" if target == "windows-x86" else "libz.a"))
        if len(libraries) != 1:
            raise ValueError("Missing exact staged static zlib")
        native_build = output / "cmake-build"
        run([cmake, "-S", ROOT / "make/native", "-B", native_build, *generator,
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
             "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
             "-DW2L_STORMLIB_SOURCE=" + source.as_posix(),
             "-DW2L_ZLIB_PREFIX=" + prefix.as_posix(),
             "-DW2L_ZLIB_LIBRARY=" + libraries[0].as_posix()])
        run([cmake, "--build", native_build, "--config", "Release", "--parallel", str(min(4, os.cpu_count() or 1))])
        artifacts = json.loads((native_build / "artifacts-Release.json").read_text())
        for name in ("library", "probe"):
            if not Path(artifacts[name]).resolve().is_relative_to(native_build):
                raise ValueError("Build artifact escaped native build directory")
        # Use a fresh directory to avoid stale archives influencing probes.
        with tempfile.TemporaryDirectory(prefix="native-probe-\u010d\u00ed\u0148\u00e1-", dir=output) as directory:
            probe = json.loads(run([artifacts["probe"], directory], capture=True))
        validate_probe(probe, target)
        destination = output / ("bin/stormlib.dll" if target == "windows-x86" else "libstorm.so")
        content = Path(artifacts["library"]).read_bytes()
        if target == "windows-x86":
            probe["pe"] = validate_pe_x86_dll(content)
        else:
            if content[:5] != b"\x7fELF\x02":
                raise ValueError("Linux bridge output must be ELF64")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        (output / "abi.json").write_text(json.dumps(probe, indent=2) + "\n", encoding="utf-8")
        # Check again after compilation: generated files cannot dirty dependencies.
        verify_source(source, STORMLIB_COMMIT)
        verify_source(zlib_source, ZLIB_COMMIT)
        data = make_manifest(git(ROOT, "rev-parse", "HEAD"), git(ROOT, "rev-parse", "HEAD^{tree}"),
                             target, destination, probe, artifacts["compiler"], cmake_version)
        data["components"][0]["probe"]["abi_sha256"] = sha256(output / "abi.json")
        data["components"][0]["build"]["static_zlib_sha256"] = sha256(libraries[0])
        data["components"][0]["build"]["c_compiler"] = artifacts["c_compiler"]
        data["build_inputs"] = {path: sha256(ROOT / path) for path in
                                ("make/native_runtime.py", "make/native/CMakeLists.txt", "make/native/probe.cpp")}
        manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("build")
    command.add_argument("--target", choices=("windows-x86", "linux-x64"),
                         default="windows-x86" if os.name == "nt" else "linux-x64")
    command.add_argument("--output", type=Path, default=ROOT / "build/native")
    command.add_argument("--cmake", default="cmake")
    args = parser.parse_args()
    print(json.dumps({"library": str(build(args.target, args.output, args.cmake)),
                      "manifest": str(args.output.resolve() / "manifest.json")}, indent=2))


if __name__ == "__main__":
    main()
