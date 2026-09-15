#!/usr/bin/env python3
"""Exercise installed update/restart against complete, locally built releases."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release_archive', ROOT / 'scripts/release-archive.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def ready(path, process=None, previous=None):
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError('fixture daemon exited before readiness')
        try:
            record = json.loads(path.read_text())
            if record['status'] == 'ready' and record.get('epoch') != previous:
                return record
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    raise RuntimeError('fixture daemon never published readiness')


def stop_fixture(record_path, state):
    if not record_path.exists():
        return
    record = json.loads(record_path.read_text())
    pid = record['pid']
    command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], text=True,
                             stdout=subprocess.PIPE).stdout
    # Only the daemon launched with this test's unique private state is ours.
    if str(state) in command:
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            observed = subprocess.run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'command='],
                                      text=True, stdout=subprocess.PIPE).stdout.strip()
            if not observed or observed.startswith('Z') or str(state) not in observed:
                return
            time.sleep(0.05)
        raise RuntimeError('fixture daemon has not retired; retain its release trees')


def main():
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    temporary = tempfile.mkdtemp(prefix='update-release-smoke-', dir=build)
    root = Path(temporary).resolve()
    dist = root / 'dist'
    dist.mkdir()
    prefix = root / 'prefix with spaces'
    state = root / 'state'
    state.mkdir(mode=0o700)
    configuration = state / 'loom.toml'
    configuration.write_text((ROOT / 'scripts/release-smoke.toml').read_text().replace('"on-boot"', '"off"'))
    platform = subprocess.check_output([ROOT / 'scripts/platform.sh'], text=True).strip()
    launcher = (build / 'release/loom/bin/loomd').read_text()
    commit = re.search(r'^LOOM_BUILD_COMMIT="([0-9a-f]{40})"$', launcher, re.M).group(1)
    version = re.search(r'^LOOM_BUILD_VERSION="([^"]+)"$', launcher, re.M).group(1)
    slim = root / 'slim'
    (slim / 'bin').mkdir(parents=True)
    (slim / 'build').mkdir()
    shutil.copy2(ROOT / 'bin/loom', slim / 'bin/loom')
    shutil.copytree(build / 'tui-erlang-shipment', slim / 'build/tui-erlang-shipment', symlinks=True)
    artifacts = []
    for component, source in [('server', build / 'release/loom'),
                              ('client', build / 'release/loom-client'), ('slim', slim)]:
        stem = 'loom-smoke-' + component
        path = dist / (stem + '.tar.gz')
        release.archive(source, path, stem, 123)
        artifacts.append({'component': component, 'name': path.name, 'root': stem,
                          'size': path.stat().st_size, 'sha256': release.digest(path)})
    (dist / f'manifest-{platform}.json').write_text(json.dumps({
        'schema': 1, 'repository': 'Roasbeef/loom', 'tag': 'smoke-fixture',
        'version': version, 'commit': commit, 'platform': platform, 'artifacts': artifacts}))
    environment = os.environ.copy()
    environment.update(PREFIX=str(prefix), LOOM_CLIENT='bundled', LOOM_STATE_DIR=str(state))
    subprocess.run(['bash', ROOT / 'scripts/install.sh'], env=environment, check=True)
    old_tree = (prefix / 'lib/loom/server').resolve()
    record_path = state / 'daemon.endpoint'
    daemon_log = root / 'original-daemon.log'
    with daemon_log.open('w') as log:
        original = subprocess.Popen([prefix / 'bin/loomd', '--state-dir', state,
                                     '--config', configuration], stdout=log, stderr=subprocess.STDOUT)
        try:
            first = ready(record_path, original)
            # The original server is our child. Reap it concurrently so a
            # successful shutdown does not remain a zombie while the updater
            # correctly waits for the original native lifetime to disappear.
            reaper = threading.Thread(target=original.wait, daemon=True)
            reaper.start()
            result = subprocess.run([prefix / 'bin/loom', 'update', '--from', dist,
                                     '--state-dir', state, '--config', configuration],
                                    env=environment, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=180)
            print(result.stdout, end='')
            if result.returncode:
                raise RuntimeError(f'installed updater exited {result.returncode}')
            second = ready(record_path, previous=first['epoch'])
            original.wait(timeout=10)
            assert second['pid'] != first['pid']
            assert second['build_commit'] == commit
            assert (prefix / 'lib/loom/server').resolve() != old_tree
            assert (old_tree / 'bin/loomd').is_file()
            # The newly installed client must itself contain the updater.
            help_text = subprocess.check_output([prefix / 'bin/loom', 'update', '--help'], text=True)
            assert 'Usage: loom update' in help_text
            # Switch to the portable client through the same installed command.
            result = subprocess.run([prefix / 'bin/loom', 'update', '--from', dist,
                                     '--client', 'slim', '--state-dir', state,
                                     '--config', configuration], env=environment, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
            print(result.stdout, end='')
            if result.returncode:
                raise RuntimeError(f'slim update exited {result.returncode}')
            third = ready(record_path, previous=second['epoch'])
            assert third['pid'] != second['pid']
            assert third['build_commit'] == commit
            help_text = subprocess.check_output([prefix / 'bin/loom', 'update', '--help'], text=True)
            assert 'Usage: loom update' in help_text

            # A portable launcher must ask its execution host, not remember the
            # builder. Stub only uname and erl to observe the exported choice.
            fake = root / 'platform-probe'
            fake.mkdir()
            (fake / 'uname').write_text('#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo aarch64;; esac\n')
            (fake / 'erl').write_text('#!/bin/sh\nprintf "%s\\n" "$LOOM_BUILD_PLATFORM"\n')
            (fake / 'uname').chmod(0o755)
            (fake / 'erl').chmod(0o755)
            probe_environment = environment | {'PATH': str(fake) + ':' + environment['PATH']}
            observed = subprocess.check_output([prefix / 'bin/loom', '--help'],
                                                env=probe_environment, text=True).strip()
            assert observed == 'linux-arm64', observed
            print(f'installed bundled/slim update passed: {platform}, commit {commit}, two old daemons retired, new epochs accepted')
        finally:
            stop_fixture(record_path, state)
            if original.poll() is None:
                original.terminate()
                original.wait(timeout=15)
            if daemon_log.exists():
                print(daemon_log.read_text()[-2000:])
    shutil.rmtree(root)


if __name__ == '__main__':
    main()
