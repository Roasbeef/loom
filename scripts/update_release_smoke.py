#!/usr/bin/env python3
"""Exercise installed update/restart against complete, locally built releases."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
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


def update(prefix, dist, state, config, environment):
    return subprocess.run(
        [prefix / 'bin/loom', 'update', '--from', dist, '--state-dir', state,
         '--config', config], env=environment, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
    )


def authenticated(prefix, state, environment):
    result = subprocess.run(
        [prefix / 'bin/loom', 'access', '--state-dir', state, 'list'],
        env=environment, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=15,
    )
    if result.returncode:
        raise RuntimeError('original control authentication failed: ' + result.stdout)


def refused(prefix, dist, state, config, environment, first, original, description):
    result = update(prefix, dist, state, config, environment)
    if result.returncode == 0:
        raise RuntimeError(description + ' unexpectedly updated the daemon')
    print(result.stdout, end='')
    expected = {
        'mismatched launch pid': 'does not match the authenticated endpoint',
        'mismatched launch birth': 'does not match the authenticated endpoint',
        'mismatched launch epoch': 'does not match the authenticated endpoint',
        'malformed launch metadata': 'invalid launch metadata',
        'missing launch metadata': 'launch metadata is missing',
        'different updater configuration': 'configuration differs',
        'invalid original configuration': 'invalid configuration',
        'local configuration enables profiling': 'local launch cannot reproduce daemon.profile = true',
        'missing TLS options': 'options file',
        'invalid TLS options': 'options file',
        'missing TLS key': 'credential',
        'invalid TLS key': 'credential',
        'mismatched TLS key': 'credential',
        'missing TLS cookie': 'credential',
        'mismatched HOME': 'credential',
        'missing distribution ledger': 'distribution.ledger',
        'corrupt distribution ledger': 'distribution.ledger',
    }[description]
    if expected not in result.stdout:
        raise RuntimeError(description + ' gave an unrelated refusal: ' + result.stdout)
    after = json.loads((state / 'daemon.endpoint').read_text())
    if after != first:
        raise RuntimeError(description + ' changed the original endpoint')
    if original.poll() is not None:
        raise RuntimeError(description + ' retired the original native process')
    os.kill(first['pid'], 0)
    authenticated(prefix, state, environment)
    print(description + ': refused while original remained authenticated')


def absent_config_replacement(root, prefix, dist, commit):
    state = root / 'absent config state'
    state.mkdir(mode=0o700)
    (state / 'loom.toml').write_text('[daemon]\nprofile = true\n')
    home = root / 'absent config home'
    home.mkdir(mode=0o700)
    environment = os.environ.copy()
    for key in ('LOOM_DISTRIBUTION_OPTFILE', 'ERL_FLAGS', 'ERL_AFLAGS',
                'ERL_ZFLAGS', 'ERL_EPMD_PORT', 'ERL_EPMD_ADDRESS',
                'LOOM_DEBUG_ARGS_FILE'):
        environment.pop(key, None)
    environment.update(HOME=str(home), LOOM_STATE_DIR=str(state))
    record_path = state / 'daemon.endpoint'
    log_path = root / 'absent-config-daemon.log'
    with log_path.open('w') as log:
        original = subprocess.Popen([prefix / 'bin/loomd', '--state-dir', state,
                                     '--config', ''], env=environment,
                                    stdout=log, stderr=subprocess.STDOUT)
        try:
            first = ready(record_path, original)
            threading.Thread(target=original.wait, daemon=True).start()
            metadata = json.loads((state / 'launch.json').read_text())
            assert metadata['config'] is None and metadata['mode'] == 'local'
            authenticated(prefix, state, environment)
            result = update(prefix, dist, state, '', environment)
            print(result.stdout, end='')
            if result.returncode:
                raise RuntimeError('absent-config update failed')
            if 'Loom profiling enabled' in result.stdout:
                raise RuntimeError('absent-config update enabled profiling')
            second = ready(record_path, previous=first['epoch'])
            original.wait(timeout=10)
            assert second['pid'] != first['pid'] and second['build_commit'] == commit
            metadata = json.loads((state / 'launch.json').read_text())
            assert metadata['config'] is None and metadata['mode'] == 'local'
            assert not list((state / 'tokens').glob('loom-*-profile.*'))
            authenticated(prefix, state, environment)
            print('absent configuration retained with new authenticated epoch')
        finally:
            stop_fixture(record_path, state)
            if original.poll() is None:
                original.terminate()
                original.wait(timeout=15)
            log.flush()
            if 'Loom profiling enabled' in log_path.read_text():
                raise RuntimeError('original absent-config launch enabled profiling')


def preflight_effects(root, prefix, environment, mode="local", configuration=None):
    """Observe the shipped preflight after OTP startup and through its exit."""
    fixture = root / (mode + ' preflight effects')
    fixture.mkdir(mode=0o700)
    home = Path(environment['HOME']) if mode == 'tls' else fixture / 'home'
    state = fixture / 'state'
    state.mkdir(mode=0o700)
    if mode == 'local':
        (home / '.loom').mkdir(parents=True, mode=0o700)
        (home / '.loom/loom.toml').write_text('[daemon]\nprofile = true\n')
    text = '' if configuration is None else configuration.read_text()
    source = fixture / 'configuration fifo'
    os.mkfifo(source, 0o600)
    opened, resume = threading.Event(), threading.Event()
    errors = []

    def supply_configuration():
        try:
            with source.open('w') as stream:
                opened.set()
                if not resume.wait(20):
                    raise RuntimeError('preflight observation did not resume')
                stream.write(text)
        except Exception as error:
            errors.append(error)

    def filesystem():
        return {(str(directory), str(path.relative_to(directory))): (path.stat().st_mode,
                path.stat().st_size, path.stat().st_mtime_ns)
                for directory in (home, state)
                for path in (directory, *directory.rglob('*'))}

    def processes():
        output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
        return [line.split(None, 2) for line in output.splitlines() if line.strip()]

    def has_internet_socket(pid):
        pid = str(pid)
        if Path('/proc/self/fd').is_dir():
            sockets = set()
            for descriptor in Path('/proc', pid, 'fd').iterdir():
                try:
                    target = os.readlink(descriptor)
                except FileNotFoundError:
                    continue
                if target.startswith('socket:['):
                    sockets.add(target[8:-1])
            for protocol in ('tcp', 'tcp6', 'udp', 'udp6'):
                table = Path('/proc', pid, 'net', protocol)
                if table.exists():
                    if any(line.split()[9] in sockets for line in
                           table.read_text().splitlines()[1:]):
                        return True
            return False
        else:
            observed = subprocess.run(['/usr/sbin/lsof', '-b', '-w', '-nP', '-a', '-p',
                                       pid, '-i'], text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert observed.returncode in (0, 1), observed.stderr
            assert not observed.stderr.strip(), observed.stderr
            return bool(observed.stdout.strip())

    # A known listener validates the socket sensor before absence is accepted.
    # lsof's network-only query avoids unrelated mounted-filesystem inspection.
    with socket.socket() as control:
        control.bind(('127.0.0.1', 0))
        control.listen()
        assert has_internet_socket(os.getpid()), 'socket sensor missed its control'

    before_files = filesystem()
    before_epmd = {row[0] for row in processes() if Path(row[2]).name == 'epmd'}
    child_environment = environment | {'HOME': str(home), 'LOOM_STATE_DIR': str(state)}
    with (fixture / 'preflight.log').open('w+') as log:
        child = subprocess.Popen([prefix / 'bin/loomd', '__launch_preflight',
                                  mode, source], env=child_environment,
                                 stdout=log, stderr=subprocess.STDOUT)
        writer = threading.Thread(target=supply_configuration, daemon=True)
        writer.start()
        try:
            # Opening the writer witnesses the actual application's config read.
            if not opened.wait(15):
                raise RuntimeError('shipped preflight did not reach configuration read')
            assert child.poll() is None, 'preflight exited before observation'
            rows = processes()
            owned = {str(child.pid)}
            while True:
                descendants = {row[0] for row in rows if row[1] in owned}
                if descendants <= owned:
                    break
                owned |= descendants
            for pid in owned:
                assert not has_internet_socket(pid), 'preflight opened an Internet socket'
            assert filesystem() == before_files, 'preflight changed private state or HOME'
            assert {row[0] for row in rows if Path(row[2]).name == 'epmd'} <= before_epmd
            resume.set()
            assert child.wait(timeout=20) == 0, 'shipped preflight refused valid ' + mode + ' config'
            writer.join(timeout=2)
            assert not writer.is_alive() and not errors, errors
            assert filesystem() == before_files, 'preflight left filesystem effects'
            assert {row[0] for row in processes() if Path(row[2]).name == 'epmd'} <= before_epmd
            print(mode + ' preflight: no Internet socket after dependency startup; '
                  'epmd and private HOME/state unchanged through exit')
        finally:
            resume.set()
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=10)
            # Unblock a writer if the launcher failed before reading the FIFO.
            descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK)
            writer.join(timeout=2)
            os.close(descriptor)
            log.seek(0)
            print(log.read(), end='')


def tls_replacement(root, prefix, dist, commit):
    fixture = root / 'TLS fixture with spaces'
    home = fixture / 'orchestrator/home'
    other_home = fixture / 'executor/home'
    node = f'loom_update_{os.getpid()}@127.0.0.1'
    peer = f'loom_peer_{os.getpid()}@127.0.0.1'
    subprocess.run([ROOT / 'scripts/distributed/mint-fixture.sh', fixture,
                    node, home, peer, other_home, 'proj', root], check=True)
    config = home / '.loom/loom.toml'
    config.write_text((ROOT / 'scripts/release-smoke.toml').read_text().replace(
        '"on-boot"', '"off"') + '\n' + config.read_text())
    options = home / '.loom/distribution options'
    state = root / 'TLS state with spaces'
    state.mkdir(mode=0o700)
    environment = os.environ.copy()
    for key in ('LOOM_DISTRIBUTION_OPTFILE', 'ERL_FLAGS', 'ERL_AFLAGS',
                'ERL_ZFLAGS', 'ERL_EPMD_PORT', 'ERL_EPMD_ADDRESS',
                'LOOM_DEBUG_ARGS_FILE'):
        environment.pop(key, None)
    environment.update(HOME=str(home), LOOM_STATE_DIR=str(state))
    subprocess.run([prefix / 'bin/loomd', 'distribution', 'options', config, options],
                   env=environment, check=True, timeout=30)
    environment['LOOM_DISTRIBUTION_OPTFILE'] = str(options)
    preflight_effects(root, prefix, environment, 'tls', config)
    record_path = state / 'daemon.endpoint'
    log_path = root / 'tls-daemon.log'
    with log_path.open('w') as log:
        original = subprocess.Popen([prefix / 'bin/loomd', '--state-dir', state,
                                     '--config', config], env=environment,
                                    stdout=log, stderr=subprocess.STDOUT)
        try:
            first = ready(record_path, original)
            threading.Thread(target=original.wait, daemon=True).start()
            authenticated(prefix, state, environment)
            metadata = state / 'launch.json'
            saved = metadata.read_bytes()
            for field, replacement in [('pid', first['pid'] + 1),
                                       ('birth', 'stale-birth'),
                                       ('epoch', 'stale-epoch')]:
                changed = json.loads(saved)
                changed[field] = replacement
                metadata.write_text(json.dumps(changed))
                refused(prefix, dist, state, config, environment, first, original,
                        'mismatched launch ' + field)
                metadata.write_bytes(saved)
            metadata.write_text('{broken')
            refused(prefix, dist, state, config, environment, first, original,
                    'malformed launch metadata')
            metadata.unlink()
            refused(prefix, dist, state, config, environment, first, original,
                    'missing launch metadata')
            metadata.write_bytes(saved)
            metadata.chmod(0o600)
            different = root / 'different config.toml'
            different.write_bytes(config.read_bytes())
            refused(prefix, dist, state, different, environment, first, original,
                    'different updater configuration')
            config_saved = config.read_bytes()
            config.write_text('[broken')
            refused(prefix, dist, state, config, environment, first, original,
                    'invalid original configuration')
            config.write_bytes(config_saved)
            # Keep the current TLS credentials and regenerate options for the
            # ledger configuration, so credential-only validation cannot pass
            # these failures by rejecting a stale options file first.
            static_config = config.read_bytes()
            static_options = options.read_bytes()
            ledger = fixture / 'missing membership ledger'
            try:
                source = static_config.decode('utf-8')
                ledger_config, count = re.subn(
                    r'\n\[\[distribution\.peers\]\]\n.*?(?=\n\[|\Z)',
                    '', source, flags=re.DOTALL,
                )
                if count != 1:
                    raise RuntimeError('TLS fixture must contain exactly one peer table')
                ledger_config = ledger_config.replace(
                    '[distribution]\n',
                    '[distribution]\nledger = ' + json.dumps(str(ledger)) + '\n',
                    1,
                )
                config.write_text(ledger_config)
                options_environment = environment.copy()
                options_environment.pop('LOOM_DISTRIBUTION_OPTFILE', None)
                subprocess.run(
                    [prefix / 'bin/loomd', 'distribution', 'options', config, options],
                    env=options_environment, check=True, timeout=30,
                )
                refused(prefix, dist, state, config, environment, first, original,
                        'missing distribution ledger')
                corrupt = b'corrupt membership ledger\n'
                ledger.write_bytes(corrupt)
                ledger.chmod(0o600)
                refused(prefix, dist, state, config, environment, first, original,
                        'corrupt distribution ledger')
                assert ledger.read_bytes() == corrupt
            finally:
                config.write_bytes(static_config)
                options.write_bytes(static_options)
                options.chmod(0o600)

            options_saved = options.read_bytes()
            options.unlink()
            refused(prefix, dist, state, config, environment, first, original,
                    'missing TLS options')
            options.write_text('not Erlang options')
            options.chmod(0o600)
            refused(prefix, dist, state, config, environment, first, original,
                    'invalid TLS options')
            options.write_bytes(options_saved)
            options.chmod(0o600)
            key = home / '.loom/distribution/key.pem'
            saved_key = key.read_bytes()
            key.unlink()
            refused(prefix, dist, state, config, environment, first, original,
                    'missing TLS key')
            key.write_text('invalid private key')
            key.chmod(0o600)
            refused(prefix, dist, state, config, environment, first, original,
                    'invalid TLS key')
            key.write_bytes((other_home / '.loom/distribution/key.pem').read_bytes())
            key.chmod(0o600)
            refused(prefix, dist, state, config, environment, first, original,
                    'mismatched TLS key')
            key.write_bytes(saved_key)
            key.chmod(0o600)
            cookie = home / '.erlang.cookie'
            saved_cookie = cookie.read_bytes()
            cookie.unlink()
            refused(prefix, dist, state, config, environment, first, original,
                    'missing TLS cookie')
            cookie.write_bytes(saved_cookie)
            cookie.chmod(0o600)
            bad_home = root / 'bad home'
            bad_home.mkdir(mode=0o700)
            refused(prefix, dist, state, config, environment | {'HOME': str(bad_home)},
                    first, original, 'mismatched HOME')
            result = update(prefix, dist, state, config, environment)
            print(result.stdout, end='')
            if result.returncode:
                raise RuntimeError('TLS update failed')
            second = ready(record_path, previous=first['epoch'])
            original.wait(timeout=10)
            assert second['pid'] != first['pid']
            assert second['build_commit'] == commit
            authenticated(prefix, state, environment)
            print('TLS replacement passed with new authenticated epoch and build')
        finally:
            stop_fixture(record_path, state)
            if original.poll() is None:
                original.terminate()
                original.wait(timeout=15)
            print(log_path.read_text()[-2000:])


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
    for key in ('LOOM_DISTRIBUTION_OPTFILE', 'ERL_FLAGS', 'ERL_AFLAGS',
                'ERL_ZFLAGS', 'ERL_EPMD_PORT', 'ERL_EPMD_ADDRESS',
                'LOOM_DEBUG_ARGS_FILE'):
        environment.pop(key, None)
    local_home = root / 'local home'
    local_home.mkdir(mode=0o700)
    environment.update(PREFIX=str(prefix), LOOM_CLIENT='bundled',
                       LOOM_STATE_DIR=str(state), HOME=str(local_home))
    subprocess.run(['bash', ROOT / 'scripts/install.sh'], env=environment, check=True)
    preflight_effects(root, prefix, environment)
    old_tree = (prefix / 'lib/loom/server').resolve()
    record_path = state / 'daemon.endpoint'
    daemon_log = root / 'original-daemon.log'
    with daemon_log.open('w') as log:
        original = subprocess.Popen([prefix / 'bin/loomd', '--state-dir', state,
                                     '--config', configuration], env=environment,
                                    stdout=log, stderr=subprocess.STDOUT)
        try:
            first = ready(record_path, original)
            # A local replacement must not inherit distribution flags from the updater.
            (local_home / ".loom").mkdir()
            (local_home / ".loom/loom.toml").write_text("[daemon]\nprofile = true\n")
            environment["ERL_FLAGS"] = "-kernel connect_all false"
            environment["LOOM_DEBUG_ARGS_FILE"] = str(root / "absent debug args")
            environment["LOOM_DISTRIBUTION_OPTFILE"] = str(root / "absent options")
            # The original server is our child. Reap it concurrently so a
            # successful shutdown does not remain a zombie while the updater
            # correctly waits for the original native lifetime to disappear.
            reaper = threading.Thread(target=original.wait, daemon=True)
            reaper.start()
            saved_config = configuration.read_bytes()
            configuration.write_bytes(saved_config + b'\n[daemon]\nprofile = true\n')
            refused(prefix, dist, state, configuration, environment, first, original,
                    'local configuration enables profiling')
            configuration.write_bytes(saved_config)
            result = subprocess.run([prefix / 'bin/loom', 'update', '--from', dist,
                                     '--state-dir', state, '--config', configuration],
                                    env=environment, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=180)
            print(result.stdout, end='')
            if 'Loom profiling enabled' in result.stdout:
                raise RuntimeError('update enabled profiling from the updater home')
            if result.returncode:
                raise RuntimeError(f'installed updater exited {result.returncode}')
            second = ready(record_path, previous=first['epoch'])
            original.wait(timeout=10)
            assert second['pid'] != first['pid']
            assert second['build_commit'] == commit
            assert json.loads((state / 'launch.json').read_text())['mode'] == 'local'
            authenticated(prefix, state, environment)
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
            assert json.loads((state / 'launch.json').read_text())['mode'] == 'local'
            authenticated(prefix, state, environment)
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
    absent_config_replacement(root, prefix, dist, commit)
    tls_replacement(root, prefix, dist, commit)
    shutil.rmtree(root)


if __name__ == '__main__':
    main()
