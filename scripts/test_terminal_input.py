"""Check the terminal boundary without starting the TUI or a daemon."""

import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


class TerminalInputTest(unittest.TestCase):
    def test_interactive_mode_requires_both_terminal_streams(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="loom-terminal-") as build:
            subprocess.run(
                ["erlc", "-o", build, str(root / "packages/tui/src/tui_ffi.erl")],
                check=True, capture_output=True, timeout=20,
            )
            master, slave = pty.openpty()
            try:
                for input_terminal, output_terminal in (
                    (False, False), (True, False), (False, True), (True, True)
                ):
                    with self.subTest(input=input_terminal, output=output_terminal):
                        result = subprocess.run(
                            ["erl", "+S", "2:2", "-noshell", "-pa", build,
                             "-eval", 'io:format(standard_error, "~p", '
                             '[tui_ffi:require_terminal()]), halt().'],
                            stdin=slave if input_terminal else subprocess.DEVNULL,
                            stdout=slave if output_terminal else subprocess.DEVNULL,
                            stderr=subprocess.PIPE, timeout=10,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        if input_terminal and output_terminal:
                            self.assertEqual(result.stderr, b"{ok,nil}")
                        else:
                            self.assertIn(b"{error,", result.stderr)
                            self.assertIn(b"requires terminal input and output", result.stderr)
            finally:
                os.close(slave)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
