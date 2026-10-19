"""The renderer release must retain every locked dependency's license text."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "packages/web_mermaid/bundle/licenses.py"
spec = importlib.util.spec_from_file_location("mermaid_licenses", MODULE)
licenses = importlib.util.module_from_spec(spec)
spec.loader.exec_module(licenses)


class MermaidLicenseTest(unittest.TestCase):
    def test_locked_notices_are_retained_and_deterministic(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "package-lock.json").write_text(json.dumps({
                "packages": {"": {}, "node_modules/a": {}, "node_modules/b": {}}
            }))
            for name in ["b", "a"]:
                package = root / "node_modules" / name
                package.mkdir(parents=True)
                (package / "package.json").write_text(json.dumps({
                    "name": name, "version": "1.2.3", "license": "MIT"
                }))
                (package / "LICENSE").write_text(f"Copyright and permission for {name}.\n")
                (package / "NOTICE.txt").write_text(f"Additional notice for {name}.\n")
            text = licenses.notices(root)
            self.assertEqual(text, licenses.notices(root))
            self.assertLess(text.index("a 1.2.3"), text.index("b 1.2.3"))
            for name in ["a", "b"]:
                self.assertIn(f"Copyright and permission for {name}.", text)
                self.assertIn(f"Additional notice for {name}.", text)

    def test_missing_notice_is_a_generation_failure(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "package-lock.json").write_text(json.dumps({
                "packages": {"node_modules/a": {}}
            }))
            package = root / "node_modules/a"
            package.mkdir(parents=True)
            (package / "package.json").write_text('{"name":"a","version":"1","license":"MIT"}')
            with self.assertRaisesRegex(ValueError, "no shipped license notice"):
                licenses.notices(root)

    def test_lock_paths_cannot_leave_node_modules(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "package-lock.json").write_text(json.dumps({
                "packages": {"node_modules/../../elsewhere": {}}
            }))
            with self.assertRaisesRegex(ValueError, "outside node_modules"):
                licenses.notices(root)
