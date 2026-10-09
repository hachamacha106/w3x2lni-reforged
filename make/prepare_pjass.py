#!/usr/bin/env python3
"""Prepare the checksum-pinned Windows pjass helper or the same-source Linux checker."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from runtime_origins import PJASS_COMMIT, PJASS_RELEASE, PJASS_SHA256, PJASS_URL, fetch_pjass

def run(command, cwd=None):
    subprocess.run(list(map(str, command)), cwd=cwd, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=('windows', 'linux'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.target == 'windows':
        fetch_pjass(args.output)
        print(json.dumps({'path': str(args.output), 'release': PJASS_RELEASE,
                          'source_commit': PJASS_COMMIT, 'sha256': PJASS_SHA256, 'url': PJASS_URL}))
        return
    if os.name == 'nt':
        parser.error('The Linux test checker must be built on Linux')
    missing = [name for name in ('git', 'make', 'gcc', 'bison', 'flex') if not shutil.which(name)]
    if missing:
        parser.error('Missing Linux build tools: ' + ', '.join(missing))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / 'source'
    if not source.exists():
        run(['git', 'clone', '--no-checkout', 'https://github.com/lep/pjass', source])
    run(['git', 'fetch', '--depth=1', 'origin', PJASS_COMMIT], source)
    run(['git', 'checkout', '--detach', PJASS_COMMIT], source)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if revision != PJASS_COMMIT:
        raise ValueError('pjass source pin mismatch')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=source):
        raise ValueError('pjass pinned source must be clean')
    run(['make', '-f', 'GNUmakefile', 'clean'], source)
    run(['make', '-f', 'GNUmakefile', '-j2', 'CC=gcc', 'CFLAGS=-O2 -MMD', 'VERSION=' + PJASS_RELEASE, 'all'], source)
    run(['make', '-f', 'GNUmakefile', 'test'], source)
    shutil.copyfile(source / 'pjass', output / 'pjass')
    (output / 'pjass').chmod(0o755)
    (output / 'provenance.json').write_text(json.dumps({
        'release': PJASS_RELEASE, 'source_commit': PJASS_COMMIT,
        'purpose': 'Linux test-only checker; portable Windows tool is the verified upstream asset',
    }, indent=2) + '\n')
    print(output / 'pjass')

if __name__ == '__main__':
    main()

