"""Shipment freshness regressions without spending the gate on compilation."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import shipment


class ShipmentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.package = self.root / 'packages/tui'
        (self.package / 'src').mkdir(parents=True)
        (self.package / 'src/tui.gleam').write_text('pub fn main() { Nil }')
        (self.package / 'gleam.toml').write_text('name = "tui"\n')
        (self.package / 'manifest.toml').write_text('packages = []\n')
        self.cache = self.root / 'build/shipment-cache'
        self.output = self.package / 'build/erlang-shipment'
        self.builds = 0
        self.fail = False
        self.mutate = False
        for name, value in [('ROOT', self.root), ('CACHE', self.cache)]:
            self.enterContext(patch.object(shipment, name, value))
        self.enterContext(patch.object(shipment, 'toolchain', return_value='otp29-gleam119'))
        self.enterContext(patch.object(shipment.subprocess, 'run'))
        self.enterContext(patch.object(shipment.subprocess, 'call', side_effect=self.compile))

    def compile(self, *args, **kwargs):
        self.builds += 1
        if self.fail:
            return 7
        if self.output.exists():
            import shutil
            shutil.rmtree(self.output)
        self.output.mkdir(parents=True)
        # Deleted source modules must disappear just as in Gleam's clean export.
        for source in (self.package / 'src').glob('*.gleam'):
            (self.output / (source.stem + '.beam')).write_bytes(source.read_bytes())
        if self.mutate:
            (self.package / 'src/tui.gleam').write_text('changed while compiling')
        return 0

    def test_unchanged_export_restores_outputs_without_compiling(self):
        self.assertEqual(shipment.export('tui', False), 0)
        (self.output / 'tui.beam').write_text('damaged staged output')
        self.assertEqual(shipment.export('tui', False), 0)
        self.assertEqual(self.builds, 1)
        self.assertEqual((self.output / 'tui.beam').read_text(), 'pub fn main() { Nil }')

    def test_added_changed_and_removed_modules_rebuild(self):
        shipment.export('tui', False)
        source = self.package / 'src/extra.gleam'
        source.write_text('first')
        shipment.export('tui', False)
        self.assertEqual((self.output / 'extra.beam').read_text(), 'first')
        source.write_text('second')
        shipment.export('tui', False)
        self.assertEqual((self.output / 'extra.beam').read_text(), 'second')
        source.unlink()
        shipment.export('tui', False)
        self.assertFalse((self.output / 'extra.beam').exists())
        self.assertEqual(self.builds, 4)

    def test_corrupt_cache_rebuilds(self):
        shipment.export('tui', False)
        cached = self.cache / 'shipments/tui/output/tui.beam'
        cached.write_text('tainted')
        shipment.export('tui', False)
        self.assertEqual(self.builds, 2)
        self.assertNotEqual((self.output / 'tui.beam').read_text(), 'tainted')

    def test_toolchain_and_flags_invalidate(self):
        shipment.export('tui', False)
        with patch.object(shipment, 'toolchain', return_value='new-compiler'):
            shipment.export('tui', False)
        with patch.dict(os.environ, {'ERL_COMPILER_OPTIONS': '[no_debug_info]'}):
            shipment.export('tui', False)
        self.assertEqual(self.builds, 3)

    def test_failed_or_mixed_build_never_becomes_a_hit(self):
        shipment.export('tui', False)
        source = self.package / 'src/tui.gleam'
        source.write_text('bad source')
        self.fail = True
        self.assertEqual(shipment.export('tui', False), 7)
        self.fail = False
        self.mutate = True
        with self.assertRaisesRegex(ValueError, 'changed during compilation'):
            shipment.export('tui', False)
        self.mutate = False
        shipment.export('tui', False)
        self.assertEqual(self.builds, 4)

    def test_failed_export_does_not_publish_dependency_misses(self):
        def failed_compile(*args, **kwargs):
            context = json.loads((self.cache / 'tui-context.json').read_text())
            staged = Path(context['pending']) / 'new-dependency'
            staged.mkdir()
            (staged / 'metadata.json').write_text('partial dependency')
            return 9

        with patch.object(shipment.subprocess, 'call', side_effect=failed_compile):
            self.assertEqual(shipment.export('tui', False), 9)
        self.assertFalse((self.cache / 'dependencies/new-dependency').exists())
        context = json.loads((self.cache / 'tui-context.json').read_text())
        self.assertFalse(Path(context['pending']).exists())

    def test_fresh_bypasses_reuse(self):
        shipment.export('tui', False)
        shipment.export('tui', True)
        self.assertEqual(self.builds, 2)

    def test_local_transitive_dependency_and_symlink_contents_invalidate(self):
        leaf = self.root / 'packages/leaf'
        (leaf / 'src/build').mkdir(parents=True)
        source = leaf / 'src/build/resource'
        source.write_text('first')
        outside = self.root / 'shared'
        outside.write_text('shared input')
        (leaf / 'src/link').symlink_to(outside)
        (self.package / 'gleam.toml').write_text('name="tui"\n[dependencies]\nleaf={path="../leaf"}\n')
        (self.package / 'manifest.toml').write_text('packages=[{name="leaf",source="local",path="../leaf",requirements=[],build_tools=["gleam"]}]\n')
        shipment.export('tui', False)
        source.write_text('second')
        shipment.export('tui', False)
        outside.write_text('new shared input')
        shipment.export('tui', False)
        self.assertEqual(self.builds, 3)

    def test_native_builder_never_reuses_whole_export(self):
        native = self.package / 'build/packages/esqlite_loom'
        native.mkdir(parents=True)
        (native / 'rebar.config.script').write_text('native compiler hook')
        (self.package / 'gleam.toml').write_text('name="tui"\n[dependencies]\nesqlite_loom="0.9.1"\n')
        (self.package / 'manifest.toml').write_text('packages=[{name="esqlite_loom",version="0.9.1",source="hex",requirements=[],build_tools=["rebar3"]}]\n')
        shipment.export('tui', False)
        shipment.export('tui', False)
        self.assertEqual(self.builds, 2)
        plan = json.loads((self.cache / 'tui-context.json').read_text())
        self.assertEqual(plan['dependencies'], {})
        self.assertFalse((self.cache / 'shipments/tui').exists())

    def test_dependency_restores_priv_and_invalidates_transitive_inputs(self):
        cwd = self.package / 'build/prod/erlang/cowlib'
        cwd.mkdir(parents=True)
        context = self.cache / 'context.json'
        context.parent.mkdir(parents=True)
        plan = {'dependencies': {str(cwd): ['cowlib source', 'transitive source']},
                'toolchain': 'otp29', 'rebar3': '/real/rebar3',
                'pending': str(self.cache / 'dependencies')}
        context.write_text(json.dumps(plan))
        calls = []

        def compile_dependency(*args, **kwargs):
            calls.append(args)
            for name, filename in [('ebin', 'cowlib.app'), ('priv', 'resource')]:
                (cwd / name).mkdir(exist_ok=True)
                (cwd / name / filename).write_text('compiled')
            return 0

        original = Path.cwd()
        try:
            os.chdir(cwd)
            with patch.dict(os.environ, {'LOOM_SHIPMENT_CONTEXT': str(context)}), \
                 patch.object(shipment.subprocess, 'call', side_effect=compile_dependency):
                arguments = ['bare', 'compile', '--paths', '../*/ebin']
                self.assertEqual(shipment.rebar(arguments), 0)
                (cwd / 'priv/resource').unlink()
                self.assertEqual(shipment.rebar(arguments), 0)
                self.assertEqual((cwd / 'priv/resource').read_text(), 'compiled')
                self.assertEqual(len(calls), 1)
                plan['dependencies'][str(cwd)][1] = 'changed transitive source'
                context.write_text(json.dumps(plan))
                self.assertEqual(shipment.rebar(arguments), 0)
                self.assertEqual(len(calls), 2)
                self.assertEqual(shipment.rebar(['version']), 0)
                self.assertEqual(len(calls), 3)
        finally:
            os.chdir(original)


if __name__ == '__main__':
    unittest.main()
