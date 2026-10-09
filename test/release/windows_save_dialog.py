"""Exercise real Win32 Save As on owned desktops that are never displayed.

The controller never calls SwitchDesktop. It posts cancellation only to dialogs
belonging to its exact child process. No user window or map file is touched.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import hashlib
import os
from pathlib import Path
import subprocess
import time
import uuid


SCENARIOS = ("valid_owner", "yue_callback", "invalid_owner_control", "invalid_owner_adapter", "owner_retry")


class NativeController:
    def __init__(self):
        if os.name != "nt":
            raise RuntimeError("Native Save As verification requires Windows")
        from ctypes import wintypes as w
        c = ctypes
        self.c, self.w = c, w
        self.user = c.WinDLL("user32", use_last_error=True)
        self.kernel = c.WinDLL("kernel32", use_last_error=True)

        class Security(c.Structure):
            _fields_ = [("length", w.DWORD), ("descriptor", c.c_void_p), ("inherit", w.BOOL)]

        class Startup(c.Structure):
            _fields_ = [("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR),
                        ("title", w.LPWSTR), ("x", w.DWORD), ("y", w.DWORD),
                        ("width", w.DWORD), ("height", w.DWORD), ("columns", w.DWORD),
                        ("rows", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
                        ("show", w.WORD), ("reserved_bytes", w.WORD), ("reserved_data", c.c_void_p),
                        ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]

        class Process(c.Structure):
            _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE),
                        ("pid", w.DWORD), ("tid", w.DWORD)]

        self.Security, self.Startup, self.Process = Security, Startup, Process
        self.Enum = c.WINFUNCTYPE(w.BOOL, w.HWND, c.c_ssize_t)
        api = (
            (self.user, "CreateDesktopW", [w.LPCWSTR, w.LPCWSTR, c.c_void_p, w.DWORD, w.DWORD, c.c_void_p], w.HANDLE),
            (self.user, "CloseDesktop", [w.HANDLE], w.BOOL),
            (self.user, "GetProcessWindowStation", [], w.HANDLE),
            (self.user, "GetUserObjectInformationW", [w.HANDLE, c.c_int, c.c_void_p, w.DWORD, c.POINTER(w.DWORD)], w.BOOL),
            (self.user, "EnumDesktopWindows", [w.HANDLE, self.Enum, c.c_ssize_t], w.BOOL),
            (self.user, "GetWindowThreadProcessId", [w.HWND, c.POINTER(w.DWORD)], w.DWORD),
            (self.user, "GetClassNameW", [w.HWND, w.LPWSTR, c.c_int], c.c_int),
            (self.user, "PostMessageW", [w.HWND, w.UINT, c.c_size_t, c.c_ssize_t], w.BOOL),
            (self.kernel, "CreateFileW", [w.LPCWSTR, w.DWORD, w.DWORD, c.POINTER(Security), w.DWORD, w.DWORD, w.HANDLE], w.HANDLE),
            (self.kernel, "CreateProcessW", [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(Startup), c.POINTER(Process)], w.BOOL),
            (self.kernel, "CloseHandle", [w.HANDLE], w.BOOL),
            (self.kernel, "WaitForSingleObject", [w.HANDLE, w.DWORD], w.DWORD),
            (self.kernel, "TerminateProcess", [w.HANDLE, w.UINT], w.BOOL),
            (self.kernel, "GetExitCodeProcess", [w.HANDLE, c.POINTER(w.DWORD)], w.BOOL),
        )
        for library, name, args, result in api:
            function = getattr(library, name)
            function.argtypes, function.restype = args, result
        station = self.user.GetProcessWindowStation()
        station_name, needed = c.create_unicode_buffer(256), w.DWORD()
        if not station or not self.user.GetUserObjectInformationW(station, 2, station_name,
                                                                  c.sizeof(station_name), c.byref(needed)):
            raise self.error("GetProcessWindowStation name")
        self.station_name = station_name.value

    def error(self, action):
        return OSError(f"{action}: {self.c.WinError(self.c.get_last_error())}")

    def run_scenario(self, package, evidence, scenario, timeout=12):
        c, w, user, kernel = self.c, self.w, self.user, self.kernel
        name = "w2l-save-test-" + uuid.uuid4().hex
        # This is a fresh non-input desktop. There is deliberately no API for
        # switching to it in this controller, even on an error path.
        # Request only object/window/enumeration rights, never SWITCHDESKTOP.
        desktop = user.CreateDesktopW(name, None, None, 0, 0x00C3, None)
        if not desktop:
            raise self.error("CreateDesktopW")
        handles, cleanup_errors = [], []
        process, started, reaped = self.Process(), False, False
        cancelled, callback_errors = set(), []
        stdout = evidence / (scenario + ".stdout.log")
        stderr = evidence / (scenario + ".stderr.log")
        try:
            security = self.Security(c.sizeof(self.Security), None, True)
            for path, access, creation in ((stdout, 0x40000000, 2), (stderr, 0x40000000, 2), ("NUL", 0x80000000, 3)):
                handle = kernel.CreateFileW(str(path), access, 3, c.byref(security), creation, 0x80, None)
                if not handle or handle == c.c_void_p(-1).value:
                    raise self.error("CreateFileW")
                handles.append(handle)
            startup = self.Startup()
            startup.cb = c.sizeof(self.Startup)
            startup.desktop = self.station_name + "\\" + name
            startup.flags, startup.show = 0x101, 0
            startup.stdin, startup.stdout, startup.stderr = handles[2], handles[0], handles[1]
            command = subprocess.list2cmdline([str(package / "bin/w3x2lni-lua.exe"), "-E",
                                               str(package / "test/release/windows_save_dialog.lua"),
                                               str(package), scenario])
            if not kernel.CreateProcessW(None, c.create_unicode_buffer(command), None, None, True,
                                         0x08000000, None, str(package / "script"), c.byref(startup), c.byref(process)):
                raise self.error("CreateProcessW")
            started = True

            @self.Enum
            def cancel_owned_dialog(hwnd, unused):
                try:
                    pid = w.DWORD()
                    user.GetWindowThreadProcessId(hwnd, c.byref(pid))
                    if pid.value != process.pid:
                        return True
                    title = c.create_unicode_buffer(256)
                    if not user.GetClassNameW(hwnd, title, len(title)):
                        # A window can disappear between enumeration and query.
                        return True
                    if title.value == "#32770" and hwnd not in cancelled:
                        if not user.PostMessageW(hwnd, 0x111, 2, 0):
                            raise self.error("PostMessageW(IDCANCEL)")
                        cancelled.add(hwnd)
                    return True
                except BaseException as error:
                    callback_errors.append(str(error))
                    return False

            deadline = time.monotonic() + timeout
            while True:
                status = kernel.WaitForSingleObject(process.process, 25)
                if status == 0:
                    reaped = True
                    break
                if status != 0x102:
                    raise self.error("WaitForSingleObject")
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"Native Save As child timed out: {scenario}")
                c.set_last_error(0)
                enumerated = user.EnumDesktopWindows(desktop, cancel_owned_dialog, 0)
                if not enumerated and not callback_errors and c.get_last_error():
                    raise self.error("EnumDesktopWindows")
                if callback_errors:
                    raise RuntimeError("; ".join(callback_errors))
            exit_code = w.DWORD()
            if not kernel.GetExitCodeProcess(process.process, c.byref(exit_code)):
                raise self.error("GetExitCodeProcess")
            if exit_code.value:
                raise RuntimeError(f"Native Save As child failed ({scenario}, {exit_code.value}): "
                                   + stderr.read_bytes().decode("utf-8", errors="replace").replace("\0", "\n"))
            content = stdout.read_bytes().decode("utf-8", errors="strict")
            marker = "SAVE_DIALOG_NATIVE|" + scenario + "|passed"
            if marker not in content:
                raise RuntimeError(f"Native Save As child supplied no pass evidence: {scenario}")
            if scenario != "invalid_owner_control" and not cancelled:
                raise RuntimeError(f"Native Save As created no cancellable dialog: {scenario}")
            if scenario == "invalid_owner_control" and cancelled:
                raise RuntimeError("Invalid owner unexpectedly created a dialog")
            leftovers = []

            @self.Enum
            def collect_owned(hwnd, unused):
                try:
                    pid = w.DWORD()
                    user.GetWindowThreadProcessId(hwnd, c.byref(pid))
                    if pid.value == process.pid:
                        leftovers.append(hwnd)
                    return True
                except BaseException as error:
                    callback_errors.append(str(error))
                    return False

            c.set_last_error(0)
            enumerated = user.EnumDesktopWindows(desktop, collect_owned, 0)
            if callback_errors:
                raise RuntimeError("; ".join(callback_errors))
            # An empty private desktop returns FALSE without a Win32 error.
            if not enumerated and c.get_last_error():
                raise self.error("EnumDesktopWindows after exit")
            if leftovers:
                raise RuntimeError(f"Owned child windows survived exit: {scenario}")
            result = {"scenario": scenario, "status": "passed", "exit_code": exit_code.value,
                      "dialogs_cancelled": len(cancelled), "owned_windows_left": 0,
                      "stdout_log": stdout.name, "stderr_log": stderr.name}
        finally:
            # Errors never leave a live modal child on an undisplayed desktop.
            if started and not reaped:
                if kernel.WaitForSingleObject(process.process, 0) != 0:
                    if not kernel.TerminateProcess(process.process, 7):
                        cleanup_errors.append(str(self.error("TerminateProcess owned child")))
                if kernel.WaitForSingleObject(process.process, 3000) != 0:
                    cleanup_errors.append("Owned child could not be reaped")
            for handle in (process.thread, process.process, *handles):
                if handle and not kernel.CloseHandle(handle):
                    cleanup_errors.append(str(self.error("CloseHandle")))
            if not user.CloseDesktop(desktop):
                cleanup_errors.append(str(self.error("CloseDesktop")))
            if cleanup_errors:
                raise RuntimeError("Native Save As cleanup failed: " + "; ".join(cleanup_errors))
        return result


def run(package_root, evidence_directory):
    package, evidence = Path(package_root).resolve(), Path(evidence_directory).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    fixture_root = package / "test/fixtures"
    if not fixture_root.is_dir():
        raise RuntimeError("Native Save As fixture inventory is missing")
    suggested = package / "地图 hráč 😀.optimized.w3x"

    def snapshot():
        paths = [path for path in fixture_root.rglob("*") if path.is_file()]
        if suggested.exists():
            paths.append(suggested)
        return {path.relative_to(package).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(paths)}

    before = snapshot()
    if not before:
        raise RuntimeError("Native Save As fixture inventory is empty")
    controller = NativeController()
    scenarios = [controller.run_scenario(package, evidence, name) for name in SCENARIOS]
    if snapshot() != before:
        raise RuntimeError("Native Save As changed map fixtures or its suggested destination")
    result = {"status": "passed", "isolated_desktop": True, "hook_used": False,
              "owner_error_ffff_reproduced": True, "invalid_owner_discarded": True,
              "unowned_retry_verified": True, "unicode_verified": True,
              "inputs_unchanged": True,
              "input_scope": "test/fixtures and suggested destination",
              "native_dialog_invocation_verified": True,
              "owner_validation_verified": True, "invalid_owner_control_verified": True,
              "owner_retry_verified": True, "unicode_buffers_verified": True,
              "cancellation_verified": True, "private_desktop": True,
              "input_desktop_switched": False, "interactive_dialog_tested": False,
              "gui_rendering_tested": False, "scenarios": scenarios}
    (evidence / "SAVE_DIALOG_NATIVE.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.root, args.evidence), indent=2))
