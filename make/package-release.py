#!/usr/bin/env python3
"""Build a reproducible portable release from committed source and pinned binaries.

A candidate is built first, tested after extraction by test/compat/verify_package.py,
then rebuilt with --validation and that test run's --map-validation directory.
Only a separately built and probed StormLib artifact may replace its pinned upstream DLL.
The packager performs no network access, compilation, or publication.
"""
from __future__ import annotations

import argparse
import configparser
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runtime_origins import apply_origins, verify_origins

UPSTREAM_BASE = '82916514a12b7edb15252d42225cd8cc8ce61cfd'
NATIVE_SOURCE_COMMIT = '05e3e371e36f078031d54bcc9783b52b9b86485a'
UPSTREAM_ZIP_SHA256 = '58c6523b6d34fea55b6904f40298b24f72367f7d975494cb7dff23cb1241c440'
UPSTREAM_ZIP_URL = 'https://github.com/sumneko/w3x2lni/releases/download/2.7.3/w3x2lni-2.7.3.zip'
FIXTURE_SHA256 = '293af514783fdd0fc71aeff7170c1931f38a2f6bae55e0c29614da75ed3da553'
SUITE_FILES = {
    'run_legacy.lua', 'object_formats.lua', 'slk.lua', 'current_data.lua',
    'legacy_profile_fields.lua', 'scripts.lua', 'integration.lua',
    'archive_lifecycle.lua', 'import_cli.py', 'archive_header.lua',
    'crashreport.lua', 'w3i_names.lua', 'gui_report.lua', 'user_map.py',
    'jass_verify.lua', 'lossless.lua',
}
SOURCE_PREFIXES = ('script/', 'test/', 'make/', 'docs/', 'data/warcraft-current/')
SOURCE_ROOT_FILES = {'README.md', 'CHANGELOG.md', 'LICENSE.txt', 'config.ini', 'release.json'}
GENERATED_GITLOG = 'script/share/gitlog.lua'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def runtime_fingerprint(files):
    runtime = {name: sha256(content) for name, content in files.items()
               if name.startswith(('script/', 'test/', 'make/', 'data/', 'bin/'))
               or name in ('config.ini', 'release.json')
               or ('/' not in name and name.lower().endswith(('.exe', '.dll')))}
    return sha256(json.dumps(runtime, sort_keys=True, separators=(',', ':')).encode())


def valid_member(name):
    path = PurePosixPath(name)
    return (bool(name) and not path.is_absolute() and '..' not in path.parts
            and '\\' not in name and ':' not in name and '\n' not in name
            and '\r' not in name and path.as_posix() == name)


def git(repo, *args, env=None, input=None):
    result = subprocess.run(['git', *args], cwd=repo, env=env, input=input,
                            capture_output=True)
    require(result.returncode == 0,
            'git ' + ' '.join(args) + ' failed: ' + result.stderr.decode(errors='replace'))
    return result.stdout


def clean_status(repo):
    return git(repo, 'status', '--porcelain=v1', '-z', '--untracked-files=all',
               '--ignore-submodules=none')


def index_environment(index):
    return dict(os.environ, GIT_INDEX_FILE=str(index))


def tree_snapshot(repo, tree):
    # Read blobs directly. git archive and checkout both apply attributes such
    # as text/eol conversion, so neither provides the committed object bytes.
    entries = []
    names = set()
    for record in git(repo, 'ls-tree', '-r', '-z', '--full-tree', tree).split(b'\0'):
        if not record:
            continue
        attributes, raw_name = record.split(b'\t', 1)
        mode, kind, object_id = attributes.decode().split()
        name = raw_name.decode()
        require(valid_member(name), 'Unsafe source path: ' + name)
        require(name not in names, 'Duplicate source path: ' + name)
        names.add(name)
        if mode == '160000' and kind == 'commit':
            continue
        require(kind == 'blob' and mode in ('100644', '100755'),
                'Release source contains a non-regular file: ' + name)
        entries.append((name, object_id))
    requests = ''.join(object_id + '\n' for _, object_id in entries).encode()
    blobs = git(repo, 'cat-file', '--batch', input=requests)
    contents = {}
    offset = 0
    for name, expected_object_id in entries:
        end = blobs.index(b'\n', offset)
        object_id, kind, size = blobs[offset:end].split()
        require(object_id.decode() == expected_object_id and kind == b'blob',
                'Unexpected Git object for source path: ' + name)
        start, length = end + 1, int(size)
        require(length >= 0 and start + length < len(blobs)
                and blobs[start + length:start + length + 1] == b'\n',
                'Truncated Git source blob: ' + name)
        contents[name] = blobs[start:start + length]
        offset = start + length + 1
    require(offset == len(blobs), 'Unexpected trailing Git source blob data')
    return contents


