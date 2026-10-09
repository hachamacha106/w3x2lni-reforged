#!/usr/bin/env python3
"""Test an exact release ZIP with its real Windows x86 EXE and DLLs.

Requires Windows and Python 3.10+. Creates a fresh, disposable extraction.
Does not launch the GUI, use an installed game, or extract a CASC storage.
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
        "scope": "Packaged x86 interpreter/modules and CLI; OBJ, LNI, LNI-to-OBJ and SLK; native MPQ and map semantics",
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

        def native(name, action, *arguments):
            run(name, [lua, "-E", helper, root, action, *arguments])

        native("native-runtime", "runtime", release["version"])
        run("cli-version", [root / "w2l.exe", "version", "-s"])

        def convert(name, mode, source, destination, optimized=False):
            log = root / "log/report.log"
            if log.exists():
                log.unlink()
            run(name, [root / "w2l.exe", mode, source, destination, "-s"])
            assert log.is_file(), "CLI returned without a conversion report: " + name
            log_bytes = log.read_bytes()
            (evidence / (name + ".report.log")).write_bytes(log_bytes)
            result = check_report(root, log_bytes, mode, source, destination)
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
