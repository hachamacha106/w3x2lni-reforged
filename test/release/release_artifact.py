#!/usr/bin/env python3
"""Small independent checks shared by release CI and native Windows tests."""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import zipfile

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM_SHA256 = "58c6523b6d34fea55b6904f40298b24f72367f7d975494cb7dff23cb1241c440"
FIXTURE_SHA256 = "293af514783fdd0fc71aeff7170c1931f38a2f6bae55e0c29614da75ed3da553"


def sha256(content):
    return hashlib.sha256(content).hexdigest()


def metadata(path=None):
    path = Path(path) if path else ROOT / "release.json"
    result = json.loads(path.read_text(encoding="utf-8"))
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", result["version"]), "Invalid version"
    assert result["tag"] == "v" + result["version"], "Tag must match the version"
    assert re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", result["repository"]), "Invalid repository"
    for key in ("archive_root", "asset_name"):
        assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", result[key]), "Unsafe " + key
        assert not result[key].endswith("."), "Unsafe " + key
    assert result["asset_name"].endswith(".zip"), "The release asset must be a ZIP"
    for key in ("product_name", "display_version"):
        assert isinstance(result[key], str) and result[key] and "\n" not in result[key] and "\r" not in result[key]
    return result


def workflow_outputs(values):
    destination = os.environ.get("GITHUB_OUTPUT")
    if destination:
        with open(destination, "a", encoding="utf-8") as output:
            for key, value in values.items():
                assert "\n" not in str(value) and "\r" not in str(value)
                output.write(f"{key}={value}\n")


def runtime_fingerprint(files):
    payload = {name: sha256(content) for name, content in files.items()
               if name.startswith(("script/", "test/", "make/", "data/", "bin/"))
               or name in ("config.ini", "release.json")
               or ("/" not in name and name.lower().endswith((".exe", ".dll")))}
    return sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())


def inspect_archive(archive_path, expected_metadata, checksum_path=None, expected_sha256=None):
    archive_path = Path(archive_path)
    archive_hash = sha256(archive_path.read_bytes())
    assert archive_path.name == expected_metadata["asset_name"], "Unexpected release filename"
    if expected_sha256:
        assert re.fullmatch(r"[0-9a-f]{64}", expected_sha256), "Invalid expected ZIP checksum"
        assert archive_hash == expected_sha256, "ZIP differs from the Linux-validated asset"
    if checksum_path:
        entries = Path(checksum_path).read_text(encoding="utf-8").splitlines()
        assert len(entries) == 1, "Expected one external ZIP checksum"
        digest, filename = entries[0].split("  ", 1)
        assert filename == archive_path.name and digest == archive_hash, "External ZIP checksum mismatch"
    files = {}
    with zipfile.ZipFile(archive_path) as archive:
        assert archive.testzip() is None, "ZIP CRC failure"
        names = archive.namelist()
        assert len(names) == len(set(names)), "Duplicate ZIP members"
        for item in archive.infolist():
            name = item.filename
            parts = PurePosixPath(name).parts
            assert parts and parts[0] == expected_metadata["archive_root"], "Wrong archive root"
            assert not name.startswith("/") and "\\" not in name and ":" not in name and ".." not in parts, name
            if item.is_dir():
                continue
            assert len(parts) > 1, name
            relative = "/".join(parts[1:])
            files[relative] = archive.read(item)
    assert len(files) == len({name.casefold() for name in files}), "Windows filename collision"
    manifest = {}
    for line in files["CHECKSUMS.sha256"].decode("utf-8").splitlines():
        digest, name = line.split("  ", 1)
        assert re.fullmatch(r"[0-9a-f]{64}", digest) and name not in manifest, "Invalid checksum entry"
        manifest[name] = digest
    assert set(manifest) == set(files) - {"CHECKSUMS.sha256"}, "Incomplete checksum coverage"
    for name, digest in manifest.items():
        assert sha256(files[name]) == digest, "Package checksum mismatch: " + name
    assert json.loads(files["release.json"]) == expected_metadata, "Packaged metadata differs from source"
    changelog = files["script/share/changelog.lua"].decode("utf-8-sig")
    version = re.search(r"\bversion\s*=\s*['\"]([^'\"]+)['\"]", changelog)
    assert version and version[1] == expected_metadata["version"], "Application version mismatch"
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(files["config.ini"].decode("utf-8-sig"))
    assert config["global"]["data"] == "warcraft-current", "Current dataset is not selected"
    for key in ("data_meta", "data_ui", "data_wes"):
        assert config["global"][key] == "${DATA}", "Wrong current-data setting: " + key
    assert config.getboolean("lni", "read_slk") and config.getboolean("obj", "read_slk")
    assert sha256(files["test/fixtures/HiTestMapFromWorldEditor.w3x"]) == FIXTURE_SHA256
    info = json.loads(files["BUILD_INFO.json"])
    assert info["package_runtime_fingerprint"] == runtime_fingerprint(files), "Runtime fingerprint mismatch"
    verification = json.loads(files["PACKAGE_VERIFICATION.json"])
    assert verification["status"] == "validated", "A candidate cannot be released"
    assert verification["package_runtime_fingerprint"] == info["package_runtime_fingerprint"]
    assert info["validation"]["extracted_package_suites_passed"] == 14, "Missing compatibility suite gate"
    assert info["native_runtime"]["rebuilt"] is False, "This release path must retain the official runtime"
    return files, archive_hash


