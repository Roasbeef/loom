#!/usr/bin/env python3
"""Local gzip experiment; never forwards a request to an external provider.

Run `serve DIRECTORY` and point an Anthropic catalogue entry at port 18744,
using the dummy key `scripted`. Send `gzip-seed` through either real UI, then
`gzip-probe`. The first answer supplies deterministic, mixed source/hex history;
the second request is saved for byte-identical transport replays. mode.json
selects identity/gzip, compression level and a SIMULATED upload rate in Mbps.

This is an experiment proxy, not a production transport implementation. UI
traffic is compressed with Python's zlib; the companion escript measures OTP.
Only synthetic sessions belong here: captures contain complete request bodies.
"""

import argparse
from contextlib import closing
import gzip
import hashlib
import http.client
import json
from pathlib import Path
import statistics
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parent.parent
MAX_BODY = 8 * 1024 * 1024


def history(size=512 * 1024):
    """A fixed public-source corpus with unique hex records, not repeated prose."""
    source = (ROOT / 'packages/provider/src/provider/http.gleam').read_text()
    rows, length, index = [], 0, 0
    while length < size:
        row = source[index % len(source):][:512]
        row += '\ntrace ' + hashlib.shake_256(str(index).encode()).hexdigest(128) + '\n'
        rows.append(row)
        length += len(row.encode())
        index += 1
    return ''.join(rows).encode()[:size].decode(errors='ignore') + '\nGZIP_SEEDED'


def latest(body):
    message = body['messages'][-1]['content']
    if isinstance(message, str):
        return message
    return '\n'.join(b.get('text', '') for b in message if b['type'] == 'text')


def events(model, text):
    """A valid streamed text answer; each chunk is independently flushable."""
    def event(kind, **fields):
        return ('event: ' + kind + '\ndata: ' + json.dumps(
            {'type': kind, **fields}) + '\n\n').encode()

    yield event('message_start', message={
        'id': 'msg_compression_fixture', 'type': 'message', 'role': 'assistant',
        'model': model, 'content': [], 'stop_reason': None,
        'usage': {'input_tokens': 128, 'output_tokens': 1}})
    yield event('content_block_start', index=0,
                content_block={'type': 'text', 'text': ''})
    for at in range(0, len(text), 8192):
        yield event('content_block_delta', index=0,
                    delta={'type': 'text_delta', 'text': text[at:at + 8192]})
    yield event('content_block_stop', index=0)
    yield event('message_delta', delta={'stop_reason': 'end_turn', 'stop_sequence': None},
                usage={'output_tokens': 128})
    yield event('message_stop')


class LocalHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def body(self):
        length = int(self.headers.get('content-length', '0'))
        if not 0 < length <= MAX_BODY:
            raise ValueError('request outside experiment byte bound')
        if self.headers.get('x-api-key') != 'scripted':
            raise ValueError('only the dummy experiment key is accepted')
        return self.rfile.read(length)

    def begin_stream(self):
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.send_header('transfer-encoding', 'chunked')
        if hasattr(self, 'digest'):
            self.send_header('x-lab-sha256', self.digest)
        self.end_headers()

    def chunk(self, data):
        self.wfile.write(b'%x\r\n' % len(data) + data + b'\r\n')
        self.wfile.flush()


class Backend(LocalHandler):
    def do_POST(self):
        try:
            wire = self.body()
            # This delay models upload serialization only. It is not a WAN,
            # TCP congestion, TLS, model prefill, or a measured uplink.
            rate = float(self.headers.get('x-lab-mbps', '0'))
            if rate > 0:
                time.sleep(len(wire) * 8 / (rate * 1_000_000))
            raw = gzip.decompress(wire) if self.headers.get('content-encoding') == 'gzip' else wire
            body = json.loads(raw)
            self.digest = hashlib.sha256(raw).hexdigest()
            asked = latest(body)
            answer = history() if body['model'] == 'gzip-experiment' and 'gzip-seed' in asked else 'gzip-probe-ok'
            self.begin_stream()
            for chunk in events(body['model'], answer):
                self.chunk(chunk)
            self.wfile.write(b'0\r\n\r\n')
        except (ValueError, OSError):
            self.close_connection = True


