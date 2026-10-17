#!/usr/bin/env python3
"""Drive real TUI/browser sessions against request_compression.py.

Requires a running isolated daemon, built packages/client (including its TUI
dev dependency), tmux for TUI, and Python Playwright with Chromium for web. Use --container
when the daemon and tmux run inside a Docker container. The browser runs here.
Generated captures stay under the ignored build directory.
"""

import argparse
import base64
from contextlib import ExitStack
import importlib.util
import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time
import uuid

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


class DeadlineSocket:
    """Each blocking operation spends the same RPC budget, even with traffic."""

    def __init__(self, sock, deadline):
        self.sock, self.deadline = sock, deadline

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('control RPC deadline expired')
        return remaining

    def recv(self, count):
        self.sock.settimeout(self.remaining())
        data = self.sock.recv(count)
        if not data:
            raise ConnectionError('control peer closed the socket')
        return data

    def sendall(self, data):
        self.sock.settimeout(self.remaining())
        self.sock.sendall(data)


def control_rpc(control, state, port, name, body, timeout=120):
    """Reuse frame encoding, but bound upgrade, hello and reply together."""
    deadline = time.monotonic() + timeout
    token = (state / 'owner.token').read_text().strip()
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('control RPC deadline expired')
    with socket.create_connection(('127.0.0.1', port), timeout=remaining) as raw:
        sock = DeadlineSocket(raw, deadline)
        key = base64.b64encode(uuid.uuid4().bytes).decode()
        sock.sendall((
            f'GET /v2/control HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
            'Upgrade: websocket\r\nConnection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
            f'Authorization: Bearer {token}\r\n\r\n').encode())
        head = bytearray()
        while not head.endswith(b'\r\n\r\n'):
            head.extend(sock.recv(1))
            if len(head) > 65536:
                raise ValueError('control upgrade header exceeds experiment bound')
        if b' 101 ' not in head.split(b'\r\n')[0]:
            raise ConnectionError('control upgrade refused')
        stream = control.events(sock)
        hello = next(event for event in stream if event.get('event') == 'hello')
        body = dict(body)
        if name in ('sessions.open', 'sessions.stop'):
            body['epoch'] = hello['body']['epoch']
        sock.sendall(control.frame(json.dumps({'v': 2, 'id': 1, 'cmd': name, 'body': body})))
        reply = next(event for event in stream if event.get('reply_to') == 1)
        if reply['event'] == 'error':
            raise RuntimeError(reply['body'])
        return reply['body']


def run_trial(rpc, args, ui, encoding, trial, drive):
    """A visible answer becomes evidence only after capture and saved custody."""
    mode(args.directory / 'lab', encoding, 10, 6)
    name = f'gzip-{ui}-{encoding}-{uuid.uuid4().hex[:8]}'
    created = rpc('sessions.create', {'request_key': name, 'workspace': args.workspace,
                                      'name': name, 'configuration': ''})
    session = created.get('session_id') or created['id']
    try:
        # An open timeout may follow admission, so it still owes cleanup.
        rpc('sessions.open', {'session_id': session})
        elapsed = drive(session)
    finally:
        rpc('sessions.stop', {'session_id': session})
        deadline = time.monotonic() + 120
        wait_for(lambda: rpc('sessions.get', {'session_id': session},
                             timeout=max(0.001, deadline - time.monotonic()))['status']['state'] == 'saved')
    record(args, ui, encoding, trial, session, elapsed)


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
    args.run_id = uuid.uuid4().hex
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
        return subprocess.check_output([*prefix, *values], text=True, timeout=30)

    def rpc(name, body, timeout=120):
        return control_rpc(control, args.state, args.port, name, body, timeout)

    with ExitStack() as stack:
        uis = ['tui', 'web'] if args.ui == 'both' else [args.ui]
        if 'web' in uis:
            from playwright.sync_api import sync_playwright
            playwright = stack.enter_context(sync_playwright())
            browser = playwright.chromium.launch(executable_path=args.chromium, headless=True,
                                                  args=['--no-sandbox', '--disable-dev-shm-usage'])
            stack.callback(browser.close)
        for ui in uis:
            drive = (lambda session: drive_web(browser, rpc, args, session)) if ui == 'web' else (
                lambda session: drive_tui(command, args, session))
            for trial in range(args.rounds):
                order = ('identity', 'gzip') if trial % 2 == 0 else ('gzip', 'identity')
                for encoding in order:
                    run_trial(rpc, args, ui, encoding, trial, drive)


def record(args, ui, encoding, trial, session, elapsed):
    with (args.directory / 'ui.jsonl').open('a') as output:
        output.write(json.dumps({'run_id': args.run_id, 'session_id': session,
                                 'ui': ui, 'encoding': encoding, 'trial': trial, 'simulated_mbps': 10,
                                 'submit_to_visible_reply_ms': round(elapsed * 1000, 3)}) + '\n')
    print(f'{ui} {encoding} trial={trial} visible_reply_ms={elapsed * 1000:.3f}', flush=True)


def drive_web(browser, rpc, args, session):
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
        elapsed = time.perf_counter() - start
        # The idle composer has Send; a busy strand offers Queue and Steer.
        page.get_by_role('button', name='Send', exact=True).wait_for(timeout=120000)
        page.screenshot(path=str(args.directory / f'web-{args.run_id}-{session}.png'))
        return elapsed
    finally:
        page.close()


def drive_tui(command, args, session):
    socket = 'gzip-' + uuid.uuid4().hex
    runtime = Path(args.runtime_root)
    token = runtime / args.state.resolve().relative_to(ROOT) / 'owner.token'
    # The private launcher carries a token-file path, never a bearer in argv.
    script = args.directory / f'tui-{args.run_id}-{session}.sh'
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
        elapsed = time.perf_counter() - start
        wait_for(lambda: 'main · idle' in capture())
        (args.directory / f'tui-{args.run_id}-{session}.txt').write_text(capture())
        return elapsed
    finally:
        try:
            tmux('kill-server')
        except subprocess.CalledProcessError:
            pass


if __name__ == '__main__':
    main()
