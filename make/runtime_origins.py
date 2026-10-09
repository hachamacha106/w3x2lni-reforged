"""Verify portable native files against their pinned origins, never a blanket override."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import struct
import urllib.request
from native_runtime import validate_probe, validate_pe_x86_dll

STORMLIB_COMMIT = '6bb1882bd00ddbc3729cac5dac0fda81a61e5514'
ZLIB_COMMIT = 'da607da739fa6047df13e66a2af6b8bec7c2a498'
PJASS_COMMIT = '378a1ca9af3848fbc3be3d17069bcdb6a940ee32'
PJASS_RELEASE = 'release-2026-06-15'
PJASS_SHA256 = 'e6384d68fbaf4950d68e174945377dbd8b3b7c310c59122651d5a95ec0fb37d6'
PJASS_URL = 'https://github.com/lep/pjass/releases/download/' + PJASS_RELEASE + '/pjass.exe'
REBUILT_PATH = 'bin/stormlib.dll'
PJASS_PATH = 'bin/pjass.exe'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def require(condition, message):
    if not condition:
        raise ValueError(message)

def pe_x86(data):
    require(len(data) >= 64 and data[:2] == b'MZ', 'Expected a Windows PE artifact')
    offset = struct.unpack_from('<I', data, 60)[0]
    require(offset >= 64 and offset + 26 <= len(data), 'Truncated Windows PE header')
    require(data[offset:offset + 4] == b'PE\0\0', 'Invalid Windows PE signature')
    require(struct.unpack_from('<H', data, offset + 4)[0] == 0x14c
            and struct.unpack_from('<H', data, offset + 24)[0] == 0x10b,
            'Portable native artifact must target Windows x86 PE32')

def fetch_pjass(destination):
    destination = Path(destination)
    if destination.is_file():
        content = destination.read_bytes()
    else:
        with urllib.request.urlopen(PJASS_URL, timeout=60) as response:
            content = response.read(2 * 1024 * 1024 + 1)
    require(digest(content) == PJASS_SHA256, 'pjass checksum mismatch')
    pe_x86(content)
    if not destination.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix('.download')
        temporary.write_bytes(content)
        temporary.replace(destination)
    return content

def validate_rebuilt(manifest, source, abi_bytes, content):
    require(manifest.get('schema_version') == 1 and manifest.get('target') == 'windows-x86',
            'Unsupported native build manifest')
    require(manifest.get('source_commit') == source['commit'], 'Native build came from another source commit')
    require(source['submodule_commits'].get('3rd/stormlib') == STORMLIB_COMMIT
            and source['submodule_commits'].get('3rd/zlib') == ZLIB_COMMIT,
            'Release dependency pins differ from native build pins')
    if not source['dirty']:
        require(manifest.get('source_tree') == source['tree'], 'Native build came from another source tree')
    components = manifest.get('components', [])
    require(len(components) == 1, 'Expected exactly one rebuilt native component')
    item = components[0]
    require(item.get('path') == REBUILT_PATH and item.get('origin') == 'rebuilt', 'Unexpected native replacement')
    require(item.get('sources') == {'stormlib': STORMLIB_COMMIT, 'zlib': ZLIB_COMMIT}, 'Unexpected native source pins')
    settings = item.get('build', {})
    require(settings.get('arch') == 'x86' and settings.get('configuration') == 'Release'
            and settings.get('unicode') is True and settings.get('static_zlib') is True
            and settings.get('crt') == 'static' and bool(settings.get('compiler')),
            'Native build settings do not match the portable runtime')
    probe = item.get('probe', {})
    require(probe.get('status') == 'passed' and probe.get('abi_file') == 'abi.json', 'Native API/storage probe did not pass')
    require(digest(abi_bytes) == probe.get('abi_sha256'), 'Native ABI evidence checksum mismatch')
    abi = json.loads(abi_bytes)
    validate_probe(abi, 'windows-x86')
    require(probe.get('data') == abi, 'Native probe manifest differs from ABI evidence')
    require(digest(content) == item.get('sha256'), 'Rebuilt native checksum mismatch')
    validate_pe_x86_dll(content)
    return item

def load_rebuilt(directory, source):
    directory = Path(directory)
    manifest = json.loads((directory / 'manifest.json').read_bytes())
    abi_bytes = (directory / 'abi.json').read_bytes()
    content = (directory / REBUILT_PATH).read_bytes()
    validate_rebuilt(manifest, source, abi_bytes, content)
    return content, manifest, abi_bytes

def apply_origins(files, upstream, source, native_directory=None, pjass=None):
    original = sorted(name for name in upstream if name.lower().endswith(('.exe', '.dll')))
    require(len(original) == 22, 'Expected 22 official upstream native files')
    records = []
    manifest = None
    if native_directory is not None:
        content, manifest, abi_bytes = load_rebuilt(native_directory, source)
        files[REBUILT_PATH] = content
        files['NATIVE_BUILD.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
        files['NATIVE_ABI.json'] = abi_bytes
    for name in original:
        if manifest is not None and name == REBUILT_PATH:
            records.append(dict(manifest['components'][0]))
        else:
            require(files.get(name) == upstream[name], 'Retained native binary changed: ' + name)
            records.append({'path': name, 'origin': 'retained', 'sha256': digest(upstream[name])})
    if pjass is not None:
        content = Path(pjass).read_bytes()
        require(digest(content) == PJASS_SHA256, 'pjass checksum mismatch')
        pe_x86(content)
        files[PJASS_PATH] = content
        records.append({'path': PJASS_PATH, 'origin': 'added', 'sha256': PJASS_SHA256,
                        'source_commit': PJASS_COMMIT, 'release': PJASS_RELEASE, 'url': PJASS_URL})
    require({item['path'] for item in records}
            == {name for name in files if name.lower().endswith(('.exe', '.dll'))},
            'Unexpected or missing portable native file')
    return {'schema_version': 1, 'files': records, 'rebuilt': manifest is not None,
            'files_verified_unchanged': [item['path'] for item in records if item['origin'] == 'retained']}

def verify_origins(files, info, upstream=None):
    native = info['native_runtime']
    if 'files' not in native:
        require(native.get('rebuilt') is False, 'Legacy provenance cannot authorize rebuilt files')
        if upstream is not None:
            for name, content in upstream.items():
                if name.lower().endswith(('.exe', '.dll')):
                    require(files.get(name) == content, 'Changed legacy native binary: ' + name)
        return len(native['files_verified_unchanged'])
    require(native.get('schema_version') == 1, 'Unknown runtime origin schema')
    records = native['files']
    require(len(records) == len({item['path'] for item in records}), 'Duplicate native origin')
    require({item['path'] for item in records}
            == {name for name in files if name.lower().endswith(('.exe', '.dll'))},
            'Native origin coverage mismatch')
    retained, rebuilt, added = [], [], []
    for item in records:
        name, origin = item['path'], item['origin']
        require(digest(files[name]) == item['sha256'], 'Native origin checksum mismatch: ' + name)
        if origin == 'retained':
            require(name != PJASS_PATH, 'pjass cannot claim upstream provenance')
            if upstream is not None:
                require(name in upstream and files[name] == upstream[name], 'Retained native changed: ' + name)
            retained.append(name)
        elif origin == 'rebuilt':
            require(name == REBUILT_PATH, 'Unexpected rebuilt native path')
            manifest = json.loads(files['NATIVE_BUILD.json'])
            require(manifest.get('components') == [item], 'Native build provenance mismatch')
            validate_rebuilt(manifest, info['source'], files['NATIVE_ABI.json'], files[name])
            rebuilt.append(name)
        elif origin == 'added':
            require(name == PJASS_PATH and item.get('sha256') == PJASS_SHA256
                    and item.get('source_commit') == PJASS_COMMIT and item.get('release') == PJASS_RELEASE
                    and item.get('url') == PJASS_URL, 'Unexpected added native tool')
            pe_x86(files[name])
            added.append(name)
        else:
            raise ValueError('Unknown native origin: ' + str(origin))
    require(len(retained) + len(rebuilt) == 22 and len(rebuilt) <= 1 and len(added) <= 1, 'Native allowlist mismatch')
    require(native.get('rebuilt') is bool(rebuilt), 'Native rebuilt flag differs from origins')
    require(sorted(native['files_verified_unchanged']) == sorted(retained), 'Retained native list mismatch')
    if upstream is not None:
        require({name for name in upstream if name.lower().endswith(('.exe', '.dll'))}
                == set(retained + rebuilt), 'Native baseline membership mismatch')
    return len(retained)