class Proxy(LocalHandler):
    def do_POST(self):
        try:
            raw = self.body()
            config = json.loads((self.server.directory / 'mode.json').read_text())
            encoding = config['encoding']
            if encoding not in ('identity', 'gzip'):
                raise ValueError('unknown encoding')
            start = time.perf_counter()
            wire = gzip.compress(raw, compresslevel=config.get('level', 6), mtime=0) if encoding == 'gzip' else raw
            compressed_at = time.perf_counter()
            headers = {'content-type': 'application/json', 'x-api-key': 'scripted',
                       'x-lab-mbps': str(config['mbps'])}
            if encoding == 'gzip':
                headers['content-encoding'] = 'gzip'
            with closing(http.client.HTTPConnection('127.0.0.1', 18746, timeout=120)) as upstream:
                upstream.request('POST', '/v1/messages', wire, headers)
                response = upstream.getresponse()
                if response.status != 200:
                    raise ValueError('local backend refused the request')
                if response.getheader('x-lab-sha256') != hashlib.sha256(raw).hexdigest():
                    raise ValueError('decoded request differs from the original bytes')
                self.begin_stream()
                first = None
                while chunk := response.read1(8192):
                    if first is None:
                        first = time.perf_counter()
                    self.chunk(chunk)
                self.wfile.write(b'0\r\n\r\n')
            end = time.perf_counter()
            if 'gzip-probe' in latest(json.loads(raw)):
                digest = hashlib.sha256(raw).hexdigest()
                with self.server.lock:
                    (self.server.directory / (digest + '.json')).write_bytes(raw)
                    row = {'sha256': digest, 'encoding': encoding,
                           'level': config.get('level', 6), 'simulated_mbps': config['mbps'],
                           'raw_bytes': len(raw), 'wire_bytes': len(wire),
                           'compress_ms': (compressed_at - start) * 1000,
                           'first_chunk_ms': (first - start) * 1000,
                           'complete_ms': (end - start) * 1000}
                    with (self.server.directory / 'requests.jsonl').open('a') as output:
                        output.write(json.dumps(row) + '\n')
        except (ValueError, OSError, http.client.HTTPException):
            self.close_connection = True


def mode(directory, encoding, mbps, level):
    config = directory / 'mode.json'
    temporary = config.with_suffix('.tmp')
    temporary.write_text(json.dumps({'encoding': encoding, 'mbps': mbps, 'level': level}))
    temporary.replace(config)


def serve(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not (directory / 'mode.json').exists():
        mode(directory, 'identity', 0, 6)
    backend = ThreadingHTTPServer(('127.0.0.1', 18746), Backend)
    proxy = ThreadingHTTPServer(('127.0.0.1', 18744), Proxy)
    proxy.directory, proxy.lock = directory, threading.Lock()
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    try:
        proxy.serve_forever()
    finally:
        proxy.server_close()
        backend.shutdown()
        backend.server_close()


def replay(directory, capture, count, rates):
    raw = capture.read_bytes()
    for rate in rates:
        for index in range(count):
            # Alternation avoids attributing warmup or monotonic load to gzip.
            order = ('identity', 'gzip') if index % 2 == 0 else ('gzip', 'identity')
            for encoding in order:
                mode(directory, encoding, rate, 6)
                with closing(http.client.HTTPConnection('127.0.0.1', 18744, timeout=120)) as connection:
                    connection.request('POST', '/v1/messages', raw, {'x-api-key': 'scripted'})
                    response = connection.getresponse()
                    answer = response.read()
                    assert response.status == 200 and b'gzip-probe-ok' in answer
                    assert b'message_stop' in answer


def summary(directory):
    groups = {}
    for line in (directory / 'requests.jsonl').read_text().splitlines():
        row = json.loads(line)
        key = (row['sha256'], row['simulated_mbps'], row['encoding'], row['level'])
        groups.setdefault(key, []).append(row)
    # Validate every group before printing any apparently usable summary.
    for key, rows in groups.items():
        if len({(r['raw_bytes'], r['wire_bytes']) for r in rows}) != 1:
            raise ValueError(f'inconsistent byte sizes in summary group {key}')
    for key, rows in sorted(groups.items()):
        print(json.dumps({'sha256': key[0], 'simulated_mbps': key[1], 'encoding': key[2],
                          'level': key[3],
                          'samples': len(rows), 'raw_bytes': rows[0]['raw_bytes'],
                          'wire_bytes': rows[0]['wire_bytes'],
                          **{field: round(statistics.median(r[field] for r in rows), 3)
                             for field in ('compress_ms', 'first_chunk_ms', 'complete_ms')}}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['serve', 'mode', 'replay', 'summary'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--encoding', choices=['identity', 'gzip'], default='identity')
    parser.add_argument('--mbps', type=float, default=0)
    parser.add_argument('--level', type=int, choices=range(1, 10), default=6)
    parser.add_argument('--capture', type=Path)
    parser.add_argument('--count', type=int, default=7)
    parser.add_argument('--rates', type=float, nargs='+', default=[0, 1, 10, 100])
    args = parser.parse_args()
    if args.mbps < 0 or args.count < 1 or any(rate < 0 for rate in args.rates):
        parser.error('rates must be nonnegative and count must be positive')
    if args.action == 'serve':
        serve(args.directory)
    elif args.action == 'mode':
        mode(args.directory, args.encoding, args.mbps, args.level)
    elif args.action == 'replay':
        if args.capture is None:
            parser.error('replay requires --capture')
        replay(args.directory, args.capture, args.count, args.rates)
    else:
        summary(args.directory)


if __name__ == '__main__':
    main()
