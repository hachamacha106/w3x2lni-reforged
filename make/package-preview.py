#!/usr/bin/env python3
"""Build the portable preview from an immutable byte snapshot, then check the ZIP.

No network or native build is performed. The official release supplies Windows
executables, DLLs and legacy datasets; this checkout supplies every script/test
and the complete supplied current dataset. A candidate can be tested with
test/compat/verify_package.py, then rebuilt with --validation and its map output.
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import zipfile

VERSION = '2.7.4-current-preview.5'
PREPARED_DATE = '2026-10-09'
SUITE_COUNT = 14
ROOT_NAME = 'w3x2lni-current-preview'
RELEASE_SHA256 = '58c6523b6d34fea55b6904f40298b24f72367f7d975494cb7dff23cb1241c440'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def runtime_fingerprint(files):
    runtime = {name: sha256(content) for name, content in files.items()
               if name.startswith(('script/', 'test/', 'make/', 'data/', 'bin/'))
               or name in ('config.ini', 'w2l.exe', 'w3x2lni.exe')}
    return sha256(json.dumps(runtime, sort_keys=True, separators=(',', ':')).encode())


def snapshot_tree(folder):
    return {file.relative_to(folder).as_posix(): file.read_bytes()
            for file in sorted(folder.rglob('*')) if file.is_file()
            and '__pycache__' not in file.parts and not file.name.endswith('.pyc')
            and file.name != 'gitlog.lua'}


def source_patch(repo, checktree):
    def git(*args):
        return subprocess.run(['git', *args], cwd=repo, capture_output=True, check=True).stdout
    git('diff', '--check')
    base = git('rev-parse', 'HEAD').decode().strip()
    scopes = ['script', 'make', 'test', 'docs']
    patch = git('diff', '--binary', '--', *scopes)
    new = git('ls-files', '--others', '--exclude-standard', '-z', '--', *scopes).decode().split('\0')
    for name in sorted(filter(None, new)):
        assert not name.endswith(('.o', '.so', '.pyc')), name
        result = subprocess.run(['git', 'diff', '--no-index', '--binary', '--', '/dev/null', name],
                                cwd=repo, capture_output=True)
        assert result.returncode == 1, result.stderr.decode()
        patch += result.stdout
    check = subprocess.run(['git', 'apply', '--check', '--whitespace=nowarn', '-'],
                           cwd=checktree, input=patch, capture_output=True)
    assert check.returncode == 0, check.stdout + check.stderr
    return base, patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--map-validation', type=Path, required=True)
    parser.add_argument('--patch-check-tree', type=Path, required=True)
    parser.add_argument('--validation', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    release_bytes = args.upstream.read_bytes()
    assert sha256(release_bytes) == RELEASE_SHA256, 'Unexpected upstream release bytes'
    with zipfile.ZipFile(io.BytesIO(release_bytes)) as archive:
        upstream = {item.filename: archive.read(item) for item in archive.infolist() if not item.is_dir()}
    for name in upstream:
        path = PurePosixPath(name)
        assert not path.is_absolute() and '..' not in path.parts, name
    # Do not reuse a staging tree. Replace the whole script/test namespace so
    # older release files cannot survive a partial source overlay.
    files = {name: content for name, content in upstream.items()
             if not name.startswith(('script/', 'test/', 'data/warcraft-current/'))}
    source_files = {}
    for folder in ['script', 'test', 'data/warcraft-current']:
        for name, content in snapshot_tree(repo / folder).items():
            source_files[folder + '/' + name] = content
    for name in ['make/import-game-data.lua', 'make/package-preview.py',
                 'docs/en-us/current-warcraft.md', 'docs/en-us/w3i-fields.md', 'LICENSE.txt']:
        source_files[name] = (repo / name).read_bytes()
    files.update(source_files)
    files['CURRENT_WARCRAFT_PREVIEW.md'] = source_files['docs/en-us/current-warcraft.md']
    files['W3I_FIELDS.md'] = source_files['docs/en-us/w3i-fields.md']
    base, patch = source_patch(repo, args.patch_check_tree)
    files['SOURCE_CHANGES.patch'] = patch
    for name, content in snapshot_tree(args.map_validation).items():
        files['map-validation/' + name] = content
    map_result = json.loads(files['map-validation/RESULTS.json'])
    assert len(map_result['steps']) == 14 and all(step['exit_code'] == 0 for step in map_result['steps'])
    assert len(map_result['archives']) == 6 and all(item['verified'] for item in map_result['archives'])
    for item in map_result['archives']:
        assert sha256(files['map-validation/' + item['path']]) == item['sha256'], item['path']
    for name, content in files.items():
        if name.startswith('map-validation/reports/') and name.endswith('.txt'):
            assert b'Errors: 0\nWarnings: 0\n' in content, name

    configuration = configparser.ConfigParser(interpolation=None)
    configuration.read_string(upstream['config.ini'].decode('utf-8-sig'))
    configuration['global'].update({'data': 'warcraft-current', 'data_meta': '${DATA}',
                                    'data_ui': '${DATA}', 'data_wes': '${DATA}'})
    for mode in ['lni', 'obj']:
        configuration[mode]['read_slk'] = 'true'
    buffer = io.StringIO()
    configuration.write(buffer)
    files['config.ini'] = buffer.getvalue().replace('\n', '\r\n').encode()
    binaries = [name for name in upstream if name.lower().endswith(('.exe', '.dll'))]
    assert len(binaries) == 22
    for name in binaries:
        assert files[name] == upstream[name], name
    manifest = json.loads(files['data/warcraft-current/source-manifest.json'])
    assert len(manifest['files']) == 111
    assert b'Status: required input files present' in files['data/warcraft-current/import-report.txt']
    assert 'data/warcraft-current/version' in files
    for item in manifest['files']:
        content = files['data/warcraft-current/' + item['path']]
        assert len(content) == item['bytes'] and sha256(content) == item['sha256'], item['path']

    fingerprint = runtime_fingerprint(files)
    validation = json.loads(args.validation.read_text()) if args.validation else None
    if validation:
        assert validation['package_runtime_fingerprint'] == fingerprint, 'Runtime differs from tested ZIP'
        assert validation['archive_integrity']['status'] == 'passed'
        assert len(validation['suites']) == SUITE_COUNT and all(item['exit_code'] == 0 for item in validation['suites'])
    verified = validation is not None
    acceptance = {'date': '2026-10-08', 'source': 'user report',
                  'statement': 'All practical checks succeeded',
                  'scope': 'Previously supplied practical map checks; individual steps not enumerated',
                  'preview_2_error_also_reported': True,
                  'preview_4_feedback': {'date': '2026-10-09',
                                         'statement': 'Works great; report resizing and copying requested'}}
    info = {
        'name': ROOT_NAME, 'script_version': VERSION, 'prepared_date': PREPARED_DATE,
        'source_repository': 'https://github.com/sumneko/w3x2lni', 'source_base_commit': base,
        'source_patch_sha256': sha256(patch), 'source_patch_check': 'passed against clean source base',
        'packaged_source_files_verified': len(source_files),
        'package_runtime_fingerprint': fingerprint,
        'native_runtime': {'release': '2.7.3', 'release_source_commit': '05e3e371e36f078031d54bcc9783b52b9b86485a',
                           'release_zip_sha256': RELEASE_SHA256, 'files_verified_unchanged': binaries,
                           'rebuilt': False, 'executed_on_windows': False},
        'package_configuration': {'data': 'warcraft-current', 'data_meta': '${DATA}', 'data_ui': '${DATA}',
                                  'data_wes': '${DATA}', 'lni.read_slk': True, 'obj.read_slk': True},
        'supplied_data': {'files': 111, 'version': None, 'build': None, 'locale': None,
                          'missing_required_files': 0, 'custom_balance_overlay_supplied': False, 'selectable': True},
        'supplied_map': {'name': 'HiTestMapFromWorldEditor.w3x', 'sha256': map_result['source_sha256'],
                         'version': '3.0.1.24342', 'editor_version': 7003, 'w3i_version': 39, 'script_language': 'JASS'},
        'validation': {'extracted_package_suites_passed': SUITE_COUNT if verified else 0,
                       'map_conversions': 8, 'map_errors': 0, 'map_warnings': 0, 'rebuilt_mpqs_verified': 6,
                       'windows_gui_native_tested_here': False, 'real_casc_extraction_tested_here': False,
                       'user_acceptance': acceptance},
    }
    files['BUILD_INFO.json'] = (json.dumps(info, indent=2) + '\n').encode()
    package_verification = {
        'status': 'validated' if verified else 'candidate awaiting extracted-package tests',
        'method': 'All final ZIP members compared byte-for-byte against one source snapshot and CHECKSUMS.sha256',
        'package_runtime_fingerprint': fingerprint,
        'tested_archive_sha256': validation['archive_sha256'] if verified else None,
        'tested_archive_integrity': validation['archive_integrity'] if verified else None,
        'source_and_data_files_checked': len(source_files),
        'native_executables_and_dlls_unchanged': len(binaries),
        'user_acceptance': acceptance,
    }
    files['PACKAGE_VERIFICATION.json'] = (json.dumps(package_verification, indent=2) + '\n').encode()
    lines = [f'W3x2Lni {VERSION} - verification', f'Date: {PREPARED_DATE}', f'Source base: {base}',
             'Tests run from files extracted from the candidate ZIP, with the final runtime fingerprint locked.',
             'Environment: Linux; pinned Lua/native parsers with documented Windows compatibility adapters.',
             'CASC lifecycle, map-header native boundary and Win32 message-box calls use explicit mocks.',
             'Report tests load actual Lua UI logic with mocked Yue and Win32 controls/clipboard.',
             'Actual MPQ extraction/repacking uses pinned Linux StormLib.',
             'Windows GUI/native execution and real CASC extraction were not performed here.',
             'User reports all supplied practical map checks succeeded; individual checks were not enumerated.',
             'Raw dataset exact build and locale remain unverified.', '',
             f'{SUITE_COUNT}/{SUITE_COUNT} extracted-package suites passed.' if verified else 'Candidate: extracted-package suite results pending.',
             'Six rebuilt MPQs passed reopening/member-byte verification; eight conversions had zero errors/warnings.',
             'All 111 raw data files and all 22 official native binaries retain their recorded bytes.', '']
    for result in validation['suites'] if verified else []:
        lines.extend([result['name'], 'File: test/compat/' + result['file'],
                      f"Exit status: {result['exit_code']}; elapsed: {result['elapsed_seconds']} seconds",
                      result['stdout'].rstrip(), result['stderr'].rstrip(), ''])
    files['TEST_RESULTS.txt'] = ('\n'.join(lines) + '\n').encode()
    start = f'''W3X2LNI CURRENT WARCRAFT COMPATIBILITY PREVIEW 5

Version: {VERSION}. Prepared {PREPARED_DATE}.

Extract into a NEW folder and launch that folder's w3x2lni.exe.
Check that the application version ends in current-preview.5.
The complete supplied game dataset is already built and selected.
No additional import is required for the included data.

The window can now be resized, maximized and minimized with Windows controls.
Reports wrap long messages and scroll. Select text with the mouse and Ctrl+C,
or use Ctrl+A then Ctrl+C. Copy all copies the complete log with one click.
Tab reaches Copy all; Shift+Tab reaches Back. The report is read-only.

All numbered unknown W3I fields retain their descriptive names and comments.
Current fog/weather field order, minimap alpha color and loading HUD are corrected.
Re-export LNI from original maps to obtain the new names and locale dictionary.
The preview 3 packaging and complete-error-message repairs are retained.
Every final ZIP member is checked against its source snapshot and checksum.
{f'{SUITE_COUNT}/{SUITE_COUNT} suites passed from the extracted package.' if verified else 'Candidate awaiting extracted-package suite results.'}
Eight current-map conversion paths passed with zero errors and warnings.
Six rebuilt map archives were reopened and their decoded contents verified.
The user reports the previously supplied practical map checks succeeded.
Windows GUI/native execution and real CASC extraction were not tested here.

Included:
  CURRENT_WARCRAFT_PREVIEW.md Changes, settings, coverage and limitations
  W3I_FIELDS.md              New W3I names, numeric values and corrected field layout
  TEST_RESULTS.txt           Extracted-package test output and limitations
  PACKAGE_VERIFICATION.json  Tested runtime/data fingerprint and archive evidence
  CHECKSUMS.sha256           SHA-256 for every other file inside this folder
  SOURCE_CHANGES.patch       Source patch against the stated upstream commit
  BUILD_INFO.json            Source/native provenance and user acceptance report
  data/warcraft-current/     111 raw files and complete generated defaults
  map-validation/            Original map, six rebuilt maps, LNI folders and reports
  make/import-game-data.lua  Rebuild a dataset from matching extracted game files
  make/package-preview.py    Source packager; requires a Git checkout
  test/compat/               Regression tests and extracted-ZIP validation runner

For editor checks use OBJ, LNI-OBJ or SLK-editor maps. Optimized SLK maps remove
editor-only files according to the normal setting; test those in Warcraft.

If an error remains, attach its log/error/*.log file and identify the action/map.
The previous screenshot's expected log is log/error/2026-10-08 23-15-30.log.
Commit: unknown is informational, not the cause of an error.

This modified preview is not an official upstream release.
'''
    files['START_HERE.txt'] = start.replace('\n', '\r\n').encode()
    files['CHECKSUMS.sha256'] = ''.join(sha256(content) + '  ' + name + '\n'
                                        for name, content in sorted(files.items())).encode()
    destination = args.output.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.zip.tmp')
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=8) as archive:
        for name, content in sorted(files.items()):
            archive.writestr(ROOT_NAME + '/' + name, content)
    # Verify actual archive bytes, not a staging-directory assertion or CRC alone.
    with zipfile.ZipFile(temporary) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(set(archive.namelist())) == len(files)
        packed = {name: archive.read(ROOT_NAME + '/' + name) for name in files}
    assert packed == files, 'Final ZIP differs from the immutable build snapshot'
    for line in packed['CHECKSUMS.sha256'].decode().splitlines():
        expected, name = line.split('  ', 1)
        assert sha256(packed[name]) == expected, 'ZIP checksum mismatch: ' + name
    for name, content in source_files.items():
        assert packed[name] == (repo / name).read_bytes(), 'Source changed while packaging: ' + name
    assert runtime_fingerprint(packed) == fingerprint
    temporary.replace(destination)
    print(json.dumps({'file': str(destination), 'bytes': destination.stat().st_size,
                      'sha256': sha256(destination.read_bytes()), 'archive_members_verified': len(files),
                      'source_files_verified': len(source_files), 'native_files_unchanged': len(binaries),
                      'package_runtime_fingerprint': fingerprint,
                      'extracted_package_tests_passed': SUITE_COUNT if verified else 0}, indent=2))


if __name__ == '__main__':
    main()
