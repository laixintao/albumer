import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('distribution', ROOT / 'scripts/distribution.py')
distribution = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distribution)


class ReleaseCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='albumer-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.repo = self.directory / 'app'
        self.remote = self.directory / 'remote.git'
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        for variable in ['VERSION', 'RELEASE_TAG', 'ARTIFACT_DIR', 'GIT_DIR', 'GIT_WORK_TREE']:
            self.env.pop(variable, None)
        self.run_command('git', 'init', '--bare', '-b', 'main', str(self.remote))
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release@example.test')
        for name in ['.gitignore', 'Makefile', 'scripts/release.py', 'scripts/distribution.py', 'Sources/Albumer/Resources/Info.plist', 'CHANGELOG.md']:
            destination = self.repo / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        # Keep fixtures independent of the version currently being released.
        plist = self.repo / 'Sources/Albumer/Resources/Info.plist'
        data = plistlib.loads(plist.read_bytes())
        data['CFBundleShortVersionString'] = '1.0.0'
        data['CFBundleVersion'] = '1'
        plist.write_bytes(plistlib.dumps(data))
        self.git('add', '.')
        self.git('commit', '-m', 'Initial application')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-u', 'origin', 'main')
        self.initial = self.git('rev-parse', 'HEAD').stdout.strip()
        self.original_plist = plist.read_bytes()

    def run_command(self, *args, check=True, cwd=None, env=None):
        return subprocess.run(args, cwd=cwd or self.repo, env=env or self.env,
                              text=True, capture_output=True, check=check)

    def git(self, *args, **kwargs):
        return self.run_command('git', *args, **kwargs)

    def release(self, version=None):
        args = ['make', 'release']
        if version is not None:
            args.append('VERSION=' + version)
        return self.run_command(*args, check=False)

    def assert_untouched(self):
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)
        self.assertEqual((self.repo / 'Sources/Albumer/Resources/Info.plist').read_bytes(), self.original_plist)

    def test_plain_make_release_bumps_commits_tags_and_pushes(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        head = self.git('rev-parse', 'HEAD').stdout.strip()
        self.assertEqual(self.git('rev-parse', 'v1.0.1^{commit}').stdout.strip(), head)
        self.assertEqual(self.git('cat-file', '-t', 'v1.0.1').stdout.strip(), 'tag')
        self.assertIn(head, self.git('ls-remote', 'origin', 'refs/heads/main').stdout)
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        info = plistlib.loads((self.repo / 'Sources/Albumer/Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '1.0.1')
        self.assertEqual(info['CFBundleVersion'], '2')
        self.assertIn('Initial application', (self.repo / 'docs/releases/v1.0.1.md').read_text())
        self.assertIn('/actions/workflows/release.yml', result.stdout)
        self.assertNotEqual(self.release().returncode, 0, 'Do not publish an empty follow-up release')

    def test_explicit_version_preserves_committed_curated_notes(self):
        path = self.repo / 'docs/releases/v1.2.0.md'
        path.parent.mkdir(parents=True)
        curated = '# Albumer 1.2.0\n\nCurated notes that must survive automatic release preparation.\n'
        path.write_text(curated)
        self.git('add', '.')
        self.git('commit', '-m', 'Curate next release')
        result = self.release('1.2.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), curated)

    def test_dirty_tree_rejected_before_edits(self):
        (self.repo / 'uncommitted.txt').write_text('work in progress')
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_untouched()

    def test_wrong_branch_rejected_before_edits(self):
        self.git('switch', '-c', 'feature')
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_untouched()

    def test_invalid_or_nonincreasing_versions_rejected(self):
        for version in ['1.0.0', '0.9.0', 'v1.2.0', '01.2.3', '1.1.0-rc.1', 'invalid']:
            with self.subTest(version=version):
                self.assertNotEqual(self.release(version).returncode, 0)
                self.assert_untouched()

    def test_local_tag_conflict_rejected(self):
        self.git('tag', '-a', 'v1.0.1', '-m', 'Already prepared')
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_untouched()

    def test_remote_tag_conflict_rejected(self):
        self.git('tag', '-a', 'v1.0.1', '-m', 'Published tag')
        self.git('push', 'origin', 'v1.0.1')
        self.git('tag', '-d', 'v1.0.1')
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_untouched()

    def test_remote_ahead_rejected_before_edits(self):
        other = self.directory / 'other'
        self.git('clone', str(self.remote), str(other))
        self.run_command('git', 'config', 'user.name', 'Other', cwd=other)
        self.run_command('git', 'config', 'user.email', 'other@example.test', cwd=other)
        (other / 'new.txt').write_text('remote change')
        self.run_command('git', 'add', '.', cwd=other)
        self.run_command('git', 'commit', '-m', 'Remote change', cwd=other)
        self.run_command('git', 'push', cwd=other)
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_untouched()

    def test_rejected_atomic_push_retains_retryable_commit_and_tag(self):
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        retry = 'git push --atomic origin HEAD:refs/heads/main refs/tags/v1.0.1'
        self.assertIn(retry, result.stderr)
        self.assertNotEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        self.assertEqual(self.git('cat-file', '-t', 'v1.0.1').stdout.strip(), 'tag')
        self.assertIn(self.initial, self.git('ls-remote', 'origin', 'refs/heads/main').stdout)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/v1.0.1').stdout, '')
        hook.unlink()
        self.git('push', '--atomic', 'origin', 'HEAD:refs/heads/main', 'refs/tags/v1.0.1')
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout, self.git('rev-parse', 'origin/main').stdout)


class ReleaseBoundaryTests(unittest.TestCase):
    def test_public_release_cannot_be_replaced(self):
        with patch.object(distribution, 'validate_metadata', return_value='1.0.1'), \
             patch.object(distribution, 'verify_packages', return_value=['package.dmg']), \
             patch.object(distribution, 'release_record', return_value={'draft': False}), \
             patch.object(distribution, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'already public'):
                distribution.publish(Path('/unused'), 'v1.0.1')
            command.assert_not_called()

    def test_changed_checksum_rejected_before_archive_mount(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            names = distribution.artifact_names('1.0.1')
            for name in names:
                (directory / name).write_bytes(b'changed')
            (directory / 'package-manifest.json').write_text(json.dumps({
                'version': '1.0.1', 'files': {name: '0' * 64 for name in names}
            }))
            with patch.object(distribution, 'run') as command:
                with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                    distribution.verify_packages(directory, '1.0.1')
                command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
