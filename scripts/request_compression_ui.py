#!/usr/bin/env python3
"""Drive real TUI/browser sessions against request_compression.py.

Requires a running isolated daemon, built packages/client (including its TUI
dev dependency), tmux, and Python Playwright with Chromium. Use --container
when the daemon and tmux run inside a Docker container. The browser runs here.
Generated captures stay under the ignored build directory.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time
import uuid

from playwright.sync_api import sync_playwright

from request_compression import mode

ROOT = Path(__file__).resolve().parent.parent


def wait_for(attempt, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = attempt()
        if result:
            return result
        time.sleep(0.05)
    raise TimeoutError('UI did not reach the expected state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--runtime-root', default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument('--workspace', required=True, help='workspace path seen by the daemon')
    parser.add_argument('--container')
    parser.add_argument('--port', type=int, default=18745)
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    parser.add_argument('--ui', choices=['tui', 'web', 'both'], default='both')
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error('--rounds must be positive')
    spec = importlib.util.spec_from_file_location('lab_control', Path(__file__).parent / 'web_seed/control.py')
    control = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(control)
    args.directory.mkdir(parents=True, exist_ok=True)

    def command(*values):
        prefix = ['docker', '--host=unix:///var/run/docker.sock', 'exec',
                  '-e', 'HOME=' + args.runtime_root + '/build/compression/home',
                  args.container] if args.container else []
        return subprocess.check_output([*prefix, *values], text=True)

    def rpc(name, body):
        with control.connect(str(args.state), args.port) as sock:
            stream = control.events(sock)
            hello = next(stream)
            if name in ('sessions.open', 'sessions.stop'):
                body['epoch'] = hello['body']['epoch']
            sock.sendall(control.frame(json.dumps({'v': 2, 'id': 1, 'cmd': name, 'body': body})))
            reply = next(e for e in stream if e.get('reply_to') == 1)
            if reply['event'] == 'error':
                raise RuntimeError(reply['body'])
            return reply['body']

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=args.chromium, headless=True,
                                              args=['--no-sandbox', '--disable-dev-shm-usage'])
        try:
            uis = ['tui', 'web'] if args.ui == 'both' else [args.ui]
            for ui in uis:
                for trial in range(args.rounds):
                    order = ('identity', 'gzip') if trial % 2 == 0 else ('gzip', 'identity')
                    for encoding in order:
                        mode(args.directory / 'lab', encoding, 10, 6)
                        name = f'gzip-{ui}-{encoding}-{uuid.uuid4().hex[:8]}'
                        created = rpc('sessions.create', {'request_key': name, 'workspace': args.workspace,
                                                          'name': name, 'configuration': ''})
                        session = created.get('session_id') or created['id']
                        rpc('sessions.open', {'session_id': session})
                        try:
                            if ui == 'web':
                                drive_web(browser, rpc, args, session, encoding, trial)
                            else:
                                drive_tui(command, args, session, encoding, trial)
                        finally:
                            rpc('sessions.stop', {'session_id': session})
                            wait_for(lambda: rpc('sessions.get', {'session_id': session})['status']['state'] == 'saved')
        finally:
            browser.close()


def record(args, ui, encoding, trial, elapsed):
    with (args.directory / 'ui.jsonl').open('a') as output:
        output.write(json.dumps({'ui': ui, 'encoding': encoding, 'trial': trial, 'simulated_mbps': 10,
                                 'submit_to_visible_reply_ms': round(elapsed * 1000, 3)}) + '\n')
    print(f'{ui} {encoding} trial={trial} visible_reply_ms={elapsed * 1000:.3f}', flush=True)


def drive_web(browser, rpc, args, session, encoding, trial):
    link = rpc('ui.link', {'session_id': session, 'page': 'operator'})['path']
    page = browser.new_page(viewport={'width': 1440, 'height': 1000})
    try:
        page.goto(f'http://127.0.0.1:{args.port}{link}')
        editor = page.get_by_placeholder('Message the agent')
        editor.wait_for(timeout=120000)
        editor.fill('gzip-seed')
        page.get_by_role('button', name='Send', exact=True).click()
        page.get_by_text('GZIP_SEEDED', exact=False).last.wait_for(timeout=120000)
        editor = page.get_by_placeholder('Message the agent')
        editor.fill('gzip-probe')
        start = time.perf_counter()
        page.get_by_role('button', name='Send', exact=True).click()
        page.get_by_text('gzip-probe-ok', exact=True).last.wait_for(timeout=120000)
        record(args, 'web', encoding, trial, time.perf_counter() - start)
        page.get_by_role('button', name='Send', exact=True).wait_for(timeout=120000)
        page.screenshot(path=str(args.directory / f'web-{encoding}.png'))
    finally:
        page.close()


def drive_tui(command, args, session, encoding, trial):
    socket = 'gzip-' + uuid.uuid4().hex
    runtime = Path(args.runtime_root)
    token = runtime / args.state.resolve().relative_to(ROOT) / 'owner.token'
    # The private launcher carries a token-file path, never a bearer in argv.
    script = args.directory / f'tui-{encoding}.sh'
    script.write_text('#!/bin/sh\nexec erl +S 2:2 +Bd -pa ' + shlex.quote(str(runtime))
                      + '/packages/client/build/dev/erlang/*/ebin -noshell '
                      + "-eval 'application:ensure_all_started(tui),client@@main:run(tui)' -extra --addr "
                      + f'ws://127.0.0.1:{args.port}/v2/control --session {session} '
                      + '--token-file ' + shlex.quote(str(token)) + '\n')
    script.chmod(0o700)
    runtime_script = runtime / script.resolve().relative_to(ROOT)

    def tmux(*values):
        return command('tmux', '-L', socket, *values)

    def capture():
        return tmux('capture-pane', '-p', '-t', 'lab')

    try:
        tmux('new-session', '-d', '-s', 'lab', '-x', '120', '-y', '40', str(runtime_script))
        wait_for(lambda: 'Enter sends' in capture())
        tmux('send-keys', '-t', 'lab', '-l', 'gzip-seed')
        tmux('send-keys', '-t', 'lab', 'Enter')
        wait_for(lambda: 'GZIP_SEEDED' in capture())
        tmux('send-keys', '-t', 'lab', '-l', 'gzip-probe')
        start = time.perf_counter()
        tmux('send-keys', '-t', 'lab', 'Enter')
        wait_for(lambda: 'gzip-probe-ok' in capture())
        record(args, 'tui', encoding, trial, time.perf_counter() - start)
        wait_for(lambda: 'main · idle' in capture())
        (args.directory / f'tui-{encoding}.txt').write_text(capture())
    finally:
        try:
            tmux('kill-server')
        except subprocess.CalledProcessError:
            pass


if __name__ == '__main__':
    main()