def replay_patch(repo, base, tree, patch):
    # Replay all source changes, including already committed changes and binaries.
    # A separate index never changes the developer's worktree or real Git index.
    build = repo / 'build'
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-patch-', dir=build) as temporary:
        environment = index_environment(Path(temporary) / 'index')
        git(repo, 'read-tree', base, env=environment)
        if patch:
            git(repo, 'apply', '--cached', '--binary', '--whitespace=nowarn', '-',
                env=environment, input=patch)
        reconstructed = git(repo, 'write-tree', env=environment).decode().strip()
    require(reconstructed == tree, 'Source patch does not reproduce the recorded release tree')


def source_snapshot(repo, allow_dirty=False):
    commit = git(repo, 'rev-parse', 'HEAD').decode().strip()
    committed_tree = git(repo, 'rev-parse', 'HEAD^{tree}').decode().strip()
    timestamp = int(git(repo, 'show', '-s', '--format=%ct', 'HEAD').decode())
    require(git(repo, 'merge-base', UPSTREAM_BASE, commit).decode().strip() == UPSTREAM_BASE,
            'Release HEAD does not descend from the pinned upstream base')
    status = clean_status(repo)
    if status and not allow_dirty:
        # Name the runner-side mutation without discarding or admitting it.
        entries = [json.dumps(entry.decode('utf-8', errors='backslashreplace'), ensure_ascii=False)
                   for entry in status.split(b'\0') if entry]
        details = '\nGit status entries (paths only):\n  ' + '\n  '.join(entries)
        nested = subprocess.run(['git', 'submodule', 'foreach', '--recursive',
                                 'git status --porcelain=v1 --untracked-files=all'],
                                cwd=repo, capture_output=True)
        if nested.returncode == 0 and nested.stdout:
            # JSON quoting prevents control characters in filenames/log output.
            lines = [json.dumps(line, ensure_ascii=False) for line in
                     nested.stdout.decode('utf-8', errors='backslashreplace').splitlines()]
            details += '\nRecursive submodule status:\n  ' + '\n  '.join(lines)
        elif nested.returncode:
            details += '\nRecursive submodule status could not be read.'
        raise ValueError(
            'Release source must be clean and committed. Commit source changes and keep outputs in build/. '
            'Use --allow-dirty only for a development candidate.' + details)
    tree = committed_tree
    if status:
        build = repo / 'build'
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='release-source-', dir=build) as temporary:
            environment = index_environment(Path(temporary) / 'index')
            git(repo, 'read-tree', commit, env=environment)
            git(repo, 'add', '-A', '--', '.', env=environment)
            tree = git(repo, 'write-tree', env=environment).decode().strip()
    patch = git(repo, '-c', 'core.quotePath=true', 'diff', '--binary', '--full-index',
                '--no-ext-diff', '--no-textconv', '--no-renames',
                '--src-prefix=a/', '--dst-prefix=b/', UPSTREAM_BASE, tree, '--')
    replay_patch(repo, UPSTREAM_BASE, tree, patch)
    submodules = {}
    for record in git(repo, 'ls-tree', '-r', '-z', tree).split(b'\0'):
        if not record:
            continue
        attributes, raw_name = record.split(b'\t', 1)
        mode, kind, object_id = attributes.decode().split()
        if mode == '160000':
            submodules[raw_name.decode()] = object_id
    iso_date = datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace('+00:00', 'Z')
    metadata = {'commit': commit, 'tree': tree, 'committed_tree': committed_tree,
                'commit_date_utc': iso_date, 'commit_timestamp': timestamp,
                'dirty': bool(status), 'upstream_base_commit': UPSTREAM_BASE,
                'submodule_commits': submodules,
                'patch_sha256': sha256(patch), 'patch_replay_tree': tree}
    return metadata, tree_snapshot(repo, tree), patch, status


