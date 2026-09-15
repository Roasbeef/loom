#!/usr/bin/env python3
"""Verify native downloads against an isolated HTTPS fixture and test-only CA."""
import http.server
import json
import pathlib
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        status, body = 200, b'fixture artifact'
        headers = {}
        if self.path == '/missing':
            status, body = 404, b'missing'
        elif self.path == '/error':
            status, body = 503, b'unavailable'
        elif self.path == '/redirect':
            status, headers = 302, {'Location': '/asset'}
        elif self.path == '/loop':
            status, headers = 302, {'Location': '/loop'}
        elif self.path == '/downgrade':
            status, headers = 302, {'Location': 'http://localhost/asset'}
        elif self.path == '/large':
            body = b'x' * 65536
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class DownloadTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['gleam', 'build', '--warnings-as-errors'], cwd=ROOT / 'packages/tui', check=True)
        cls.temp = tempfile.TemporaryDirectory(prefix='loom-download-test-')
        cls.root = pathlib.Path(cls.temp.name)
        cls.cert, cls.key = cls.root / 'cert.pem', cls.root / 'key.pem'
        cls.ca = cls.root / 'ca.pem'
        ca_key = cls.root / 'ca-key.pem'
        csr = cls.root / 'server.csr'
        extensions = cls.root / 'extensions.cnf'
        extensions.write_text('subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
        commands = [
            ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=Loom fixture CA', '-addext', 'basicConstraints=critical,CA:TRUE',
             '-keyout', str(ca_key), '-out', str(cls.ca)],
            ['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
             '-keyout', str(cls.key), '-out', str(csr)],
            ['openssl', 'x509', '-req', '-in', str(csr), '-CA', str(cls.ca), '-CAkey', str(ca_key),
             '-CAcreateserial', '-days', '1', '-extfile', str(extensions), '-out', str(cls.cert)],
        ]
        for command in commands:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.cert, cls.key)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def fetch(self, path, limit=1024, trust=True, host='localhost'):
        destination = self.root / 'download'
        destination.unlink(missing_ok=True)
        url = f'https://{host}:{self.server.server_port}{path}'
        roots = f'ok=public_key:cacerts_load({json.dumps(str(self.ca))}),' if trust else ''
        expression = ("application:ensure_all_started(tui)," + roots +
                      "R='tui@update@download':fetch(" +
                      f'<<{json.dumps(url)}>>, <<{json.dumps(str(destination))}>>, {limit}),' +
                      'io:format("~p~n",[R]), halt().')
        paths = sorted((ROOT / 'packages/tui/build/dev/erlang').glob('*/ebin'))
        result = subprocess.run(['erl', '+S', '2:2', '-noshell', '-pa', *map(str, paths), '-eval', expression],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout, destination

    def test_verified_download_and_relative_redirect(self):
        for path in ['/asset', '/redirect']:
            output, destination = self.fetch(path)
            self.assertIn('{ok,present}', output)
            self.assertEqual(destination.read_bytes(), b'fixture artifact')

    def test_flow_control_preserves_multiple_fragments(self):
        output, destination = self.fetch('/large', limit=65536)
        self.assertIn('{ok,present}', output)
        self.assertEqual(destination.read_bytes(), b'x' * 65536)

    def test_only_404_is_absence(self):
        output, destination = self.fetch('/missing')
        self.assertIn('{ok,absent}', output)
        self.assertFalse(destination.exists())
        output, destination = self.fetch('/error')
        self.assertIn('HTTP 503', output)
        self.assertFalse(destination.exists())

    def test_size_limit_and_redirect_policy(self):
        for path, error in [('/large', 'byte limit'), ('/loop', 'too many download redirects'),
                            ('/downgrade', 'requires HTTPS')]:
            output, destination = self.fetch(path)
            self.assertIn(error, output)
            self.assertFalse(destination.exists())

    def test_certificate_and_hostname_are_verified(self):
        for options in [{'trust': False}, {'host': '127.0.0.1'}]:
            output, destination = self.fetch('/asset', **options)
            self.assertIn('{error,', output)
            self.assertFalse(destination.exists())


if __name__ == '__main__':
    unittest.main()
