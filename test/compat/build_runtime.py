#!/usr/bin/env python3
"""Build the pinned Lua/parser dependencies for Linux regression tests.

Requires git submodules, GCC and G++. It does not build the Windows application.
Usage: python3 test/compat/build_runtime.py /absolute/output/directory
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "bee").mkdir(exist_ok=True)
LUA = ROOT / "3rd/bee.lua/3rd/lua"
SHIM = ROOT / "test/compat/msvc_compat.h"


def run(job):
    name, args = job
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    print(name, "OK" if result.returncode == 0 else "FAILED", flush=True)
    if result.returncode:
        print(result.stdout + result.stderr, flush=True)
    return result.returncode


def cxx(name, sources, extra=()):
    return name, ["g++", "-std=c++17", "-O2", "-fPIC", "-shared",
                  "-fno-strict-aliasing", "-I", str(LUA), "-include", str(SHIM),
                  *map(str, sources), *extra, "-o", str(OUT / (name + ".so"))]


jobs = [
    ("lua", ["gcc", "-O2", "-DLUA_USE_LINUX", "-Wl,-E", str(LUA / "onelua.c"),
             "-lm", "-ldl", "-o", str(OUT / "lua")]),
    cxx("w3xparser", ["3rd/w3xparser/src/main.cpp", "3rd/w3xparser/src/real.cpp"]),
    cxx("lni", ["3rd/lni/src/main.cpp"]),
    cxx("lml", ["3rd/lml/src/main.cpp", "3rd/lml/src/LmlParse.cpp"]),
    ("lpeglabel", ["gcc", "-O2", "-fPIC", "-shared", "-I", str(LUA),
                   *map(str, sorted((ROOT / "3rd/lpeglabel").glob("lpl*.c"))),
                   "-o", str(OUT / "lpeglabel.so")]),
    cxx("bee/filesystem", [
        "3rd/bee.lua/binding/lua_filesystem.cpp",
        "3rd/bee.lua/bee/error.cpp",
        "3rd/bee.lua/bee/utility/file_handle.cpp",
        "3rd/bee.lua/bee/utility/file_handle_posix.cpp",
        "3rd/bee.lua/bee/utility/file_handle_linux.cpp",
        "3rd/bee.lua/bee/utility/path_helper.cpp",
        "3rd/bee.lua/bee/nonstd/fmt/format.cc",
    ], ["-I", str(ROOT / "3rd/bee.lua"),
        "-I", str(ROOT / "3rd/bee.lua/bee/nonstd"), "-ldl"]),
    cxx("bee/subprocess", [
        "3rd/bee.lua/binding/lua_subprocess.cpp",
        "3rd/bee.lua/bee/subprocess/subprocess_posix.cpp",
        "3rd/bee.lua/bee/net/socket.cpp",
        "3rd/bee.lua/bee/net/endpoint.cpp",
        "3rd/bee.lua/bee/error.cpp",
        "3rd/bee.lua/bee/nonstd/fmt/format.cc",
    ], ["-I", str(ROOT / "3rd/bee.lua"),
        "-I", str(ROOT / "3rd/bee.lua/bee/nonstd"), "-pthread", "-ldl"]),
    cxx("bee/time", ["3rd/bee.lua/binding/lua_time.cpp"],
        ["-I", str(ROOT / "3rd/bee.lua"), "-include", "time.h"]),
    cxx("bee/thread", [
        "3rd/bee.lua/binding/lua_thread.cpp",
        "3rd/bee.lua/bee/thread/simplethread_posix.cpp",
        "3rd/bee.lua/bee/error.cpp",
    ], ["-I", str(ROOT / "3rd/bee.lua"),
        "-I", str(ROOT / "3rd/bee.lua/3rd/lua-seri"),
        str(OUT / "bee/seri.o"), "-pthread", "-ldl"]),
]
if len(sys.argv) > 2:
    jobs = [job for job in jobs if job[0] == sys.argv[2]]
# lua-seri is C, so compile it separately before the dependent thread module.
if any(name == "bee/thread" for name, _ in jobs):
    code = run(("bee/seri", ["gcc", "-O2", "-fPIC", "-I", str(LUA),
                            "-c", str(ROOT / "3rd/bee.lua/3rd/lua-seri/lua-seri.c"),
                            "-o", str(OUT / "bee/seri.o")]))
    if code:
        sys.exit(code)
with ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(run, jobs))
sys.exit(1 if any(results) else 0)