def validate_windows_report(path, archive_hash):
    report = json.loads(Path(path).read_text(encoding="utf-8"))
    assert report["status"] == "passed", "Windows smoke tests did not pass"
    assert report["archive_sha256"] == archive_hash, "Windows tested a different release ZIP"
    assert report["archive_unchanged"] and report["packaged_inputs_unchanged"]
    assert report["native_windows_execution"], "The Windows runtime was not exercised"
    conversions = report["conversions"]
    assert report["conversion_count"] == len(conversions) == 4
    assert {item["name"] for item in conversions} == {"obj", "lni", "lni-to-obj", "slk"}
    assert all(item["errors"] == 0 and item["warnings"] == 0 and item["native_contents_verified"]
               for item in conversions), "A native conversion gate failed"
    assert report["steps"] and all(item["exit_code"] == 0 for item in report["steps"])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("metadata")
    upstream = commands.add_parser("upstream")
    upstream.add_argument("archive", type=Path)
    checksum = commands.add_parser("checksum")
    checksum.add_argument("archive", type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("--archive", type=Path, required=True)
    verify.add_argument("--checksum", type=Path, required=True)
    verify.add_argument("--expected-sha256")
    verify.add_argument("--windows-report", type=Path)
    args = parser.parse_args()
    if args.command == "upstream":
        assert sha256(args.archive.read_bytes()) == UPSTREAM_SHA256, "Unexpected official runtime ZIP"
        print("PASS pinned official 2.7.3 runtime checksum")
        return
    release = metadata()
    if args.command == "metadata":
        if os.environ.get("GITHUB_REF_TYPE") == "tag":
            assert os.environ["GITHUB_REF_NAME"] == release["tag"], "Pushed tag differs from release.json"
        changelog = (ROOT / "script/share/changelog.lua").read_text(encoding="utf-8-sig")
        version = re.search(r"\bversion\s*=\s*['\"]([^'\"]+)['\"]", changelog)
        assert version and version[1] == release["version"], "Changelog version differs from release.json"
        assert (ROOT / "docs/releases" / (release["version"] + ".md")).is_file(), "Missing release notes"
        workflow_outputs({key: release[key] for key in
                          ("version", "tag", "asset_name", "archive_root", "product_name", "display_version")})
        print(f"PASS {release['product_name']} {release['version']} metadata")
    elif args.command == "checksum":
        assert args.archive.name == release["asset_name"], "Unexpected release filename"
        digest = sha256(args.archive.read_bytes())
        Path(str(args.archive) + ".sha256").write_text(
            f"{digest}  {args.archive.name}\n", encoding="utf-8")
        workflow_outputs({"sha256": digest})
        print(f"{digest}  {args.archive.name}")
    else:
        files, digest = inspect_archive(args.archive, release, args.checksum, args.expected_sha256)
        if args.windows_report:
            validate_windows_report(args.windows_report, digest)
        print(f"PASS independent final artifact verification: {len(files)} files, SHA-256 {digest}")


if __name__ == "__main__":
    main()
