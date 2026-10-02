"""Exercise Observer discovery and credential handling without a desktop GUI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ObserverLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="loom observer ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "operator home"
        self.home.mkdir()
        self.state = self.home / ".loom"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.records = self.root / "erl.jsonl"
        self.processes = self.root / "processes"
        self.processes.write_text("")
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        OBSERVER_RECORDS=str(self.records),
                        OBSERVER_PROCESSES=str(self.processes))
        self.executable("ps", "#!/bin/sh\ncat \"$OBSERVER_PROCESSES\"\n")
        self.executable("erl", """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['OBSERVER_RECORDS'], 'a') as output:
    output.write(json.dumps({'args': sys.argv[1:], 'home': os.environ['HOME'],
                            'crash': os.environ.get('ERL_CRASH_DUMP')}) + '\\n')
if '-eval' in sys.argv and os.environ.get('OBSERVER_NO_GUI'):
    sys.exit(2)
""")

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o700)
        return path

    def profile(self, pid, role="daemon", state=None):
        state = state or self.state
        cookie = state / "tokens" / f"loom-{role}-profile.TEST{pid}"
        cookie.mkdir(parents=True, mode=0o700)
        (cookie / ".erlang.cookie").write_text("PRIVATE_TEST_COOKIE\n")
        (cookie / ".erlang.cookie").chmod(0o600)
        node = f"loom_{role}_profile_{pid}_{'a' * 32}@127.0.0.1"
        with self.processes.open("a") as output:
            output.write(f"{pid} /runtime/beam -name {node} -home {cookie} -noshell\n")
        return node, cookie

    def run_observer(self, *args):
        return subprocess.run(["/bin/bash", str(ROOT / "scripts/observer.sh"), *args],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.records.read_text().splitlines()]

    def test_default_daemon_preserves_spaces_and_private_cookie(self):
        node, cookie = self.profile(123)
        self.profile(456, "client")
        stale = self.state / "tokens/loom-daemon-profile.STALE"
        stale.mkdir()
        (stale / ".erlang.cookie").write_text("STALE\n")
        result = self.run_observer()
        self.assertEqual(result.returncode, 0, result.stderr)
        preflight, launch = self.calls()
        self.assertNotIn("-name", preflight["args"])
        self.assertEqual(launch["home"], str(cookie))
        self.assertEqual(launch["crash"], "/dev/null")
        self.assertIn("-hidden", launch["args"])
        self.assertIn("{127,0,0,1}", launch["args"])
        start = launch["args"].index("-run")
        self.assertEqual(launch["args"][start:],
                         ["-run", "observer", "start_and_wait", node, "-s", "init", "stop"])
        env_start = launch["args"].index("-env")
        self.assertEqual(launch["args"][env_start + 1:env_start + 3], ["HOME", str(self.home)])
        self.assertNotIn("PRIVATE_TEST_COOKIE", json.dumps(self.calls()) + result.stderr)
        self.assertNotIn("-setcookie", launch["args"])

    def test_explicit_client_and_state(self):
        alternate = self.root / "alternate state"
        node, cookie = self.profile(456, "client", alternate)
        result = self.run_observer("--pid", "456", "--state-dir", str(alternate),
                                   "--erl", str(self.bin / "erl"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(node, self.calls()[1]["args"])
        self.assertEqual(self.calls()[1]["home"], str(cookie))

    def test_ambiguous_daemons_require_pid(self):
        self.profile(123)
        self.profile(789)
        result = self.run_observer()
        self.assertEqual(result.returncode, 2)
        self.assertIn("--pid", result.stderr)
        self.assertFalse(self.records.exists())

    def test_stale_pid_identity_and_unprofiled_process_are_rejected(self):
        self.profile(123)
        self.processes.write_text(self.processes.read_text().replace("123 /runtime", "789 /runtime"))
        result = self.run_observer("--pid", "789")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--profile", result.stderr)
        self.assertFalse(self.records.exists())
        self.processes.write_text("789 /runtime/loomd -run loom_satellite main\n")
        self.assertEqual(self.run_observer("--pid", "789").returncode, 2)

    def test_missing_cookie_is_rejected(self):
        _, cookie = self.profile(123)
        (cookie / ".erlang.cookie").unlink()
        self.assertEqual(self.run_observer().returncode, 2)
        self.assertFalse(self.records.exists())

    def test_runtime_without_gui_has_actionable_error(self):
        self.profile(123)
        self.env["OBSERVER_NO_GUI"] = "1"
        result = self.run_observer()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Observer and wx", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_help_and_invalid_options_do_not_start_runtime(self):
        self.assertEqual(self.run_observer("--help").returncode, 0)
        for args in [("--pid",), ("--pid", "0"), ("--pid", "1;halt()"),
                     ("--wat",), ("--erl", "missing-erl")]:
            with self.subTest(args=args):
                self.assertEqual(self.run_observer(*args).returncode, 2)
        self.assertFalse(self.records.exists())


if __name__ == "__main__":
    unittest.main()
