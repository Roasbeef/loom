#!/usr/bin/env python3
"""One control command to a local daemon, for scripts/web_seed/seed.sh.

The daemon's control socket (`/v2/control`) is a WebSocket that takes the
owner's bearer token, greets with a `hello` naming its epoch, and answers
one JSON request per id. The standard library has no WebSocket client, so
this speaks just enough of RFC 6455 for one exchange: the handshake, masked
text frames out, and unmasked frames in.

Usage:
  control.py STATE PORT create NAME WORKSPACE     prints the session id
  control.py STATE PORT open SESSION
  control.py STATE PORT link SOURCE TARGET        main to main, may_wake
  control.py STATE PORT send SOURCE TARGET ID TEXT
  control.py STATE PORT ui SESSION operator|observer   prints the page link
"""

import base64
import json
import os
import socket
import struct
import sys


def frame(text):
    data = text.encode()
    mask = os.urandom(4)
    head = bytes([0x81])
    if len(data) < 126:
        head += bytes([0x80 | len(data)])
    elif len(data) < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", len(data))
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", len(data))
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data))


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise SystemExit("control: the daemon closed the socket")
        data += chunk
    return data


def read_frame(sock):
    first, second = read_exact(sock, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(sock, 8))[0]
    payload = read_exact(sock, length)
    return first & 0x0F, payload


def connect(state, port):
    token = open(os.path.join(state, "owner.token")).read().strip()
    sock = socket.create_connection(("127.0.0.1", int(port)))
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((
        "GET /v2/control HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
        "Authorization: Bearer %s\r\n\r\n" % (port, key, token)).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += sock.recv(1)
    if b" 101 " not in head.split(b"\r\n")[0]:
        raise SystemExit("control: upgrade refused: " + head.split(b"\r\n")[0].decode())
    return sock


def events(sock):
    while True:
        opcode, payload = read_frame(sock)
        if opcode == 1:
            yield json.loads(payload)
        elif opcode == 8:
            raise SystemExit("control: the daemon closed the socket")


def main():
    state, port, command, rest = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    sock = connect(state, port)
    stream = events(sock)
    epoch = next(e for e in stream if e.get("event") == "hello")["body"]["epoch"]
    if command == "create":
        cmd, body = "sessions.create", {"request_key": "seed-" + rest[0], "workspace": rest[1],
                                        "name": rest[0], "configuration": ""}
    elif command == "open":
        cmd, body = "sessions.open", {"session_id": rest[0], "epoch": epoch}
    elif command == "link":
        cmd, body = "peers.link", {"source_session": rest[0], "source_strand": "main",
                                   "target_session": rest[1], "target_strand": "main",
                                   "wake": "may_wake", "epoch": epoch}
    elif command == "send":
        cmd, body = "peers.send", {"source_session": rest[0], "source_strand": "main",
                                   "target_session": rest[1], "target_strand": "main",
                                   "message_id": rest[2], "text": rest[3], "epoch": epoch}
    elif command == "ui":
        cmd, body = "ui.link", {"session_id": rest[0], "page": rest[1]}
    else:
        raise SystemExit(__doc__)
    sock.sendall(frame(json.dumps({"v": 2, "id": 1, "cmd": cmd, "body": body})))
    reply = next(e for e in stream if e.get("reply_to") == 1)
    if reply.get("event") == "error":
        raise SystemExit("control: " + json.dumps(reply.get("body")))
    body = reply.get("body", {})
    if command == "create":
        print(body.get("session_id") or body.get("id") or json.dumps(body))
    elif command == "ui":
        print(body.get("path", json.dumps(body)))
    else:
        print(json.dumps(body))


if __name__ == "__main__":
    main()
