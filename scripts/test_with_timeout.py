"""Fault tests for the outer test deadline; every subprocess is itself bounded."""

from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import with_timeout


WRAPPER = Path(__file__).with_name("with_timeout.py")


class DeadlineTest(unittest.TestCase):
    def command(self, seconds, source):
        return [sys.executable, str(WRAPPER), str(seconds), "--",
                sys.executable, "-c", source]

    def invoke(self, seconds, source):
        return subprocess.run(self.command(seconds, source),
                              capture_output=True, text=True, timeout=5)

    def test_success_and_failure_keep_their_status(self):
        for status in (0, 7):
            with self.subTest(status=status):
                result = self.invoke(2, f"raise SystemExit({status})")
                self.assertEqual(result.returncode, status)
                self.assertIn(f"exit={status}", result.stdout)

    def test_deadlock_exits_with_timeout_status(self):
        started = time.monotonic()
        result = self.invoke(0.2, "import time; time.sleep(60)")
        self.assertEqual(result.returncode, 124)
        self.assertIn("TIMEOUT", result.stderr)
        self.assertLess(time.monotonic() - started, 3)

    def test_deadline_reaches_a_descendant_not_just_the_launcher(self):
        with tempfile.TemporaryDirectory(prefix="loom-deadline-test-") as root:
            marker = Path(root) / "escaped"
            descendant = ("import time; from pathlib import Path; time.sleep(1); "
                          f"Path({str(marker)!r}).touch()")
            source = ("import subprocess, sys, time; "
                      f"subprocess.Popen([sys.executable, '-c', {descendant!r}]); "
                      "time.sleep(60)")
            result = self.invoke(0.3, source)
            self.assertEqual(result.returncode, 124)
            time.sleep(1.2)
            self.assertFalse(marker.exists(), "descendant outlived the test deadline")

    def test_invalid_deadlines_do_not_run_the_command(self):
        for seconds in ("0", "-1", "nan", "inf"):
            with self.subTest(seconds=seconds):
                result = self.invoke(seconds, "print('unexpected execution')")
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("unexpected execution", result.stdout)

    def test_interrupt_terminates_the_test_group(self):
        child = subprocess.Popen(self.command(60, "import time; time.sleep(60)"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True)
        try:
            # Give the wrapper time to install its handler. The independent
            # communicate deadline bounds a failed startup or signal path.
            time.sleep(0.2)
            child.send_signal(signal.SIGTERM)
            child.communicate(timeout=3)
            self.assertEqual(child.returncode, 128 + signal.SIGTERM)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=2)

    def test_macos_assertion_is_scoped_to_the_command(self):
        with mock.patch.object(sys, "platform", "darwin"):
            self.assertEqual(with_timeout.command_for_host(["gleam", "test"]),
                             ["/usr/bin/caffeinate", "-i", "gleam", "test"])
        with mock.patch.object(sys, "platform", "linux"):
            self.assertEqual(with_timeout.command_for_host(["gleam", "test"]),
                             ["gleam", "test"])


if __name__ == "__main__":
    unittest.main()
