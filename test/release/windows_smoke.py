#!/usr/bin/env python3
"""Test an exact release ZIP with its real Windows x86 EXE and DLLs.

Requires Windows and Python 3.10+. Creates a fresh, disposable extraction.
Does not launch the interactive application GUI, use an installed game, or extract CASC.
Actual Save As calls and editable output controls are checked on an owned,
non-input desktop that is never displayed.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

from release_artifact import FIXTURE_SHA256, inspect_archive, metadata, sha256
from runtime_origins import PJASS_RELEASE, PJASS_SHA256
from windows_save_dialog import run as verify_save_dialog


def locale_values(path):
    values, key = {}, None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        section = re.fullmatch(r"\[([^\]]+)\]", line)
        if section:
            key = section[1]
            values[key] = []
        elif key:
            values[key].append(line)
    return {name: "\n".join(lines).rstrip("\n") for name, lines in values.items()}


def check_report(root, report, mode, source, destination):
    lines = report.decode("utf-8-sig").splitlines()
    for locale in ("enUS", "zhCN"):
        folder = root / "script/locale" / locale
        labels = locale_values(folder / "report.lng")
        script = locale_values(folder / "script.lng")
        pieces = (labels["RESULT"] + script["ERROR_COUNT"]).split("%d")
        assert len(pieces) == 3, "Unexpected report count format"
        pattern = r"(\d+)".join(re.escape(piece) for piece in pieces)
        matches = [re.fullmatch(pattern, line) for line in lines]
        match = next((item for item in matches if item), None)
        if not match:
            continue
        assert match.groups() == ("0", "0"), "Conversion reported errors or warnings"
        assert labels["OUTPUT_MODE"] + mode in lines, "Report describes another conversion mode"
        for field, path in (("INPUT_PATH", source), ("OUTPUT_PATH", destination)):
            actual = [line[len(labels[field]):] for line in lines if line.startswith(labels[field])]
            assert len(actual) == 1 and os.path.normcase(os.path.abspath(actual[0])) == os.path.normcase(str(path)), \
                "Report describes another input/output path"
        return {"locale": locale, "errors": 0, "warnings": 0}
    raise AssertionError("Conversion report has no recognized result/count line")


def pjass_report_statuses(report):
    phases = {}
    for line in report.decode("utf-8-sig").splitlines():
        match = re.match(r"^(Before|After) conversion: (Passed|Failed|Unavailable|Skipped)(?: -|$)", line)
        if match:
            assert match[1] not in phases, "Repeated pjass conversion phase"
            phases[match[1]] = match[2]
    assert set(phases) == {"Before", "After"}, "Missing report-only pjass conversion results"
    return {"before": phases["Before"], "after": phases["After"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--checksum", type=Path, required=True)
    parser.add_argument("--expected-sha256")
    parser.add_argument("--workdir", type=Path, required=True)
    args = parser.parse_args()
    assert os.name == "nt", "Native smoke tests require Windows; Linux compatibility tests are separate"
    release = metadata()
    archive = args.archive.resolve()
    work = args.workdir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    evidence = work / "evidence"
    evidence.mkdir()
    report_path = evidence / "WINDOWS_SMOKE.json"
    report = {
        "status": "running", "started_utc": datetime.now(timezone.utc).isoformat(),
        "archive_sha256": sha256(archive.read_bytes()),
        "version": release["version"], "platform": "Windows", "native_windows_execution": True,
        "scope": "Packaged x86 interpreter/modules, pjass and CLI; OBJ, LNI, LNI-to-OBJ and SLK; native MPQ and report-only invalid JASS; headless conversion/worker checks, private archive regressions and isolated native Save As/output-entry controls",
        "gui_tested": False, "system_clipboard_tested": False, "game_tested": False,
        "world_editor_tested": False, "casc_storage_extraction_tested": False,
        "archive_unchanged": False, "packaged_inputs_unchanged": False,
        "conversion_count": 0, "steps": [], "conversions": [],
    }
    files, root = {}, work / release["archive_root"]
    try:
        files, digest = inspect_archive(archive, release, args.checksum, args.expected_sha256)
        assert digest == report["archive_sha256"]
        report["source_commit"] = json.loads(files["BUILD_INFO.json"])["source_commit"]
        for name, content in files.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        fixture = root / "test/fixtures/HiTestMapFromWorldEditor.w3x"
        assert sha256(fixture.read_bytes()) == FIXTURE_SHA256
        lua = root / "bin/w3x2lni-lua.exe"
        helper = root / "test/release/windows_native.lua"
        output = work / "Maps with spaces"
        output.mkdir()

        def run(name, command):
            started = time.monotonic()
            process = subprocess.Popen(list(map(str, command)), cwd=root / "script",
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = process.communicate(timeout=180)
            except subprocess.TimeoutExpired:
                # Kill only this smoke-test process and the worker it launched.
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               capture_output=True, check=False)
                stdout, stderr = process.communicate(timeout=20)
                (evidence / (name + ".stdout.log")).write_bytes(stdout)
                (evidence / (name + ".stderr.log")).write_bytes(stderr)
                raise AssertionError("Native Windows command timed out: " + name)
            (evidence / (name + ".stdout.log")).write_bytes(stdout)
            (evidence / (name + ".stderr.log")).write_bytes(stderr)
            report["steps"].append({"name": name, "exit_code": process.returncode,
                                    "elapsed_seconds": round(time.monotonic() - started, 2)})
            assert process.returncode == 0, name + ": " + stderr.decode("utf-8", errors="replace").replace("\0", "\n")
            print("PASS " + name, flush=True)
            return stdout

        def native(name, action, *arguments):
            return run(name, [lua, "-E", helper, root, action, *arguments])

        runtime_stdout = native("native-runtime", "runtime", release["version"])
        assert b"PUBLIC_ARCHIVE_ACTIONS_REMOVED|passed" in runtime_stdout, "Removed archive actions are still public"
        report["public_archive_actions_removed"] = True
        abi_bytes = files["NATIVE_ABI.json"]
        abi = json.loads(abi_bytes)
        # These queries use the IDs recorded by the compiled pinned-header probe.
        queried_constants = ("SFileMpqNumberOfFiles", "SFileMpqFlags", "SFileInfoLocale", "SFileInfoFileIndex",
                             "SFileInfoByteOffset", "SFileInfoFileTime", "SFileInfoFileSize",
                             "SFileInfoCompressedSize", "SFileInfoFlags")
        def fields(values):
            return ",".join(f"{key}={value}" for key, value in sorted(values.items()))
        native("native-abi", "abi", fixture, ",".join(abi["exports"]),
               fields({key: abi["constants"][key] for key in queried_constants}),
               fields(abi["offsets"]["create"]), fields(abi["offsets"]["find"]),
               abi["sizes"]["SFILE_CREATE_MPQ"], abi["sizes"]["SFILE_FIND_DATA"],
               abi["pointer_size"], abi["dword_size"])
        report["native_abi_verification"] = {
            "status": "passed", "abi_sha256": sha256(abi_bytes), "dll_sha256": sha256(files["bin/stormlib.dll"]),
            "pointer_size": abi["pointer_size"], "dword_size": abi["dword_size"],
            "create_size": abi["sizes"]["SFILE_CREATE_MPQ"], "find_size": abi["sizes"]["SFILE_FIND_DATA"],
            "create_offsets_verified": len(abi["offsets"]["create"]),
            "find_offsets_verified": len(abi["offsets"]["find"]), "exports_verified": len(abi["exports"]),
            "constants_queried": list(queried_constants), "native_file_info_verified": True,
        }
        run("cli-version", [root / "w2l.exe", "version", "-s"])

        checker = root / "bin/pjass.exe"
        assert checker.is_file() and sha256(checker.read_bytes()) == PJASS_SHA256, "Packaged pjass pin mismatch"
        report["pjass_verification"] = {"status": "running", "report_only": True,
                                        "release": PJASS_RELEASE, "checker_sha256": PJASS_SHA256}
        checker_stdout = native("pjass-verification", "pjass", fixture)
        cases = []
        for match in re.finditer(rb"(?m)^PJASS_CASE\|([^|\r\n]+)\|([^|\r\n]+)\|([^|\r\n]+)\|(\d+)\|(\d+)\|([^|\r\n]+)\|(\d+)\r?$",
                                 checker_stdout):
            name, status, dataset, diagnostics, raw_bytes, checker_exit, ignored_errors = match.groups()
            cases.append({"name": name.decode(), "status": status.decode(), "dataset": dataset.decode(),
                          "diagnostic_count": int(diagnostics), "raw_output_bytes": int(raw_bytes),
                          "checker_exit_code": None if checker_exit == b"skipped" else int(checker_exit),
                          "ignored_errors": int(ignored_errors)})
        expected_cases = {
            "current-valid": "Passed", "legacy-127-valid": "Passed", "legacy-124-valid": "Passed",
            "invalid-syntax": "Failed", "invalid-type": "Failed", "suppressed-errors": "Failed",
            "modern-current": "Passed", "modern-legacy-mismatch": "Failed", "lua-skipped": "Skipped",
            "current-fixture": "Passed",
        }
        assert len(cases) == len(expected_cases) and {item["name"]: item["status"] for item in cases} == expected_cases, \
            "Missing or unexpected native pjass cases"
        report["pjass_verification"]["checks"] = cases


        def convert(name, mode, source, destination, optimized=False):
            log = root / "log/report.log"
            if log.exists():
                log.unlink()
            run(name, [root / "w2l.exe", mode, source, destination, "-s"])
            assert log.is_file(), "CLI returned without a conversion report: " + name
            log_bytes = log.read_bytes()
            (evidence / (name + ".report.log")).write_bytes(log_bytes)
            result = check_report(root, log_bytes, mode, source, destination)
            result["pjass"] = pjass_report_statuses(log_bytes)
            assert result["pjass"] == {"before": "Passed", "after": "Passed"}, "Valid fixture failed pjass: " + name
            assert destination.exists(), "CLI returned without its output: " + name
            if mode == "lni":
                native(name + "-contents", "lni", destination)
                result["output_files"] = sum(path.is_file() for path in destination.rglob("*"))
            else:
                native(name + "-reopen", "archive", fixture, destination,
                       "optimized" if optimized else "editor")
                result["output_sha256"] = sha256(destination.read_bytes())
                result["output_bytes"] = destination.stat().st_size
            result.update({"name": name, "mode": mode,
                           "output": str(destination.relative_to(work)), "native_contents_verified": True})
            report["conversions"].append(result)
            report["conversion_count"] += 1

        convert("obj", "obj", fixture, output / "Native OBJ.w3x")
        lni = output / "Native LNI"
        convert("lni", "lni", fixture, lni)
        convert("lni-to-obj", "obj", lni, output / "Native LNI to OBJ.w3x")
        convert("slk", "slk", fixture, output / "Native SLK.w3x", optimized=True)
        assert report["conversion_count"] == 4
        # A deliberately invalid script must be reported without blocking OBJ output.
        invalid_input, invalid_output = output / "Invalid JASS input.w3x", output / "Invalid JASS output.w3x"
        native("pjass-invalid-fixture", "pjass-fixture", fixture, invalid_input)
        input_sha256 = sha256(invalid_input.read_bytes())
        invalid_log = root / "log/report.log"
        if invalid_log.exists():
            invalid_log.unlink()
        run("pjass-report-only-conversion", [root / "w2l.exe", "obj", invalid_input, invalid_output, "-s"])
        assert invalid_log.is_file() and invalid_output.is_file(), "Report-only conversion did not write its output/report"
        invalid_report = invalid_log.read_bytes()
        (evidence / "pjass-report-only-conversion.report.log").write_bytes(invalid_report)
        invalid_result = check_report(root, invalid_report, "obj", invalid_input, invalid_output)
        invalid_statuses = pjass_report_statuses(invalid_report)
        assert invalid_statuses == {"before": "Failed", "after": "Failed"}, "Invalid JASS was not reported as failed"
        native("pjass-report-only-output", "pjass-output", invalid_input, invalid_output)
        assert sha256(invalid_input.read_bytes()) == input_sha256, "Report-only conversion changed its input"
        invalid_result.update({"mode": "obj", "pjass": invalid_statuses, "output_exists": True,
                               "output_script_preserved": True, "input_unchanged": True,
                               "output_sha256": sha256(invalid_output.read_bytes())})
        report["pjass_verification"]["report_only_conversion"] = invalid_result
        report["pjass_verification"]["status"] = "passed"
        # Preserve low-level archive safety coverage for the rebuilt StormLib DLL.
        # These retired services are invoked only through a private test entry;
        # w2l.exe and the GUI expose the conversion actions.
        archive_worker = root / "test/release/archive_worker.lua"
        # The storage fixture includes Unicode paths and opaque/editor/HD members.
        lossless_stdout = native("lossless-native", "lossless", output)
        storage = re.search(rb"LOSSLESS_NATIVE saved=(\d+) size=(\d+) sector=(\d+)", lossless_stdout)
        assert storage and int(storage[1]) > 0, "Lossless native helper produced no verified savings"
        lossless_input = output / "地图 hráč" / "来源 hráč.w3x"
        lossless_output = output / "地图 hráč" / "CLI 优化.w3x"
        lossless_before = lossless_input.read_bytes()
        lni_before = {path.relative_to(lni).as_posix(): sha256(path.read_bytes())
                      for path in lni.rglob('*') if path.is_file()}
        gui_stdout = native("gui-archive-actions", "gui-archive-actions", output, lni)
        assert b"GUI_ARCHIVE_ACTIONS|passed" in gui_stdout, "Missing native GUI worker evidence"
        assert lni_before == {path.relative_to(lni).as_posix(): sha256(path.read_bytes())
                              for path in lni.rglob('*') if path.is_file()}, "Analyze modified the LNI project"
        assert lossless_input.read_bytes() == lossless_before, "GUI worker changed its source map"
        dialog_evidence = verify_save_dialog(root, evidence / "save-dialog")
        report["gui_archive_actions"] = {
            "status": "passed", "headless": True, "internal_regression_only": True, "interactive_dialog_tested": False,
            "dialog_abi_verified": True, "dialog_unicode_buffers_verified": True,
            "dialog_cancel_and_errors_verified": True, "native_dialog": dialog_evidence, "lni_folder_analyzed": True,
            "lni_marker_analyzed": True, "lni_project_unchanged": True,
            "optimization_worker_verified": True, "failure_reports_verified": True, "failure_recovery_verified": True,
        }
        log = root / "log/report.log"
        if log.exists():
            log.unlink()
        run("lossless-analyze-cli", [lua, "-E", archive_worker, "analyze", lossless_input, "-s"])
        analysis_log = log.read_bytes()
        (evidence / "lossless-analyze-cli.report.log").write_bytes(analysis_log)
        assert b"inventory: complete; optimization: eligible" in analysis_log
        assert b"Analyze input: Passed" in analysis_log
        assert lossless_input.read_bytes() == lossless_before, "Analyze modified its input"
        log.unlink()
        run("lossless-optimize-cli", [lua, "-E", archive_worker, "optimize", lossless_input, lossless_output, "-s"])
        optimize_log = log.read_bytes()
        (evidence / "lossless-optimize-cli.report.log").write_bytes(optimize_log)
        assert b"Optimize input: Passed" in optimize_log and b"Optimize output: Passed" in optimize_log
        assert lossless_output.is_file() and lossless_output.stat().st_size < len(lossless_before)
        assert lossless_input.read_bytes() == lossless_before, "Optimize modified its input"
        assert lossless_output.read_bytes()[:512] == lossless_before[:512], "Optimize changed the outer map header"
        native("lossless-cli-output", "lossless-output", output)
        marker = output / "cooperative cancel marker"
        marker.write_bytes(b"cancel")
        cancelled_output = output / "Cancelled archive.w3x"
        log.unlink()
        run("lossless-cancel-cli", [lua, "-E", archive_worker, "optimize", lossless_input, cancelled_output,
                                    "-s", "-cancel-file=" + str(marker)])
        cancellation_log = log.read_bytes()
        (evidence / "lossless-cancel-cli.report.log").write_bytes(cancellation_log)
        assert b"Operation cancelled" in cancellation_log and not cancelled_output.exists()
        assert marker.read_bytes() == b"cancel", "Worker deleted a frontend-owned cancellation marker"
        assert lossless_input.read_bytes() == lossless_before
        assert not list(lossless_input.parent.glob(".w2l-optimize-*")), "Cancellation left partial candidates"
        marker.unlink()
        report["lossless_archive"] = {
            "status": "passed", "internal_regression_only": True, "source_unchanged": True, "decoded_payloads_equal": True,
            "bookkeeping_equal": True, "outer_header_equal": True, "unicode_paths_tested": True,
            "unknown_editor_hd_data_preserved": True, "existing_output_refused": True,
            "output_race_preserved": True, "cancellation_cleaned_up": True, "cli_cancellation_verified": True,
            "attempted_sector_sizes": [512, 4096, 65536], "verified_sector_sizes": [4096, 65536],
            "skipped_sector_sizes": [512], "native_savings": int(storage[1]),
            "native_output_bytes": int(storage[2]), "native_selected_sector_size": int(storage[3]),
            "cli_savings": len(lossless_before) - lossless_output.stat().st_size,
            "cli_output_sha256": sha256(lossless_output.read_bytes()),
            "pjass": {"analyze_input": "Passed", "optimize_input": "Passed", "optimize_output": "Passed"},
        }
        for name, content in files.items():
            assert (root / name).read_bytes() == content, "Native test changed a packaged input: " + name
        report["packaged_inputs_unchanged"] = True
        assert sha256(archive.read_bytes()) == report["archive_sha256"], "Native test changed the release ZIP"
        report["archive_unchanged"] = True
        report["status"] = "passed"
        print("PASS four native Windows CLI conversions; packaged input and ZIP bytes unchanged", flush=True)
    except Exception:
        report["status"] = "failed"
        report["failure"] = traceback.format_exc()
        error_folder = root / "log/error"
        if error_folder.is_dir():
            for error in error_folder.glob("*.log"):
                shutil.copyfile(error, evidence / ("crash-" + error.name))
        raise
    finally:
        report["completed_utc"] = datetime.now(timezone.utc).isoformat()
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
