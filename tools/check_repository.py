#!/usr/bin/env python3
"""Ensure release configuration points to the actual GitHub Actions repository."""
import json
import os
from pathlib import Path

configured = json.loads((Path(__file__).resolve().parents[1] / 'release.json').read_text(encoding='utf-8'))['repository']
actual = os.environ.get('GITHUB_REPOSITORY')
if not actual:
    raise SystemExit('GITHUB_REPOSITORY is not set (run this script in GitHub Actions)')
if configured != actual:
    raise SystemExit(f'Wrong release.json repository: {configured!r}; expected {actual!r}. Run tools/configure_repository.py OWNER/REPO and commit the change.')
print(f'Repository identifier matches: {actual}')
