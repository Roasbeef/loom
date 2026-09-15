#!/usr/bin/env python3
"""Exercise the Gleam updater against local artifacts and an isolated prefix."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release_archive', ROOT / 'scripts/release-archive.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class UpdateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['gleam', 'build', '--warnings-as-errors'], cwd=ROOT / 'packages/tui', check=True,
                       stdout=subprocess.DEVNULL)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='loom-update-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.prefix = self.root / 'prefix with spaces'
        self.commit = 'a' * 40
        artifacts = []
        for component in ['server', 'client', 'slim']:
            source = self.root / component
            binaries = source / 'bin'
            binaries.mkdir(parents=True)
            for name in (['loomd', 'loom-exec'] if component == 'server' else ['loom', 'loom-profile']):
                (binaries / name).write_text('#!/bin/sh\nprintf "fixture\\n"\n')
                (binaries / name).chmod(0o755)
            if component == 'server':
                (source / 'share/codemode-seed').mkdir(parents=True)
                (source / 'share/codemode-seed/manifest.toml').write_text('# fixture\n')
            if component == 'slim':
                shipment = source / 'build/tui-erlang-shipment'
                shutil.copytree(self.root / 'client', shipment)
                (shipment / 'entrypoint.sh').write_text('# fixture\n')
            stem = 'loom-fixture-' + component
            archive = self.dist / (stem + '.tar.gz')
            release.archive(source, archive, stem, 123)
            artifacts.append({'component': component, 'name': archive.name, 'root': stem,
                              'size': archive.stat().st_size, 'sha256': release.digest(archive)})
        self.manifest = self.dist / 'manifest-linux-x86_64.json'
        self.manifest.write_text(json.dumps({'schema': 1, 'repository': 'Roasbeef/loom', 'tag': 'v0.3.0',
                                            'version': '0.3.0', 'commit': self.commit,
                                            'platform': 'linux-x86_64', 'artifacts': artifacts}))

    def update(self, *arguments, success=True, install_only=True):
        environment = os.environ.copy()
        environment['LOOM_BUILD_VERSION'] = '0.2.0'
        environment['LOOM_BUILD_PLATFORM'] = 'linux-x86_64'
        action = ['--install-only'] if install_only else []
        result = subprocess.run(['gleam', 'run', '-m', 'tui', '--', 'update', '--from', str(self.dist),
                                 '--prefix', str(self.prefix), *action, *arguments],
                                cwd=ROOT / 'packages/tui', env=environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def test_check_is_noninteractive_and_does_not_create_installation_or_state(self):
        state = self.root / 'private-state'
        self.update('--check', '--state-dir', str(state), install_only=False)
        self.assertFalse(self.prefix.exists())
        self.assertFalse(state.exists())

    def test_complete_update_retains_previous_tree(self):
        self.update()
        first = (self.prefix / 'lib/loom/server').resolve()
        self.update('--commit', self.commit)
        second = (self.prefix / 'lib/loom/server').resolve()
        self.assertNotEqual(first, second)
        self.assertTrue((first / 'bin/loomd').is_file())
        self.assertTrue((second / 'share/codemode-seed/manifest.toml').is_file())
        self.assertEqual(subprocess.check_output([self.prefix / 'bin/loom'], text=True), 'fixture\n')
        wrapper = (self.prefix / 'bin/loom').read_text()
        self.assertIn('LOOM_INSTALL_PREFIX=', wrapper)

    def test_slim_shape_installs_its_complete_shipment(self):
        self.update('--client', 'slim')
        self.assertTrue((self.prefix / 'lib/loom/tui/bin/loom-profile').is_file())
        self.assertEqual(subprocess.check_output([self.prefix / 'bin/loom'], text=True), 'fixture\n')

    def test_wrong_commit_and_digest_do_not_publish(self):
        self.update('--commit', 'b' * 40, success=False)
        self.assertFalse((self.prefix / 'bin/loom').exists())
        artifact = self.dist / 'loom-fixture-server.tar.gz'
        artifact.write_bytes(artifact.read_bytes() + b'changed')
        self.update(success=False)
        self.assertFalse((self.prefix / 'bin/loom').exists())

    def test_local_signature_verifies_and_tampering_keeps_installed_tree(self):
        signing_home = self.root / 'signing'
        signing_home.mkdir(mode=0o700)
        command = ['gpg', '--homedir', str(signing_home), '--batch', '--pinentry-mode', 'loopback', '--passphrase', '']
        subprocess.run([*command, '--quick-generate-key', 'Loom test <fixture@example.invalid>', 'ed25519', 'sign', '0'],
                       check=True, stdout=subprocess.DEVNULL)
        self.addCleanup(lambda: subprocess.run(['gpgconf', '--homedir', str(signing_home), '--kill', 'gpg-agent'],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        keyring = self.root / 'trusted.gpg'
        with keyring.open('wb') as output:
            subprocess.run([*command, '--export'], check=True, stdout=output, stderr=subprocess.DEVNULL)
        subprocess.run([*command, '--armor', '--detach-sign', str(self.manifest)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.update('--require-signature', '--keyring', str(keyring))
        installed = (self.prefix / 'lib/loom/server').resolve()
        self.manifest.write_text(self.manifest.read_text().replace('0.3.0', '0.3.1'))
        self.update('--keyring', str(keyring), success=False)
        self.assertEqual((self.prefix / 'lib/loom/server').resolve(), installed)

    def test_signature_policy_refuses_missing_or_invalid(self):
        self.update('--require-signature', success=False)
        self.assertFalse((self.prefix / 'bin/loom').exists())
        Path(str(self.manifest) + '.asc').write_text('not a signature\n')
        self.update(success=False)
        self.assertFalse((self.prefix / 'bin/loom').exists())


if __name__ == '__main__':
    unittest.main()
