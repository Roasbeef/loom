#!/usr/bin/env python3
"""Startup time and resident memory of the release daemon and client.

This is the body of `make bench-startup-memory`. It drives the built
self-contained releases (build/release/loom and build/release/loom-client)
through six scenarios, each from a fresh private state root, and reports
wall-clock and peak resident memory per process:

  a  daemon cold boot     loomd until it prints its listening line
  b  client cold start    loom with no daemon running, until its first frame;
                          the client bootstraps the daemon itself
  c  client attach        loom against a running daemon, until its first frame
  d  one-shot command     `loom sessions list` against a running daemon
  e  session growth       ten sessions admitted over the control socket; the
                          time is one admission, the memory is the daemon's
                          growth per session between the first and the tenth
  f  long session         loom attached to a copy of a real session database
                          (DB=...), until its first frame and until the
                          transcript has been drawn

Why each measurement is taken the way it is:

The first frame is the end of the first synchronised update after the client
opens the alternate screen: the moment a person sees a drawn screen, not a
blank one. The client runs under a pseudo-terminal sized 120x40 that answers
the primary device attributes query, as every real terminal does. Without
that answer the client's graphics probe would wait out its 200 ms timeout and
the bench would be timing the timeout.

Peak RSS comes from wait4's ru_maxrss for every process the bench starts
itself, which is the true high-water mark of that process. The daemon the
client starts in scenario b is not the bench's child, so its figure is the
RSS sampled by ps at the first frame and is marked as a sample.

The BEAM's own erlang:memory/0 breakdown is taken by one extra run per
scenario with --profile, through the release's own loom-profile census.
Profiling names the node and starts distribution, which costs startup time,
so the timed runs never use it.

Every scenario runs under its own HOME so the operator's ~/.claude and
~/.loom are never read, with a minimal PATH, and with the smoke catalogue
(scripts/release-smoke.toml) whose only model is an unreachable loopback
port: nothing here can make a provider request.

Usage:
  scripts/bench_startup_memory.py [--runs N] [--only abcdef] [--db PATH]
                                  [--label NAME] [--compare RESULTS.json]

Results are also written as JSON to build/bench-startup-memory/<label>.json,
and --compare prints the change against an earlier file.
"""

import argparse
import base64
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import fcntl
import termios

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_REL = os.path.join(REPO, "build", "release", "loom")
CLIENT_REL = os.path.join(REPO, "build", "release", "loom-client")
LOOMD = os.path.join(SERVER_REL, "bin", "loomd")
LOOM = os.path.join(CLIENT_REL, "bin", "loom")
CONFIG = os.path.join(REPO, "scripts", "release-smoke.toml")
OUT_DIR = os.path.join(REPO, "build", "bench-startup-memory")

ROWS, COLS = 40, 120
ALT_SCREEN = b"\x1b[?1049h"
SYNC_END = b"\x1b[?2026l"
DA1_QUERY = b"\x1b[c"

# A VT220-class answer naming no graphics. It ends the client's probe the way
# a terminal that cannot draw images ends it, so no scenario pays the timeout.
DA1_REPLY = b"\x1b[?62;22c"

READY_LINE = "listening on ws://"
MEMORY_KEYS = ("total", "processes", "binary", "ets", "code", "atom")

# Every process the bench started and has not yet reaped, so an interrupted
# run leaves no daemon behind holding a port and a state lock.
LIVE = set()


class BenchError(Exception):
    pass


def now_ms():
    return time.monotonic() * 1000.0


# ---------------------------------------------------------------- profiles


class Profile:
    """A private state root, workspace and HOME for one run.

    The workspace is its own git repository because the client canonicalises
    a workspace to its repository root, and the profile lives inside this
    checkout: without the nested repository every run would be a session of
    the Loom checkout itself. Nothing may live under /tmp, where code mode
    refuses a capability socket.
    """

    def __init__(self, name):
        self.root = os.path.join(OUT_DIR, "runs", name)
        shutil.rmtree(self.root, ignore_errors=True)
        self.home = os.path.join(self.root, "home")
        self.state = os.path.join(self.root, "state")
        self.work = os.path.join(self.root, "work")
        for directory in (self.home, self.state, self.work):
            os.makedirs(directory)
        subprocess.run(["git", "init", "-q", self.work], check=True)
        self.env = {
            "HOME": self.home,
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
        }

    def remove(self):
        shutil.rmtree(self.root, ignore_errors=True)


