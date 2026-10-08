"""Execute the release workflow's shell decisions without publishing assets."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SHA = 'a' * 40


def workflow_step(name):
    lines = (ROOT / '.github/workflows/release.yml').read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line == '      - name: ' + name)
    body = next(i for i in range(start, len(lines)) if lines[i] == '        run: |') + 1
    end = body
    while end < len(lines) and (not lines[end] or lines[end].startswith('          ')):
        end += 1
    return '\n'.join(line[10:] for line in lines[body:end]) + '\n'


class PublicationTest(unittest.TestCase):
    def run_step(self, name, nightly=True, **extra):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            gh = root / 'gh'
            gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ['CALLS']).open('a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'api':
    if os.environ.get('API_FAILURE'): sys.exit(1)
    if any('releases?' in arg for arg in sys.argv): print(os.environ.get('TAGS', ''))
    else: print(os.environ['ACTUAL'])
''')
            git = root / 'git'
            git.write_text('''#!/bin/sh
case "$1" in
  merge-base) exit "${OFF_MAIN:-0}" ;;
  show-ref) exit "${TAG_ABSENT:-1}" ;;
  rev-parse) case "$2" in *^{commit}) printf '%s\\n' "${TAG_ACTUAL:-$ACTUAL}" ;; *) printf '%s\\n' "$ACTUAL" ;; esac ;;
esac
''')
            gh.chmod(0o755)
            git.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       CALLS=str(root / 'calls'), GITHUB_OUTPUT=str(root / 'output'),
                       GH_REPO='Roasbeef/loom', SOURCE_COMMIT=SHA, ACTUAL=SHA,
                       RELEASE_TAG='commit-' + SHA if nightly else 'v0.2.0',
                       NIGHTLY_COMMIT=SHA if nightly else '')
            env.update(extra)
            # The identity step selects nightlies from SOURCE_COMMIT; stable
            # publication is tested separately without executing tag tooling.
            result = subprocess.run(['bash', '-c', workflow_step(name)], cwd=root,
                                    env=env, text=True, capture_output=True)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            outputs = (root / 'output').read_text() if (root / 'output').exists() else ''
            return result, calls, outputs

    def test_nightly_is_published_without_advancing_stable(self):
        result, calls, _ = self.run_step('Publish the immutable release')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"--target", "' + SHA + '"', calls)
        self.assertIn('"--prerelease"', calls)
        self.assertIn('"--latest=false"', calls)
        self.assertNotIn('"--draft"', calls)

    def test_stable_still_requires_tag_binding_and_creates_draft(self):
        result, calls, _ = self.run_step('Publish the immutable release', nightly=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"--draft"', calls)
        self.assertIn('"--verify-tag"', calls)
        result, calls, _ = self.run_step('Publish the immutable release', nightly=False, ACTUAL='b' * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('"release", "create"', calls)

    def test_main_identity_existing_release_and_failures(self):
        name = 'Bind release to the checked-out source'
        result, _, outputs = self.run_step(name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('tag=commit-' + SHA, outputs)
        result, _, outputs = self.run_step(name, TAGS='commit-' + SHA)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('exists=true', outputs)
        for failure in ({'ACTUAL': 'b' * 40}, {'OFF_MAIN': '1'}, {'API_FAILURE': '1'},
                        {'SOURCE_COMMIT': 'main'}, {'TAG_ABSENT': '0', 'TAG_ACTUAL': 'b' * 40}):
            with self.subTest(failure=failure):
                result, _, outputs = self.run_step(name, **failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('tag=', outputs)


if __name__ == '__main__':
    unittest.main()
