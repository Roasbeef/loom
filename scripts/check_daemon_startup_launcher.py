#!/usr/bin/env python3
"""Exercise application startup in a disposable copy of a server release.

Usage: python3 scripts/check_daemon_startup_launcher.py RELEASE [--source-eval]

The normal mode executes the copied artifact's real launcher. --source-eval
substitutes only the daemon eval expression from scripts/release.sh, allowing
that exact seam to be checked before rebuilding; it does not validate a newly
generated artifact. All callback and entrypoint substitutions stay in the copy.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
OPTIONS = None

CALLBACK = r'''
-module(startup_probe_app).
-behaviour(application).
-export([start/2, stop/1]).
start(_, [Name]) ->
    Stdout = io:getopts(standard_io),
    true = proplists:get_value(binary, Stdout),
    unicode = proplists:get_value(encoding, Stdout),
    Stderr = io:getopts(standard_error),
    unicode = proplists:get_value(encoding, Stderr),
    io:format("callback stdout: ~ts~n", [[16#3bb]]),
    io:format(standard_error, "callback stderr: ~ts~n", [[16#3bb]]),
    case Name of
        startup_probe ->
            true = lists:keymember(startup_probe_base, 1,
                                   application:which_applications());
        startup_probe_base -> ok
    end,
    record("started", Name),
    case {Name, os:getenv("LOOM_STARTUP_PROBE_MODE")} of
        {startup_probe, "failure"} -> {error, 'startup_probe_refusal_λ'};
        _ -> {ok, spawn_link(fun() -> receive stop -> ok end end), Name}
    end.
stop(Name) -> record("stopped", Name).
record(Event, Name) ->
    file:write_file(os:getenv("LOOM_STARTUP_PROBE_EVENTS"),
                    io_lib:format("~s ~p~n", [Event, Name]), [append]).
'''

ENTRY = r'''
-module('client@@main').
-export([run/1]).
run(client) ->
    Apps = application:which_applications(),
    true = lists:keymember(client, 1, Apps),
    true = lists:keymember(startup_probe, 1, Apps),
    true = lists:keymember(startup_probe_base, 1, Apps),
    ok = file:write_file(os:getenv("LOOM_STARTUP_PROBE_MAIN"), <<"entered">>),
    io:format("startup fixture ready pid=~s~n", [os:getpid()]),
    erlang:halt(0, [{flush, true}]).
'''


def source_eval():
    """Read the actual daemon expression, without running the release builder."""
    source = (ROOT / 'scripts/release.sh').read_text()
    block = source.split('cat > "$REL/bin/loomd" <<EOF\n', 1)[1].split('\nEOF', 1)[0]
    matches = re.findall(r"^\s*-eval '([^']+)'", block, re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError('expected exactly one daemon eval expression')
    return matches[0]


class StartupLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = ROOT / 'build/startup-launcher-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(dir=scratch)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.release = cls.root / 'release'
        shutil.copytree(OPTIONS.release, cls.release, symlinks=True)
        cls.home = cls.root / 'home'
        cls.home.mkdir()
        cls.env = {'HOME': str(cls.home), 'PATH': '/usr/bin:/bin',
                   'LANG': 'C', 'LC_ALL': 'C'}
        erlc = shutil.which('erlc')
        if erlc is None:
            raise RuntimeError('erlc from OTP 29 or newer is required')

        client_apps = list((cls.release / 'lib').glob('client-*/ebin/client.app'))
        if len(client_apps) != 1:
            raise RuntimeError('expected exactly one client.app in the release')
        client_app = client_apps[0]
        text, count = re.subn(r'(\{applications,\s*\[)', r'\1startup_probe,',
                              client_app.read_text(), count=1)
        if count != 1:
            raise RuntimeError('client.app has no application dependency list')
        client_app.write_text(text)

        probe_ebin = cls.release / 'lib/startup_probe-0.0.0/ebin'
        probe_ebin.mkdir(parents=True)
        for name, dependencies in [('startup_probe_base', 'kernel,stdlib'),
                                   ('startup_probe', 'kernel,stdlib,startup_probe_base')]:
            (probe_ebin / (name + '.app')).write_text(
                '{application, %s, [{vsn,"0.0.0"},{applications,[%s]},'
                '{modules,[startup_probe_app]},{mod,{startup_probe_app,[%s]}}]}.\n'
                % (name, dependencies, name))
        for name, contents, output in [('startup_probe_app', CALLBACK, probe_ebin),
                                       ('client@@main', ENTRY, client_app.parent)]:
            source = cls.root / (name + '.erl')
            source.write_text(contents)
            subprocess.run([erlc, '-o', str(output), str(source)], env=cls.env,
                           cwd=cls.root, check=True, capture_output=True, timeout=30)

        if OPTIONS.source_eval:
            launcher = cls.release / 'bin/loomd'
            text, count = re.subn(r"(?m)^(\s*-eval )'[^']+'",
                                 lambda match: match[1] + "'" + source_eval() + "'",
                                 launcher.read_text())
            if count != 1:
                raise RuntimeError('expected exactly one artifact eval expression')
            launcher.write_text(text)

    def launch(self, mode):
        work = self.root / mode
        work.mkdir()
        events, entered = work / 'events', work / 'main-entered'
        env = dict(self.env, LOOM_STARTUP_PROBE_MODE=mode,
                   LOOM_STARTUP_PROBE_EVENTS=str(events),
                   LOOM_STARTUP_PROBE_MAIN=str(entered))
        proc = subprocess.Popen([str(self.release / 'bin/loomd'),
                                 '--state-dir', str(work / 'state')],
                                cwd=work, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = proc.communicate(timeout=30)
        except BaseException:
            proc.kill()
            proc.communicate()
            raise
        self.assertFalse(list(self.root.rglob('erl_crash.dump')))
        return proc, stdout.decode(), stderr.decode(), events.read_text(), entered, work

    def test_success_enters_main_after_dependencies_without_replacing_pid(self):
        proc, out, err, events, entered, _ = self.launch('success')
        self.assertEqual(proc.returncode, 0, out + err)
        self.assertIn('startup fixture ready pid=%d' % proc.pid, out)
        self.assertIn('callback stdout: λ', out)
        self.assertIn('callback stderr: λ', err)
        self.assertTrue(entered.is_file())
        self.assertLess(events.index('started startup_probe_base'),
                        events.index('started startup_probe\n'))

    def test_failed_callback_rolls_back_and_never_enters_main(self):
        proc, out, err, events, entered, work = self.launch('failure')
        self.assertEqual(proc.returncode, 1, out + err)
        self.assertIn('loomd: application startup failed:', err)
        self.assertIn('startup_probe', err)
        self.assertIn('startup_probe_refusal_λ', err)
        self.assertIn('callback stdout: λ', out)
        self.assertIn('callback stderr: λ', err)
        self.assertIn('stopped startup_probe_base', events)
        self.assertFalse(entered.exists())
        self.assertFalse((work / 'state').exists())
        self.assertNotIn('daemon listening', out + err)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release', type=Path)
    parser.add_argument('--source-eval', action='store_true')
    OPTIONS = parser.parse_args()
    OPTIONS.release = OPTIONS.release.resolve()
    print('Checking %s in a disposable copy (%s)' %
          (OPTIONS.release, 'source eval seam' if OPTIONS.source_eval else 'artifact launcher'),
          flush=True)
    unittest.main(argv=[__file__], verbosity=2)
