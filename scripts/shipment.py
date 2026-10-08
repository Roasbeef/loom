#!/usr/bin/env python3
"""Export current production shipments with verified local build reuse.

Gleam still owns compilation, dependency ordering and shipment construction.
An unchanged complete input set reuses its shipment; otherwise the official
export runs cleanly, with a scoped rebar3 adapter reusing unchanged dependencies.
Every input change therefore takes Gleam's clean-export path, including module
removals. Caches are private to this checkout and never enter the release.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / 'build/shipment-cache'
RECIPE = Path(__file__).resolve()

# These locked releases build Erlang only, with no native compiler or plugins.
# A new dependency/version remains fresh until its build recipe is reviewed.
ERLANG_ONLY = {
    'cowlib': '2.20.0',
    'gun': '2.6.0',
    'hpack_erl': '0.3.0',
    'yamerl': '0.10.0',
}


def reusable(item):
    entry = item['entry']
    return (entry['source'] == 'hex'
            and ERLANG_ONLY.get(entry['name']) == entry['version'])


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def tree(path, ignored=(), follow_links=False, ancestors=()):
    """Hash names, file bytes, modes and symlink targets, including removals."""
    rows = []
    if follow_links:
        resolved = path.resolve()
        if resolved in ancestors:
            raise ValueError(f'cyclic build input: {path}')
        ancestors = (*ancestors, resolved)
    if path.is_file():
        with path.open('rb') as contents:
            return [['.', 'file', path.stat().st_mode & 0o777,
                     hashlib.file_digest(contents, 'sha256').hexdigest()]]
    if not path.exists():
        return rows
    for directory, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = sorted(d for d in dirs
                         if Path(directory) != path or d not in ignored)
        for name in sorted(dirs + files):
            item = Path(directory) / name
            relative = item.relative_to(path).as_posix()
            if item.is_symlink():
                row = [relative, 'link', os.readlink(item)]
                if follow_links:
                    row.append(tree(item.resolve(), ignored, True, ancestors))
                rows.append(row)
            elif item.is_dir():
                rows.append([relative, 'directory'])
            elif item.is_file():
                with item.open('rb') as contents:
                    checksum = hashlib.file_digest(contents, 'sha256').hexdigest()
                rows.append([relative, 'file', item.stat().st_mode & 0o777, checksum])
            else:
                raise ValueError(f'unsupported build input: {item}')
    return sorted(rows)


def environment():
    # These shell bookkeeping values cannot affect compiler inputs. Everything
    # else participates, including flags and configuration paths. Store only
    # the digest, so credentials in the environment never enter cache metadata.
    return digest({k: v for k, v in os.environ.items()
                   if k not in {'_', 'SHLVL', 'PWD', 'OLDPWD'}
                   and k not in {'LOOM_SHIPMENT_CONTEXT', 'LOOM_SHIPMENT_CACHE'}})


def executable(name):
    path = shutil.which(name)
    if path is None:
        raise ValueError(f'shipment requires {name} on PATH')
    path = Path(path).resolve()
    with path.open('rb') as contents:
        return [str(path), hashlib.file_digest(contents, 'sha256').hexdigest()]


def toolchain():
    """Identify compiler/runtime bytes, including OTP compiler modules and headers."""
    tools = {name: executable(name) for name in
             ['gleam', 'rebar3', 'erl', 'erlc', 'escript', 'make']}
    runtime = subprocess.check_output(
        ['erl', '-noshell', '-eval',
         'io:format("~s~n~s~n", [code:root_dir(), '
         'erlang:system_info(version)]), halt().'], text=True).splitlines()
    otp = Path(runtime[0])
    runtime_inputs = []
    for path in sorted((otp / 'lib').glob('*/ebin')):
        runtime_inputs.append([str(path), tree(path, follow_links=True)])
    for path in sorted((otp / 'lib').glob('*/include')):
        runtime_inputs.append([str(path), tree(path, follow_links=True)])
    for suffix in ['bin', 'include']:
        path = otp / ('erts-' + runtime[1]) / suffix
        runtime_inputs.append([str(path), tree(path, follow_links=True)])

    config_root = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config')))
    global_config = tree(config_root / 'rebar3', follow_links=True)
    return digest([tools, runtime_inputs, global_config, platform.platform(),
                   RECIPE.read_bytes().hex()])


def packages(package):
    """Select only the root's production closure from Gleam's locked graph."""
    config = tomllib.loads((package / 'gleam.toml').read_text())
    manifest = tomllib.loads((package / 'manifest.toml').read_text())
    locked = {entry['name']: entry for entry in manifest['packages']}
    selected = {}

    def visit(name):
        if name in selected:
            return
        entry = locked[name]
        source = ((package / entry['path']).resolve() if entry['source'] == 'local'
                  else package / 'build/packages' / name)
        if not source.is_dir():
            raise ValueError(f'dependency source is missing: {source}')
        # Local build directories and VCS state are outputs, never inputs.
        selected[name] = {'entry': entry, 'source': str(source),
                          'tree': tree(source, ('.git', 'build', '_build'), True)}
        for dependency in entry['requirements']:
            visit(dependency)

    for name in config.get('dependencies', {}):
        visit(name)
    return selected


def inputs(package, selected, identity):
    return digest([str(package), identity, environment(),
                   (package / 'gleam.toml').read_text(),
                   (package / 'manifest.toml').read_text(),
                   [[name, tree(package / name, follow_links=True)] for name in ['src', 'priv']],
                   selected])


@contextmanager
def locked():
    CACHE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (CACHE / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def hit(entry, key):
    try:
        metadata = json.loads((entry / 'metadata.json').read_text())
        return ((entry / 'output').is_dir() and metadata['key'] == key
                and metadata['output'] == tree(entry / 'output'))
    except (OSError, ValueError, KeyError):
        return False


def remember(entry, key, source):
    """Publish only a completed, content-verified build under the writer lock."""
    entry.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=entry.parent) as temporary:
        staged = Path(temporary) / 'entry'
        shutil.copytree(source, staged / 'output', symlinks=True)
        (staged / 'metadata.json').write_text(json.dumps(
            {'key': key, 'output': tree(staged / 'output')}, sort_keys=True))
        if entry.exists():
            shutil.rmtree(entry)
        staged.rename(entry)


def restore(source, target):
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target, symlinks=True)


def rebar(arguments):
    """Reuse only Gleam's production bare-compile calls in the current plan."""
    context = json.loads(Path(os.environ['LOOM_SHIPMENT_CONTEXT']).read_text())
    cwd = Path.cwd().resolve()
    item = context['dependencies'].get(str(cwd))
    if arguments != ['bare', 'compile', '--paths', '../*/ebin'] or item is None:
        return subprocess.call([context['rebar3'], *arguments])
    key = digest([item, context['toolchain'], str(cwd), environment(), arguments])
    entry = CACHE / 'dependencies' / digest(str(cwd))
    if hit(entry, key):
        for path in (entry / 'output').iterdir():
            restore(path, cwd / path.name)
        print(f'shipment: reuse dependency {cwd.name}', flush=True)
        return 0

    status = subprocess.call([context['rebar3'], *arguments])
    if status:
        return status
    with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
        output = Path(temporary) / 'output'
        output.mkdir()
        for name in ['ebin', 'include', 'priv']:
            if (cwd / name).is_dir():
                shutil.copytree(cwd / name, output / name, symlinks=True)
        if not list((output / 'ebin').glob('*.app')):
            raise ValueError(f'dependency produced no application: {cwd}')
        remember(Path(context['pending']) / entry.name, key, output)
    return 0


