"""Prove a native seed remains relocatable without relaxing archive links."""

import importlib.util
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest

from codemode_seed_plugin import materialize

spec = importlib.util.spec_from_file_location(
    'release_archive', Path(__file__).with_name('release-archive.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class NativeSeedPluginTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.seed = self.root / 'seed'
        native = self.seed / 'build/dev/erlang/esqlite'
        self.target = native / '_build/default/plugins/pc'
        self.target.mkdir(parents=True)
        (self.target / 'pc.beam').write_bytes(b'compiled plugin')
        (self.target / 'build-tool').write_bytes(b'executable plugin tool')
        (self.target / 'build-tool').chmod(0o755)
        self.native_library = native / 'priv/esqlite3_nif.so'
        self.native_library.parent.mkdir()
        self.native_library.write_bytes(b'native fixture')
        self.plugin = native / '_build/prod/plugins/pc'
        self.plugin.parent.mkdir(parents=True)
        self.plugin.symlink_to(self.target)

    def test_native_seed_packages_and_relocates_without_the_original_root(self):
        archive = self.root / 'seed.tar.gz'
        with self.assertRaisesRegex(ValueError, 'unsupported release symlink'):
            release.archive(self.seed, archive, 'seed', 123)

        materialize(self.seed)
        materialize(self.seed)
        self.assertFalse(self.plugin.is_symlink())
        release.archive(self.seed, archive, 'seed', 123)
        with tarfile.open(archive) as packed:
            self.assertTrue(all(not entry.issym() for entry in packed))
        relocated = self.root / 'relocated'
        shutil.copytree(self.seed, relocated)
        shutil.rmtree(self.seed)
        plugin = relocated / self.plugin.relative_to(self.seed)
        self.assertEqual((plugin / 'pc.beam').read_bytes(), b'compiled plugin')
        self.assertEqual((plugin / 'build-tool').stat().st_mode & 0o777, 0o755)
        library = relocated / self.native_library.relative_to(self.seed)
        self.assertEqual(library.read_bytes(), b'native fixture')

    def test_external_plugin_target_is_refused_without_changing_the_seed(self):
        outside = self.root / 'outside'
        outside.mkdir()
        self.plugin.unlink()
        self.plugin.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'in-seed default plugin'):
            materialize(self.seed)
        self.assertEqual(self.plugin.readlink(), outside)

    def test_nested_plugin_link_is_refused_without_dereferencing_it(self):
        (self.target / 'unexpected').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'only regular paths'):
            materialize(self.seed)
        self.assertTrue(self.plugin.is_symlink())


if __name__ == '__main__':
    unittest.main()
