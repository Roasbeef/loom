#!/usr/bin/env python3
"""Focused evidence and lifecycle regressions; no daemon or browser required."""

from contextlib import contextmanager, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest

import request_compression as lab
import request_compression_ui as ui

spec = importlib.util.spec_from_file_location('control', Path(__file__).parent / 'web_seed/control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


@contextmanager
def peer(behavior):
    """A bounded loopback peer makes stalled and partial RPCs observable."""
    stopped = threading.Event()
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(2)

        def serve():
            try:
                with listener.accept()[0] as conn:
                    conn.settimeout(2)
                    head = bytearray()
                    while not head.endswith(b'\r\n\r\n'):
                        chunk = conn.recv(1)
                        if not chunk:
                            return
                        head.extend(chunk)
                    behavior(conn, stopped)
            except OSError:
                pass

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            yield listener.getsockname()[1]
        finally:
            stopped.set()
            thread.join(3)
            if thread.is_alive():
                raise AssertionError('fixture peer failed to stop')


def event(conn, value):
    payload = json.dumps(value).encode()
    assert len(payload) < 126
    conn.sendall(bytes([0x81, len(payload)]) + payload)


class CompressionEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        (self.directory / 'lab').mkdir()
        (self.directory / 'owner.token').write_text('synthetic-token')

    def summary(self, rows):
        (self.directory / 'requests.jsonl').write_text('\n'.join(map(json.dumps, rows)))
        output = io.StringIO()
        with redirect_stdout(output):
            lab.summary(self.directory)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def row(self, level, wire, elapsed):
        return dict(sha256='same-body', simulated_mbps=10, encoding='gzip', level=level,
                    raw_bytes=1000, wire_bytes=wire, compress_ms=elapsed,
                    first_chunk_ms=elapsed, complete_ms=elapsed)

    def test_summary_keeps_levels_separate(self):
        rows = self.summary([self.row(1, 500, 1), self.row(9, 300, 9)])
        self.assertEqual([(r['level'], r['wire_bytes'], r['samples'], r['compress_ms'])
                          for r in rows], [(1, 500, 1, 1), (9, 300, 1, 9)])

    def test_summary_refuses_inconsistent_sizes(self):
        for field in ('raw_bytes', 'wire_bytes'):
            with self.subTest(field=field):
                altered = self.row(6, 400, 2)
                altered[field] += 1
                with self.assertRaisesRegex(ValueError, 'inconsistent byte sizes'):
                    self.summary([self.row(6, 400, 2), altered])

    def rpc(self, port, name='sessions.get', body=None):
        return ui.control_rpc(control, self.directory, port, name, body or {}, timeout=0.15)

    def test_silent_upgrade_expires(self):
        with peer(lambda conn, stopped: stopped.wait(1)) as port:
            started = time.monotonic()
            with self.assertRaises(TimeoutError):
                self.rpc(port)
            self.assertLess(time.monotonic() - started, 0.8)

    def test_upgrade_eof_fails(self):
        with peer(lambda conn, stopped: conn.sendall(b'HTTP/1.1 101')) as port:
            with self.assertRaisesRegex(ConnectionError, 'closed'):
                self.rpc(port)

    def test_unrelated_events_do_not_renew_rpc_deadline(self):
        def noisy(conn, stopped):
            conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\n\r\n')
            event(conn, {'event': 'hello', 'body': {'epoch': 'fixture'}})
            for _ in range(20):
                if stopped.wait(0.025):
                    break
                event(conn, {'event': 'unrelated'})

        with peer(noisy) as port:
            started = time.monotonic()
            with self.assertRaises(TimeoutError):
                self.rpc(port)
            self.assertLess(time.monotonic() - started, 0.8)

    def test_control_reply_keeps_epoch_and_caller_body(self):
        received = []

        def reply(conn, stopped):
            conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\n\r\n')
            event(conn, {'event': 'hello', 'body': {'epoch': 'fixture'}})
            first, second = control.read_exact(conn, 2)
            self.assertEqual(first, 0x81)
            self.assertLess(second & 127, 126)
            mask = control.read_exact(conn, 4)
            payload = control.read_exact(conn, second & 127)
            received.append(json.loads(bytes(c ^ mask[i % 4] for i, c in enumerate(payload))))
            event(conn, {'event': 'reply', 'reply_to': 1, 'body': {'ok': True}})

        body = {'session_id': 'fixture'}
        with peer(reply) as port:
            self.assertEqual(self.rpc(port, 'sessions.open', body), {'ok': True})
        self.assertNotIn('epoch', body)
        self.assertEqual(received[0]['body']['epoch'], 'fixture')

    def test_partial_trials_do_not_record_success(self):
        for failure in ('sessions.open', 'idle', 'capture', 'sessions.stop', 'sessions.get'):
            with self.subTest(failure=failure):
                calls = []

                def rpc(name, body, **kwargs):
                    calls.append(name)
                    if name == failure:
                        raise TimeoutError(failure)
                    if name == 'sessions.create':
                        return {'session_id': 'fixture'}
                    return {'status': {'state': 'saved'}}

                def drive(session):
                    if failure in ('idle', 'capture'):
                        raise TimeoutError(failure)
                    return 0.1

                args = SimpleNamespace(directory=self.directory, workspace='fixture', run_id='run')
                with self.assertRaises(TimeoutError):
                    ui.run_trial(rpc, args, 'web', 'gzip', 0, drive)
                self.assertIn('sessions.stop', calls)
                self.assertFalse((self.directory / 'ui.jsonl').exists())

    def test_success_is_identifiable_and_follows_saved(self):
        args = SimpleNamespace(directory=self.directory, workspace='fixture', run_id='first')
        completed = []

        def rpc(name, body, **kwargs):
            if name == 'sessions.create':
                return {'session_id': args.run_id + '-session'}
            if name == 'sessions.get':
                # No success from this trial exists when custody is checked.
                path = self.directory / 'ui.jsonl'
                self.assertEqual(len(path.read_text().splitlines()) if path.exists() else 0,
                                 len(completed))
                completed.append(args.run_id)
            return {'status': {'state': 'saved'}}

        with redirect_stdout(io.StringIO()):
            for run in ('first', 'second'):
                args.run_id = run
                ui.run_trial(rpc, args, 'tui', 'identity', 0, lambda session: 0.125)
        rows = [json.loads(line) for line in (self.directory / 'ui.jsonl').read_text().splitlines()]
        self.assertEqual([(r['run_id'], r['session_id']) for r in rows],
                         [('first', 'first-session'), ('second', 'second-session')])
        self.assertTrue(all(r['submit_to_visible_reply_ms'] == 125 for r in rows))


if __name__ == '__main__':
    unittest.main()
