"""Run the shipped shell, unmodified, against a fake release and stub binaries.

No container is involved. The install script is pointed at a `file://` release
directory laid out like a real one (`SHA256SUMS` plus per-platform archives),
and the run script at stub `loomd` and `loom` executables, so what is checked
is the scripts' own logic: platform selection, digest verification,
idempotence, daemon start and readiness, report passing, exit mapping,
session collection and shutdown.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import signal
import subprocess
import tarfile
import textwrap
import threading
import time
from pathlib import Path

import pytest

from loom_harbor import scripts
from tests.conftest import REPORT

PLATFORM = "linux-x86_64"
KEY = "sk-ant-secret-0123456789"


def bash(script: str, env: dict[str, str], cwd: Path, timeout: int = 60) -> subprocess.CompletedProcess:
    # The same single-argument `bash -c` the agent hands Harbor, minus Harbor's
    # own `set -o pipefail;` prefix, which bash accepts.
    base = {"PATH": os.environ["PATH"], "HOME": str(cwd)}
    return subprocess.run(
        ["bash", "-c", script], env={**base, **env}, cwd=cwd, capture_output=True, text=True, timeout=timeout
    )


def test_every_script_parses_under_bash():
    for script in (
        scripts.INSTALL_SCRIPT, scripts.RUN_SCRIPT, scripts.COLLECT_SCRIPT,
        scripts.BWRAP_PROBE, scripts.BWRAP_DISABLE, scripts.BWRAP_RESTORE,
    ):
        check = subprocess.run(["bash", "-n", "-c", script], capture_output=True, text=True)
        assert check.returncode == 0, check.stderr


def test_the_command_wrapper_survives_quotes_newlines_and_harbors_prefix(tmp_path):
    awkward = "echo 'it'\"'\"'s'; echo \"$HOME\"\nprintf '%s' 'done'"
    command = "set -o pipefail; " + scripts.bash_command(awkward)
    run = subprocess.run(["bash", "-c", command], capture_output=True, text=True, env={"HOME": "/h"})
    assert run.returncode == 0 and run.stdout.endswith("done")


# ------------------------------------------------------------------ install


def make_archive(path: Path, root: str, files: dict[str, str]) -> str:
    stage = path.parent / f".stage-{root}"
    shutil.rmtree(stage, ignore_errors=True)
    for name, body in files.items():
        target = stage / root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
        target.chmod(0o755 if name.startswith("bin/") else 0o644)
    with tarfile.open(path, "w:gz") as archive:
        archive.add(stage / root, arcname=root)
    shutil.rmtree(stage)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_release(directory: Path, version: str = "9.9.9", client_ok: bool = True) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    sums = []
    for platform in (PLATFORM, "macos-arm64"):
        server = f"loomd-{version}-{platform}"
        client = f"loom-{version}-{platform}"
        slim = f"loom-slim-{version}-{platform}"
        entries = {
            server: {"bin/loomd": "#!/bin/sh\nexit 0\n", "bin/loom-exec": "#!/bin/sh\nexit 0\n"},
            client: {"bin/loom": f"#!/bin/sh\necho 'loom {version} (abc1234, {platform})'\n"
                     if client_ok else "#!/bin/sh\necho 'cannot execute: ld.so missing' >&2\nexit 127\n"},
            slim: {"bin/loom": "#!/bin/sh\necho slim\n"},
        }
        for stem, files in entries.items():
            sums.append(f"{make_archive(directory / (stem + '.tar.gz'), stem, files)}  {stem}.tar.gz\n")
    (directory / "SHA256SUMS").write_text("".join(sorted(sums, key=lambda line: line.split()[1])))
    return directory


def install(release: Path, prefix: Path, cwd: Path, **env: str):
    return bash(
        scripts.INSTALL_SCRIPT,
        {"LOOM_PREFIX": str(prefix), "LOOM_BASE_URL": release.as_uri(), "LOOM_PLATFORM": PLATFORM, **env},
        cwd,
    )


def test_install_picks_the_platform_archives_and_ignores_slim_and_other_platforms(tmp_path):
    release = make_release(tmp_path / "release")
    prefix = tmp_path / "opt"
    run = install(release, prefix, tmp_path)
    assert run.returncode == 0, run.stderr
    assert (prefix / "server/bin/loomd").is_file() and os.access(prefix / "server/bin/loomd", os.X_OK)
    assert (prefix / "server/bin/loom-exec").is_file()
    assert "loom 9.9.9" in run.stderr
    # The client tree is the self-contained `loom-`, not `loom-slim-`, and nothing leaks into stdout.
    assert "slim" not in (prefix / "client/bin/loom").read_text()
    assert run.stdout == ""
    assert not list(prefix.glob(".work.*"))


def test_a_second_install_of_the_same_release_does_nothing(tmp_path):
    release = make_release(tmp_path / "release")
    prefix = tmp_path / "opt"
    assert install(release, prefix, tmp_path).returncode == 0
    marker = prefix / "server/bin/loomd"
    inode = marker.stat().st_ino
    again = install(release, prefix, tmp_path)
    assert again.returncode == 0 and "already installed" in again.stderr
    assert marker.stat().st_ino == inode


def test_a_different_release_replaces_the_tree(tmp_path):
    prefix = tmp_path / "opt"
    assert install(make_release(tmp_path / "r1", "1.0.0"), prefix, tmp_path).returncode == 0
    run = install(make_release(tmp_path / "r2", "2.0.0"), prefix, tmp_path)
    assert run.returncode == 0 and "already installed" not in run.stderr
    assert "loom 2.0.0" in run.stderr


def test_a_corrupted_archive_fails_loudly_and_installs_nothing(tmp_path):
    release = make_release(tmp_path / "release")
    victim = release / f"loomd-9.9.9-{PLATFORM}.tar.gz"
    victim.write_bytes(victim.read_bytes() + b"tamper")
    prefix = tmp_path / "opt"
    run = install(release, prefix, tmp_path)
    assert run.returncode != 0
    assert "digest mismatch" in run.stderr and victim.name in run.stderr
    assert not (prefix / "server").exists() and not (prefix / ".installed").exists()


def test_a_platform_with_no_published_archive_names_the_platform(tmp_path):
    release = make_release(tmp_path / "release")
    run = install(release, tmp_path / "opt", tmp_path, LOOM_PLATFORM="linux-arm64")
    assert run.returncode != 0 and "linux-arm64" in run.stderr


def test_an_unreachable_release_names_the_url(tmp_path):
    run = install(tmp_path / "missing", tmp_path / "opt", tmp_path)
    assert run.returncode != 0 and "could not download" in run.stderr and "SHA256SUMS" in run.stderr


def test_a_client_that_will_not_run_is_reported_after_install(tmp_path):
    release = make_release(tmp_path / "release", client_ok=False)
    run = install(release, tmp_path / "opt", tmp_path)
    assert run.returncode != 0 and "does not run in this container" in run.stderr


def test_a_non_url_source_is_refused(tmp_path):
    run = bash(
        scripts.INSTALL_SCRIPT,
        {"LOOM_PREFIX": str(tmp_path / "opt"), "LOOM_BASE_URL": "ftp://x/y", "LOOM_PLATFORM": PLATFORM},
        tmp_path,
    )
    assert run.returncode != 0 and "refusing to fetch" in run.stderr


def test_plain_http_is_refused_before_any_connection_is_made(tmp_path):
    run = install(tmp_path / "r", tmp_path / "opt", tmp_path, LOOM_BASE_URL="http://127.0.0.1:9/releases")
    assert run.returncode != 0 and "plain http" in run.stderr
    assert not (tmp_path / "opt/server").exists()


def test_a_pinned_sums_digest_must_match(tmp_path):
    release = make_release(tmp_path / "release")
    good = hashlib.sha256((release / "SHA256SUMS").read_bytes()).hexdigest()
    assert install(release, tmp_path / "ok", tmp_path, LOOM_SUMS_SHA256=good).returncode == 0
    bad = install(release, tmp_path / "bad", tmp_path, LOOM_SUMS_SHA256="0" * 64)
    assert bad.returncode != 0 and "digest mismatch for SHA256SUMS" in bad.stderr
    assert not (tmp_path / "bad/server").exists()


def test_a_server_and_client_of_different_versions_are_refused(tmp_path):
    release = make_release(tmp_path / "release", "1.0.0")
    other = make_release(tmp_path / "other", "2.0.0")
    shutil.copy(other / f"loom-2.0.0-{PLATFORM}.tar.gz", release / f"loom-2.0.0-{PLATFORM}.tar.gz")
    sums = (release / "SHA256SUMS").read_text().replace(
        f"loom-1.0.0-{PLATFORM}.tar.gz", f"loom-2.0.0-{PLATFORM}.tar.gz"
    )
    # Point the client line's digest at the 2.0.0 archive so only the version differs.
    digest = hashlib.sha256((other / f"loom-2.0.0-{PLATFORM}.tar.gz").read_bytes()).hexdigest()
    lines = [l if f"loom-2.0.0-{PLATFORM}" not in l else f"{digest}  loom-2.0.0-{PLATFORM}.tar.gz" for l in sums.splitlines()]
    (release / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    run = install(release, tmp_path / "opt", tmp_path)
    assert run.returncode != 0 and "version 1.0.0" in run.stderr and "2.0.0" in run.stderr


def test_the_install_does_not_take_ownership_or_modes_from_the_archive(tmp_path):
    # The archive's modes are 0644/0755; a hostile one could carry setuid. GNU tar
    # with --no-same-permissions applies the umask, so setuid cannot survive.
    release = make_release(tmp_path / "release")
    prefix = tmp_path / "opt"
    assert install(release, prefix, tmp_path).returncode == 0
    for path in prefix.rglob("*"):
        if path.is_file():
            assert not path.stat().st_mode & 0o6000, path


def test_offline_install_from_local_archives_needs_no_network(tmp_path):
    release = make_release(tmp_path / "release")
    prefix = tmp_path / "opt"
    run = bash(
        scripts.INSTALL_SCRIPT,
        {
            "LOOM_PREFIX": str(prefix),
            "LOOM_PLATFORM": PLATFORM,
            "LOOM_SERVER_TARBALL": str(release / f"loomd-9.9.9-{PLATFORM}.tar.gz"),
            "LOOM_CLIENT_TARBALL": str(release / f"loom-9.9.9-{PLATFORM}.tar.gz"),
            "http_proxy": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9",
        },
        tmp_path,
    )
    assert run.returncode == 0, run.stderr
    assert (prefix / "client/bin/loom").is_file() and "local:" in run.stderr
    # With no expected digest the check is only against the files themselves, and says so.
    assert "not verified against any expected digest" in run.stderr


def test_offline_install_verifies_pinned_digests(tmp_path):
    release = make_release(tmp_path / "release")
    server = release / f"loomd-9.9.9-{PLATFORM}.tar.gz"
    client = release / f"loom-9.9.9-{PLATFORM}.tar.gz"
    env = {"LOOM_PLATFORM": PLATFORM, "LOOM_SERVER_TARBALL": str(server), "LOOM_CLIENT_TARBALL": str(client)}
    good = {
        "LOOM_SERVER_SHA256": hashlib.sha256(server.read_bytes()).hexdigest(),
        "LOOM_CLIENT_SHA256": hashlib.sha256(client.read_bytes()).hexdigest(),
    }
    ok = bash(scripts.INSTALL_SCRIPT, {"LOOM_PREFIX": str(tmp_path / "a"), **env, **good}, tmp_path)
    assert ok.returncode == 0 and "not verified" not in ok.stderr
    bad = bash(scripts.INSTALL_SCRIPT, {"LOOM_PREFIX": str(tmp_path / "b"), **env, **good, "LOOM_SERVER_SHA256": "0" * 64}, tmp_path)
    assert bad.returncode != 0 and "digest mismatch for the server archive" in bad.stderr


# ---------------------------------------------------------------------- run

STUB_LOOMD = textwrap.dedent(
    r"""
    #!/usr/bin/env bash
    # Records its arguments and environment, publishes a ready endpoint and a session file, waits for TERM.
    state=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = --state-dir ] && state="${@:i+1:1}"; done
    printf '%s\n' "$@" > "$state/loomd.argv"
    env | sort > "$state/loomd.env"
    echo "$$" > "$state/stub.pid"
    [ -n "${STUB_LOOMD_DIE:-}" ] && { echo "boom: cannot bind" >&2; exit 9; }
    [ -n "${STUB_LOOMD_DIE_LATE:-}" ] && { sleep 1; echo "late boom" >&2; exit 9; }
    mkdir -p "$state/sessions"
    printf 'SQLite stub' > "$state/sessions/s-123.db"
    printf 'wal stub' > "$state/sessions/s-123.db-wal"
    echo "daemon log line ${STUB_LOOMD_LEAK:-}" > "$state/daemon.log"
    [ -n "${STUB_LOOMD_LEAK:-}" ] && echo "${STUB_LOOMD_LEAK}" >&2
    if [ -n "${STUB_LOOMD_STARTING_FIRST:-}" ]; then
      printf '{"pid":%s,"status":"starting"}' "$$" > "$state/daemon.endpoint"; sleep 1
    fi
    [ -n "${STUB_LOOMD_NEVER_READY:-}" ] || printf '{"pid":%s,"status":"ready"}' "$$" > "$state/daemon.endpoint"
    # A real daemon flushes its database when it stops; the copy must come after.
    trap 'printf " closed" >> "$state/sessions/s-123.db"; exit 0' TERM
    while true; do sleep 0.1; done
    """
).lstrip()

STUB_LOOM = textwrap.dedent(
    r"""
    #!/usr/bin/env bash
    printf '%s\n' "$@" > "$STUB_RECORD"
    env | sort > "$STUB_RECORD.env"
    pwd -P > "$STUB_RECORD.cwd"
    cat "$STUB_ENDPOINT" > "$STUB_RECORD.endpoint" 2>/dev/null
    [ -n "${STUB_REPORT_FILE:-}" ] && cat "$STUB_REPORT_FILE"
    echo "model said: rate limit exceeded (this is stderr prose)" >&2
    exit "${STUB_LOOM_EXIT:-0}"
    """
).lstrip()


@pytest.fixture
def rig(tmp_path):
    prefix = tmp_path / "opt"
    for name, body in (("server/bin/loomd", STUB_LOOMD), ("client/bin/loom", STUB_LOOM)):
        path = prefix / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)
    (tmp_path / "loom.toml").write_text("[models.harbor]\n")
    (tmp_path / "prompt.txt").write_text("Fix the bug.\nIt's \"quoted\" and $HOME stays literal; `uname`\n")
    (tmp_path / "report.json").write_text(REPORT + "\n")
    (tmp_path / "key").write_text(KEY)
    workdir = tmp_path / "app"
    workdir.mkdir()
    env = {
        "LOOM_PREFIX": str(prefix),
        "LOOM_STATE_DIR": str(tmp_path / "state"),
        "LOOM_KEY_NAME": "ANTHROPIC_API_KEY",
        "LOOM_KEY_FILE": str(tmp_path / "key"),
        "LOOM_CONFIG": str(tmp_path / "loom.toml"),
        "LOOM_PROMPT_FILE": str(tmp_path / "prompt.txt"),
        "LOOM_RUN_TIMEOUT_SEC": "120",
        "LOOM_JAIL_FLAG": "--best-effort",
        "STUB_RECORD": str(tmp_path / "loom.argv"),
        "STUB_REPORT_FILE": str(tmp_path / "report.json"),
        "STUB_ENDPOINT": str(tmp_path / "state" / "daemon.endpoint"),
    }
    return SimpleNamespaceRig(tmp_path, workdir, env)


class SimpleNamespaceRig:
    def __init__(self, root, workdir, env):
        self.root, self.workdir, self.env = root, workdir, env

    def run(self, script=scripts.RUN_SCRIPT, **extra):
        return bash(script, {**self.env, **extra}, self.workdir)

    @property
    def out(self) -> Path:
        return self.root / "state" / "harbor-out"

    @property
    def state(self) -> Path:
        return self.root / "state"


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_a_completed_run_prints_only_the_report_and_cleans_up(rig):
    run = rig.run()
    assert run.returncode == 0, run.stderr
    assert run.stdout == REPORT + "\n"
    assert (rig.out / "loom-run.exit").read_text() == "0\n"
    time.sleep(0.2)
    assert not alive(int((rig.state / "stub.pid").read_text())), "the daemon must be stopped before the script returns"
    # A stopped daemon leaves no pidfile behind for a later pass to signal.
    assert not (rig.out / "loomd.pid").exists()


def test_loomd_gets_the_posture_flag_the_config_and_only_the_key(rig):
    assert rig.run().returncode == 0
    argv = (rig.state / "loomd.argv").read_text().split()
    assert argv[:4] == ["--state-dir", str(rig.state), "--config", str(rig.root / "loom.toml")]
    assert argv[4:] == ["--best-effort"]
    environment = (rig.state / "loomd.env").read_text()
    assert f"ANTHROPIC_API_KEY={KEY}" in environment  # the daemon reads the key at dispatch
    for name in ("LOOM_PROMPT_FILE", "LOOM_KEY_FILE", "LOOM_KEY_NAME"):
        assert name + "=" not in environment


def test_loom_run_does_not_inherit_the_key(rig):
    assert rig.run().returncode == 0
    assert KEY not in (rig.root / "loom.argv.env").read_text()


def test_the_key_file_is_emptied_as_soon_as_it_is_read(rig):
    assert rig.run().returncode == 0
    key_file = rig.root / "key"
    assert not key_file.exists() or key_file.read_text() == ""


def test_a_missing_key_fails_before_a_daemon_starts(rig):
    (rig.root / "key").write_text("")
    run = rig.run()
    assert run.returncode == scripts.EXIT_PREREQUISITE and "no API key" in run.stderr
    assert not (rig.state / "loomd.argv").exists()


def test_the_platform_posture_passes_no_flag_at_all(rig):
    assert rig.run(LOOM_JAIL_FLAG="").returncode == 0
    assert (rig.state / "loomd.argv").read_text().split() == [
        "--state-dir", str(rig.state), "--config", str(rig.root / "loom.toml"),
    ]


def test_loom_run_is_pointed_at_the_workspace_state_and_prompt_verbatim(rig):
    assert rig.run().returncode == 0
    lines = (rig.root / "loom.argv").read_text().split("\n")
    assert lines[0] == "run"
    flags = dict(zip(lines[1:-1:2], lines[2::2]))
    assert flags["--server"] == str(rig.root / "opt/server/bin/loomd")
    assert flags["--state-dir"] == str(rig.state) and flags["--config"] == str(rig.root / "loom.toml")
    assert flags["--workspace"] == str(rig.workdir.resolve()) and flags["--timeout"] == "120"
    prompt = (rig.root / "prompt.txt").read_text().rstrip("\n")
    assert "-p" in lines and prompt in "\n".join(lines)


def test_loom_run_is_wrapped_in_timeout_with_a_kill_backstop(rig):
    shim = rig.root / "shim"
    shim.mkdir()
    (shim / "timeout").write_text('#!/bin/sh\necho "$@" > "$STUB_RECORD.timeout"\nshift 3\nexec "$@"\n')
    (shim / "timeout").chmod(0o755)
    run = rig.run(PATH=f"{shim}:{os.environ['PATH']}")
    assert run.returncode == 0, run.stderr
    assert (rig.root / "loom.argv.timeout").read_text().startswith("-k 30 210 ")  # --timeout 120 plus 90


def test_the_key_is_never_written_to_the_output_directory(rig):
    assert rig.run().returncode == 0
    for path in rig.out.rglob("*"):
        if path.is_file():
            assert KEY.encode() not in path.read_bytes(), path


def test_run_leaves_the_evidence_in_the_state_directory_not_in_a_logs_directory(rig):
    assert rig.run().returncode == 0
    assert (rig.out / "loom-run.json").is_file() and (rig.out / "loomd.log").is_file()
    assert not (rig.root / "logs").exists()


@pytest.mark.parametrize("code", [1, 124])
def test_a_failed_or_timed_out_run_is_a_result_not_a_script_failure(rig, code):
    run = rig.run(STUB_LOOM_EXIT=str(code))
    assert run.returncode == 0 and run.stdout == REPORT + "\n"
    assert (rig.out / "loom-run.exit").read_text() == f"{code}\n"


@pytest.mark.parametrize("code", [2, 3])
def test_bad_arguments_or_no_daemon_fail_the_script_with_the_same_status(rig, code):
    assert rig.run(STUB_LOOM_EXIT=str(code)).returncode == code


def test_exit_zero_with_no_report_is_its_own_failure(rig):
    run = rig.run(STUB_REPORT_FILE="")
    assert run.returncode == scripts.EXIT_NO_REPORT and "printed no report" in run.stderr


def test_a_daemon_that_dies_at_startup_is_reported_with_its_log(rig):
    run = rig.run(STUB_LOOMD_DIE="1")
    assert run.returncode == scripts.EXIT_DAEMON_NOT_READY
    assert "loomd exited before it was ready" in run.stderr
    # The log's contents stay out of the exec's stderr, which Harbor puts in exceptions and logs
    # unscrubbed; the file is fetched and scrubbed instead.
    assert "boom: cannot bind" not in run.stderr
    assert "boom: cannot bind" in (rig.out / "loomd.log").read_text()


def test_a_stale_ready_endpoint_does_not_pass_for_a_daemon_that_has_not_started(rig):
    # A record left by an earlier daemon is older than this launch and must not count:
    # `loom run` would otherwise find no live daemon and start its own, without the posture flag.
    rig.state.mkdir()
    stale = rig.state / "daemon.endpoint"
    stale.write_text('{"pid":1,"status":"ready"}')
    os.utime(stale, (time.time() - 3600, time.time() - 3600))
    run = rig.run(STUB_LOOMD_DIE_LATE="1")
    assert run.returncode == scripts.EXIT_DAEMON_NOT_READY, run.stderr
    assert not (rig.root / "loom.argv").exists(), "loom run must not have been started"


def test_a_starting_record_is_not_readiness(rig):
    run = rig.run(STUB_LOOMD_STARTING_FIRST="1")
    assert run.returncode == 0, run.stderr
    assert '"status":"ready"' in (rig.root / "loom.argv.endpoint").read_text()


def test_a_missing_install_fails_before_starting_anything(rig):
    shutil.rmtree(rig.root / "opt")
    run = rig.run()
    assert run.returncode == scripts.EXIT_PREREQUISITE and "install step did not run" in run.stderr
    assert not rig.state.exists() or not (rig.state / "loomd.argv").exists()


def test_a_missing_home_is_a_clear_prerequisite_failure(rig):
    run = subprocess.run(
        ["env", "-u", "HOME", "bash", "-c", scripts.RUN_SCRIPT],
        env={"PATH": os.environ["PATH"], **{k: v for k, v in rig.env.items()}},
        cwd=rig.workdir, capture_output=True, text=True,
    )
    assert run.returncode != 0 and "HOME" in run.stderr


def start_daemon(rig):
    """Start the stub the way the run script does and record its pidfile."""
    rig.out.mkdir(parents=True)
    daemon = subprocess.Popen([str(rig.root / "opt/server/bin/loomd"), "--state-dir", str(rig.state)])
    # In the container the script's own parent reaps a finished daemon; here the
    # test is the parent, and an unreaped zombie would still answer `kill -0`.
    reaper = threading.Thread(target=daemon.wait, daemon=True)
    reaper.start()
    for _ in range(50):
        if (rig.state / "daemon.endpoint").exists():
            break
        time.sleep(0.1)
    started = subprocess.run(
        ["awk", "{ sub(/^.*\\) /, \"\"); print $20 }", f"/proc/{daemon.pid}/stat"], capture_output=True, text=True
    ).stdout.strip()
    (rig.out / "loomd.pid").write_text(f"{daemon.pid} {started}\n")
    return daemon, reaper


def test_collect_stops_the_daemon_before_it_lists_the_session(rig):
    daemon, reaper = start_daemon(rig)
    run = rig.run(scripts.COLLECT_SCRIPT)
    assert run.returncode == 0, run.stderr
    reaper.join(timeout=10)
    assert daemon.returncode == 0
    # The daemon appended to its database while shutting down; the listing came after that.
    assert (rig.state / "sessions/s-123.db").read_text() == "SQLite stub closed"
    listed = [line.split(" ", 1)[1] for line in run.stdout.splitlines() if line.startswith("LOOM_FILE ")]
    assert str(rig.state / "sessions/s-123.db") in listed and str(rig.state / "sessions/s-123.db-wal") in listed
    assert str(rig.state / "daemon.log") in listed
    assert not (rig.out / "loomd.pid").exists()


def test_collect_does_not_signal_a_process_that_merely_reuses_the_pid(rig):
    bystander = subprocess.Popen(["sleep", "30"])
    try:
        rig.out.mkdir(parents=True)
        (rig.out / "loomd.pid").write_text(f"{bystander.pid} 1\n")  # start time that is not this process's
        assert rig.run(scripts.COLLECT_SCRIPT).returncode == 0
        assert bystander.poll() is None, "an unrelated process was signalled"
        assert not (rig.out / "loomd.pid").exists()
    finally:
        bystander.kill()
        bystander.wait()


def test_collect_empties_a_key_file_the_run_never_read(rig):
    assert (rig.root / "key").read_text() == KEY
    assert rig.run(scripts.COLLECT_SCRIPT).returncode == 0
    assert not (rig.root / "key").exists() or (rig.root / "key").read_text() == ""


def test_collect_with_nothing_to_collect_still_succeeds(rig):
    run = rig.run(scripts.COLLECT_SCRIPT)
    assert run.returncode == 0 and "LOOM_FILE" not in run.stdout


# ------------------------------------------------------------------ bubblewrap


def fake_bwrap(directory: Path, body: str) -> Path:
    directory.mkdir(exist_ok=True)
    path = directory / "bwrap"
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return path


def path_with(directory: Path) -> dict[str, str]:
    # Keep the system tools, but make sure no real bwrap on this machine answers.
    return {"PATH": f"{directory}:{os.environ['PATH']}"}


def probe(cwd: Path, directory: Path | None) -> list[str]:
    env = {"PATH": f"{directory}:{os.environ['PATH']}"} if directory else {"PATH": os.environ["PATH"]}
    return subprocess.run(
        ["bash", "-c", scripts.BWRAP_PROBE], env=env, cwd=cwd, capture_output=True, text=True
    ).stdout.strip().splitlines()


def test_the_probe_distinguishes_usable_from_unusable_and_names_the_file(tmp_path):
    ok = fake_bwrap(tmp_path / "ok", "exit 0\n")
    assert probe(tmp_path, ok.parent) == ["usable", str(ok)]
    bad = fake_bwrap(tmp_path / "bad", "echo 'No permissions to create new namespace' >&2\nexit 1\n")
    assert probe(tmp_path, bad.parent) == ["unusable", str(bad)]


def test_the_probe_asks_for_the_namespaces_the_helper_asks_for(tmp_path):
    record = tmp_path / "argv"
    directory = fake_bwrap(tmp_path / "rec", f"printf '%s\\n' \"$@\" > {record}\nexit 0\n").parent
    assert probe(tmp_path, directory)[0] == "usable"
    asked = record.read_text().split()
    assert {"--unshare-user", "--unshare-pid", "--unshare-net", "--proc", "--dev"} <= set(asked)


def disable(path: Path, script: str = scripts.BWRAP_DISABLE, env_path: Path | None = None):
    return subprocess.run(
        ["bash", "-c", script], env={"PATH": os.environ["PATH"], "LOOM_BWRAP_PATH": str(env_path or path)},
        capture_output=True, text=True,
    )


def test_disabling_moves_the_probed_file_aside_and_restoring_puts_it_back(tmp_path):
    binary = fake_bwrap(tmp_path / "bin", "exit 1\n")
    run = disable(binary)
    assert run.returncode == 0, run.stderr
    assert not binary.exists() and (binary.parent / "bwrap.disabled-by-loom-harbor").is_file()
    assert "moved" in run.stderr and run.stdout == ""
    restored = disable(binary, scripts.BWRAP_RESTORE)
    assert restored.returncode == 0 and binary.is_file()
    assert not (binary.parent / "bwrap.disabled-by-loom-harbor").exists()


def test_disabling_acts_on_the_probed_path_and_never_on_a_path_lookup(tmp_path):
    # Another bwrap earlier on root's PATH must not be the one that is moved.
    probed = fake_bwrap(tmp_path / "probed", "exit 1\n")
    other = fake_bwrap(tmp_path / "other", "exit 0\n")
    run = subprocess.run(
        ["bash", "-c", scripts.BWRAP_DISABLE],
        env={"PATH": f"{other.parent}:{os.environ['PATH']}", "LOOM_BWRAP_PATH": str(probed)},
        capture_output=True, text=True,
    )
    assert run.returncode == 0 and other.is_file() and not probed.exists()


@pytest.mark.parametrize("path", ["", "relative/bwrap", "/usr/bin/sh", "/etc/passwd"])
def test_disabling_refuses_anything_that_is_not_an_absolute_bwrap(tmp_path, path):
    run = subprocess.run(
        ["bash", "-c", scripts.BWRAP_DISABLE], env={"PATH": os.environ["PATH"], "LOOM_BWRAP_PATH": path},
        capture_output=True, text=True,
    )
    assert run.returncode != 0


def test_restoring_never_overwrites_a_bwrap_that_is_back(tmp_path):
    binary = fake_bwrap(tmp_path / "bin", "echo new\n")
    (binary.parent / "bwrap.disabled-by-loom-harbor").write_text("old")
    assert disable(binary, scripts.BWRAP_RESTORE).returncode == 0
    assert "new" in binary.read_text()


def test_no_log_content_is_echoed_to_the_scripts_stderr(rig):
    """stderr becomes exception text in Harbor's result.json; the logs are fetched scrubbed instead."""
    leak = "SECRET-TOKEN-IN-A-LOG"
    (rig.root / "report.json").write_text(REPORT + "\n")
    run = rig.run(STUB_LOOM_EXIT="2", STUB_LOOMD_LEAK=leak)
    assert run.returncode == 2
    assert leak not in run.stderr and "model said" not in run.stderr


