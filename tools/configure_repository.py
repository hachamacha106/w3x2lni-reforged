#!/usr/bin/env python3
"""Point new maintenance repo metadata and navigational links at OWNER/REPO."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OLD = 'hachamacha106/w3x2lni-Reforged'
LINK_FILES = ('README.md', 'docs/en-us/reforged-release.md', 'docs/en-us/current-warcraft.md')


def configure(repo: str) -> None:
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Expected a GitHub OWNER/REPO (e.g. YourName/w3x2lni-reforged)')
    data_file = ROOT / 'release.json'
    content = json.loads(data_file.read_text(encoding='utf-8'))
    old_repo = content['repository']
    content['repository'] = repo
    data_file.write_text(json.dumps(content, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    for name in LINK_FILES:
        path = ROOT / name
        text = path.read_text(encoding='utf-8')
        # Only replace complete project slug in GitHub URLs; preserve author credit.
        for previous in (OLD, old_repo):
            text = text.replace('https://github.com/' + previous,
                                'https://github.com/' + repo)
        path.write_text(text, encoding='utf-8')
    print(f'Configured release.json repository and project links for {repo}')
    print('Review `git diff`; then commit, add your GitHub remote and push.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', help='GitHub OWNER/REPO')
    args = parser.parse_args()
    configure(args.repository)


if __name__ == '__main__':
    main()
