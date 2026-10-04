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
  f  long session         loom reopening a copy of a real session database
                          (DB=...) whose search index is already built, until
                          its first frame and until the transcript is drawn

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
                                  [--against SNAPSHOT] [--snapshot NAME]

Results are also written as JSON to build/bench-startup-memory/<label>.json,
and --compare prints the change against an earlier file. A comparison across
minutes is only as good as the machine was quiet, so for a before-and-after
--snapshot NAME keeps this build's releases under
build/bench-startup-memory/releases/NAME, and a later --against NAME times
that snapshot and the new build alternately, run by run, and prints the
change between them.
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


class Build:
    """One pair of self-contained releases: the server and the client.

    The bench measures this tree's build/release by default. With --against
    it also measures a snapshot of an earlier build and alternates the two
    run by run, so both are timed on the same machine in the same minutes;
    another process loading the machine then moves both, not one.
    """

    def __init__(self, name, root):
        self.name = name
        self.loomd = os.path.join(root, "loom", "bin", "loomd")
        self.loom = os.path.join(root, "loom-client", "bin", "loom")

    def check(self):
        for path in (self.loomd, self.loom):
            if not os.access(path, os.X_OK):
                sys.exit("bench: no release at %s; run make release release-client" % path)


CURRENT = Build("current", os.path.join(REPO, "build", "release"))


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

    def __init__(self, profile, build, profiled=False, extra=()):
        self.profile = profile
        self.log = os.path.join(profile.root, "loomd.log")
        args = [build.loomd, "--state-dir", profile.state, "--config", CONFIG] + list(extra)
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

    def __init__(self, profile, build, args, extra_env=None):
        env = dict(profile.env)
        env.update(extra_env or {})
        argv = [build.loom] + args
        self.started = now_ms()
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(profile.work)
                os.execve(build.loom, argv, env)
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


