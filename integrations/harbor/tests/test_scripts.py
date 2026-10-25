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
        scripts.BWRAP_PROBE, scripts.BWRAP_DISABLE,
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


# ---------------------------------------------------------------------- run

STUB_LOOMD = textwrap.dedent(
    r"""
    #!/usr/bin/env bash
    # Records its arguments, publishes an endpoint and a session file, then waits for TERM.
    state=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = --state-dir ] && state="${@:i+1:1}"; done
    printf '%s\n' "$@" > "$state/loomd.argv"
    env | sort > "$state/loomd.env"
    [ -n "${STUB_LOOMD_DIE:-}" ] && { echo "boom: cannot bind" >&2; exit 9; }
    mkdir -p "$state/sessions"
    printf 'SQLite stub' > "$state/sessions/s-123.db"
    printf 'wal stub' > "$state/sessions/s-123.db-wal"
    [ -n "${STUB_LOOMD_NEVER_READY:-}" ] || echo '{"pid":1}' > "$state/daemon.endpoint"
    trap 'exit 0' TERM
    while true; do sleep 0.1; done
    """
).lstrip()

STUB_LOOM = textwrap.dedent(
    r"""
    #!/usr/bin/env bash
    printf '%s\n' "$@" > "$STUB_RECORD"
    pwd -P > "$STUB_RECORD.cwd"
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
    workdir = tmp_path / "app"
    workdir.mkdir()
    env = {
        "LOOM_PREFIX": str(prefix),
        "LOOM_STATE_DIR": str(tmp_path / "state"),
        "LOOM_OUT": str(tmp_path / "out"),
        "LOOM_CONFIG": str(tmp_path / "loom.toml"),
        "LOOM_PROMPT_FILE": str(tmp_path / "prompt.txt"),
        "LOOM_RUN_TIMEOUT_SEC": "120",
        "LOOM_JAIL_FLAG": "--best-effort",
        "STUB_RECORD": str(tmp_path / "loom.argv"),
        "STUB_REPORT_FILE": str(tmp_path / "report.json"),
        "ANTHROPIC_API_KEY": "sk-ant-secret-0123456789",
    }
    return SimpleNamespaceRig(tmp_path, workdir, env)


class SimpleNamespaceRig:
    def __init__(self, root, workdir, env):
        self.root, self.workdir, self.env = root, workdir, env

    def run(self, script=scripts.RUN_SCRIPT, **extra):
        return bash(script, {**self.env, **extra}, self.workdir)

    @property
    def out(self) -> Path:
        return self.root / "out"

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
    pid = int((rig.out / "loomd.pid").read_text())
    time.sleep(0.2)
    assert not alive(pid), "the daemon must be stopped before the script returns"


def test_loomd_gets_the_posture_flag_the_config_and_a_clean_environment(rig):
    assert rig.run().returncode == 0
    argv = (rig.state / "loomd.argv").read_text().split()
    assert argv[:4] == ["--state-dir", str(rig.state), "--config", str(rig.root / "loom.toml")]
    assert argv[4:] == ["--best-effort"]
    environment = (rig.state / "loomd.env").read_text()
    assert "ANTHROPIC_API_KEY=sk-ant-secret-0123456789" in environment  # the daemon reads the key at dispatch
    assert "LOOM_PROMPT_FILE" not in environment


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


def test_the_api_key_is_never_written_to_any_log_or_output_file(rig):
    assert rig.run().returncode == 0
    for path in rig.out.rglob("*"):
        if path.is_file():
            assert b"sk-ant-secret" not in path.read_bytes(), path


def test_the_session_database_and_its_wal_are_copied_into_the_logs(rig):
    assert rig.run().returncode == 0
    assert (rig.out / "loom-session/s-123.db").read_text() == "SQLite stub"
    assert (rig.out / "loom-session/s-123.db-wal").read_text() == "wal stub"


@pytest.mark.parametrize("code", [1, 124])
def test_a_failed_or_timed_out_run_is_a_result_not_a_script_failure(rig, code):
    run = rig.run(STUB_LOOM_EXIT=str(code))
    assert run.returncode == 0 and run.stdout == REPORT + "\n"
    assert (rig.out / "loom-run.exit").read_text() == f"{code}\n"


@pytest.mark.parametrize("code", [2, 3])
def test_bad_arguments_or_no_daemon_fail_the_script_with_the_same_status(rig, code):
    run = rig.run(STUB_LOOM_EXIT=str(code))
    assert run.returncode == code and run.stdout == REPORT + "\n"[:0] or run.returncode == code


def test_exit_zero_with_no_report_is_its_own_failure(rig):
    run = rig.run(STUB_REPORT_FILE="")
    assert run.returncode == scripts.EXIT_NO_REPORT and "printed no report" in run.stderr


def test_a_daemon_that_dies_at_startup_is_reported_with_its_log(rig):
    run = rig.run(STUB_LOOMD_DIE="1")
    assert run.returncode == scripts.EXIT_DAEMON_NOT_READY
    assert "loomd exited before it was ready" in run.stderr and "boom: cannot bind" in run.stderr


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


def test_collect_after_a_cut_off_run_copies_the_session_and_stops_the_daemon(rig):
    # Start the daemon the way the run script does, then never let the script finish.
    stub = rig.root / "opt/server/bin/loomd"
    rig.out.mkdir()
    rig.state.mkdir()
    daemon = subprocess.Popen([str(stub), "--state-dir", str(rig.state)])
    # In the container the script's own parent reaps a finished daemon; here the
    # test is the parent, and an unreaped zombie would still answer `kill -0`.
    reaper = threading.Thread(target=daemon.wait, daemon=True)
    reaper.start()
    (rig.out / "loomd.pid").write_text(f"{daemon.pid}\n")
    for _ in range(50):
        if (rig.state / "daemon.endpoint").exists():
            break
        time.sleep(0.1)
    run = rig.run(scripts.COLLECT_SCRIPT)
    assert run.returncode == 0, run.stderr
    assert (rig.out / "loom-session/s-123.db").is_file()
    reaper.join(timeout=10)
    assert daemon.returncode == 0


def test_collect_with_nothing_to_collect_still_succeeds(rig):
    assert rig.run(scripts.COLLECT_SCRIPT).returncode == 0


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


def probe(cwd: Path, directory: Path | None) -> str:
    env = {"PATH": f"{directory}:{os.environ['PATH']}"} if directory else {"PATH": os.environ["PATH"]}
    return subprocess.run(
        ["bash", "-c", scripts.BWRAP_PROBE], env=env, cwd=cwd, capture_output=True, text=True
    ).stdout.strip()


def test_the_probe_distinguishes_usable_from_unusable(tmp_path):
    assert probe(tmp_path, fake_bwrap(tmp_path / "ok", "exit 0\n").parent) == "usable"
    assert probe(tmp_path, fake_bwrap(tmp_path / "bad", "echo 'No permissions to create new namespace' >&2\nexit 1\n").parent) == "unusable"


@pytest.mark.skipif(shutil.which("bwrap") is not None, reason="a real bwrap on this machine answers instead")
def test_the_probe_reports_absent_when_there_is_no_bwrap(tmp_path):
    assert probe(tmp_path, None) == "absent"


def test_the_probe_asks_for_the_namespaces_the_helper_asks_for(tmp_path):
    record = tmp_path / "argv"
    directory = fake_bwrap(tmp_path / "rec", f"printf '%s\\n' \"$@\" > {record}\nexit 0\n").parent
    assert probe(tmp_path, directory) == "usable"
    asked = record.read_text().split()
    assert {"--unshare-user", "--unshare-pid", "--unshare-net", "--proc", "--dev"} <= set(asked)


def test_disabling_moves_the_binary_aside_and_nothing_else(tmp_path):
    binary = fake_bwrap(tmp_path / "bin", "exit 1\n")
    run = subprocess.run(
        ["bash", "-c", scripts.BWRAP_DISABLE], env={"PATH": f"{binary.parent}:{os.environ['PATH']}"},
        cwd=tmp_path, capture_output=True, text=True,
    )
    assert run.returncode == 0, run.stderr
    assert not binary.exists() and (binary.parent / "bwrap.disabled-by-loom-harbor").is_file()
    assert "moved" in run.stderr and run.stdout == ""
