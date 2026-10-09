#!/usr/bin/env python3
"""Verify final ZIP bytes and run compatibility suites from its extracted files.

Uses the pinned Linux test runtime, real Linux StormLib and explicit mocks for
documented Windows-only boundaries. Does not execute the Windows GUI or DLLs.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import subprocess
import time
import zipfile

ROOT_NAME = 'w3x2lni-current-preview'
SUITES = [
    ('Original and modern map/trigger/placement regressions', 'run_legacy.lua'),
    ('Modern object formats', 'object_formats.lua'),
    ('SLK schemas and native profiles', 'slk.lua'),
    ('Actual supplied game data and import', 'current_data.lua'),
    ('Legacy LNI model migration', 'legacy_profile_fields.lua'),
    ('Current JASS and Lua/WTS preservation', 'scripts.lua'),
    ('Dataset caches and archive integration', 'integration.lua'),
    ('CASC/MPQ lifecycle with mocked DLL boundary', 'archive_lifecycle.lua'),
    ('Relative-path importer CLI', 'import_cli.py'),
    ('Current and unknown outer map-header flags', 'archive_header.lua'),
    ('Complete Windows crash diagnostics with mocked Win32 boundary', 'crashreport.lua'),
    ('Descriptive W3I fields and current fog layout', 'w3i_names.lua'),
    ('Resizable and copyable reports with mocked Yue/Win32 boundary', 'gui_report.lua'),
    ('Current-editor map conversions and real MPQ archives', 'user_map.py'),
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def runtime_fingerprint(files):
    runtime = {name: sha256(content) for name, content in files.items()
               if name.startswith(('script/', 'test/', 'make/', 'data/', 'bin/'))
               or name in ('config.ini', 'release.json')
               or ('/' not in name and name.lower().endswith(('.exe', '.dll')))}
    return sha256(json.dumps(runtime, sort_keys=True, separators=(',', ':')).encode())


def parse_checksums(content):
    manifest = {}
    for line in content.decode().splitlines():
        expected, name = line.split('  ', 1)
        assert re.fullmatch(r'[0-9a-f]{64}', expected), 'Invalid checksum: ' + name
        assert name not in manifest, 'Duplicate checksum entry: ' + name
        manifest[name] = expected
    return manifest


def archive_root(files):
    if 'release.json' in files:
        return json.loads(files['release.json'])['archive_root']
    return ROOT_NAME


def inspect_archive(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), 'Duplicate ZIP member names'
        assert len(names) == len({name.casefold() for name in names}), 'Windows ZIP path collision'
        assert archive.testzip() is None, 'ZIP CRC failure'
        files, roots = {}, set()
        for item in archive.infolist():
            name = item.filename
            parts = PurePosixPath(name).parts
            assert not name.startswith('/') and len(parts) > 1, name
            assert '..' not in parts and '\\' not in name and ':' not in name, name
            assert '\n' not in name and '\r' not in name, name
            roots.add(parts[0])
            if not item.is_dir():
                assert '/'.join(parts) == name, 'Noncanonical ZIP path: ' + name
                relative = '/'.join(parts[1:])
                files[relative] = archive.read(item)
    assert roots == {archive_root(files)}, 'ZIP root does not match release metadata'
    manifest = parse_checksums(files['CHECKSUMS.sha256'])
    assert set(manifest) == set(files) - {'CHECKSUMS.sha256'}, 'Checksum coverage differs from ZIP'
    mismatches = [name for name, expected in manifest.items() if sha256(files[name]) != expected]
    assert not mismatches, f'ZIP checksum mismatches ({len(mismatches)}): {mismatches}'
    return files


def verify_release_metadata(files):
    info = json.loads(files['BUILD_INFO.json'])
    if 'release.json' not in files:
        return info
    release = json.loads(files['release.json'])
    source = info['source']
    for key in ('product_name', 'version', 'display_version', 'tag', 'archive_root', 'asset_name'):
        assert info[key] == release[key], 'Release/build metadata mismatch: ' + key
    assert release['tag'] == 'v' + release['version'], 'Release tag/version mismatch'
    assert info['source_repository'] == 'https://github.com/' + release['repository']
    assert info['source_commit'] == source['commit'] and info['source_tree'] == source['tree']
    assert re.fullmatch(r'[0-9a-f]{40}', source['commit'])
    assert re.fullmatch(r'[0-9a-f]{40}', source['tree'])
    assert sha256(files['SOURCE_CHANGES.patch']) == info['source_patch_sha256'] == source['patch_sha256']
    assert source['patch_replay_tree'] == source['tree']
    if not source['dirty']:
        assert source['committed_tree'] == source['tree'], 'Clean release source tree mismatch'
    version = re.search(rb"version\s*=\s*['\"]([^'\"]+)", files['script/share/changelog.lua'])
    assert version and version.group(1).decode() == release['version'], 'Release changelog version mismatch'
    brand = re.search(rb"name\s*=\s*['\"]([^'\"]+)", files['script/share/brand.lua'])
    assert brand and brand.group(1).decode() == release['product_name'], 'Application brand mismatch'
    suffix = '-dirty' if source['dirty'] else ''
    expected_gitlog = ("return {\n    commit = '%s%s',\n    date = '%s',\n}\n" %
                       (source['commit'], suffix, source['commit_date_utc'])).encode()
    assert files['script/share/gitlog.lua'] == expected_gitlog, 'Generated commit/date do not match source'
    assert info['generated_source_files'] == {'script/share/gitlog.lua': sha256(expected_gitlog)}
    source_manifest = parse_checksums(files['SOURCE_FILES.sha256'])
    assert len(source_manifest) == info['packaged_source_files_verified']
    for name, expected in source_manifest.items():
        assert sha256(files[name]) == expected, 'Packaged source checksum mismatch: ' + name
    return info


def verify_release_source(files, repo, info):
    """Compare all packaged source against the claimed Git object snapshot."""
    manifest = parse_checksums(files['SOURCE_FILES.sha256'])
    source = info['source']
    def git(*args, input=None):
        result = subprocess.run(['git', *args], cwd=repo, input=input, capture_output=True)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        return result.stdout
    assert git('rev-parse', 'HEAD').decode().strip() == source['commit'], 'Source checkout HEAD differs'
    if source['dirty']:
        for name in manifest:
            assert (repo / name).read_bytes() == files[name], 'Development source mismatch: ' + name
        return len(manifest)
    assert not git('status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none'), \
        'Source checkout must remain clean during release verification'
    assert git('rev-parse', 'HEAD^{tree}').decode().strip() == source['tree'], 'Source Git tree differs'
    expected_names = set()
    prefixes = ('script/', 'test/', 'make/', 'docs/', 'data/warcraft-current/')
    roots = {'README.md', 'CHANGELOG.md', 'LICENSE.txt', 'config.ini', 'release.json'}
    for record in git('ls-tree', '-r', '-z', source['tree']).split(b'\0'):
        if not record:
            continue
        attributes, name = record.split(b'\t', 1)
        mode, kind, oid = attributes.decode().split()
        name = name.decode()
        if kind == 'blob' and (name.startswith(prefixes) or name in roots) and name != 'script/share/gitlog.lua':
            assert mode in ('100644', '100755'), 'Non-regular source file: ' + name
            expected_names.add(name)
    assert set(manifest) == expected_names, 'Packaged source manifest differs from committed source set'
    names = sorted(manifest)
    requests = ''.join(source['commit'] + ':' + name + '\n' for name in names).encode()
    blobs = git('cat-file', '--batch', input=requests)
    offset = 0
    for name in names:
        end = blobs.index(b'\n', offset)
        oid, kind, size = blobs[offset:end].split()
        assert kind == b'blob', 'Expected source blob: ' + name
        start, length = end + 1, int(size)
        content = blobs[start:start + length]
        assert content == files[name], 'ZIP/committed-source mismatch: ' + name
        assert blobs[start + length:start + length + 1] == b'\n'
        offset = start + length + 1
    assert offset == len(blobs), 'Unexpected source blob data'
    return len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--stormlib', type=Path, required=True)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--upstream', type=Path)
    args = parser.parse_args()
    files = inspect_archive(args.archive)
    fingerprint = runtime_fingerprint(files)
    info = verify_release_metadata(files)
    assert info['package_runtime_fingerprint'] == fingerprint
    checked_source, checked_native = 0, 0
    if args.source:
        if 'release.json' in files:
            checked_source = verify_release_source(files, args.source, info)
        else:
            for folder in ['script', 'test', 'data/warcraft-current']:
                for path in (args.source / folder).rglob('*'):
                    if not path.is_file() or '__pycache__' in path.parts or path.suffix == '.pyc' or path.name == 'gitlog.lua':
                        continue
                    name = path.relative_to(args.source).as_posix()
                    assert files[name] == path.read_bytes(), 'ZIP/source mismatch: ' + name
                    checked_source += 1
    if args.upstream:
        if 'release.json' in files:
            assert sha256(args.upstream.read_bytes()) == info['native_runtime']['release_zip_sha256'], \
                'Official runtime ZIP hash does not match release provenance'
        with zipfile.ZipFile(args.upstream) as upstream:
            for name in upstream.namelist():
                if name.lower().endswith(('.exe', '.dll')):
                    assert files[name] == upstream.read(name), 'Changed native binary: ' + name
                    checked_native += 1
        assert checked_native == 22
    work = args.workdir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    extracted = work / archive_root(files)
    for name, content in files.items():
        path = extracted / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    for name, content in files.items():
        assert (extracted / name).read_bytes() == content, 'Extraction mismatch: ' + name
    print(f'PASS final ZIP integrity: {len(files)} members, {checked_source} source/data files, {checked_native} native binaries', flush=True)
    runtime = args.runtime.resolve()
    environment = dict(os.environ, W2L_TEST_RUNTIME=str(runtime), PYTHONDONTWRITEBYTECODE='1')

    def run(index, name, filename):
        path = extracted / 'test/compat' / filename
        command = [str(runtime / 'lua'), str(path)] if filename.endswith('.lua') else ['python3', '-B', str(path)]
        if filename == 'user_map.py':
            command += ['--map', str(extracted / 'map-validation/HiTestMapFromWorldEditor-original.w3x'),
                        '--library', str(args.stormlib.resolve()), '--output', str(work / 'map-validation')]
        start = time.monotonic()
        result = subprocess.run(command, cwd=extracted, env=environment, capture_output=True, text=True)
        return index, {'name': name, 'file': filename, 'command': command, 'exit_code': result.returncode,
                       'elapsed_seconds': round(time.monotonic() - start, 2),
                       'stdout': result.stdout, 'stderr': result.stderr}

    suites = [None] * len(SUITES)
    with ThreadPoolExecutor(max_workers=3) as pool:
        pending = [pool.submit(run, i, *suite) for i, suite in enumerate(SUITES)]
        for future in as_completed(pending):
            index, result = future.result()
            suites[index] = result
            print(('PASS' if result['exit_code'] == 0 else 'FAIL') + ': ' + result['file'], flush=True)
            if result['exit_code']:
                print(result['stdout'] + result['stderr'], flush=True)
    # Tests may create temporary outputs, but may not mutate any packaged input.
    for name, content in files.items():
        assert (extracted / name).read_bytes() == content, 'Test mutated packaged file: ' + name
    report = {'archive': str(args.archive.resolve()), 'archive_sha256': sha256(args.archive.read_bytes()),
              'source_commit': info.get('source_commit'), 'source_tree': info.get('source_tree'),
              'package_runtime_fingerprint': fingerprint,
              'archive_integrity': {'status': 'passed', 'members_verified': len(files),
                                    'source_data_files_verified': checked_source,
                                    'unchanged_native_binaries': checked_native,
                                    'extracted_bytes_verified_before_and_after_tests': True},
              'extracted_root': str(extracted), 'map_validation': str(work / 'map-validation'),
              'suites': suites, 'windows_gui_native_tested': False}
    (work / 'VALIDATION.json').write_text(json.dumps(report, indent=2) + '\n')
    assert all(result['exit_code'] == 0 for result in suites), 'One or more package suites failed'
    print(f'PASS all {len(suites)} extracted-package suites; report: {work / "VALIDATION.json"}', flush=True)


if __name__ == '__main__':
    main()
