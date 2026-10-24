"""Exercise the Dagger pilot's source boundary and GraphQL failure handling."""

import base64
import json
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dagger_pilot


class PilotFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "pilot test")
        self.git("config", "user.email", "pilot@example.invalid")
        for script in dagger_pilot.SCRIPTS:
            self.write(script, "fixture\n")
        self.write("packages/core/gleam.toml", self.config())
        for folder in ("src", "test", "dev", "priv"):
            self.write(f"packages/core/{folder}/input.txt", folder + "\n")
        self.write("packages/core/manifest.toml", "fixture = true\n")
        self.write("packages/core/build/generated.txt", "generated\n")
        self.write("packages/core/unrelated.txt", "unrelated\n")
        self.write("packages/machine/gleam.toml", self.config())
        self.write("packages/machine/src/input.txt", "machine\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "fixture")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True,
                              capture_output=True, text=True).stdout

    def write(self, relative, contents):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    @staticmethod
    def config(dependencies="", dev_dependencies=""):
        return ("name = \"fixture\"\n"
                "version = \"1.0.0\"\n"
                "target = \"erlang\"\n"
                "\n[dependencies]\n" + dependencies +
                "\n[dev_dependencies]\n" + dev_dependencies)


class InputSelectionTest(PilotFixture):
    def test_dependency_closure_follows_native_path_dependencies(self):
        self.write("packages/core/gleam.toml", self.config('machine = { path = "../machine" }'))
        self.write("packages/machine/gleam.toml", self.config('core = { path = "../core" }'))
        self.assertEqual(dagger_pilot.closure(self.root, "core"), {"core", "machine"})

    def test_native_development_dependency_is_included(self):
        self.write("packages/core/gleam.toml", self.config(
            dev_dependencies='machine = { path = "../machine" }'))
        self.assertEqual(dagger_pilot.closure(self.root, "core"), {"core", "machine"})

    def test_dependency_outside_the_five_package_pilot_is_refused(self):
        self.write("packages/core/gleam.toml", self.config('other = { path = "../other" }'))
        with self.assertRaisesRegex(ValueError, "outside pilot"):
            dagger_pilot.closure(self.root, "core")

    def test_source_fixture_and_native_config_are_selected_but_build_is_not(self):
        selected = dagger_pilot.input_files(self.root, {"core"})
        for folder in ("src", "test", "dev", "priv"):
            self.assertIn(f"packages/core/{folder}/input.txt", selected)
        self.assertIn("packages/core/gleam.toml", selected)
        self.assertIn("packages/core/manifest.toml", selected)
        self.assertNotIn("packages/core/build/generated.txt", selected)
        self.assertNotIn("packages/core/unrelated.txt", selected)
        self.assertFalse(any(name.startswith("packages/machine/") for name in selected))

    def test_untracked_source_fails_closed(self):
        self.write("packages/core/src/new_test.gleam", "pub fn new() { Nil }\n")
        with self.assertRaisesRegex(ValueError, "stage new pilot inputs"):
            dagger_pilot.input_files(self.root, {"core"})

    def test_ignored_native_source_still_fails_closed(self):
        self.write(".gitignore", "packages/core/src/ignored.gleam\n")
        self.write("packages/core/src/ignored.gleam", "pub fn ignored() { Nil }\n")
        with self.assertRaisesRegex(ValueError, "stage new pilot inputs"):
            dagger_pilot.input_files(self.root, {"core"})

    def test_snapshot_uses_working_tree_edits_and_omits_tracked_deletions(self):
        edited = "packages/core/src/input.txt"
        deleted = "packages/core/test/input.txt"
        self.write(edited, "edited bytes\n")
        (self.root / deleted).unlink()
        selected = dagger_pilot.input_files(self.root, {"core"})
        destination = self.root / "snapshot"
        dagger_pilot.snapshot(self.root, destination, selected)
        self.assertEqual((destination / edited).read_text(), "edited bytes\n")
        self.assertFalse((destination / deleted).exists())

    def test_snapshot_rejects_symlink_leaf(self):
        outside = self.root.parent / (self.root.name + "-outside")
        outside.write_text("outside\n")
        self.addCleanup(outside.unlink)
        leaf = self.root / "toolchain/Dockerfile"
        leaf.parent.mkdir()
        leaf.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink input is not supported"):
            dagger_pilot.snapshot(self.root, self.root / "snapshot", ["toolchain/Dockerfile"])

    def test_snapshot_rejects_symlink_ancestor(self):
        outside = self.root.parent / (self.root.name + "-outside-dir")
        outside.mkdir()
        self.addCleanup(lambda: outside.exists() and shutil.rmtree(outside))
        (outside / "Dockerfile").write_text("outside\n")
        (self.root / "toolchain").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink input is not supported"):
            dagger_pilot.snapshot(self.root, self.root / "snapshot", ["toolchain/Dockerfile"])

    def test_snapshot_accepts_root_symlink_and_checks_only_input_components(self):
        alias = self.root.parent / (self.root.name + "-alias")
        alias.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(alias.unlink)
        destination = alias / "snapshot"
        dagger_pilot.snapshot(alias, destination, ["packages/core/src/input.txt"])
        self.assertEqual((destination / "packages/core/src/input.txt").read_text(), "src\n")


class QueryTest(unittest.TestCase):
    ENV = {"DAGGER_SESSION_PORT": "12345", "DAGGER_SESSION_TOKEN": "secret"}

    def test_gate_query_adds_fresh_cache_buster_only_when_requested(self):
        ordinary = dagger_pilot.gate_query("toolchain-id", "source-id", "core")
        self.assertNotIn("LOOM_DAGGER_FRESH", ordinary)
        self.assertIn('"scripts/check.sh", "core"', ordinary)

        fresh = dagger_pilot.gate_query("toolchain-id", "source-id", "core", "nonce-123")
        self.assertIn("LOOM_DAGGER_FRESH", fresh)
        self.assertIn("nonce-123", fresh)

    @mock.patch.object(dagger_pilot.urllib.request, "build_opener")
    def test_query_returns_json_data_and_uses_session_auth(self, build_opener):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'{"data":{"ok":true}}'
        build_opener.return_value.open.return_value = response
        data, trace = dagger_pilot.query("dagger", "ignored-engine", "{ ok }", self.ENV)
        self.assertEqual(data, {"ok": True})
        self.assertEqual(trace, "")
        opener = build_opener.return_value
        opener.open.assert_called_once()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "http://127.0.0.1:12345/query")
        self.assertEqual(request.get_header("Authorization"),
                         "Basic " + base64.b64encode(b"secret:").decode())
        self.assertEqual(json.loads(request.data), {"query": "{ ok }"})
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 1800)

    @mock.patch.object(dagger_pilot.urllib.request, "build_opener")
    def test_query_graphql_errors_fail_even_when_http_succeeds(self, build_opener):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(
            {"data": None, "errors": [{"message": "bad query"}]}).encode()
        build_opener.return_value.open.return_value = response
        with self.assertRaisesRegex(RuntimeError, "bad query"):
            dagger_pilot.query("dagger", "engine", "{ invalid }", self.ENV)

    @mock.patch.object(dagger_pilot.urllib.request, "build_opener")
    def test_http_errors_propagate_as_failures(self, build_opener):
        build_opener.return_value.open.side_effect = urllib.error.HTTPError(
            "http://127.0.0.1:12345/query", 401, "unauthorized", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            dagger_pilot.query("dagger", "engine", "{ ok }", self.ENV)


if __name__ == "__main__":
    unittest.main()