def one_shot(profile, build, args):
    """Runs a non-interactive client command, answering (ms, peak RSS KiB)."""
    started = now_ms()
    proc = subprocess.Popen([build.loom] + args, cwd=profile.work, env=profile.env,
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


def client_args(profile, build, *extra):
    return ["--state-dir", profile.state, "--server", build.loomd, "--config", CONFIG,
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
#
# A scenario is two functions. `once_<key>` takes one run against one build
# and answers, per process, the times and peak RSS figures that run produced.
# `census_<key>` takes the extra --profile run and answers erlang:memory/0
# per process. `measure` below calls them, alternating the builds.


def endpoint_pid(profile):
    path = os.path.join(profile.state, "daemon.endpoint")
    with open(path) as handle:
        return int(json.load(handle)["pid"])


def once_a(build, tag, _db):
    """Daemon cold boot to its listening line."""
    profile = Profile("a-" + tag)
    d = Daemon(profile, build)
    ready = d.ready_ms
    rss = d.stop()
    profile.remove()
    return {"daemon": ([ready], [rss])}


def census_a(build, _db):
    profile = Profile("a-census-" + build.name)
    d = Daemon(profile, build, profiled=True)
    memory = {"daemon": census(d.attach_line(), "a daemon ready")}
    d.stop()
    profile.remove()
    return memory


def once_b(build, tag, _db):
    """Client cold start with no daemon, to its first frame."""
    profile = Profile("b-" + tag)
    c = Client(profile, build, client_args(profile, build))
    first = c.await_first_frame()
    pid = endpoint_pid(profile)
    daemon_rss = ps_rss_kib(pid)
    c.await_settled()
    client_rss = c.stop()
    stop_foreign(pid)
    profile.remove()
    return {"client": ([first], [client_rss]), "daemon": ([], [daemon_rss])}


def census_b(build, _db):
    profile = Profile("b-census-" + build.name)
    c = Client(profile, build, client_args(profile, build, "--profile"))
    c.await_first_frame()
    c.drain(0.5)
    memory = {"client": census(client_attach(c), "b client first frame")}
    pid = endpoint_pid(profile)
    memory["daemon"] = census(daemon_log_attach(profile), "b daemon first frame")
    c.stop()
    stop_foreign(pid)
    profile.remove()
    return memory


def once_c(build, tag, _db):
    """Client attach to a running daemon, to its first frame."""
    profile = Profile("c-" + tag)
    d = Daemon(profile, build)
    c = Client(profile, build, client_args(profile, build))
    first = c.await_first_frame()
    c.await_settled()
    client_rss = c.stop()
    daemon_rss = d.stop()
    profile.remove()
    return {"client": ([first], [client_rss]), "daemon": ([], [daemon_rss])}


def census_c(build, _db):
    profile = Profile("c-census-" + build.name)
    d = Daemon(profile, build, profiled=True)
    c = Client(profile, build, client_args(profile, build, "--profile"))
    c.await_first_frame()
    c.drain(0.5)
    memory = {"client": census(client_attach(c), "c client first frame"),
              "daemon": census(d.attach_line(), "c daemon attached")}
    c.stop()
    d.stop()
    profile.remove()
    return memory


def sessions_list(profile, build):
    return ["sessions", "list"] + client_args(profile, build)


def once_d(build, tag, _db):
    """A one-shot client command against a running daemon."""
    profile = Profile("d-" + tag)
    d = Daemon(profile, build)
    elapsed, rss = one_shot(profile, build, sessions_list(profile, build))
    d.stop()
    profile.remove()
    return {"client": ([elapsed], [rss])}


def census_d(build, _db):
    profile = Profile("d-census-" + build.name)
    d = Daemon(profile, build, profiled=True)
    one_shot(profile, build, sessions_list(profile, build))
    memory = {"daemon": census(d.attach_line(), "d daemon after a one-shot")}
    d.stop()
    profile.remove()
    return memory


# The daemon admits eight sessions by default; the growth measurement needs ten.
GROWTH_CAPACITY = ("--capacity", "16")
GROWTH_SESSIONS = 10


def once_e(build, tag, _db):
    """Daemon growth per admitted session, between the first and the tenth."""
    profile = Profile("e-" + tag)
    d = Daemon(profile, build, extra=GROWTH_CAPACITY)
    control = Control(profile, d.port)
    admissions, rss = [], []
    for k in range(GROWTH_SESSIONS):
        started = now_ms()
        control.create_session(profile, "bench-%d" % k)
        admissions.append(now_ms() - started)
        if k in (0, GROWTH_SESSIONS - 1):
            time.sleep(0.2)
            rss.append(d.rss_kib())
    control.close()
    peak = d.stop()
    profile.remove()
    growth = (rss[1] - rss[0]) / (GROWTH_SESSIONS - 1)
    return {"daemon": (admissions, [peak]), "per_session": ([], [growth])}


def census_e(build, _db):
    profile = Profile("e-census-" + build.name)
    d = Daemon(profile, build, profiled=True, extra=GROWTH_CAPACITY)
    control = Control(profile, d.port)
    control.create_session(profile, "bench-0")
    one = census(d.attach_line(), "e one session")
    for k in range(1, GROWTH_SESSIONS):
        control.create_session(profile, "bench-%d" % k)
    ten = census(d.attach_line(), "e ten sessions")
    control.close()
    d.stop()
    profile.remove()
    per = {key: (ten[key] - one[key]) / (GROWTH_SESSIONS - 1) for key in MEMORY_KEYS}
    return {"daemon@1": one, "daemon@10": ten, "per_session": per}


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


def long_profile(name, build, db, ident):
    profile = Profile(name)
    d = Daemon(profile, build)
    control = Control(profile, d.port)
    control.create_session(profile, "bench-domain")
    control.close()
    d.stop()
    install_session(profile, db, ident)
    return profile


# The composer's title once a session lane is attached and its transcript has
# been drawn; before that it offers /sessions to reconnect.
ATTACHED = r"Enter(sends|queues)"


def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    total = 0.0
    for part in out.split(":"):
        total = total * 60 + float(part)
    return total


def await_idle(pid, within_s=120):
    """Waits until the process uses under 2% of a core over half a second."""
    deadline = time.monotonic() + within_s
    last = cpu_seconds(pid)
    while time.monotonic() < deadline:
        time.sleep(0.5)
        now = cpu_seconds(pid)
        if now - last < 0.01:
            return
        last = now
    raise BenchError("daemon never went idle")


def first_open(profile, build, ident):
    """Opens the long session once and lets the daemon finish with it.

    The first time a session's history enters its workspace domain, the
    daemon indexes every entry for search, and that index persists. A
    person reopening a long session paid for that once, long ago, so the
    timed runs reopen a session whose index is already built.
    """
    d = Daemon(profile, build)
    control = Control(profile, d.port)
    with open(os.path.join(profile.state, "daemon.endpoint")) as handle:
        epoch = json.load(handle)["epoch"]
    control.request("sessions.open", {"session_id": ident, "epoch": epoch})
    deadline = time.monotonic() + 60
    while control.request("sessions.get", {"session_id": ident}) \
            .get("status", {}).get("state") != "resident":
        if time.monotonic() > deadline:
            raise BenchError("long session never became resident")
        time.sleep(0.01)
    await_idle(d.proc.pid)
    control.close()
    d.stop()


# One prepared state root per build, reused by every run of scenario f, as a
# person reopens the same session in the same state.
PREPARED = {}


def long_session(build, db):
    if build.name not in PREPARED:
        ident = session_id_of(db)
        profile = long_profile("f-" + build.name, build, db, ident)
        first_open(profile, build, ident)
        PREPARED[build.name] = (profile, ident)
    return PREPARED[build.name]


def once_f(build, _tag, db):
    """A client reopening a long real session, and the daemon serving it."""
    profile, ident = long_session(build, db)
    d = Daemon(profile, build)
    c = Client(profile, build, client_args(profile, build, "--session", ident))
    first = c.await_first_frame()
    drawn = c.await_text(ATTACHED)
    c.await_settled()
    client_rss = c.stop()
    daemon_rss = d.stop()
    return {"client": ([first], [client_rss]), "client drawn": ([drawn], []),
            "daemon": ([], [daemon_rss])}


def census_f(build, db):
    profile, ident = long_session(build, db)
    d = Daemon(profile, build, profiled=True)
    c = Client(profile, build,
               client_args(profile, build, "--session", ident, "--profile"))
    c.await_first_frame()
    c.await_text(ATTACHED)
    c.await_settled()
    memory = {"client": census(client_attach(c), "f client drawn"),
              "daemon": census(d.attach_line(), "f daemon serving")}
    c.stop()
    d.stop()
    profile.remove()
    del PREPARED[build.name]
    return memory


SCENARIOS = {
    "a": ("daemon cold boot", once_a, census_a),
    "b": ("client cold start", once_b, census_b),
    "c": ("client attach", once_c, census_c),
    "d": ("one-shot command", once_d, census_d),
    "e": ("session growth", once_e, census_e),
    "f": ("long session", once_f, census_f),
}

# Rows whose RSS is a ps sample rather than a wait4 peak.
SAMPLED = {"b daemon"}


def series():
    return {"time_ms": [], "rss_kib": []}


def measure(key, builds, runs, db):
    """Runs one scenario `runs` times per build, alternating the builds.

    The order flips every run (A B, B A, ...), so a drift in the machine's
    load over the series lands on both builds equally.
    """
    _, once, census_of = SCENARIOS[key]
    measured = {build.name: {} for build in builds}
    for i in range(runs):
        order = builds if i % 2 == 0 else list(reversed(builds))
        for build in order:
            for process, (times, rss) in once(build, "%s-%d" % (build.name, i), db).items():
                row = measured[build.name].setdefault(process, series())
                row["time_ms"].extend(times)
                row["rss_kib"].extend(rss)
    memory = {build.name: census_of(build, db) for build in builds}
    return measured, memory


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


def summarise(results, name):
    rows = {}
    for scenario, (measured, _) in results.items():
        for process, data in measured[name].items():
            key = "%s %s" % (scenario, process)
            rows[key] = {
                "time_median_ms": median(data["time_ms"]),
                "time_p95_ms": p95(data["time_ms"]),
                "rss_median_mib": median(data["rss_kib"]) / 1024.0,
                "rss_max_mib": max(data["rss_kib"], default=0.0) / 1024.0,
                "sampled": key in SAMPLED,
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


def print_rows(rows, baseline):
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


def print_memory(results, name):
    head = "%-24s" % "scenario / process" + "".join("%11s" % k for k in MEMORY_KEYS)
    print(head)
    print("-" * len(head))
    for scenario, (_, memory) in results.items():
        for process, values in memory[name].items():
            print("%-24s" % ("%s %s" % (scenario, process))
                  + "".join("%11.2f" % values[k] for k in MEMORY_KEYS))


def print_report(results, rows, against_rows, baseline):
    if against_rows is not None:
        print("against (the snapshot, timed in the same window):")
        print_rows(against_rows, None)
        print()
        print("current, with its change against the snapshot:")
        print_rows(rows, against_rows)
    else:
        print_rows(rows, baseline)
    print()
    print("Client time is to the first frame; 'f client drawn' is until the long")
    print("transcript is drawn. 'e daemon' time is one admission and its RSS the peak")
    print("with ten sessions; 'e per_session' is growth per session from 1 to 10.")
    print("* = RSS sampled by ps at the first frame, not a peak.")
    for name in ([AGAINST_NAME, CURRENT.name] if against_rows is not None else [CURRENT.name]):
        print()
        print("erlang:memory/0 at the census point, MiB (%s)" % name)
        print_memory(results, name)


AGAINST_NAME = "against"


def warm_up(build):
    """One untimed daemon boot and client attach before any series.

    A release just rebuilt is not yet in the page cache, so the first run
    after a build reads it from disk. Left in, that run is the p95 of the
    first scenario and measures the disk rather than Loom.
    """
    profile = Profile("warm-up-" + build.name)
    d = Daemon(profile, build)
    c = Client(profile, build, client_args(profile, build))
    c.await_first_frame()
    c.stop()
    d.stop()
    profile.remove()


def snapshot(name):
    """Keeps a copy of this tree's releases for a later --against."""
    target = os.path.join(OUT_DIR, "releases", name)
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target)
    for part in ("loom", "loom-client"):
        shutil.copytree(os.path.join(REPO, "build", "release", part),
                        os.path.join(target, part), symlinks=True)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--only", default="abcdef")
    parser.add_argument("--db", default=os.environ.get("DB", ""))
    parser.add_argument("--label", default="latest")
    parser.add_argument("--compare", default="")
    parser.add_argument("--against", default="")
    parser.add_argument("--snapshot", default="")
    options = parser.parse_args()

    builds = [CURRENT]
    if options.against:
        root = options.against
        if not os.path.isabs(root):
            root = os.path.join(OUT_DIR, "releases", root)
        builds = [Build(AGAINST_NAME, root), CURRENT]
    for build in builds:
        build.check()
    if "f" in options.only and not options.db:
        sys.exit("bench: scenario f needs DB=<a session .db>; pass --only without f to skip it")

    commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    print("bench-startup-memory at %s, %d runs per scenario%s" % (
        commit, options.runs,
        ", alternating with " + builds[0].loomd.rsplit("/loom/bin", 1)[0] if options.against else ""))

    for build in builds:
        warm_up(build)
    results = {}
    for key in "abcdef":
        if key in options.only:
            started = time.monotonic()
            results[key] = measure(key, builds, options.runs, options.db)
            print("  %s %-18s %5.1f s" % (key, SCENARIOS[key][0], time.monotonic() - started),
                  file=sys.stderr)

    rows = summarise(results, CURRENT.name)
    against_rows = summarise(results, AGAINST_NAME) if options.against else None
    baseline = None
    if options.compare:
        with open(options.compare) as handle:
            baseline = json.load(handle)["rows"]
    print()
    print_report(results, rows, against_rows, baseline)

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, options.label + ".json")
    with open(out, "w") as handle:
        json.dump({"commit": commit, "runs": options.runs, "against": options.against,
                   "rows": rows, "rows_against": against_rows,
                   "memory": {k: m for k, (_, m) in results.items()},
                   "raw": {k: r for k, (r, _) in results.items()}}, handle, indent=1)
    print()
    print("wrote " + os.path.relpath(out, REPO))
    if options.snapshot:
        print("kept releases in " + os.path.relpath(snapshot(options.snapshot), REPO))


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