def test_a_key_already_in_the_environment_does_not_reach_loom_run(rig):
    """Harbor overlays agent env onto every exec; the script must not pass it on."""
    run = rig.run(ANTHROPIC_API_KEY="overlay-key-should-not-propagate")
    assert run.returncode == 0, run.stderr
    assert "overlay-key" not in (rig.root / "loom.argv.env").read_text()
    daemon_env = (rig.state / "loomd.env").read_text()
    assert f"ANTHROPIC_API_KEY={KEY}" in daemon_env, "the daemon gets the key from the file, not the overlay"
    assert "overlay-key" not in daemon_env


def test_a_ready_record_for_another_pid_is_not_this_daemons(rig):
    rig.state.mkdir()
    (rig.state / "daemon.endpoint").write_text('{"pid":999999,"status":"ready"}')
    run = rig.run(STUB_LOOMD_DIE_LATE="1")
    assert run.returncode == scripts.EXIT_DAEMON_NOT_READY and not (rig.root / "loom.argv").exists()


def test_readiness_follows_the_daemons_own_pid_not_file_age(rig):
    # A fresh file for the wrong pid (mtime would have accepted it) is not readiness.
    rig.state.mkdir()
    (rig.state / "daemon.endpoint").write_text('{"pid":4242,"status":"ready"}')
    assert rig.run(STUB_LOOMD_DIE_LATE="1").returncode == scripts.EXIT_DAEMON_NOT_READY


