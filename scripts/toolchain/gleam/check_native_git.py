#!/usr/bin/env python3
"""Verify native Git dependencies survive clean resolution and source updates."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import tomllib


def run(argv, cwd, *, input=None, env=None):
    completed = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, input=input, env=env)
    if completed.returncode:
        raise RuntimeError(completed.stdout)
    return completed.stdout.strip()


def write(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)


def force_maintenance(clone):
    # Two valid packs exceed Git's auto-GC pack threshold without needing a
    # large repository. Reverse indexes reach the transient-file copy race.
    for name, value in [('gc.auto', '1'), ('gc.autoPackLimit', '1'),
                        ('gc.autoDetach', 'true'), ('maintenance.autoDetach', 'true'),
                        ('pack.writeReverseIndex', 'true')]:
        run(['git', 'config', name, value], clone)
    for index in range(2):
        oid = run(['git', 'hash-object', '-w', '--stdin'], clone,
                  input=f'unreachable maintenance fixture {index}\n')
        run(['git', 'pack-objects', '.git/objects/pack/pack'], clone, input=oid + '\n')


def verify_maintenance(trace, clone):
    # An old compiler can return while GC is detached. Wait only to collect
    # its complete trace and keep the temporary repo alive, never to retry it.
    deadline = time.monotonic() + 10
    while (clone / '.git/gc.pid').exists():
        if time.monotonic() >= deadline:
            raise RuntimeError('Git auto-maintenance did not finish within 10 seconds')
        time.sleep(0.02)
    events = [json.loads(line) for line in trace.read_text().splitlines()]
    fetches = {event['sid'] for event in events
               if event['event'] == 'cmd_name' and event['name'] == 'fetch'}
    repacks = [event['sid'] for event in events
               if event['event'] == 'cmd_name' and event['name'] == 'repack'
               and event['hierarchy'].startswith('fetch/maintenance/')]
    assert repacks, 'The fixture did not trigger real Git auto-maintenance'
    for repack in repacks:
        fetch, = [sid for sid in fetches if repack.startswith(sid + '/')]
        fetch_exit, = [event for event in events
                       if event['event'] == 'exit' and event['sid'] == fetch]
        repack_exit, = [event for event in events
                        if event['event'] == 'exit' and event['sid'] == repack]
        assert repack_exit['code'] == 0, repack_exit
        assert repack_exit['time'] < fetch_exit['time'], (
            'Git fetch returned before repository maintenance finished',
            fetch_exit, repack_exit,
        )


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', default='gleam')
args = parser.parse_args()
compiler = shutil.which(args.compiler)
if compiler is None:
    parser.error('compiler executable was not found')

with tempfile.TemporaryDirectory(prefix='gleam-native-git-') as temporary:
    root = Path(temporary)
    native = root / 'native'
    wrapper = root / 'wrapper'
    project = root / 'project'
    write(native / 'gleam.toml',
          'name = "native_fixture"\nversion = "1.0.0"\nbuild_tool = "rebar3"\n')
    write(native / 'src/native_fixture.app.src',
          '{application, native_fixture, [{vsn, "1.0.0"}, {modules, []}, '
          '{applications, [kernel, stdlib]}]}.\n')
    # Only Rebar's compile hook creates this source. A compiler that silently
    # treats the dependency as Gleam cannot accidentally satisfy the witness.
    write(native / 'rebar.config',
          '{pre_hooks, [{compile, "cp native_fixture.erl.in src/native_fixture.erl"}, '
          '{compile, "git rev-parse --is-inside-work-tree > git-witness"}]}.\n')
    write(native / 'native_fixture.erl.in',
          '-module(native_fixture).\n-export([value/0]).\nvalue() -> 42.\n')
    run(['git', 'init', '--quiet'], native)
    run(['git', 'config', 'user.name', 'Olaoluwa Osuntokun'], native)
    run(['git', 'config', 'user.email', 'laolu32@gmail.com'], native)
    run(['git', 'add', '.'], native)
    run(['git', 'commit', '--quiet', '-m', 'test: pin native fixture'], native)
    commit = run(['git', 'rev-parse', 'HEAD'], native)

    def pin(ref):
        write(wrapper / 'gleam.toml',
              'name = "wrapper"\nversion = "1.0.0"\n[dependencies]\n'
              f'native_fixture = {{ git = "{native.as_uri()}", ref = "{ref}" }}\n')

    pin(commit)
    write(wrapper / 'src/wrapper.gleam', 'pub fn value() { Nil }\n')
    write(project / 'gleam.toml',
          'name = "project"\nversion = "1.0.0"\n[dependencies]\n'
          'wrapper = { path = "../wrapper" }\n')
    write(project / 'src/project.gleam',
          '@external(erlang, "native_fixture", "value")\n'
          'pub fn value() -> Int\n')

    def verify(ref, expected, env=None):
        run([compiler, 'build'], project, env=env)
        manifest = tomllib.loads((project / 'manifest.toml').read_text())
        package, = [p for p in manifest['packages'] if p['name'] == 'native_fixture']
        assert package['build_tools'] == ['rebar3'], package
        assert package['source'] == 'git' and package['commit'] == ref, package
        assert (project / 'build/dev/erlang/native_fixture/git-witness').read_text() == 'true\n'
        ebins = sorted((project / 'build/dev/erlang').glob('*/ebin'))
        run(['erl', '-noshell', '-pa', *map(str, ebins), '-eval',
             f'case project:value() of {expected} -> halt(0); _ -> halt(1) end.'],
            project)

    verify(commit, 42)
    # A clean build must reproduce the builder from configuration, even when
    # local-package fingerprints and compiled dependency artifacts are absent.
    shutil.rmtree(project / 'build')
    verify(commit, 42)
    write(native / 'native_fixture.erl.in',
          '-module(native_fixture).\n-export([value/0]).\nvalue() -> 43.\n')
    run(['git', 'add', 'native_fixture.erl.in'], native)
    run(['git', 'commit', '--quiet', '-m', 'test: update native fixture'], native)
    updated = run(['git', 'rev-parse', 'HEAD'], native)
    verify(commit, 42)
    clone = project / 'build/packages/native_fixture'
    force_maintenance(clone)
    trace = root / 'maintenance.trace'
    pin(updated)
    verify(updated, 43, env=dict(os.environ, GIT_TRACE2_EVENT=str(trace)))
    verify_maintenance(trace, clone)
    print('Native Git dependency: clean resolution, exact pin, source update, '
          'Git hook, and synchronous maintenance passed.')
