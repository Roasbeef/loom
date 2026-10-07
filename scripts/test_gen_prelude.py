"""Capability identities remain nameable on each module's own host seam."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "gen_prelude", Path(__file__).with_name("gen-prelude.py")
)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class AliasRenderingTest(unittest.TestCase):
    def setUp(self):
        self.identity = {
            "kind": "named", "module": "core/ids", "name": "EntryId",
            "parameters": [],
        }
        self.modules = {
            module: {"type-aliases": {"EntryId": {"alias": self.identity}}}
            for module in ("cap/peer", "cap/strand")
        }

    def test_each_capability_uses_its_own_identity_alias(self):
        aliases = renderer.build_alias_map(self.modules)
        for module in self.modules:
            with self.subTest(module=module):
                self.assertEqual(
                    renderer.render_type(self.identity, module, aliases),
                    "EntryId",
                )

    def test_alias_preference_does_not_depend_on_export_order(self):
        modules = dict(reversed(list(self.modules.items())))
        aliases = renderer.build_alias_map(modules)
        for module in modules:
            self.assertEqual(
                renderer.render_type(self.identity, module, aliases), "EntryId"
            )

    def test_other_modules_keep_the_existing_qualified_alias(self):
        aliases = renderer.build_alias_map(self.modules)
        self.assertEqual(
            renderer.render_type(self.identity, "cap/workflow", aliases),
            "peer.EntryId",
        )


class ExampleRenderingTest(unittest.TestCase):
    def test_runnable_example_keeps_indentation(self):
        docs = "Contract.\n\n## Examples\n\n```gleam\ncase value {\n  Ok(x) -> x\n}\n```"
        rendered = "\n".join(renderer.example_block(docs, ""))
        self.assertIn("///   Ok(x) -> x", rendered)
        self.assertNotIn("Contract.", rendered)

    def test_examples_extend_only_the_on_demand_surface(self):
        body = {"documentation": "A probe.", "functions": {"probe": {
            "documentation": "Contract.\n\n## Examples\n\n```gleam\nprobe.probe()\n```",
            "parameters": [], "return": {"kind": "named", "module": "gleam", "name": "Nil", "parameters": []},
        }}}
        full, typed = renderer.render_module("cap/probe", body, {}, {"cap/probe": body})
        self.assertIn("/// probe.probe()", full)
        self.assertNotIn("probe.probe()", typed)
        self.assertTrue(full.startswith(typed))

    def test_missing_example_adds_nothing(self):
        self.assertEqual(renderer.example_block("Contract.", ""), [])


if __name__ == "__main__":
    unittest.main()
