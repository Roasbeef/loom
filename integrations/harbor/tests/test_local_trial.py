"""The whole adapter, setup to post-run, over real subprocesses.

Harbor's Docker environment is replaced by `LocalEnvironment`, which runs each
`exec` in `bash` on this machine with the container's `/installed-agent` and
`/logs/agent` mapped into a temporary directory. Everything else is real: the
`LoomAgent` code, the install and run scripts, `tar`, `sha256sum`, `curl` over
`file://`, process start and stop. Only the release's contents are stubs
(`loomd`, `loom`), so what this proves is that the Python and shell halves agree
with each other, which the unit tests of each half cannot show.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from harbor.models.agent.context import AgentContext
from harbor.utils.trajectory_validator import TrajectoryValidator

from loom_harbor.agent import LoomAgent
from tests.conftest import REPORT
from tests.test_scripts import PLATFORM, STUB_LOOMD, make_archive, make_release

pytestmark = pytest.mark.skipif(
    not (platform.system() == "Linux" and platform.machine() == "x86_64"),
    reason="the fake release is laid out for linux-x86_64",
)

FIXTURES = Path(__file__).parent / "fixtures"

# `loom version` as tui.print_version prints it, then the same stub as test_scripts.
STUB_LOOM = r"""#!/usr/bin/env bash
if [ "${1:-}" = version ]; then printf 'loom 9.9.9\ncommit 0123456789abcdef0123456789abcdef01234567\nplatform linux-x86_64\n'; exit 0; fi
printf '%s\n' "$@" > "$STUB_RECORD"
cat "$STUB_REPORT_FILE"
exit "${STUB_LOOM_EXIT:-0}"
"""

# The session stub copies a real Loom-written database (and its WAL) into place.
STUB_LOOMD_WITH_SESSION = STUB_LOOMD.replace(
    "printf 'SQLite stub' > \"$state/sessions/s-123.db\"\nprintf 'wal stub' > \"$state/sessions/s-123.db-wal\"",
    "cp \"$STUB_SESSION_DB\" \"$state/sessions/s-123.db\"\ncp \"$STUB_SESSION_DB-wal\" \"$state/sessions/s-123.db-wal\"",
)
assert STUB_LOOMD_WITH_SESSION != STUB_LOOMD


class LocalEnvironment:
    """Just enough of `BaseEnvironment`: `exec`, `upload_file` and a default user."""

    default_user = None

    def __init__(self, root: Path, workdir: Path, env: dict[str, str]):
        self.root, self.workdir, self.env = root, workdir, env
        self.commands: list[str] = []

    def mapped(self, text: str) -> str:
        for container_path in ("/installed-agent", "/logs/agent"):
            text = text.replace(container_path, str(self.root) + container_path)
        return text

    async def exec(self, command, cwd=None, env=None, timeout_sec=None, user=None):
        self.commands.append(command)
        mapped_env = {key: self.mapped(value) for key, value in (env or {}).items()}
        run = subprocess.run(
            ["bash", "-c", self.mapped(command)],
            env={"PATH": os.environ["PATH"], "HOME": str(self.root / "home"), **self.env, **mapped_env},
            cwd=cwd or self.workdir, capture_output=True, text=True, timeout=timeout_sec or 120,
        )
        return SimpleNamespace(return_code=run.returncode, stdout=run.stdout, stderr=run.stderr)

    async def upload_file(self, source, target):
        destination = Path(self.mapped(str(target)))
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


@pytest.fixture
def trial(tmp_path, api_key):
    (tmp_path / "home").mkdir()
    workdir = tmp_path / "app"
    workdir.mkdir()
    logs = tmp_path / "logs" / "agent"
    logs.mkdir(parents=True)
    release = make_release(tmp_path / "release")
    # Replace the release's trivial stubs with the recording ones.
    for stem, files in (
        (f"loomd-9.9.9-{PLATFORM}", {"bin/loomd": STUB_LOOMD_WITH_SESSION, "bin/loom-exec": "#!/bin/sh\nexit 0\n"}),
        (f"loom-9.9.9-{PLATFORM}", {"bin/loom": STUB_LOOM}),
    ):
        digest = make_archive(release / f"{stem}.tar.gz", stem, files)
        sums = [line for line in (release / "SHA256SUMS").read_text().splitlines() if not line.endswith(f"{stem}.tar.gz")]
        (release / "SHA256SUMS").write_text("\n".join([*sums, f"{digest}  {stem}.tar.gz"]) + "\n")
    (tmp_path / "report.json").write_text(REPORT + "\n")
    environment = LocalEnvironment(
        tmp_path,
        workdir,
        {
            "STUB_RECORD": str(tmp_path / "loom.argv"),
            "STUB_REPORT_FILE": str(tmp_path / "report.json"),
            "STUB_SESSION_DB": str(FIXTURES / "loom-session.db"),
        },
    )
    agent = LoomAgent(
        logs_dir=logs,
        model_name="anthropic/claude-opus-4-5",
        environment_logs_dir=PurePosixPath("/logs/agent"),
        release_base_url=release.as_uri(),
        install_dir=str(tmp_path / "opt"),
        state_dir=str(tmp_path / "state"),
        bwrap="keep",  # never let a test move this machine's real bwrap
        timeout_sec=120,
    )
    agent.ensure_system_dependencies = AsyncMock()  # no package manager on the test host
    return SimpleNamespace(agent=agent, env=environment, root=tmp_path, logs=logs)


async def test_setup_run_and_post_run_agree_end_to_end(trial):
    agent, env = trial.agent, trial.env
    await agent.setup(env)

    # Setup installed the release, and the version was read back from the installed client.
    assert (trial.root / "opt/server/bin/loomd").is_file()
    assert agent.version() == "9.9.9+0123456789ab"

    context = AgentContext()
    await agent.run("Create hello.txt containing hi", env, context)
    assert context.is_empty()

    # loomd got the container posture; loom run got the workspace and the instruction.
    assert "--best-effort" in (trial.root / "state/loomd.argv").read_text().split()
    argv = (trial.root / "loom.argv").read_text().split("\n")
    assert argv[argv.index("-p") + 1] == "Create hello.txt containing hi"
    assert argv[argv.index("--workspace") + 1] == str(trial.root / "app")
    assert argv[argv.index("--timeout") + 1] == "120"

    # The key reached the daemon's environment and no file or log the trial keeps.
    assert "ANTHROPIC_API_KEY=sk-ant-test-0123456789abcdef" in (trial.root / "state/loomd.env").read_text()
    for path in trial.root.rglob("*"):
        if path.is_file() and path.suffix in (".json", ".txt", ".toml", ".log", ".exit", ".pid"):
            assert b"sk-ant-test" not in path.read_bytes(), path

    # Harbor's log sync is a no-op here (the mapped directory is the host's logs dir).
    assert (trial.logs / "loom-run.json").read_text() == REPORT + "\n"
    assert (trial.logs / "loom-session/s-123.db").is_file()
    assert (trial.logs / "loom-session/s-123.db-wal").is_file()

    agent.populate_context_post_run(context)
    assert (context.n_input_tokens, context.n_output_tokens, context.cost_usd) == (115, 20, 0.3)
    loom = context.metadata["loom"]
    assert loom["jail"]["requested"] == "container" and loom["jail"]["label"] == "degraded"
    assert loom["jail"]["bubblewrap"] in ("absent", "usable", "unusable")
    assert loom["trajectory"] == "trajectory.json"

    written = json.loads((trial.logs / "trajectory.json").read_text())
    validator = TrajectoryValidator()
    assert validator.validate(written), validator.errors
    assert [s["source"] for s in written["steps"]] == ["user", "agent", "agent"]
    assert written["agent"]["version"] == "9.9.9+0123456789ab"
    assert written["agent"]["extra"]["jail"]["loomd_flag"] == "--best-effort"
    assert "sk-livekey123" not in json.dumps(written)


async def test_the_daemon_is_gone_when_run_returns(trial):
    await trial.agent.setup(trial.env)
    await trial.agent.run("x", trial.env, AgentContext())
    pid = int((trial.logs / "loomd.pid").read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


async def test_a_second_setup_in_the_same_container_installs_nothing(trial):
    await trial.agent.setup(trial.env)
    inode = (trial.root / "opt/server/bin/loomd").stat().st_ino
    await trial.agent.setup(trial.env)
    assert (trial.root / "opt/server/bin/loomd").stat().st_ino == inode


async def test_a_tampered_release_fails_setup_with_harbors_setup_error(trial):
    victim = next((trial.root / "release").glob("loomd-*-linux-x86_64.tar.gz"))
    victim.write_bytes(victim.read_bytes() + b"x")
    with pytest.raises(RuntimeError, match="digest mismatch"):
        await trial.agent.setup(trial.env)
    assert not (trial.root / "opt/server").exists()


async def test_a_timed_out_loom_run_still_yields_a_trajectory_and_a_verdict(trial):
    (trial.env.env)["STUB_LOOM_EXIT"] = "124"
    timeout_report = {**json.loads(REPORT), "outcome": "timeout"}
    (trial.root / "report.json").write_text(json.dumps(timeout_report) + "\n")
    await trial.agent.setup(trial.env)
    context = AgentContext()
    await trial.agent.run("x", trial.env, context)  # a timeout is a result, not an error
    trial.agent.populate_context_post_run(context)
    assert context.metadata["loom"]["outcome"] == "timeout"
    assert (trial.logs / "trajectory.json").is_file()