# ------------------------------------------------------------------ daemon


class Daemon:
    """A loomd the bench started, with its output in a file.

    The output goes to a file rather than a pipe because the daemon logs
    continuously and nothing would drain a pipe once it was ready.
    """

    def __init__(self, profile, profiled=False, extra=()):
        self.profile = profile
        self.log = os.path.join(profile.root, "loomd.log")
        args = [LOOMD, "--state-dir", profile.state, "--config", CONFIG] + list(extra)
        if profiled:
            args.append("--profile")
        self.started = now_ms()
        with open(self.log, "wb") as out:
            self.proc = subprocess.Popen(
                args, cwd=profile.work, env=profile.env,
                stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        LIVE.add(self.proc.pid)
        self.ready_ms = self._await_ready()
        self.port = self._port()

    def _await_ready(self):
        deadline = self.started + 60_000
        while now_ms() < deadline:
            with open(self.log, "rb") as log:
                if READY_LINE.encode() in log.read():
                    return now_ms() - self.started
            if self.proc.poll() is not None:
                raise BenchError("loomd exited before listening:\n" + tail(self.log))
            time.sleep(0.002)
        raise BenchError("loomd never listened:\n" + tail(self.log))

    def _port(self):
        with open(self.log, encoding="utf-8", errors="replace") as log:
            match = re.search(r"listening on ws://127\.0\.0\.1:(\d+)", log.read())
        return int(match.group(1))

    def rss_kib(self):
        return ps_rss_kib(self.proc.pid)

    def attach_line(self):
        with open(self.log, encoding="utf-8", errors="replace") as log:
            return parse_attach(log.read())

    def stop(self):
        """Stops the daemon and answers its peak RSS in KiB."""
        return terminate(self.proc.pid)


def terminate(pid, grace_s=20):
    """SIGTERM, then SIGKILL after the grace, answering ru_maxrss in KiB."""
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace_s
    while True:
        reaped, _, usage = os.wait4(pid, os.WNOHANG)
        if reaped == pid:
            LIVE.discard(pid)
            return usage.ru_maxrss / 1024.0
        if time.monotonic() > deadline:
            os.kill(pid, signal.SIGKILL)
            _, _, usage = os.wait4(pid, 0)
            LIVE.discard(pid)
            return usage.ru_maxrss / 1024.0
        time.sleep(0.01)


def stop_foreign(pid, grace_s=20):
    """Stops a process the bench did not start and so cannot reap."""
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + grace_s
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.02)
    os.kill(pid, signal.SIGKILL)