def generated_gitlog(source):
    # Both values are generated from Git metadata, never a hand-written version.
    suffix = '-dirty' if source['dirty'] else ''
    return ("return {\n    commit = '%s%s',\n    date = '%s',\n}\n" %
            (source['commit'], suffix, source['commit_date_utc'])).encode()


def load_release(source_files):
    release = json.loads(source_files['release.json'])
    required = ('product_name', 'version', 'display_version', 'tag', 'repository',
                'archive_root', 'asset_name')
    require(all(isinstance(release.get(key), str) and release[key] for key in required),
            'release.json is missing required string metadata')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', release['version']),
            'release.json version must be a semantic version')
    require(release['tag'] == 'v' + release['version'], 'Release tag/version mismatch')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', release['repository']),
            'Invalid release repository')
    require(all(valid_member(release[key]) and '/' not in release[key]
                for key in ('archive_root', 'asset_name')), 'Invalid release archive name')
    require(release['asset_name'].endswith('.zip'), 'Release asset must be a ZIP')
    first_version = re.search(rb"version\s*=\s*['\"]([^'\"]+)",
                              source_files['script/share/changelog.lua'])
    require(first_version and first_version.group(1).decode() == release['version'],
            'The first changelog version must match release.json')
    brand = re.search(rb"name\s*=\s*['\"]([^'\"]+)", source_files['script/share/brand.lua'])
    require(brand and brand.group(1).decode() == release['product_name'],
            'The application brand must match release.json')
    return release


def read_upstream(path):
    data = path.read_bytes()
    require(sha256(data) == UPSTREAM_ZIP_SHA256, 'Unexpected official 2.7.3 release bytes')
    files = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            require(valid_member(item.filename), 'Unsafe upstream ZIP member: ' + item.filename)
            require(item.filename not in files, 'Duplicate upstream ZIP member: ' + item.filename)
            files[item.filename] = archive.read(item)
    return files


def folder_snapshot(folder):
    require(folder.is_dir(), 'Missing map validation directory: ' + str(folder))
    files = {}
    for path in sorted(folder.rglob('*')):
        require(not path.is_symlink(), 'Validation input must not be a symlink: ' + str(path))
        if not path.is_file() or '__pycache__' in path.parts or path.suffix == '.pyc':
            continue
        name = path.relative_to(folder).as_posix()
        require(valid_member(name), 'Unsafe validation path: ' + name)
        files[name] = path.read_bytes()
    return files


def validate_map(files):
    result = json.loads(files['RESULTS.json'])
    require(result['source_sha256'] == FIXTURE_SHA256, 'Unexpected map-validation fixture')
    require(sha256(files['HiTestMapFromWorldEditor-original.w3x']) == FIXTURE_SHA256,
            'Map-validation original fixture bytes changed')
    require(len(result['steps']) == 14 and all(step['exit_code'] == 0 for step in result['steps']),
            'All eight conversions and six semantic map checks must pass')
    cases = {'OBJ', 'LNI-OBJ', 'SLK-editor', 'SLK-LNI-OBJ', 'SLK', 'SLK-obfuscated'}
    require(len(result['archives']) == 6 and {item['case'] for item in result['archives']} == cases,
            'Expected six different rebuilt MPQ cases')
    for item in result['archives']:
        require(item['verified'] and valid_member(item['path'])
                and sha256(files[item['path']]) == item['sha256'],
                'Rebuilt MPQ verification failed: ' + item['path'])
    report_cases = cases | {'LNI', 'SLK-LNI'}
    for case in report_cases:
        name = 'reports/' + case + '.txt'
        require(b'Errors: 0\nWarnings: 0\n' in files[name], 'Map report has errors or warnings: ' + name)
    return result


