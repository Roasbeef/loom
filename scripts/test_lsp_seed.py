"""Workspace preparation refuses failed or perpetually resolving packages."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LspSeedTest(unittest.TestCase):
    def run_seed(self, mode):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            shutil.copy(Path(__file__).with_name('lsp_seed.sh'), root / 'scripts')
            for name in ['one', 'two']:
                package = root / 'packages' / name
                package.mkdir(parents=True)
                (package / 'gleam.toml').write_text('name = "fixture"\n')
            binaries = root / 'bin'
            binaries.mkdir()
            gleam = binaries / 'gleam'
            gleam.write_text('''#!/usr/bin/env bash
set -eu
test "$*" = "deps download"
echo "$PWD" >> "$SEED_CALLS"
case "$SEED_MODE" in
  fail) echo "missing envoy" >&2; exit 7 ;;
  resolving) echo "Resolving versions" ;;
  warm) test -f ready || { touch ready; echo "Resolving versions"; } ;;
esac
''')
            gleam.chmod(0o755)
            calls = root / 'calls'
            environment = dict(os.environ, PATH=f'{binaries}:{os.environ["PATH"]}',
                               SEED_CALLS=str(calls), SEED_MODE=mode)
            result = subprocess.run(['bash', str(root / 'scripts/lsp_seed.sh')],
                                    env=environment, capture_output=True, text=True,
                                    timeout=10)
            return result, calls.read_text().splitlines()

    def test_every_package_is_stabilized(self):
        result, calls = self.run_seed('warm')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([Path(call).name for call in calls],
                         ['one', 'one', 'two', 'two'])

    def test_download_failure_stops_before_the_next_package(self):
        result, calls = self.run_seed('fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing envoy', result.stderr)
        self.assertEqual(len(calls), 1)

    def test_resolution_is_bounded(self):
        result, calls = self.run_seed('resolving')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('six passes', result.stderr)
        self.assertEqual(len(calls), 6)