def ps_rss_kib(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return float(out) if out else 0.0


def tail(path, lines=30):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return "".join(handle.readlines()[-lines:])
    except OSError:
        return "(no log)"


# ------------------------------------------------------------------ client


class Client:
    """A loom terminal client under a pseudo-terminal.

    The reader answers the primary device attributes query and timestamps
    the first frame. Output read after the first frame is kept only to find
    when the screen settles, and the descriptor is drained until the client
    is stopped so it never blocks on a full terminal buffer.
    """

    def __init__(self, profile, args, extra_env=None):
        env = dict(profile.env)
        env.update(extra_env or {})
        argv = [LOOM] + args
        self.started = now_ms()
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(profile.work)
                os.execve(LOOM, argv, env)
            finally:
                os._exit(127)
        LIVE.add(pid)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.output = b""
        self.first_frame_ms = None
        self.settled_ms = None

    def _read(self, timeout_s):
        ready, _, _ = select.select([self.fd], [], [], timeout_s)
        if not ready:
            return None
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:
            return b""
        if DA1_QUERY in chunk:
            os.write(self.fd, DA1_REPLY)
        return chunk

    def await_first_frame(self, within_ms=60_000):
        deadline = self.started + within_ms
        while now_ms() < deadline:
            chunk = self._read(0.05)
            if chunk is None:
                continue
            if chunk == b"":
                raise BenchError("client exited before its first frame:\n"
                                 + strip_ansi(self.output)[-2000:])
            self.output += chunk
            opened = self.output.find(ALT_SCREEN)
            if opened >= 0 and self.output.find(SYNC_END, opened) >= 0:
                self.first_frame_ms = now_ms() - self.started
                return self.first_frame_ms
        raise BenchError("no first frame within %d ms:\n%s"
                         % (within_ms, strip_ansi(self.output)[-2000:]))

    def await_text(self, pattern, within_ms=60_000):
        """Answers when the screen first shows text matching `pattern`.

        The match is over the output with escapes removed and spaces
        dropped, because the frame differ writes words in separate runs.
        """
        deadline = self.started + within_ms
        compiled = re.compile(pattern)
        while now_ms() < deadline:
            if compiled.search(strip_ansi(self.output).replace(" ", "")):
                return now_ms() - self.started
            chunk = self._read(0.02)
            if chunk is None:
                continue
            if chunk == b"":
                break
            self.output += chunk
        raise BenchError("screen never showed %r:\n%s"
                         % (pattern, strip_ansi(self.output)[-2000:]))

    def await_settled(self, quiet_ms=400, within_ms=30_000):
        """Waits until no substantial output arrives for `quiet_ms`.

        The client repaints its status line every second with a few dozen
        bytes; those small writes are not drawing, so they do not count.
        """
        last = now_ms()
        deadline = last + within_ms
        while now_ms() < deadline:
            chunk = self._read(0.02)
            if chunk is None:
                if now_ms() - last >= quiet_ms:
                    break
                continue
            if chunk == b"":
                break
            if len(chunk) >= 64:
                last = now_ms()
        self.settled_ms = last - self.started
        return self.settled_ms

    def drain(self, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            chunk = self._read(0.02)
            if chunk:
                self.output += chunk

    def stop(self):
        """Kills the client and answers its peak RSS in KiB.

        The terminal is read until the client is reaped. A process whose
        output is still queued on its terminal does not finish exiting
        until that output has been read, so a blocking wait here would
        hang on any client that drew more than the buffer holds.
        """
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        while True:
            reaped, _, usage = os.wait4(self.pid, os.WNOHANG)
            if reaped == self.pid:
                break
            self._read(0.01)
        LIVE.discard(self.pid)
        os.close(self.fd)
        return usage.ru_maxrss / 1024.0


def one_shot(profile, args):
    """Runs a non-interactive client command, answering (ms, peak RSS KiB)."""
    started = now_ms()
    proc = subprocess.Popen([LOOM] + args, cwd=profile.work, env=profile.env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    LIVE.add(proc.pid)
    output = proc.stdout.read()
    _, status, usage = os.wait4(proc.pid, 0)
    elapsed = now_ms() - started
    LIVE.discard(proc.pid)
    if os.waitstatus_to_exitcode(status) != 0:
        raise BenchError("loom %s failed:\n%s" % (" ".join(args), output.decode(errors="replace")))
    return elapsed, usage.ru_maxrss / 1024.0


def client_args(profile, *extra):
    return ["--state-dir", profile.state, "--server", LOOMD, "--config", CONFIG,
            "--workspace", profile.work] + list(extra)


# --------------------------------------------------------- control socket


class Control:
    """The daemon's control websocket, as the release probe speaks it.

    Requests are strictly sequential, so a reply is the next frame whose
    reply_to matches; anything else the daemon pushes is skipped.
    """

    def __init__(self, profile, port):
        with open(os.path.join(profile.state, "owner.token")) as handle:
            token = handle.read().strip()
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET /v2/control HTTP/1.1\r\n"
            "Host: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
            "Authorization: Bearer %s\r\n\r\n" % (port, key, token)).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise BenchError("control upgrade refused: %r" % head[:200])
        self.next_id = 1

    def _exact(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise BenchError("control socket closed")
            data += chunk
        return data

    def _send(self, opcode, payload):
        mask = os.urandom(4)
        header = bytes([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _frame(self):
        while True:
            first, second = self._exact(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._exact(8))[0]
            payload = self._exact(length)
            if opcode == 0x9:
                self._send(0xA, payload)
            elif opcode == 0x8:
                raise BenchError("control socket closed by the daemon")
            elif opcode == 0x1:
                return json.loads(payload)

    def request(self, command, body):
        ident = self.next_id
        self.next_id += 1
        self._send(0x1, json.dumps(
            {"v": 2, "id": ident, "cmd": command, "body": body}).encode())
        while True:
            frame = self._frame()
            if frame.get("reply_to") != ident:
                continue
            if frame.get("event") == "error":
                raise BenchError("%s refused: %s" % (command, json.dumps(frame)))
            return frame.get("body", {})

    def create_session(self, profile, key):
        created = self.request("sessions.create", {
            "request_key": key, "workspace": profile.work,
            "name": key, "configuration": CONFIG})
        ident = created["session_id"]
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            view = self.request("sessions.get", {"session_id": ident})
            if view.get("status", {}).get("state") == "resident":
                return ident
            time.sleep(0.01)
        raise BenchError("session %s never became resident" % ident)

    def close(self):
        self.sock.close()


# ------------------------------------------------------------------ census


ANSI = re.compile(rb"\x1b(\[[0-9;?>=]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|_[^\x1b]*\x1b\\|P[^\x1b]*\x1b\\|[()][0-9A-B]|[=>78])")


def strip_ansi(data):
    if isinstance(data, str):
        data = data.encode()
    return ANSI.sub(b"", data).decode(errors="replace")


def parse_attach(text):
    """The `attach: <tool> <node> <cookie-home>` line a --profile launch prints."""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("attach: "):
            parts = line[len("attach: "):].split()
            if len(parts) == 3:
                return parts
    return None


def census(attach, label):
    """erlang:memory/0 of a profiled node in MiB, through its loom-profile."""
    if attach is None:
        raise BenchError("no profiling attach line for " + label)
    tool, node, cookie_home = attach
    result = subprocess.run([tool, node, cookie_home, label], capture_output=True,
                            text=True, timeout=60)
    values, top = {}, []
    section = None
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("erlang:memory/0"):
            section = "memory"
            continue
        if section == "memory":
            match = re.match(r"(\w+)\s+([\d.]+) MiB$", stripped)
            if match:
                values[match.group(1)] = float(match.group(2))
                continue
            section = None
    if "total" not in values:
        raise BenchError("census of %s returned no erlang:memory/0:\n%s%s"
                         % (label, result.stdout[-1500:], result.stderr[-1500:]))
    return {key: values.get(key, 0.0) for key in MEMORY_KEYS}


def daemon_log_attach(profile):
    """Finds the attach line a client-started daemon wrote to its own log."""
    for base, _, files in os.walk(profile.state):
        for name in files:
            if name.endswith(".log"):
                attach = parse_attach(tail(os.path.join(base, name), 400))
                if attach:
                    return attach
    return None


def client_attach(client):
    return parse_attach(strip_ansi(client.output))


# --------------------------------------------------------------- scenarios


def series():
    return {"time_ms": [], "rss_kib": []}


def scenario_a(runs):
    """Daemon cold boot to its listening line."""
    daemon = series()
    for i in range(runs):
        profile = Profile("a-%d" % i)
        d = Daemon(profile)
        daemon["time_ms"].append(d.ready_ms)
        daemon["rss_kib"].append(d.stop())
        profile.remove()
    profile = Profile("a-census")
    d = Daemon(profile, profiled=True)
    memory = {"daemon": census(d.attach_line(), "a daemon ready")}
    d.stop()
    profile.remove()
    return {"daemon": daemon}, memory


def endpoint_pid(profile):
    path = os.path.join(profile.state, "daemon.endpoint")
    with open(path) as handle:
        return int(json.load(handle)["pid"])


def scenario_b(runs):
    """Client cold start with no daemon, to its first frame."""
    client, daemon = series(), series()
    for i in range(runs):
        profile = Profile("b-%d" % i)
        c = Client(profile, client_args(profile))
        client["time_ms"].append(c.await_first_frame())
        pid = endpoint_pid(profile)
        daemon["rss_kib"].append(ps_rss_kib(pid))
        c.await_settled()
        client["rss_kib"].append(c.stop())
        stop_foreign(pid)
        profile.remove()
    profile = Profile("b-census")
    c = Client(profile, client_args(profile, "--profile"))
    c.await_first_frame()
    c.drain(0.5)
    memory = {"client": census(client_attach(c), "b client first frame")}
    pid = endpoint_pid(profile)
    memory["daemon"] = census(daemon_log_attach(profile), "b daemon first frame")
    c.stop()
    stop_foreign(pid)
    profile.remove()
    daemon["sampled"] = True
    return {"client": client, "daemon": daemon}, memory


def scenario_c(runs):
    """Client attach to a running daemon, to its first frame."""
    client, daemon = series(), series()
    for i in range(runs):
        profile = Profile("c-%d" % i)
        d = Daemon(profile)
        c = Client(profile, client_args(profile))
        client["time_ms"].append(c.await_first_frame())
        c.await_settled()
        client["rss_kib"].append(c.stop())
        daemon["rss_kib"].append(d.stop())
        profile.remove()
    profile = Profile("c-census")
    d = Daemon(profile, profiled=True)
    c = Client(profile, client_args(profile, "--profile"))
    c.await_first_frame()
    c.drain(0.5)
    memory = {"client": census(client_attach(c), "c client first frame"),
              "daemon": census(d.attach_line(), "c daemon attached")}
    c.stop()
    d.stop()
    profile.remove()
    return {"client": client, "daemon": daemon}, memory


def scenario_d(runs):
    """A one-shot client command against a running daemon."""
    client = series()
    profile = Profile("d")
    d = Daemon(profile, profiled=True)
    for _ in range(runs):
        elapsed, rss = one_shot(profile, ["sessions", "list"] + client_args(profile)[:-2])
        client["time_ms"].append(elapsed)
        client["rss_kib"].append(rss)
    memory = {"daemon": census(d.attach_line(), "d daemon after one-shots")}
    d.stop()
    profile.remove()
    return {"client": client}, memory


# The daemon admits eight sessions by default; the growth measurement needs ten.
GROWTH_CAPACITY = ("--capacity", "16")


def scenario_e(runs, sessions=10):
    """Daemon growth per admitted session, between the first and the tenth."""
    admit, growth = series(), series()
    for i in range(runs):
        profile = Profile("e-%d" % i)
        d = Daemon(profile, extra=GROWTH_CAPACITY)
        control = Control(profile, d.port)
        rss = []
        for k in range(sessions):
            started = now_ms()
            control.create_session(profile, "bench-%d" % k)
            admit["time_ms"].append(now_ms() - started)
            if k in (0, sessions - 1):
                time.sleep(0.2)
                rss.append(d.rss_kib())
        control.close()
        growth["rss_kib"].append((rss[1] - rss[0]) / (sessions - 1))
        admit["rss_kib"].append(d.stop())
        profile.remove()
    profile = Profile("e-census")
    d = Daemon(profile, profiled=True, extra=GROWTH_CAPACITY)
    control = Control(profile, d.port)
    control.create_session(profile, "bench-0")
    one = census(d.attach_line(), "e one session")
    for k in range(1, sessions):
        control.create_session(profile, "bench-%d" % k)
    ten = census(d.attach_line(), "e ten sessions")
    control.close()
    d.stop()
    profile.remove()
    per = {key: (ten[key] - one[key]) / (sessions - 1) for key in MEMORY_KEYS}
    return {"daemon": admit, "per_session": growth}, {"daemon@1": one, "daemon@10": ten, "per_session": per}


def session_id_of(db):
    out = subprocess.run(["sqlite3", "-readonly", db, "select metadata from session"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)["session_id"]


def install_session(profile, db, ident):
    """Registers a copy of `db` beside a session the daemon created itself.

    The copy is a SQLite backup rather than a file copy, so a database some
    live daemon still has open is copied consistently. The catalogue rows
    are the two a created session has: its registration, naming this
    profile's own sessions directory and workspace as the daemon insists,
    and its membership of the workspace's domain, which the earlier
    creation made.
    """
    target = os.path.join(profile.state, "sessions", ident + ".db")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    subprocess.run(["sqlite3", db, ".backup '%s'" % target], check=True)
    subprocess.run(["sqlite3", target, "delete from writer_lease"], check=True)
    created = int(time.time() * 1000)
    sql = ("insert into catalogue_sessions(session_id, path, workspace, name, "
           "configuration, created_at, request_key, state) values "
           "('%s', '%s', '%s', 'bench long session', '%s', %d, 'bench-long', 'saved');"
           % (ident, target, profile.work, CONFIG, created))
    sql += ("insert into catalogue_domain_sessions select '%s', domain_id "
            "from catalogue_domain_sessions limit 1;" % ident)
    subprocess.run(["sqlite3", os.path.join(profile.state, "catalogue.db"), sql], check=True)


def long_profile(name, db, ident):
    profile = Profile(name)
    d = Daemon(profile)
    control = Control(profile, d.port)
    control.create_session(profile, "bench-domain")
    control.close()
    d.stop()
    install_session(profile, db, ident)
    return profile


# The composer's title once a session lane is attached and its transcript has
# been drawn; before that it offers /sessions to reconnect.
ATTACHED = r"Enter(sends|queues)"


def scenario_f(runs, db):
    """A client attached to a long real session, and the daemon serving it."""
    ident = session_id_of(db)
    client, drawn, daemon = series(), series(), series()
    for i in range(runs):
        profile = long_profile("f-%d" % i, db, ident)
        d = Daemon(profile)
        c = Client(profile, client_args(profile, "--session", ident))
        client["time_ms"].append(c.await_first_frame())
        drawn["time_ms"].append(c.await_text(ATTACHED))
        c.await_settled()
        client["rss_kib"].append(c.stop())
        daemon["rss_kib"].append(d.stop())
        profile.remove()
    profile = long_profile("f-census", db, ident)
    d = Daemon(profile, profiled=True)
    c = Client(profile, client_args(profile, "--session", ident, "--profile"))
    c.await_first_frame()
    c.await_text(ATTACHED)
    c.await_settled()
    memory = {"client": census(client_attach(c), "f client drawn"),
              "daemon": census(d.attach_line(), "f daemon serving")}
    c.stop()
    d.stop()
    profile.remove()
    return {"client": client, "client drawn": drawn, "daemon": daemon}, memory


# ----------------------------------------------------------------- report


def median(values):
    ordered = sorted(values)
    n = len(ordered)
    if n == 0:
        return 0.0
    mid = n // 2
    return ordered[mid] if n % 2 else (ordered[mid - 1] + ordered[mid]) / 2.0


def p95(values):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    rank = max(1, -(-95 * len(ordered) // 100))
    return ordered[rank - 1]


TITLES = {
    "a": "daemon cold boot",
    "b": "client cold start",
    "c": "client attach",
    "d": "one-shot command",
    "e": "session growth",
    "f": "long session",
}


def summarise(results):
    rows = {}
    for scenario, (measured, _) in results.items():
        for process, data in measured.items():
            rows["%s %s" % (scenario, process)] = {
                "time_median_ms": median(data["time_ms"]),
                "time_p95_ms": p95(data["time_ms"]),
                "rss_median_mib": median(data["rss_kib"]) / 1024.0,
                "rss_max_mib": max(data["rss_kib"], default=0.0) / 1024.0,
                "sampled": data.get("sampled", False),
                "has_time": bool(data["time_ms"]),
                "has_rss": bool(data["rss_kib"]),
                "n": max(len(data["time_ms"]), len(data["rss_kib"])),
            }
    return rows


def cell(row, key, form, old):
    """One table cell, or "-" for a row that has no such measurement."""
    if not row["has_" + key.split("_")[0]]:
        return "-"
    return (form % row[key]) + fmt_delta(row[key], old.get(key))


def fmt_delta(new, old):
    if old is None or old == 0:
        return ""
    return " (%+.0f%%)" % (100.0 * (new - old) / old)


def print_report(rows, results, baseline):
    head = "%-24s %4s %18s %18s %18s %18s" % (
        "scenario / process", "n", "time median ms", "time p95 ms",
        "rss median MiB", "rss max MiB")
    print(head)
    print("-" * len(head))
    for key, row in rows.items():
        old = (baseline or {}).get(key, {})
        note = " *" if row["sampled"] else ""
        print("%-24s %4d %18s %18s %18s %18s%s" % (
            key, row["n"],
            cell(row, "time_median_ms", "%.0f", old),
            cell(row, "time_p95_ms", "%.0f", old),
            cell(row, "rss_median_mib", "%.1f", old),
            cell(row, "rss_max_mib", "%.1f", old),
            note))
    print()
    print("Client time is to the first frame; 'f client drawn' is until the long")
    print("transcript is drawn. 'e daemon' time is one admission and its RSS the peak")
    print("with ten sessions; 'e per_session' is growth per session from 1 to 10.")
    print("* = RSS sampled by ps at the first frame, not a peak.")
    print()
    print("erlang:memory/0 at the census point, MiB")
    head = "%-24s" % "scenario / process" + "".join("%11s" % k for k in MEMORY_KEYS)
    print(head)
    print("-" * len(head))
    for scenario, (_, memory) in results.items():
        for process, values in memory.items():
            print("%-24s" % ("%s %s" % (scenario, process))
                  + "".join("%11.2f" % values[k] for k in MEMORY_KEYS))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--only", default="abcdef")
    parser.add_argument("--db", default=os.environ.get("DB", ""))
    parser.add_argument("--label", default="latest")
    parser.add_argument("--compare", default="")
    options = parser.parse_args()

    for path in (LOOMD, LOOM):
        if not os.access(path, os.X_OK):
            sys.exit("bench: no release at %s; run make release release-client" % path)
    if "f" in options.only and not options.db:
        sys.exit("bench: scenario f needs DB=<a session .db>; pass --only without f to skip it")

    commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    print("bench-startup-memory at %s, %d runs per scenario" % (commit, options.runs))

    runners = {
        "a": lambda: scenario_a(options.runs),
        "b": lambda: scenario_b(options.runs),
        "c": lambda: scenario_c(options.runs),
        "d": lambda: scenario_d(options.runs),
        "e": lambda: scenario_e(options.runs),
        "f": lambda: scenario_f(options.runs, options.db),
    }
    results = {}
    for key in "abcdef":
        if key in options.only:
            started = time.monotonic()
            results[key] = runners[key]()
            print("  %s %-18s %5.1f s" % (key, TITLES[key], time.monotonic() - started),
                  file=sys.stderr)

    rows = summarise(results)
    baseline = None
    if options.compare:
        with open(options.compare) as handle:
            baseline = json.load(handle)["rows"]
    print()
    print_report(rows, results, baseline)

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, options.label + ".json")
    with open(out, "w") as handle:
        json.dump({"commit": commit, "runs": options.runs, "rows": rows,
                   "memory": {k: m for k, (_, m) in results.items()},
                   "raw": {k: r for k, (r, _) in results.items()}}, handle, indent=1)
    print()
    print("wrote " + os.path.relpath(out, REPO))


def cleanup(*_):
    for pid in list(LIVE):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    sys.exit(130)


if __name__ == "__main__":
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)
    try:
        main()
    except BenchError as error:
        for pid in list(LIVE):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        sys.exit("bench: %s" % error)