def validate_dataset(files):
    prefix = 'data/warcraft-current/'
    manifest = json.loads(files[prefix + 'source-manifest.json'])
    require(len(manifest['files']) == 111, 'Expected 111 supplied raw data files')
    require(b'Status: required input files present' in files[prefix + 'import-report.txt'],
            'Current dataset import is incomplete')
    require(prefix + 'version' in files, 'Current dataset is not selectable')
    for item in manifest['files']:
        content = files[prefix + item['path']]
        require(len(content) == item['bytes'] and sha256(content) == item['sha256'],
                'Supplied raw game data changed: ' + item['path'])
    return manifest


def validate_configuration(files):
    configuration = configparser.ConfigParser(interpolation=None)
    configuration.read_string(files['config.ini'].decode('utf-8-sig'))
    expected = {'data': 'warcraft-current', 'data_meta': '${DATA}',
                'data_ui': '${DATA}', 'data_wes': '${DATA}'}
    require(all(configuration['global'][key] == value for key, value in expected.items()),
            'Release config.ini must select matching current game data, metadata, UI and strings')
    require(all(configuration.getboolean(mode, 'read_slk') for mode in ('lni', 'obj')),
            'Release config.ini must enable read_slk for LNI and OBJ')
    return dict(expected, **{'lni.read_slk': True, 'obj.read_slk': True})


def validate_test_report(validation, fingerprint, source):
    require(not source['dirty'], 'A dirty development candidate cannot become a validated release')
    require(validation['package_runtime_fingerprint'] == fingerprint, 'Runtime differs from tested ZIP')
    require(validation.get('source_commit') == source['commit']
            and validation.get('source_tree') == source['tree'],
            'Validation was produced from a different committed release source')
    integrity = validation['archive_integrity']
    require(integrity['status'] == 'passed'
            and integrity['extracted_bytes_verified_before_and_after_tests'],
            'Extracted-package integrity validation did not pass')
    suites = validation['suites']
    require(len(suites) == len(SUITE_FILES)
            and {item['file'] for item in suites} == SUITE_FILES
            and all(item['exit_code'] == 0 for item in suites),
            f'All {len(SUITE_FILES)} distinct extracted-package compatibility suites must pass')


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode()


def checksum_manifest(files):
    return ''.join(sha256(content) + '  ' + name + '\n'
                   for name, content in sorted(files.items())).encode()