def export(name, fresh):
    package = ROOT / 'packages' / name
    # These flags can name files outside the declared source/OTP closure. Their
    # presence keeps the official fresh path rather than guessing those inputs.
    fresh = fresh or any(os.environ.get(name) for name in
                         ['REBAR_CONFIG', 'REBAR_GLOBAL_CONFIG_DIR', 'ERL_LIBS',
                          'ERL_FLAGS', 'ERL_AFLAGS', 'ERL_ZFLAGS', 'ERL_COMPILER_OPTIONS'])
    with locked():
        if fresh:
            return subprocess.call(['gleam', 'export', 'erlang-shipment'], cwd=package)
        # Gleam resolves/downloads the manifest before any cache decision. Its
        # own resolver remains the authority on changed version requirements.
        subprocess.run(['gleam', 'deps', 'download'], cwd=package, check=True)
        identity = toolchain()
        selected = packages(package)
        key = inputs(package, selected, identity)
        entry = CACHE / 'shipments' / name
        shipment = package / 'build/erlang-shipment'
        whole_reusable = all('gleam' in item['entry']['build_tools']
                             or reusable(item) for item in selected.values())
        if whole_reusable and hit(entry, key):
            restore(entry / 'output', shipment)
            print(f'shipment: reuse current {name} export', flush=True)
            return 0

        def closure(package_name):
            item = selected[package_name]
            return [item, [closure(dep) for dep in item['entry']['requirements']]]

        dependencies = {}
        for dependency, item in selected.items():
            if 'rebar3' in item['entry']['build_tools'] and reusable(item):
                app = item['entry'].get('otp_app', dependency)
                cwd = package / 'build/prod/erlang' / app
                dependencies[str(cwd.resolve())] = closure(dependency)
        # Dependency misses are published only after the whole export succeeds
        # and its inputs still match, so a failed or mixed build cannot seed reuse.
        with tempfile.TemporaryDirectory(dir=CACHE) as pending:
            context = CACHE / (name + '-context.json')
            context.write_text(json.dumps({'toolchain': identity, 'dependencies': dependencies,
                                          'rebar3': shutil.which('rebar3'), 'pending': pending}))
            adapter = CACHE / 'bin'
            adapter.mkdir(exist_ok=True)
            wrapper = adapter / 'rebar3'
            wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(
                [sys.executable, str(RECIPE), '--rebar3']) + ' "$@"\n')
            wrapper.chmod(0o755)
            env = dict(os.environ, LOOM_SHIPMENT_CONTEXT=str(context),
                       PATH=str(adapter) + os.pathsep + os.environ['PATH'])
            status = subprocess.call(['gleam', 'export', 'erlang-shipment'], cwd=package, env=env)
            if status:
                return status
            # A normal edit during compilation refuses publication rather than
            # recording mixed sources under the key captured before the build.
            if inputs(package, packages(package), toolchain()) != key:
                raise ValueError('shipment inputs changed during compilation; run again')
            for staged in Path(pending).iterdir():
                target = CACHE / 'dependencies' / staged.name
                target.parent.mkdir(exist_ok=True)
                if target.exists():
                    shutil.rmtree(target)
                staged.rename(target)
            if whole_reusable:
                remember(entry, key, shipment)
            return 0


def main():
    if sys.argv[1:2] == ['--rebar3']:
        return rebar(sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', choices=['client', 'tui'])
    parser.add_argument('--fresh', action='store_true', help='bypass all build reuse')
    args = parser.parse_args()
    return export(args.package, args.fresh or os.environ.get('LOOM_SHIPMENT_CACHE') == '0')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'shipment: {error}', file=sys.stderr)
        sys.exit(1)
