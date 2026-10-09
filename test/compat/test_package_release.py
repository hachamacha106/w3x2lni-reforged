#!/usr/bin/env python3
"""Regression checks for committed-source and reproducible release packaging.

These use small temporary Git repositories and ZIPs, not simulated converter
results. The 14 converter suites are run separately against the real candidate.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packager = load_module('package_release', ROOT / 'make/package-release.py')
verifier = load_module('verify_package', ROOT / 'test/compat/verify_package.py')


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='packager-test-', dir=ROOT / 'build')
        self.repo = Path(self.temporary.name)
        self.run_git('init', '-q')
        self.run_git('config', 'user.name', 'Release packaging test')
        self.run_git('config', 'user.email', 'packaging-test@example.invalid')
        (self.repo / '.gitignore').write_text('/build/\n')
        (self.repo / 'script').mkdir()
        (self.repo / 'script/main.lua').write_text("return 'base'\n")
        self.run_git('add', '.')
        # A gitlink needs no initialized checkout to supply reproducible pins.
        (self.repo / '3rd/example').mkdir(parents=True)
        self.run_git('update-index', '--add', '--cacheinfo',
                     '160000,1111111111111111111111111111111111111111,3rd/example')
        self.run_git('commit', '-qm', 'Upstream fixture')
        self.previous_base = packager.UPSTREAM_BASE
        packager.UPSTREAM_BASE = self.run_git('rev-parse', 'HEAD').decode().strip()

    def tearDown(self):
        packager.UPSTREAM_BASE = self.previous_base
        self.temporary.cleanup()

    def run_git(self, *args):
        result = subprocess.run(['git', *args], cwd=self.repo, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    def test_patch_contains_committed_changes_and_reproduces_exact_tree(self):
        (self.repo / 'script/main.lua').write_text("return 'release'\n")
        (self.repo / 'new-source.bin').write_bytes(bytes(range(256)))
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Committed release work')
        source, files, patch, status = packager.source_snapshot(self.repo)
        self.assertFalse(status)
        self.assertFalse(source['dirty'])
        self.assertEqual(source['tree'], source['committed_tree'])
        self.assertEqual(source['patch_replay_tree'], source['tree'])
        self.assertEqual(files['script/main.lua'], b"return 'release'\n")
        self.assertEqual(files['new-source.bin'], bytes(range(256)))
        self.assertIn(b"+return 'release'", patch)
        self.assertIn(b'GIT binary patch', patch)
        self.assertEqual(source['submodule_commits'],
                         {'3rd/example': '1111111111111111111111111111111111111111'})
        damaged = patch.replace(b"+return 'release'", b"+return 'wrong!!'")
        with self.assertRaisesRegex(ValueError, 'reproduce'):
            packager.replay_patch(self.repo, packager.UPSTREAM_BASE, source['tree'], damaged)

    def test_dirty_source_rejected_by_default_and_temporary_index_is_isolated(self):
        (self.repo / 'script/main.lua').write_text("return 'staged'\n")
        self.run_git('add', '.')
        (self.repo / 'script/main.lua').write_text("return 'working'\n")
        (self.repo / 'untracked.txt').write_text('new file\n')
        before = (self.repo / '.git/index').read_bytes()
        with self.assertRaisesRegex(ValueError, 'clean and committed'):
            packager.source_snapshot(self.repo)
        source, files, patch, status = packager.source_snapshot(self.repo, allow_dirty=True)
        self.assertTrue(source['dirty'])
        self.assertNotEqual(source['tree'], source['committed_tree'])
        self.assertEqual(files['script/main.lua'], b"return 'working'\n")
        self.assertEqual(files['untracked.txt'], b'new file\n')
        self.assertEqual((self.repo / '.git/index').read_bytes(), before)
        self.assertIn(b'-dirty', packager.generated_gitlog(source))
        with self.assertRaisesRegex(ValueError, 'dirty development candidate'):
            packager.validate_test_report({}, 'unused', source)

    def test_archive_reproducible_and_changed_payload_rejected(self):
        root = 'w3x2lni-reforged-1.0.0'
        files = {'release.json': json.dumps({'archive_root': root}).encode(),
                 'script/example.lua': b"return 'tested bytes'\n"}
        first, packed = packager.write_verified_zip(self.repo / 'first.zip', root, files, 1791530000)
        second, _ = packager.write_verified_zip(self.repo / 'second.zip', root, files, 1791530000)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(verifier.inspect_archive(first), packed)
        self.assertEqual(packager.runtime_fingerprint(packed), verifier.runtime_fingerprint(packed))
        broken = self.repo / 'modified.zip'
        with zipfile.ZipFile(first) as original, zipfile.ZipFile(broken, 'w') as archive:
            for item in original.infolist():
                content = original.read(item)
                if item.filename.endswith('/script/example.lua'):
                    content = b"return 'untested bytes'\n"
                archive.writestr(item, content)
        with self.assertRaisesRegex(AssertionError, 'ZIP checksum mismatches'):
            verifier.inspect_archive(broken)

    def test_validation_requires_distinct_suites_and_same_source(self):
        source = {'commit': 'a' * 40, 'tree': 'b' * 40, 'dirty': False}
        result = {'source_commit': source['commit'], 'source_tree': source['tree'],
                  'package_runtime_fingerprint': 'matching',
                  'archive_integrity': {'status': 'passed',
                                        'extracted_bytes_verified_before_and_after_tests': True},
                  'suites': [{'file': name, 'exit_code': 0} for name in sorted(packager.SUITE_FILES)]}
        packager.validate_test_report(result, 'matching', source)
        with self.assertRaisesRegex(ValueError, 'Runtime differs'):
            packager.validate_test_report(result, 'different', source)
        result['source_tree'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'different committed release source'):
            packager.validate_test_report(result, 'matching', source)
        result['source_tree'] = source['tree']
        result['suites'][0] = result['suites'][1]
        with self.assertRaisesRegex(ValueError, '14 distinct'):
            packager.validate_test_report(result, 'matching', source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