def write_verified_zip(destination, root, files, timestamp):
    require('CHECKSUMS.sha256' not in files, 'Checksum file must be generated last')
    packed = dict(files, **{'CHECKSUMS.sha256': checksum_manifest(files)})
    date = datetime.fromtimestamp(timestamp, timezone.utc)
    require(1980 <= date.year <= 2107, 'Source commit timestamp is outside the ZIP timestamp range')
    zip_date = (date.year, date.month, date.day, date.hour, date.minute, date.second // 2 * 2)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + '.tmp')
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=8) as archive:
        for name, content in sorted(packed.items()):
            require(valid_member(name), 'Unsafe output ZIP member: ' + name)
            info = zipfile.ZipInfo(root + '/' + name, date_time=zip_date)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=8)
    with zipfile.ZipFile(temporary) as archive:
        require(archive.testzip() is None, 'Final ZIP CRC verification failed')
        require(len(archive.namelist()) == len(set(archive.namelist())) == len(packed),
                'Final ZIP member count or uniqueness differs from snapshot')
        observed = {name: archive.read(root + '/' + name) for name in packed}
    require(observed == packed, 'Final ZIP differs from immutable source snapshot')
    for line in observed['CHECKSUMS.sha256'].decode().splitlines():
        expected, name = line.split('  ', 1)
        require(sha256(observed[name]) == expected, 'Final ZIP checksum mismatch: ' + name)
    return temporary, packed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--map-validation', type=Path, required=True)
    parser.add_argument('--validation', type=Path)
    parser.add_argument('--native-runtime', type=Path, help='Verified Windows native build artifact directory')
    parser.add_argument('--pjass', type=Path, help='Checksum-pinned upstream pjass.exe')
    parser.add_argument('--expected-tag', help='Check the triggering tag against release.json and HEAD if present')
    parser.add_argument('--allow-dirty', action='store_true',
                        help='Prepare an explicitly uncommitted development candidate; not a validated release')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    require(not (args.allow_dirty and args.validation), '--allow-dirty cannot be used with --validation')
    source, entire_source, patch, status = source_snapshot(repo, args.allow_dirty)
    release = load_release(entire_source)
    if tuple(map(int, release['version'].split('-')[0].split('.'))) >= (1, 1, 0) and not args.allow_dirty:
        require(args.native_runtime is not None and args.pjass is not None,
                'Version 1.1+ requires a verified native build and pinned pjass helper')
    if args.expected_tag:
        require(args.expected_tag == release['tag'], 'Triggering tag does not match release.json')
    tag_result = subprocess.run(['git', 'rev-parse', '--verify', 'refs/tags/' + release['tag'] + '^{commit}'],
                                cwd=repo, capture_output=True)
    if tag_result.returncode == 0:
        require(tag_result.stdout.decode().strip() == source['commit'], 'Release tag points to another commit')
    source['tag_present_when_packaged'] = tag_result.returncode == 0
    source['repository'] = 'https://github.com/' + release['repository']
    upstream = read_upstream(args.upstream)
    # Replace complete namespaces; no obsolete upstream script can survive.
    files = {name: content for name, content in upstream.items()
             if not name.startswith(SOURCE_PREFIXES) and name not in SOURCE_ROOT_FILES}
    source_files = {name: content for name, content in entire_source.items()
                    if (name.startswith(SOURCE_PREFIXES) or name in SOURCE_ROOT_FILES)
                    and name != GENERATED_GITLOG}
    require(SOURCE_ROOT_FILES <= set(source_files), 'Release is missing required top-level source files')
    if args.pjass is not None:
        required_notices = {'docs/licenses/pjass-BSD.txt', 'docs/licenses/pjass-AUTHORS.txt',
                            'docs/licenses/map-doctor-MIT.txt', 'docs/licenses/stormlib-MIT.txt',
                            'docs/licenses/zlib.txt', 'docs/licenses/bzip2.txt',
                            'docs/licenses/stormlib-bundled-notices.txt'}
        require(required_notices <= set(source_files), 'Missing adopted-tool license notices')
    files.update(source_files)
    files[GENERATED_GITLOG] = generated_gitlog(source)
    files['SOURCE_CHANGES.patch'] = patch
    files['SOURCE_FILES.sha256'] = checksum_manifest(source_files)
    files['W3I_FIELDS.md'] = source_files['docs/en-us/w3i-fields.md']
    require(sha256(files['test/fixtures/HiTestMapFromWorldEditor.w3x']) == FIXTURE_SHA256,
            'Committed current-editor fixture bytes changed')
    map_snapshot = folder_snapshot(args.map_validation)
    map_result = validate_map(map_snapshot)
    files.update({'map-validation/' + name: content for name, content in map_snapshot.items()})
    configuration = validate_configuration(files)
    validate_dataset(files)
    binaries = sorted(name for name in upstream if name.lower().endswith(('.exe', '.dll')))
    require(len(binaries) == 22, 'Expected 22 official native runtime files')
    origins = apply_origins(files, upstream, source, args.native_runtime, args.pjass)
    fingerprint = runtime_fingerprint(files)
    validation = json.loads(args.validation.read_bytes()) if args.validation else None
    if validation is not None:
        validate_test_report(validation, fingerprint, source)
    verified = validation is not None
    prepared_date = source['commit_date_utc'][:10]
    native = {'release': '2.7.3', 'release_source_commit': NATIVE_SOURCE_COMMIT,
              'release_zip_sha256': UPSTREAM_ZIP_SHA256, 'release_zip_url': UPSTREAM_ZIP_URL,
              'executed_on_windows': False, **origins}
    info = {
        'name': release['archive_root'], 'product_name': release['product_name'],
        'version': release['version'], 'script_version': release['version'],
        'display_version': release['display_version'], 'tag': release['tag'],
        'asset_name': release['asset_name'], 'archive_root': release['archive_root'],
        'prepared_date': prepared_date, 'source_repository': source['repository'],
        'source_commit': source['commit'], 'source_tree': source['tree'],
        'source_base_commit': UPSTREAM_BASE, 'source': source,
        'source_patch_sha256': sha256(patch), 'source_patch_check': 'passed; exact source tree reproduced',
        'packaged_source_files_verified': len(source_files),
        'generated_source_files': {GENERATED_GITLOG: sha256(files[GENERATED_GITLOG])},
        'package_runtime_fingerprint': fingerprint, 'native_runtime': native,
        'package_configuration': configuration,
        'supplied_data': {'files': 111, 'version': None, 'build': None, 'locale': None,
                          'missing_required_files': 0, 'custom_balance_overlay_supplied': False,
                          'selectable': True},
        'supplied_map': {'name': 'HiTestMapFromWorldEditor.w3x', 'sha256': FIXTURE_SHA256,
                         'version': map_result['map_version'], 'editor_version': map_result['editor_version'],
                         'w3i_version': map_result['w3i_version'], 'script_language': 'JASS',
                         'coverage': map_result['map_coverage'],
                         'not_present_in_fixture': map_result['not_present_in_fixture']},
        'validation': {'extracted_package_suites_passed': len(SUITE_FILES) if verified else 0,
                       'map_conversions': 8, 'map_errors': 0, 'map_warnings': 0, 'rebuilt_mpqs_verified': 6,
                       'windows_gui_native_tested_here': False, 'real_casc_extraction_tested_here': False,
                       'world_editor_reopen_tested_here': False, 'in_game_tested_here': False},
    }
    files['BUILD_INFO.json'] = json_bytes(info)
    files['PACKAGE_VERIFICATION.json'] = json_bytes({
        'status': 'validated' if verified else 'candidate awaiting extracted-package tests',
        'method': 'Each ZIP member checked against one Git/source byte snapshot and CHECKSUMS.sha256',
        'package_runtime_fingerprint': fingerprint, 'source_commit': source['commit'],
        'source_tree': source['tree'], 'source_dirty': source['dirty'],
        'tested_archive_sha256': validation['archive_sha256'] if verified else None,
        'tested_archive_integrity': validation['archive_integrity'] if verified else None,
        'source_and_data_files_checked': len(source_files), 'native_executables_and_dlls_unchanged': len(origins['files_verified_unchanged']),
    })
    lines = [f"{release['product_name']} {release['display_version']} - verification",
             f"Source commit: {source['commit']}", f"Source tree: {source['tree']}",
             f"Source date (UTC): {source['commit_date_utc']}",
             'Tests run from the extracted candidate ZIP; final code/data/runtime bytes are fingerprint-locked.',
             'Environment: Linux; pinned Lua/native parsers with documented Windows compatibility adapters.',
             'CASC lifecycle, map-header native boundary and Win32 message-box calls use explicit mocks.',
             'Report tests load actual Lua UI logic with mocked Yue and Win32 controls/clipboard.',
             'Actual MPQ extraction/repacking uses pinned Linux StormLib.',
             'Windows GUI/native execution, real CASC extraction, World Editor and in-game checks were not run here.',
             'One simple supplied current-editor map cannot establish coverage of every modern map feature.',
             'Raw dataset exact build and locale remain unverified.', '',
             f'{len(SUITE_FILES)}/{len(SUITE_FILES)} extracted-package suites passed.' if verified else 'Candidate: extracted-package suite results pending.',
             'Six rebuilt MPQs passed reopening/member-byte checks; eight conversions had zero errors/warnings.',
             f"All 111 raw data files and {len(origins['files_verified_unchanged'])} retained native files preserve their bytes.", '']
    for result in validation['suites'] if verified else []:
        lines.extend([result['name'], 'File: test/compat/' + result['file'],
                      f"Exit status: {result['exit_code']}; elapsed: {result['elapsed_seconds']} seconds",
                      result['stdout'].rstrip(), result['stderr'].rstrip(), ''])
    files['TEST_RESULTS.txt'] = ('\n'.join(lines) + '\n').encode()
    status_line = (f'{len(SUITE_FILES)}/{len(SUITE_FILES)} Linux extracted-package compatibility suites passed.' if verified else
                   'Development candidate: extracted-package compatibility tests are pending.')
    start = f"""{release['product_name']} {release['display_version']}

Version: {release['version']}
Source commit: {source['commit']}{'-dirty' if source['dirty'] else ''}
Source date (UTC): {source['commit_date_utc']}
Project: https://github.com/{release['repository']}

Extract the complete ZIP into a new folder and launch w3x2lni.exe.
The included current game dataset is built and selected; no import is needed.
Use w2l.exe for command-line conversion.

The window supports resize, maximize and minimize. Reports wrap and scroll.
Select message text and press Ctrl+C, or press Ctrl+A followed by Ctrl+C.
Copy all copies the complete report. See README.md for supported workflows.

{status_line}
Eight current-map conversion paths had zero errors and warnings; six rebuilt
archives were reopened and checked. See TEST_RESULTS.txt for full test output.
Windows GUI/native, real CASC, World Editor and in-game acceptance are separate
checks. This one simple test map does not exercise every modern map feature.

Included:
  README.md                  Usage and project overview
  CHANGELOG.md               Release history
  docs/releases/{release['version']}.md      Release notes and scope
  docs/en-us/credits.md       Upstream and dependency credits
  W3I_FIELDS.md              Descriptive W3I fields and binary layout
  BUILD_INFO.json            Exact source and per-file native provenance
  PACKAGE_VERIFICATION.json  Tested code/data/runtime fingerprint
  TEST_RESULTS.txt           Compatibility results and honest limitations
  CHECKSUMS.sha256           SHA-256 of every other packaged file
  SOURCE_FILES.sha256        SHA-256 of each included source/data file
  SOURCE_CHANGES.patch       Full patch from the pinned upstream base
  release.json              Release version, tag and asset naming
  data/warcraft-current/     Supplied game data and generated defaults
  map-validation/            Fixture, converted maps, LNI folders and reports
  test/fixtures/             Committed current-editor test map
  test/compat/               Conversion, UI and extracted-package checks
  make/package-release.py   Reproducible release packager; requires Git source

Release source: https://github.com/{release['repository']}/tree/{source['commit']}
The source patch applies to upstream {UPSTREAM_BASE} and was replay-checked
against the recorded source tree. Git submodule pins are in BUILD_INFO.json.
{len(origins['files_verified_unchanged'])} retained upstream 2.7.3 EXE/DLL files are byte-identical.
Rebuilt StormLib and added pjass, when present, have separate pinned provenance.
See BUILD_INFO.json, NATIVE_BUILD.json and NATIVE_ABI.json for build evidence.
Retained executable file-version resources keep their upstream version.
Rebuilt and added components have explicit per-file provenance in BUILD_INFO.json.
This is an independently maintained fork. GPLv3 terms are in LICENSE.txt.

For editor checks use OBJ, LNI-OBJ or SLK-editor maps. Optimized SLK output removes
editor-only files according to the normal settings; test it in Warcraft III.
If reporting an error, include the action, relevant map, and log/error/*.log.
"""
    files['START_HERE.txt'] = start.replace('\n', '\r\n').encode()
    require(git(repo, 'rev-parse', 'HEAD').decode().strip() == source['commit'],
            'HEAD changed during packaging')
    require(clean_status(repo) == status, 'Source status changed during packaging')
    if source['dirty']:
        check_source, _, _, _ = source_snapshot(repo, allow_dirty=True)
        require(check_source['tree'] == source['tree'], 'Development source changed during packaging')
    temporary, packed = write_verified_zip(args.output.resolve(), release['archive_root'], files,
                                           source['commit_timestamp'])
    require(runtime_fingerprint(packed) == fingerprint, 'Final runtime fingerprint changed')
    require(git(repo, 'rev-parse', 'HEAD').decode().strip() == source['commit']
            and clean_status(repo) == status, 'Source changed while writing final archive')
    temporary.replace(args.output.resolve())
    print(json.dumps({'file': str(args.output.resolve()), 'bytes': args.output.stat().st_size,
                      'sha256': sha256(args.output.read_bytes()), 'archive_members_verified': len(packed),
                      'source_commit': source['commit'], 'source_tree': source['tree'],
                      'source_files_verified': len(source_files), 'source_dirty': source['dirty'],
                      'native_files_unchanged': len(origins['files_verified_unchanged']), 'package_runtime_fingerprint': fingerprint,
                      'extracted_package_tests_passed': len(SUITE_FILES) if verified else 0}, indent=2))


if __name__ == '__main__':
    main()