def test_a_zombie_counts_as_stopped(rig):
    child = subprocess.Popen(["true"])  # exits at once and, never waited for, stays a zombie
    time.sleep(0.3)
    stat = Path(f"/proc/{child.pid}/stat").read_text()
    assert stat.rsplit(")", 1)[1].split()[0] == "Z"
    started = stat.rsplit(")", 1)[1].split()[19]
    rig.out.mkdir(parents=True)
    (rig.out / "loomd.pid").write_text(f"{child.pid} {started}\n")
    began = time.monotonic()
    assert rig.run(scripts.COLLECT_SCRIPT).returncode == 0
    assert time.monotonic() - began < 8, "a zombie was waited on as if it were still running"
    child.wait()


def shim(directory: Path, name: str, body: str) -> Path:
    directory.mkdir(exist_ok=True)
    path = directory / name
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(0o755)
    return path


def test_curl_is_restricted_to_https_and_file_including_redirects(tmp_path):
    shims = tmp_path / "shims"
    real = shutil.which("curl")
    shim(shims, "curl", f'echo "$@" >> {tmp_path}/curl.args\nexec {real} "$@"\n')
    release = make_release(tmp_path / "release")
    run = bash(
        scripts.INSTALL_SCRIPT,
        {"LOOM_PREFIX": str(tmp_path / "opt"), "LOOM_BASE_URL": release.as_uri(), "LOOM_PLATFORM": PLATFORM,
         "PATH": f"{shims}:{os.environ['PATH']}"},
        tmp_path,
    )
    assert run.returncode == 0, run.stderr
    for line in (tmp_path / "curl.args").read_text().splitlines():
        assert "--proto =https,file" in line and "--proto-redir =https" in line, line


def test_a_tar_that_is_not_gnu_gets_dash_o(tmp_path):
    shims = tmp_path / "shims"
    real = shutil.which("tar")
    shim(shims, "tar", f'if [ "$1" = --version ]; then echo "tar (busybox v1.36)"; exit 0; fi\n'
         f'echo "$@" >> {tmp_path}/tar.args\nargs=()\nfor a in "$@"; do [ "$a" = -o ] || args+=("$a"); done\nexec {real} "${{args[@]}}"\n')
    release = make_release(tmp_path / "release")
    run = bash(
        scripts.INSTALL_SCRIPT,
        {"LOOM_PREFIX": str(tmp_path / "opt"), "LOOM_BASE_URL": release.as_uri(), "LOOM_PLATFORM": PLATFORM,
         "PATH": f"{shims}:{os.environ['PATH']}"},
        tmp_path,
    )
    assert run.returncode == 0, run.stderr
    lines = (tmp_path / "tar.args").read_text().splitlines()
    assert lines and all(" -o" in line and "--no-same-owner" not in line for line in lines), lines
