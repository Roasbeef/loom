#!/usr/bin/env python3
"""Regression coverage for canonical packaging across different source trees."""

import importlib.util
import json
import shutil
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_archive', Path(__file__).with_name('release-archive.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

comparison_spec = importlib.util.spec_from_file_location('release_compare', Path(__file__).with_name('release-compare.py'))
comparison = importlib.util.module_from_spec(comparison_spec)
comparison_spec.loader.exec_module(comparison)


class ArchiveTest(unittest.TestCase):
    def test_metadata_and_creation_order_do_not_change_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, order, permissions, timestamp in [
                ('first', ['a', 'b'], 0o700, 100),
                ('second', ['b', 'a'], 0o755, 200),
            ]:
                source = root / name
                source.mkdir()
                for file in order:
                    (source / file).write_bytes(file.encode())
                    (source / file).chmod(permissions)
                    os.utime(source / file, (timestamp, timestamp))
                (source / 'alias').symlink_to('a')
                release.archive(source, root / f'{name}.tar.gz', 'loom-test', 123)
            self.assertEqual((root / 'first.tar.gz').read_bytes(), (root / 'second.tar.gz').read_bytes())
            with tarfile.open(root / 'first.tar.gz') as archive:
                self.assertEqual(archive.getnames(), ['loom-test', 'loom-test/a', 'loom-test/alias', 'loom-test/b'])
                for entry in archive:
                    self.assertEqual((entry.uid, entry.gid, entry.mtime), (0, 0, 123))
                self.assertEqual(archive.getmember('loom-test/a').mode, 0o755)
                self.assertEqual(archive.getmember('loom-test/alias').linkname, 'a')

    def test_hardlink_layout_does_not_change_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ['copied', 'linked']:
                source = root / name
                source.mkdir()
                (source / 'a').write_bytes(b'content')
                if name == 'linked':
                    os.link(source / 'a', source / 'b')
                else:
                    (source / 'b').write_bytes(b'content')
                release.archive(source, root / f'{name}.tar.gz', 'loom-test', 123)
            self.assertEqual((root / 'copied.tar.gz').read_bytes(), (root / 'linked.tar.gz').read_bytes())


class ComparisonTest(unittest.TestCase):
    def test_complete_artifacts_are_required_and_bound_to_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / 'first'
            first.mkdir()
            source = root / 'source'
            source.mkdir()
            (source / 'entry').write_text('fixture')
            artifacts = []
            for component in ['server', 'client', 'slim']:
                path = first / (component + '.tar.gz')
                release.archive(source, path, component, 123)
                artifacts.append({'component': component, 'name': path.name,
                                  'size': path.stat().st_size, 'sha256': release.digest(path)})
            manifest = first / 'manifest-linux-x86_64.json'
            manifest.write_text(json.dumps({'schema': 1, 'repository': 'Roasbeef/loom',
                                            'commit': 'a' * 40, 'artifacts': artifacts}))
            second = root / 'second'
            shutil.copytree(first, second)
            self.assertEqual(comparison.compare(first, second)['result'], 'identical')
            for directory in [first, second]:
                (directory / 'server.tar.gz').write_bytes(b'changed in both builds')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                comparison.compare(first, second)
            for directory in [first, second]:
                (directory / 'server.tar.gz').unlink()
            with self.assertRaisesRegex(ValueError, 'missing'):
                comparison.compare(first, second)

    def test_matching_manifest_only_outputs_are_not_reproduced_releases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directories = [root / 'first', root / 'second']
            for directory in directories:
                directory.mkdir()
                (directory / 'manifest-linux-x86_64.json').write_text(json.dumps({
                    'schema': 1, 'repository': 'Roasbeef/loom', 'commit': 'a' * 40, 'artifacts': []}))
            with self.assertRaisesRegex(ValueError, 'server, client and slim'):
                comparison.compare(*directories)


if __name__ == '__main__':
    unittest.main()
