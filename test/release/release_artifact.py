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
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'make'))
from runtime_origins import verify_origins, PJASS_RELEASE, PJASS_SHA256

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
    expected_suites = 16 if tuple(map(int, expected_metadata['version'].split('-')[0].split('.'))) >= (1, 1, 0) else 14
    assert info["validation"]["extracted_package_suites_passed"] == expected_suites, "Missing compatibility suite gate"
    verify_origins(files, info)
    if expected_suites == 16:
        assert info['native_runtime']['rebuilt'] is True, 'Version 1.1+ requires the verified rebuilt StormLib'
        assert any(item['path'] == 'bin/pjass.exe' and item['origin'] == 'added'
                   for item in info['native_runtime']['files']), 'Missing verified pjass helper'
    return files, archive_hash


def validate_windows_report(path, archive_hash, expected_version=None, expected_files=None):
    report = json.loads(Path(path).read_text(encoding="utf-8"))
    expected_version = expected_version or metadata()["version"]
    assert report["version"] == expected_version, "Windows tested another release version"
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
    if tuple(map(int, expected_version.split('-')[0].split('.'))) >= (1, 1, 0):
        assert all(item.get('pjass') == {'before': 'Passed', 'after': 'Passed'} for item in conversions), \
            'Known-valid native conversions did not pass real pjass'
        check = report.get('pjass_verification', {})
        assert check.get('status') == 'passed' and check.get('report_only') is True, 'Missing native pjass evidence'
        assert check.get('release') == PJASS_RELEASE and check.get('checker_sha256') == PJASS_SHA256, 'Wrong pjass pin'
        expected = {
            'current-valid': ('Passed', 'warcraft-current'), 'legacy-127-valid': ('Passed', 'enUS-1.27.1'),
            'legacy-124-valid': ('Passed', 'zhCN-1.24.4'), 'modern-current': ('Passed', 'warcraft-current'),
            'current-fixture': ('Passed', 'warcraft-current'), 'invalid-syntax': ('Failed', 'warcraft-current'),
            'invalid-type': ('Failed', 'warcraft-current'), 'modern-legacy-mismatch': ('Failed', 'enUS-1.27.1'),
            'suppressed-errors': ('Failed', 'warcraft-current'), 'lua-skipped': ('Skipped', 'warcraft-current'),
        }
        cases = check.get('checks', [])
        assert len(cases) == len(expected) and {item['name']: (item['status'], item['dataset']) for item in cases} == expected, \
            'Missing or mismatched native pjass cases'
        for case in cases:
            if case['status'] == 'Passed':
                assert case['checker_exit_code'] == 0 and case['ignored_errors'] == 0 and case['raw_output_bytes'] > 0
            elif case['status'] == 'Failed':
                assert case['diagnostic_count'] > 0 and case['raw_output_bytes'] > 0
                assert case['checker_exit_code'] != 0 or case['ignored_errors'] > 0
            else:
                assert case['checker_exit_code'] is None and case['raw_output_bytes'] == 0
        invalid = check.get('report_only_conversion', {})
        assert invalid.get('errors') == invalid.get('warnings') == 0 and invalid.get('mode') == 'obj'
        assert invalid.get('pjass') == {'before': 'Failed', 'after': 'Failed'}, 'Failed checks were hidden'
        assert all(invalid.get(key) is True for key in ('output_exists', 'output_script_preserved', 'input_unchanged')), \
            'pjass incorrectly blocked or modified otherwise valid conversion output'
        assert re.fullmatch(r'[0-9a-f]{64}', invalid.get('output_sha256', '')), 'Missing report-only output evidence'
        assert expected_files is not None, 'Exact packaged ABI and DLL bytes are required'
        abi = json.loads(expected_files['NATIVE_ABI.json'])
        live = report.get('native_abi_verification', {})
        assert live.get('status') == 'passed' and live.get('native_file_info_verified') is True, 'Missing live native ABI check'
        assert live.get('abi_sha256') == sha256(expected_files['NATIVE_ABI.json'])
        assert live.get('dll_sha256') == sha256(expected_files['bin/stormlib.dll']), 'Windows queried another DLL'
        assert live.get('pointer_size') == abi['pointer_size'] == 4 and live.get('dword_size') == abi['dword_size'] == 4
        assert live.get('create_size') == abi['sizes']['SFILE_CREATE_MPQ'] == 48
        assert live.get('find_size') == abi['sizes']['SFILE_FIND_DATA'] == 296
        assert live.get('create_offsets_verified') == len(abi['offsets']['create']) == 12
        assert live.get('find_offsets_verified') == len(abi['offsets']['find']) == 10
        assert live.get('exports_verified') == len(abi['exports'])
        assert set(live.get('constants_queried', [])) == {
            'SFileMpqNumberOfFiles', 'SFileMpqFlags', 'SFileInfoLocale', 'SFileInfoFileIndex',
            'SFileInfoByteOffset', 'SFileInfoFileTime', 'SFileInfoFileSize', 'SFileInfoCompressedSize', 'SFileInfoFlags'}
        assert report.get('public_archive_actions_removed') is True, 'Missing public archive action retirement checks'
        assert all('script/backend/cli/' + action + '.lua' not in expected_files
                   for action in ('analyze', 'optimize')), 'Retired archive commands are still packaged as public actions'
        gui = report.get('gui_archive_actions', {})
        assert gui.get('status') == 'passed' and gui.get('headless') is True, 'Missing native conversion/private worker evidence'
        assert gui.get('internal_regression_only') is True, 'Retired archive checks must be labeled private regressions'
        assert gui.get('interactive_dialog_tested') is False, 'Headless checks cannot claim interactive dialog testing'
        native_dialog = gui.get('native_dialog', {})
        assert native_dialog.get('status') == 'passed', 'Missing actual isolated Save As evidence'
        assert native_dialog.get('hook_used') is False, 'A hook can change the real Save As implementation'
        for key in ('input_desktop_switched', 'interactive_dialog_tested', 'gui_rendering_tested'):
            assert native_dialog.get(key) is False, 'Isolated Save As checks cannot claim ' + key
        for key in ('isolated_desktop', 'owner_error_ffff_reproduced', 'invalid_owner_discarded',
                    'unowned_retry_verified', 'unicode_verified', 'cancellation_verified', 'inputs_unchanged', 'output_entry_verified'):
            assert native_dialog.get(key) is True, 'Missing native GUI check: ' + key
        assert all(gui.get(key) is True for key in (
            'dialog_abi_verified', 'dialog_unicode_buffers_verified', 'dialog_cancel_and_errors_verified',
            'lni_folder_analyzed', 'lni_marker_analyzed', 'lni_project_unchanged',
            'optimization_worker_verified', 'failure_reports_verified', 'failure_recovery_verified')), 'Incomplete GUI archive regression evidence'
        lossless = report.get('lossless_archive', {})
        assert lossless.get('status') == 'passed', 'Missing native lossless archive checks'
        assert lossless.get('internal_regression_only') is True, 'Retired archive checks must be labeled private regressions'
        assert all(lossless.get(key) is True for key in (
            'source_unchanged', 'decoded_payloads_equal', 'bookkeeping_equal', 'outer_header_equal',
            'unicode_paths_tested', 'unknown_editor_hd_data_preserved', 'existing_output_refused',
            'output_race_preserved', 'cancellation_cleaned_up', 'cli_cancellation_verified')), 'Incomplete lossless preservation/safety evidence'
        assert lossless.get('attempted_sector_sizes') == [512, 4096, 65536]
        assert lossless.get('verified_sector_sizes') == [4096, 65536] and lossless.get('skipped_sector_sizes') == [512]
        assert lossless.get('native_savings', 0) > 0 and lossless.get('cli_savings', 0) > 0
        assert lossless.get('native_output_bytes', 0) > 0 and lossless.get('native_selected_sector_size') in (4096, 65536)
        assert re.fullmatch(r'[0-9a-f]{64}', lossless.get('cli_output_sha256', ''))
        assert lossless.get('pjass') == {'analyze_input': 'Passed', 'optimize_input': 'Passed', 'optimize_output': 'Passed'}

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
            validate_windows_report(args.windows_report, digest, release["version"], files)
        print(f"PASS independent final artifact verification: {len(files)} files, SHA-256 {digest}")


if __name__ == "__main__":
    main()
