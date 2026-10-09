#!/usr/bin/env python3
"""Exercise the supplied 3.0.1 editor fixture with the real converter and StormLib.

Requires the pinned Lua runtime and test-only StormLib built by build_runtime.py
and mpq_archive.py. The source fixture is supplied separately; its hash is fixed
so positive feature coverage is not accidentally attributed to another map.
Windows GUI/FFI execution and in-game behavior remain separate acceptance work.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from mpq_archive import INTERNAL_FILES, STORMLIB_COMMIT, StormLib, extract, pack

FIXTURE_SHA256 = '293af514783fdd0fc71aeff7170c1931f38a2f6bae55e0c29614da75ed3da553'


def test_map(map_path: Path, library: Path, output: Path):
    test_directory = Path(__file__).resolve().parent
    runtime = Path(os.environ['W2L_TEST_RUNTIME']).resolve()
    assert hashlib.sha256(map_path.read_bytes()).hexdigest() == FIXTURE_SHA256, 'Unexpected map fixture'
    output.mkdir(parents=True, exist_ok=False)
    reports = output / 'reports'
    reports.mkdir()
    storm = StormLib(library)
    original = output / 'original-members'
    inventory = extract(storm, map_path, original)
    assert len(inventory) == 19 and all(entry['locale'] == 0 for entry in inventory)
    (output / 'input-inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
    shutil.copyfile(map_path, output / 'HiTestMapFromWorldEditor-original.w3x')
    steps, archives = [], []

    def command(arguments):
        start = time.monotonic()
        run = subprocess.run([str(runtime / 'lua'), *(str(item) for item in arguments)],
                             cwd=test_directory.parents[1], capture_output=True, text=True)
        result = {'command': [str(item) for item in arguments], 'exit_code': run.returncode,
                  'elapsed_seconds': round(time.monotonic() - start, 2),
                  'stdout': run.stdout, 'stderr': run.stderr}
        steps.append(result)
        print(run.stdout, end='', flush=True)
        if run.returncode:
            print(run.stderr, end='', flush=True)
            raise RuntimeError(f"Map validation failed: {arguments[0]}")
        return result

    def convert(name, source, source_mode, mode, profile='editor'):
        destination = output / name
        command([test_directory / 'map_workflow.lua', source, destination,
                 source_mode, mode, profile, reports / (name + '.txt')])
        files = {p.relative_to(destination).as_posix().lower(): p.read_bytes()
                 for p in destination.rglob('*') if p.is_file()}
        assert files, 'No conversion output'
        # These newer native members are intentionally opaque to conversion.
        # Terrain, lighting, groups, conversation and graphical map data must
        # remain byte-identical; optimized profiles deliberately remove only
        # the existing documented editor-only members.
        editor_removed = {'war3map.wtg', 'war3map.wct', 'war3map.w3c',
                          'war3map.w3r', 'war3map.w3s', 'war3mapunits.doo'}
        rewritten = {'war3map.w3i', 'war3map.wts', 'war3map.wtg', 'war3map.wct', 'war3map.j'}
        for entry in inventory:
            key = entry['name'].replace('\\', '/').lower()
            if key in INTERNAL_FILES or key in rewritten:
                continue
            if profile != 'editor' and key in editor_removed:
                assert key not in files
                continue
            if mode == 'lni':
                category = 'resource' if key.endswith(('.blp', '.mdx', '.mdl', '.dds', '.tga', '.tif')) else 'map'
                target = category + '/' + key
            else:
                target = key
            assert target in files, f'{name}: lost native member {target}'
            assert hashlib.sha256(files[target]).hexdigest() == entry['sha256'], f'{name}: changed {target}'
        if mode == 'lni':
            assert 'table/w3i.ini' in files and 'map/war3map.w3i' not in files
            assert 'w3x2lni/version/lml' in files and 'map/war3map.wtg' not in files
        else:
            command([test_directory / 'verify_map.lua', original, destination,
                     'optimized' if profile != 'editor' else 'editor'])
            archive_path = output / ('HiTestMapFromWorldEditor-' + name + '.w3x')
            archive = pack(storm, destination, archive_path)
            with storm.open(archive_path) as rebuilt:
                actual = {entry.name.replace('\\', '/').lower() for entry in rebuilt.members()
                          if entry.name.lower() not in INTERNAL_FILES}
            assert actual == set(files), f'{name}: unexpected archived member set'
            archive['case'] = name
            archive['path'] = archive_path.name
            archives.append(archive)
            print(f"PASS rebuilt MPQ: {name}, {archive['content_members']} members verified after reopening", flush=True)
        return destination

    try:
        convert('OBJ', original, 'obj', 'obj')
        lni = convert('LNI', original, 'obj', 'lni')
        convert('LNI-OBJ', lni, 'lni', 'obj')
        slk = convert('SLK-editor', original, 'obj', 'slk')
        slk_lni = convert('SLK-LNI', slk, 'obj', 'lni')
        convert('SLK-LNI-OBJ', slk_lni, 'lni', 'obj')
        convert('SLK', original, 'obj', 'slk', 'default')
        convert('SLK-obfuscated', lni, 'lni', 'slk', 'obfuscated')
    finally:
        report = {
            'source_map': map_path.name, 'source_sha256': FIXTURE_SHA256,
            'stormlib_commit': STORMLIB_COMMIT, 'map_version': '3.0.1.24342',
            'editor_version': 7003, 'w3i_version': 39,
            'steps': steps, 'archives': archives,
            'windows_gui_ffi_tested': False, 'world_editor_reopen_tested': False,
            'in_game_tested': False,
            'map_coverage': 'JASS, one standard initialization trigger, one player/start marker, current native map members',
            'not_present_in_fixture': ['Lua', 'custom objects', 'binary skins', 'custom imports', 'nonempty conversations'],
        }
        (output / 'RESULTS.json').write_text(json.dumps(report, indent=2) + '\n')
    assert len(archives) == 6
    print('PASS uploaded current-editor map: 8 conversion paths, 6 rebuilt MPQs, all content verified after reopening', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output:
        test_map(args.map.resolve(), args.library.resolve(), args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='w2l-current-map-') as temporary:
            test_map(args.map.resolve(), args.library.resolve(), Path(temporary) / 'validation')


if __name__ == '__main__':
    main()
