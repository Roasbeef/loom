"""Check update orchestration without replacing the operator's installation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MAKEFILE = Path(__file__).resolve().parent.parent / "Makefile"


class MakeUpdateTest(unittest.TestCase):
    def run_update(self, failure="", extra=()):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkout = root / "checkout with spaces"
            client = checkout / "build/release/loom-client/bin/loom"
            client.parent.mkdir(parents=True)
            for package in ("client", "tui"):
                manifest = checkout / "packages" / package / "gleam.toml"
                manifest.parent.mkdir(parents=True)
                manifest.write_text('version = "0.2.0"\n')
            calls = root / "calls.jsonl"
            stub = root / "make-stub"
            script = '''#!/usr/bin/env python3
import json, os, sys
kind = "update" if sys.argv[0].endswith("/loom") else "build"
with open(os.environ["UPDATE_TEST_CALLS"], "a") as output:
    output.write(json.dumps([kind, *sys.argv[1:]]) + "\\n")
failed = os.environ["UPDATE_TEST_FAILURE"]
raise SystemExit(17 if failed and (failed == kind or failed in sys.argv[1:]) else 0)
'''
            for executable in (stub, client):
                executable.write_text(script)
                executable.chmod(0o755)
            environment = dict(os.environ, HOME=str(root / "home"),
                               UPDATE_TEST_CALLS=str(calls), UPDATE_TEST_FAILURE=failure)
            for name in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "PREFIX",
                         "INSTALL_CLIENT", "UPDATE_ARGS"):
                environment.pop(name, None)
            result = subprocess.run(
                ["make", "-C", str(checkout), "-f", str(MAKEFILE), "-j4", "update",
                 f"MAKE={stub}", *extra], env=environment,
                capture_output=True, text=True, timeout=15,
            )
            events = [json.loads(line) for line in calls.read_text().splitlines()]
            return result, events, checkout, root

    def test_default_builds_before_using_fresh_updater(self):
        result, events, checkout, root = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [
            ["build", "codemode-seed"], ["build", "-j1", "dist"],
            ["update", "update", "--from", str(checkout.resolve() / "dist"),
             "--prefix", str(root / "home/.local"), "--client", "bundled"],
        ])

    def test_failed_stage_never_advances(self):
        for stage, count in (("codemode-seed", 1), ("dist", 2), ("update", 3)):
            with self.subTest(stage=stage):
                result, events, _, _ = self.run_update(failure=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(events), count)

    def test_explicit_destination_and_state_preserve_argument_boundaries(self):
        result, events, _, _ = self.run_update(extra=(
            "PREFIX=/tmp/prefix with spaces", "INSTALL_CLIENT=slim",
            "STATE_DIR=/wrong-development-state",
            "UPDATE_ARGS=--state-dir '/tmp/real state' --config '/tmp/my config'",
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[-1][4:], [
            "--prefix", "/tmp/prefix with spaces", "--client", "slim",
            "--state-dir", "/tmp/real state", "--config", "/tmp/my config",
        ])


if __name__ == "__main__":
    unittest.main()
