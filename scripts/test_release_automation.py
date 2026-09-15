"""Exercise publication identity checks and release pushes against local remotes."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tagging = load('release-tag')
staging = load('release-stage')
COMMIT = 'a' * 40


class StagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for platform, prefix in [('linux-x86_64', 'release'), ('macos-arm64', 'release-macos')]:
            for builder in ('first', 'second'):
                directory = self.root / f'{prefix}-{builder}'
                directory.mkdir()
                artifacts = []
                for component in ('server', 'client', 'slim'):
                    name = f'{component}-{platform}.bin'
                    data = component.encode()
                    (directory / name).write_bytes(data)
                    artifacts.append(dict(component=component, name=name, size=len(data), sha256=hashlib.sha256(data).hexdigest()))
                document = dict(schema=1, repository='Roasbeef/loom', tag='v0.2.0', version='0.2.0', commit=COMMIT, platform=platform, artifacts=artifacts)
                (directory / f'manifest-{platform}.json').write_text(json.dumps(document))
                (directory / 'SHA256SUMS').write_text('builder checksums\n')

    def stage(self):
        staging.stage(self.root, self.root / 'upload', 'v0.2.0', COMMIT)

    def test_complete_upload_and_aggregate_checksums(self):
        self.stage()
        upload = self.root / 'upload'
        self.assertEqual(len(list(upload.iterdir())), 10)
        for line in (upload / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(hashlib.sha256((upload / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(set(json.loads((upload / 'reproduction.json').read_text())), {'linux-x86_64', 'macos-arm64'})

    def test_matching_builds_cannot_claim_other_identity(self):
        for field, wrong in [('commit', 'b' * 40), ('tag', 'v0.3.0'), ('version', '0.3.0'), ('platform', 'linux-arm64')]:
            with self.subTest(field=field):
                paths = list(self.root.glob('release-macos-*/manifest-*.json'))
                originals = [p.read_text() for p in paths]
                for path in paths:
                    document = json.loads(path.read_text())
                    document[field] = wrong
                    path.write_text(json.dumps(document))
                with self.assertRaisesRegex(ValueError, 'does not match'):
                    self.stage()
                self.assertFalse((self.root / 'upload').exists())
                for path, original in zip(paths, originals):
                    path.write_text(original)

    def test_missing_or_modified_build_blocks_staging(self):
        archive = self.root / 'release-second/client-linux-x86_64.bin'
        archive.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.stage()
        archive.unlink()
        with self.assertRaisesRegex(ValueError, 'different artifact sets'):
            self.stage()
        self.assertFalse((self.root / 'upload').exists())

    def test_extra_files_are_not_uploaded(self):
        for builder in ('first', 'second'):
            (self.root / f'release-{builder}/unexpected.txt').write_text('extra')
        with self.assertRaisesRegex(ValueError, 'unexpected'):
            self.stage()


class TaggingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        self.remote = Path(self.temp.name) / 'remote.git'
        self.run_git('init', '-q', '--initial-branch=main')
        self.run_git('config', 'user.name', 'Release Test')
        self.run_git('config', 'user.email', 'release@example.invalid')
        for package in ('client', 'tui'):
            directory = self.root / 'packages' / package
            directory.mkdir(parents=True)
            (directory / 'gleam.toml').write_text('version = "0.2.0"\n')
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Initial')
        self.run_git('init', '-q', '--bare', str(self.remote))
        self.run_git('remote', 'add', 'origin', str(self.remote))
        self.run_git('push', '-q', 'origin', 'main')
        self.patcher = patch.object(tagging, 'ROOT', self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def run_git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True, stderr=subprocess.STDOUT).strip()

    def invoke(self, *args):
        with patch('sys.argv', ['release-tag.py', *args]), contextlib.redirect_stdout(io.StringIO()):
            tagging.main()

    def test_preview_does_not_tag_and_push_is_atomic(self):
        (self.root / 'change').write_text('release content')
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Release')
        self.invoke('v0.2.0')
        self.assertEqual(self.run_git('tag'), '')
        self.invoke('v0.2.0', '--push')
        self.assertEqual(self.run_git('cat-file', '-t', 'v0.2.0'), 'tag')
        refs = self.run_git('ls-remote', 'origin')
        self.assertIn(self.run_git('rev-parse', 'HEAD') + '\trefs/heads/main', refs)
        self.assertIn(self.run_git('rev-parse', 'HEAD') + '\trefs/tags/v0.2.0^{}', refs)

    def test_invalid_version_and_dirty_checkout_refuse_before_tagging(self):
        for tag in ('v0.3.0', 'v01.2.0', 'v0.2.0;echo', 'main', 'v0.2.0-rc.0'):
            with self.subTest(tag=tag), self.assertRaises(SystemExit):
                self.invoke(tag, '--push')
        (self.root / 'dirty').write_text('uncommitted')
        with self.assertRaises(SystemExit):
            self.invoke('v0.2.0', '--push')
        self.assertEqual(self.run_git('tag'), '')

    def test_remote_tag_is_never_moved(self):
        self.run_git('push', '-q', 'origin', 'HEAD:refs/tags/v0.2.0')
        with self.assertRaises(SystemExit):
            self.invoke('v0.2.0', '--push')
        self.assertEqual(self.run_git('tag'), '')

    def test_rejected_tag_push_cannot_advance_main(self):
        original = self.run_git('rev-parse', 'HEAD')
        (self.root / 'change').write_text('new release')
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Release')
        hook = self.remote / 'hooks/update'
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1 ;; esac\n')
        hook.chmod(0o755)
        with self.assertRaises(SystemExit):
            self.invoke('v0.2.0', '--push')
        refs = self.run_git('ls-remote', 'origin')
        self.assertIn(original + '\trefs/heads/main', refs)
        self.assertNotIn('refs/tags/', refs)
        self.assertEqual(self.run_git('cat-file', '-t', 'v0.2.0'), 'tag')
