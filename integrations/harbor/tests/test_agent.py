"""LoomAgent against a mocked Harbor environment, the way Harbor tests its own agents."""

from __future__ import annotations

import contextvars
import json
import shlex
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from harbor.agents.factory import AgentFactory
from harbor.agents.installed.base import (
    AgentAuthenticationError,
    ApiConnectionClosedError,
    ApiInternalServerError,
    ApiOverloadedError,
    ApiRateLimitError,
    ContextWindowExceededError,
    BaseInstalledAgent,
    NonZeroAgentExitCodeError,
)
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.config import AgentConfig
from harbor.utils.trajectory_validator import TrajectoryValidator

from loom_harbor import agent as agent_module
from loom_harbor import scripts
from loom_harbor.agent import LoomAgent
from tests import sessiondb
from tests.conftest import REPORT, result


def script_of(command: str) -> str:
    """Recover the script text from `set -o pipefail; bash -c '<script>'`."""
    command = command.removeprefix("set -o pipefail; ")
    assert command.startswith("bash -c "), command[:80]
    return shlex.split(command[len("bash -c "):])[0]


def is_script(command: str) -> bool:
    return command.removeprefix("set -o pipefail; ").startswith("bash -c ")


class Scripted:
    """An `exec` that answers by which script it was handed."""

    def __init__(self, run_stdout: str = REPORT + "\n", run_code: int = 0, selftest=(0, ""), bwrap="absent",
                 files: dict | None = None):
        self.calls: list[dict] = []
        self.run_stdout, self.run_code, self.selftest, self.bwrap = run_stdout, run_code, selftest, bwrap
        # The container's files by path: a Path is copied, a str is written.
        self.files: dict = files or {}
        self.downloads: list[str] = []

    async def download_file(self, source, target):
        self.downloads.append(source)
        if source not in self.files:
            raise FileNotFoundError(source)
        content = self.files[source]
        if isinstance(content, Path):
            Path(target).write_bytes(content.read_bytes())
        else:
            Path(target).write_text(content)

    async def __call__(self, command, **kwargs):
        self.calls.append({"command": command, **kwargs})
        if "loom-exec --self-test" in command:
            code, out = self.selftest
            return result(code, out)
        if is_script(command) and script_of(command) == scripts.RUN_SCRIPT:
            return result(self.run_code, self.run_stdout if self.run_code == 0 else "", "narration")
        if is_script(command) and script_of(command) == scripts.BWRAP_PROBE:
            return result(0, f"{self.bwrap}\n{'/usr/bin/bwrap' if self.bwrap != 'absent' else ''}\n")
        if is_script(command) and script_of(command) == scripts.COLLECT_SCRIPT:
            return result(0, "".join(f"LOOM_FILE {path}\n" for path in self.files))
        return result()

    def scripts_run(self) -> list[str]:
        return [script_of(c["command"]) for c in self.calls if is_script(c["command"])]


@pytest.fixture
def agent(make_agent):
    built = make_agent()
    built.ensure_system_dependencies = AsyncMock()
    return built


# ------------------------------------------------------------------ loading


def test_harbor_loads_the_agent_by_import_path(logs_dir, api_key):
    config = AgentConfig(import_path="loom_harbor.agent:LoomAgent", model_name="anthropic/claude-opus-4-5")
    assert AgentFactory.get_agent_class_from_config(config) is LoomAgent
    built = AgentFactory.create_agent_from_config(config, logs_dir=logs_dir)
    assert isinstance(built, LoomAgent) and isinstance(built, BaseInstalledAgent)
    assert LoomAgent.import_path() == "loom_harbor.agent:LoomAgent"


def test_the_unified_agent_flag_accepts_the_same_path(logs_dir, api_key):
    config = AgentConfig(name="loom_harbor.agent:LoomAgent", model_name="anthropic/claude-opus-4-5", kwargs={"jail": "platform"})
    built = AgentFactory.create_agent_from_config(config, logs_dir=logs_dir)
    assert built.options.jail == "platform"


def test_kwargs_are_validated_and_unknown_ones_are_refused(make_agent):
    with pytest.raises(ValueError, match="Unknown option 'bogus'"):
        make_agent(bogus=1)
    with pytest.raises(ValueError, match="jail"):
        make_agent(jail="none")


def test_the_options_schema_documents_every_option():
    properties = LoomAgent.options_schema()["properties"]
    for name in ("jail", "timeout_sec", "release", "server_tarball", "rw_mounts"):
        assert properties[name].get("description"), name


def test_harbor_sees_a_trajectory_capable_agent_named_loom(agent):
    assert LoomAgent.name() == "loom" and LoomAgent.capabilities.atif


# ------------------------------------------------------------------ release


def test_default_release_is_the_latest_published_one(agent):
    assert agent.release_tag() is None
    assert agent.release_base_url() == "https://github.com/Roasbeef/loom/releases/latest/download"


@pytest.mark.parametrize(
    ("given", "tag"),
    [("v0.3.2", "v0.3.2"), ("0.3.2", "v0.3.2"), ("commit-" + "a" * 40, "commit-" + "a" * 40), ("latest", None)],
)
def test_release_and_version_name_a_tag(make_agent, given, tag):
    assert make_agent(release=given).release_tag() == tag
    assert make_agent(version=given).release_tag() == tag


def test_a_tagged_release_has_its_own_download_directory(make_agent):
    assert make_agent(release="v0.3.2").release_base_url() == (
        "https://github.com/Roasbeef/loom/releases/download/v0.3.2"
    )


def test_the_environment_can_select_the_release_and_a_mirror(make_agent, monkeypatch):
    monkeypatch.setenv("LOOM_RELEASE", "0.4.0")
    assert make_agent().release_tag() == "v0.4.0"
    monkeypatch.setenv("LOOM_RELEASE_BASE_URL", "https://mirror.example/loom/")
    assert make_agent().release_base_url() == "https://mirror.example/loom"


def test_an_option_beats_the_environment(make_agent, monkeypatch):
    monkeypatch.setenv("LOOM_RELEASE", "v9.9.9")
    assert make_agent(release="v0.3.2").release_tag() == "v0.3.2"


def test_an_invalid_tag_is_refused(make_agent):
    with pytest.raises(ValueError, match="valid tag"):
        make_agent(release="v1; rm -rf /").release_tag()


def test_offline_install_needs_both_archives_and_they_must_exist(make_agent, tmp_path):
    server = tmp_path / "loomd.tar.gz"
    server.write_bytes(b"x")
    with pytest.raises(ValueError, match="both"):
        make_agent(server_tarball=str(server)).local_tarballs()
    with pytest.raises(FileNotFoundError, match="nope.tar.gz"):
        make_agent(server_tarball=str(server), client_tarball=str(tmp_path / "nope.tar.gz")).local_tarballs()


def test_version_output_is_parsed_for_the_release_number(agent):
    # The format `tui.print_version` writes.
    shipped = "loom 0.3.2\ncommit 859dd39a3a1c2b4d5e6f708192a3b4c5d6e7f801\nplatform linux-x86_64\n"
    assert agent.parse_version(shipped) == "0.3.2+859dd39a3a1c"
    assert agent.parse_version("loom 0.3.2\nplatform linux-x86_64\n") == "0.3.2"
    assert agent.parse_version("loom 0.3.2-rc.1\n") == "0.3.2-rc.1"
    assert agent.parse_version("weird\nsecond") == "weird"
    assert agent.get_version_command() == "/opt/loom-harbor/client/bin/loom version"


# ------------------------------------------------------------------ install


async def test_install_runs_the_install_script_as_root_with_the_release_source(agent, environment):
    environment.exec = Scripted()
    seen = []
    agent.exec_as_root = AsyncMock(side_effect=lambda env_, **kw: seen.append(kw))
    await agent.install(environment)
    (call,) = seen
    assert call["command"] == scripts.bash_command(scripts.INSTALL_SCRIPT)
    assert call["env"] == {
        "LOOM_PREFIX": "/opt/loom-harbor",
        "LOOM_BASE_URL": "https://github.com/Roasbeef/loom/releases/latest/download",
    }


async def test_install_never_sends_the_api_key(agent, environment):
    agent.exec_as_root = AsyncMock()
    await agent.install(environment)
    sent = json.dumps(agent.exec_as_root.await_args.kwargs, default=str)
    assert "sk-ant" not in sent and "ANTHROPIC_API_KEY" not in sent


async def test_install_ensures_the_tools_the_script_needs_first(agent, environment):
    agent.exec_as_root = AsyncMock()
    await agent.install(environment)
    first = agent.ensure_system_dependencies.await_args_list[0]
    assert first.args[1] == ("curl", "tar", "bash", "ca_certificates")
    wanted = [call.args[1] for call in agent.ensure_system_dependencies.await_args_list[1:]]
    assert wanted == [("git",), ("ripgrep",)], "container mode must not install a bubblewrap it may not be able to use"


async def test_platform_mode_installs_bubblewrap(make_agent, environment):
    built = make_agent(jail="platform")
    built.ensure_system_dependencies = AsyncMock()
    built.exec_as_root = AsyncMock()
    await built.install(environment)
    wanted = [call.args[1] for call in built.ensure_system_dependencies.await_args_list[1:]]
    assert wanted == [("git",), ("ripgrep",), ("bubblewrap",)]


async def test_a_failed_optional_tool_is_tolerated_in_container_mode(agent, environment):
    agent.exec_as_root = AsyncMock()
    agent.ensure_system_dependencies.side_effect = [None, RuntimeError("no apt"), RuntimeError("no apt")]
    await agent.install(environment)
    agent.exec_as_root.assert_awaited_once()


async def test_a_missing_bubblewrap_is_fatal_in_platform_mode(make_agent, environment):
    built = make_agent(jail="platform")
    built.exec_as_root = AsyncMock()
    built.ensure_system_dependencies = AsyncMock(side_effect=[None, None, None, RuntimeError("no apt")])
    with pytest.raises(RuntimeError, match="no apt"):  # the fourth call is bubblewrap
        await built.install(environment)
    built.exec_as_root.assert_not_awaited()


async def test_install_uploads_local_archives_and_points_the_script_at_them(make_agent, environment, tmp_path):
    server, client = tmp_path / "loomd.tar.gz", tmp_path / "loom.tar.gz"
    server.write_bytes(b"s")
    client.write_bytes(b"c")
    built = make_agent(server_tarball=str(server), client_tarball=str(client))
    built.ensure_system_dependencies = AsyncMock()
    built.exec_as_root = AsyncMock()
    await built.install(environment)
    uploads = [(call.args[0], call.args[1]) for call in environment.upload_file.await_args_list]
    # Under their own names, because the names carry the versions the script compares.
    assert uploads == [(server, "/installed-agent/loomd.tar.gz"), (client, "/installed-agent/loom.tar.gz")]
    env = built.exec_as_root.await_args.kwargs["env"]
    assert "LOOM_BASE_URL" not in env and env["LOOM_SERVER_TARBALL"] == "/installed-agent/loomd.tar.gz"


async def test_install_fails_before_touching_the_container_when_the_key_is_missing(make_agent, environment, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    built = make_agent()
    built.ensure_system_dependencies = AsyncMock()
    with pytest.raises(ValueError, match="ANTHROPIC_API_KEY"):
        await built.install(environment)
    built.ensure_system_dependencies.assert_not_awaited()
    environment.exec.assert_not_awaited()


async def test_install_failure_surfaces_as_harbors_setup_error(agent, environment):
    agent.exec_as_root = AsyncMock(side_effect=NonZeroAgentExitCodeError("digest mismatch"))
    with pytest.raises(RuntimeError, match="digest mismatch"):
        await agent.setup(environment)


# ----------------------------------------------------------------- the key


def test_a_key_passed_with_agent_env_is_refused_because_harbor_adds_it_to_every_exec(make_agent, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "host-key-value-0000")
    built = make_agent(extra_env={"ANTHROPIC_API_KEY": "agent-env-key-1111"})
    with pytest.raises(ValueError, match="host environment instead") as raised:
        built.api_key()
    assert "agent-env-key-1111" not in str(raised.value)
    # It is still known to the scrubber, so nothing can leak it later.
    assert "agent-env-key-1111" in built._secrets()


def test_a_missing_key_does_not_suggest_agent_env(make_agent, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(ValueError) as raised:
        make_agent().api_key()
    assert "--agent-env" not in str(raised.value) and "ANTHROPIC_API_KEY" in str(raised.value)


async def test_install_and_run_refuse_before_any_command_when_the_key_is_in_agent_env(make_agent, environment):
    built = make_agent(extra_env={"ANTHROPIC_API_KEY": "agent-env-key-1111"})
    built.ensure_system_dependencies = AsyncMock()
    with pytest.raises(ValueError, match="agent-env"):
        await built.install(environment)
    environment.exec.assert_not_awaited()


def test_other_agent_env_is_unaffected(make_agent):
    built = make_agent(extra_env={"LOOM_RELEASE": "0.3.2"})
    assert built.api_key()[0] == "ANTHROPIC_API_KEY" and built.release_tag() == "v0.3.2"


def test_an_explicit_key_variable_is_honoured(make_agent, monkeypatch):
    monkeypatch.setenv("MY_PROXY_KEY", "proxy-key-value-2222")
    assert make_agent(api_key_env="MY_PROXY_KEY").api_key() == ("MY_PROXY_KEY", "proxy-key-value-2222")


def test_gemini_accepts_either_google_variable(make_agent, monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("GOOGLE_API_KEY", "google-key-value-3333")
    built = make_agent(model_name="gemini/gemini-3.8-flash")
    assert built.api_key()[0] == "GOOGLE_API_KEY"
    assert 'api_key_env = "GOOGLE_API_KEY"' in built.render_catalogue()


def test_a_missing_key_names_the_variable_and_the_model(make_agent, monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(ValueError, match=r"OPENAI_API_KEY.*|openai/gpt-5.2"):
        make_agent(model_name="openai/gpt-5.2").api_key()


def test_a_model_is_required(make_agent):
    with pytest.raises(ValueError, match="-m provider/model"):
        make_agent(model_name=None).model_spec()


def test_pricing_must_be_given_as_a_pair(make_agent):
    with pytest.raises(ValueError, match="together"):
        make_agent(price_input=3.0).render_catalogue()
    text = make_agent(price_input=3.0, price_output=15.0).render_catalogue()
    assert "[models.harbor.pricing]" in text and "input = 3.0" in text


def test_rw_mounts_accept_a_comma_separated_string(make_agent):
    assert make_agent(rw_mounts="/etc/app, /srv/data").rw_mounts() == ("/etc/app", "/srv/data")
    assert 'path = "/srv/data"' in make_agent(rw_mounts=["/srv/data"]).render_catalogue()


# ---------------------------------------------------------------------- run


async def run_agent(agent, environment, instruction="Fix it.", context=None):
    context = context or AgentContext()
    if isinstance(environment.exec, Scripted):
        environment.download_file = environment.exec.download_file
    await agent.run(instruction, environment, context)
    return context


async def test_run_starts_the_daemon_with_the_chosen_posture_and_names_the_key_file(agent, environment):
    scripted = environment.exec = Scripted()
    await run_agent(agent, environment)
    run_call = next(c for c in scripted.calls if is_script(c["command"]) and
                    script_of(c["command"]) == scripts.RUN_SCRIPT)
    env = run_call["env"]
    assert env["LOOM_JAIL_FLAG"] == "--best-effort"
    assert env["LOOM_RUN_TIMEOUT_SEC"] == "1800" and "LOOM_OUT" not in env
    assert env["LOOM_CONFIG"] == agent_module.REMOTE_CONFIG
    assert (env["LOOM_KEY_NAME"], env["LOOM_KEY_FILE"]) == ("ANTHROPIC_API_KEY", agent_module.REMOTE_KEY)
    assert run_call["timeout_sec"] == 1800 + 300


KEY = "sk-ant-test-0123456789abcdef"


async def test_the_key_never_appears_in_any_exec_argument_or_environment(agent, environment):
    """Harbor passes exec env as `docker compose exec -e KEY=VALUE`, so it would be on the host's argv."""
    scripted = environment.exec = Scripted()
    agent._upload_config_text = AsyncMock()
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    everything = json.dumps(scripted.calls, default=str) + json.dumps(
        [(c.args, c.kwargs) for c in agent.exec_as_root.await_args_list], default=str
    )
    assert KEY not in everything
    uploads = {c.kwargs["remote_path"]: c.kwargs for c in agent._upload_config_text.await_args_list}
    assert uploads[agent_module.REMOTE_KEY]["content"] == KEY


async def test_the_key_file_is_made_private_even_when_harbors_helper_would_not(agent, environment):
    environment.exec = Scripted()
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    assert any("chmod 600" in c.kwargs["command"] and agent_module.REMOTE_KEY in c.kwargs["command"]
               for c in agent.exec_as_root.await_args_list)


async def test_platform_mode_passes_no_posture_flag(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, "enforced (11):\nskipped (0)\nRESULT: OK\n"))
    await run_agent(built, environment)
    run_call = next(c for c in environment.exec.calls if c.get("env") and "LOOM_JAIL_FLAG" in c["env"])
    assert run_call["env"]["LOOM_JAIL_FLAG"] == ""


async def test_the_catalogue_and_instruction_are_uploaded_privately_not_inlined(agent, environment, logs_dir):
    environment.exec = Scripted()
    agent._upload_config_text = AsyncMock()
    await run_agent(agent, environment, instruction="It's \"tricky\"\nand $HOME")
    uploads = {c.kwargs["remote_path"]: c.kwargs["content"] for c in agent._upload_config_text.await_args_list}
    assert uploads[agent_module.REMOTE_PROMPT] == "It's \"tricky\"\nand $HOME"
    assert 'dialect = "anthropic"' in uploads[agent_module.REMOTE_CONFIG]
    assert "sk-ant" not in uploads[agent_module.REMOTE_CONFIG]
    assert (logs_dir / "loom.toml").read_text() == uploads[agent_module.REMOTE_CONFIG]


async def test_an_instruction_too_large_for_one_argument_is_refused_up_front(agent, environment):
    environment.exec = Scripted()
    with pytest.raises(ValueError, match="one argument"):
        await run_agent(agent, environment, instruction="x" * (agent_module.MAX_INSTRUCTION_BYTES + 1))
    assert environment.exec.scripts_run() == []


async def test_a_prompt_template_is_applied_to_the_instruction(make_agent, environment, tmp_path):
    template = tmp_path / "t.j2"
    template.write_text("Be careful.\n\n{{ instruction }}")
    built = make_agent(prompt_template_path=str(template))
    built._upload_config_text = AsyncMock()
    environment.exec = Scripted()
    await run_agent(built, environment, instruction="Do X.")
    prompt = next(c.kwargs["content"] for c in built._upload_config_text.await_args_list
                  if c.kwargs["remote_path"] == agent_module.REMOTE_PROMPT)
    assert prompt == "Be careful.\n\nDo X."


async def test_run_leaves_the_context_empty_so_harbor_calls_the_post_run_hook(agent, environment):
    environment.exec = Scripted()
    context = await run_agent(agent, environment)
    # Harbor calls populate_context_post_run only while the context is still empty.
    assert context.is_empty()


async def test_run_salvages_the_session_after_the_run_script(agent, environment):
    environment.exec = Scripted()
    await run_agent(agent, environment)
    assert environment.exec.scripts_run()[-1] == scripts.COLLECT_SCRIPT


async def test_run_salvages_even_when_cancelled_by_harbors_timeout(agent, environment):
    scripted = Scripted()

    async def hang_then_ok(command, **kwargs):
        if is_script(command) and script_of(command) == scripts.RUN_SCRIPT:
            raise TimeoutError("harbor cut the run off")
        return await scripted(command, **kwargs)

    environment.exec = hang_then_ok
    with pytest.raises(TimeoutError):
        await run_agent(agent, environment)
    assert scripted.scripts_run()[-1] == scripts.COLLECT_SCRIPT


async def test_a_failed_salvage_does_not_hide_the_run(agent, environment):
    scripted = Scripted()

    async def exec_(command, **kwargs):
        if is_script(command) and script_of(command) == scripts.COLLECT_SCRIPT:
            raise ConnectionError("container gone")
        return await scripted(command, **kwargs)

    environment.exec = exec_
    await run_agent(agent, environment)


@pytest.mark.parametrize("outcome", ["completed", "failed", "aborted", "timeout"])
async def test_every_loom_outcome_returns_normally_for_the_verifier_to_judge(agent, environment, outcome):
    report = {**json.loads(REPORT), "outcome": outcome}
    if outcome == "failed":
        report["reason"] = "the run failed: the model gave up"
    environment.exec = Scripted(run_stdout=json.dumps(report) + "\n")
    await run_agent(agent, environment)


FIXTURES = Path(__file__).parent / "fixtures"
# What provider/stream.describe_error wrote for each failure (see fixtures/generate_errors.gleam.txt).
PROVIDER_ERRORS = json.loads((FIXTURES / "provider-errors.json").read_text())


def failed_report(reason="the run failed: provider_error"):
    return json.dumps({**json.loads(REPORT), "outcome": "failed", "reason": reason}) + "\n"


def session_with(tmp_path, text):
    """A session whose last answer failed with `text`, in the shape Loom stores it."""
    path = tmp_path / "failed.db"
    entries = [
        sessiondb.user_entry("e1", 1, "go"),
        sessiondb.assistant_entry("e2", 2, [{"type": "text", "text": ""}]),
    ]
    entries[1]["message"].update(stopReason="error", errorMessage=text)
    return sessiondb.write(path, entries)


@pytest.mark.parametrize(
    ("name", "error"),
    [
        ("rate-limit", ApiRateLimitError),
        ("auth", AgentAuthenticationError),
        ("overloaded", ApiOverloadedError),
        ("server", ApiInternalServerError),
        ("stream", ApiOverloadedError),
        ("transport", ApiConnectionClosedError),
    ],
)
async def test_provider_failures_in_the_session_become_harbors_retryable_errors(
    agent, environment, tmp_path, name, error
):
    """The report says only `provider_error`; the provider's words are in the failed answer."""
    environment.exec = Scripted(
        run_stdout=failed_report(),
        files={"/state/sessions/s-123.db": session_with(tmp_path, PROVIDER_ERRORS[name])},
    )
    with pytest.raises(error):
        await run_agent(agent, environment)


async def test_the_real_loom_session_fixture_classifies_too(agent, environment):
    environment.exec = Scripted(
        run_stdout=failed_report(), files={"/state/sessions/s-123.db": FIXTURES / "failed-session.db"}
    )
    with pytest.raises(ApiRateLimitError, match="rate_limit_error"):
        await run_agent(agent, environment)


async def test_the_report_alone_cannot_classify_which_is_why_the_session_is_read(agent, environment):
    environment.exec = Scripted(run_stdout=failed_report())  # no session fetched
    await run_agent(agent, environment)


async def test_a_bad_request_is_the_models_or_adapters_problem_not_a_retry(agent, environment, tmp_path):
    environment.exec = Scripted(
        run_stdout=failed_report(),
        files={"/state/sessions/s-123.db": session_with(tmp_path, PROVIDER_ERRORS["badrequest"])},
    )
    await run_agent(agent, environment)


async def test_the_raised_error_does_not_carry_the_key(agent, environment, tmp_path):
    text = PROVIDER_ERRORS["auth"] + f" (sent {KEY})"
    environment.exec = Scripted(
        run_stdout=failed_report(), files={"/state/sessions/s-123.db": session_with(tmp_path, text)}
    )
    with pytest.raises(AgentAuthenticationError) as raised:
        await run_agent(agent, environment)
    assert KEY not in str(raised.value)


async def test_a_malformed_report_is_an_error_naming_the_problem(agent, environment):
    environment.exec = Scripted(run_stdout="{not json\n")
    with pytest.raises(NonZeroAgentExitCodeError, match="unusable loom run report"):
        await run_agent(agent, environment)


async def test_a_report_without_a_jail_label_is_an_error(agent, environment):
    document = json.loads(REPORT)
    del document["jail"]
    environment.exec = Scripted(run_stdout=json.dumps(document) + "\n")
    with pytest.raises(NonZeroAgentExitCodeError, match="jail"):
        await run_agent(agent, environment)


async def test_an_infrastructure_failure_in_the_script_is_a_nonzero_exit_error(agent, environment):
    environment.exec = Scripted(run_code=41)
    with pytest.raises(NonZeroAgentExitCodeError, match="exit 41"):
        await run_agent(agent, environment)


async def test_platform_mode_refuses_to_run_when_the_jail_would_not_fully_come_up(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(1, "  FAILED    bwrap (userns)\nenforced (0):\nskipped (2)\nRESULT: FAIL\n"))
    with pytest.raises(RuntimeError, match=r"jail=platform.*unverified.*docs/docker.md"):
        await run_agent(built, environment)
    # No daemon, no model call, no upload: the trial is refused before it costs anything.
    assert environment.exec.scripts_run() == []


async def test_platform_mode_runs_and_records_the_preflight_when_the_jail_is_enforced(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, "enforced (11):\nskipped (0)\nRESULT: OK\n"))
    await run_agent(built, environment)
    assert built.jail_record(None)["preflight"] == "enforced"


async def test_a_degraded_jail_is_not_enough_for_platform_mode(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, "enforced (10):\nskipped (1)\nRESULT: OK\n"))
    with pytest.raises(RuntimeError, match="degraded"):
        await run_agent(built, environment)


def bwrap_scripts(agent):
    return [c.kwargs["command"] for c in agent.exec_as_root.await_args_list
            if c.kwargs["command"] in (scripts.bash_command(scripts.BWRAP_DISABLE), scripts.bash_command(scripts.BWRAP_RESTORE))]


@pytest.mark.parametrize("state", ["absent", "usable"])
async def test_container_mode_leaves_absent_or_working_bubblewrap_alone(agent, environment, state):
    environment.exec = Scripted(bwrap=state)
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    assert bwrap_scripts(agent) == []
    assert agent.jail_record(None)["bubblewrap"] == state


async def test_container_mode_moves_the_probed_bubblewrap_aside_and_restores_it_afterwards(agent, environment):
    environment.exec = Scripted(bwrap="unusable")
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    assert bwrap_scripts(agent) == [
        scripts.bash_command(scripts.BWRAP_DISABLE),
        scripts.bash_command(scripts.BWRAP_RESTORE),
    ], "the verifier must grade a container that is not missing a binary"
    for call in agent.exec_as_root.await_args_list:
        if call.kwargs["command"] in (scripts.bash_command(scripts.BWRAP_DISABLE), scripts.bash_command(scripts.BWRAP_RESTORE)):
            assert call.kwargs["env"] == {"LOOM_BWRAP_PATH": "/usr/bin/bwrap"}  # the probed path, not a new lookup
    assert agent.jail_record(None)["bubblewrap"] == "disabled"


async def test_bubblewrap_is_restored_even_when_the_run_fails(agent, environment):
    scripted = Scripted(bwrap="unusable")

    async def exec_(command, **kwargs):
        if is_script(command) and script_of(command) == scripts.RUN_SCRIPT:
            raise TimeoutError("cut off")
        return await scripted(command, **kwargs)

    environment.exec = exec_
    environment.download_file = scripted.download_file
    agent.exec_as_root = AsyncMock()
    with pytest.raises(TimeoutError):
        await run_agent(agent, environment)
    assert bwrap_scripts(agent)[-1] == scripts.bash_command(scripts.BWRAP_RESTORE)


async def test_bwrap_keep_never_touches_it_but_records_that_it_is_unusable(make_agent, environment):
    built = make_agent(bwrap="keep")
    environment.exec = Scripted(bwrap="unusable")
    built.exec_as_root = AsyncMock()
    await run_agent(built, environment)
    assert bwrap_scripts(built) == []
    assert built.jail_record(None)["bubblewrap"] == "unusable"


async def test_platform_mode_does_not_probe_or_move_bubblewrap(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, "enforced (11):\nskipped (0)\nRESULT: OK\n"))
    built.exec_as_root = AsyncMock()
    await run_agent(built, environment)
    assert scripts.BWRAP_PROBE not in environment.exec.scripts_run()
    assert bwrap_scripts(built) == []


# ---------------------------------------------------------- after the run


def put_report(agent, text=REPORT):
    (agent.logs_dir / "loom-run.json").write_text(text + "\n")


def put_session(agent, name="s-123.db"):
    directory = agent.logs_dir / "loom-session"
    directory.mkdir(exist_ok=True)
    sessiondb.sample_session(directory / name)


def test_usage_maps_onto_the_context_with_cache_inside_the_input_count(agent):
    put_report(agent)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert (context.n_input_tokens, context.n_cache_tokens, context.n_output_tokens) == (115, 10, 20)
    assert context.cost_usd == 0.3


def test_unreported_tokens_and_unpriced_cost_stay_unset_not_zero(agent):
    document = json.loads(REPORT)
    document["usage"]["evidence"] = {"version": 1, "tokens": "unknown", "billing": "api", "cost": {"kind": "unavailable"}}
    put_report(agent, json.dumps(document))
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.n_input_tokens is None and context.cost_usd is None
    assert context.metadata["loom"]["usage_evidence"] == {"tokens": "unknown", "cost": "unavailable"}


def test_metadata_records_outcome_session_model_and_the_isolation_actually_measured(agent):
    put_report(agent)
    context = AgentContext()
    agent.populate_context_post_run(context)
    loom = context.metadata["loom"]
    assert (loom["outcome"], loom["session_id"], loom["turns"], loom["elapsed_ms"]) == ("completed", "s-123", 3, 4200)
    assert loom["model"] == {"provider": "harbor", "model_id": "claude-opus-4-5"}
    assert loom["jail"]["requested"] == "container" and loom["jail"]["loomd_flag"] == "--best-effort"
    assert loom["jail"]["label"] == "degraded" and loom["jail"]["selftest_skipped"] == 4
    assert "Harbor task container" in loom["jail"]["boundary"]
    json.dumps(context.metadata)  # Harbor serialises it into results.json


def test_the_report_in_memory_is_used_when_the_log_was_not_synced(agent):
    agent._stdout = REPORT
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.metadata["loom"]["session_id"] == "s-123"


def sample_db(tmp_path, name="s-123.db"):
    return sessiondb.sample_session(tmp_path / name)


async def gather(agent, environment, **files):
    """Run the evidence pass against a fake container holding `files`."""
    scripted = environment.exec = Scripted(files=files)
    environment.download_file = scripted.download_file
    await agent._gather_evidence(environment)
    return scripted


async def test_a_trajectory_is_written_and_valid_from_the_fetched_session(agent, environment, tmp_path):
    await gather(agent, environment, **{
        "/state/harbor-out/loom-run.json": REPORT + "\n",
        "/state/sessions/s-123.db": sample_db(tmp_path),
    })
    context = AgentContext()
    agent.populate_context_post_run(context)
    written = json.loads((agent.logs_dir / "trajectory.json").read_text())
    validator = TrajectoryValidator()
    assert validator.validate(written), validator.errors
    assert written["session_id"] == "s-123" and written["agent"]["name"] == "loom"
    assert written["agent"]["model_name"] == "anthropic/claude-opus-4-5"
    assert written["agent"]["extra"]["jail"]["requested"] == "container"
    assert written["extra"]["loom_run"]["outcome"] == "completed"
    assert context.metadata["loom"]["trajectory"] == "trajectory.json"


async def test_after_a_timeout_the_session_still_becomes_a_trajectory(agent, environment, tmp_path):
    # No report was ever printed, but the evidence pass fetched the database.
    await gather(agent, environment, **{"/state/sessions/s-9.db": sample_db(tmp_path, "s-9.db")})
    context = AgentContext()
    agent.populate_context_post_run(context)
    written = json.loads((agent.logs_dir / "trajectory.json").read_text())
    assert written["session_id"] == "s-9"
    assert context.metadata["loom"]["outcome"] == "no-report"
    assert context.metadata["loom"]["jail"]["requested"] == "container"


async def test_with_nothing_fetched_there_is_metadata_but_no_trajectory(agent, environment):
    await gather(agent, environment)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert not (agent.logs_dir / "trajectory.json").exists()
    assert context.metadata["loom"]["trajectory"] is None


async def test_a_corrupt_session_database_does_not_fail_the_trial(agent, environment):
    await gather(agent, environment, **{
        "/state/harbor-out/loom-run.json": REPORT + "\n", "/state/sessions/s-123.db": "not sqlite",
    })
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.metadata["loom"]["trajectory"] is None and context.n_input_tokens == 115


async def test_a_file_that_cannot_be_fetched_is_skipped_not_fatal(agent, environment, tmp_path):
    scripted = Scripted(files={"/state/daemon.log": "x", "/state/sessions/s-123.db": sample_db(tmp_path)})
    del scripted.files["/state/daemon.log"]
    scripted.files["/state/missing.log"] = "never"
    environment.exec = scripted

    async def flaky(source, target):
        if source.endswith("missing.log"):
            raise ConnectionError("gone")
        await Scripted.download_file(scripted, source, target)

    environment.download_file = flaky
    await agent._gather_evidence(environment)
    assert (agent.logs_dir / "trajectory.json").is_file()


async def test_the_api_key_is_scrubbed_from_the_trajectory(agent, environment, tmp_path):
    db = sessiondb.write(
        tmp_path / "s-123.db",
        [sessiondb.user_entry("e1", 1, f"the key is {KEY} (in prose)"),
         sessiondb.assistant_entry("e2", 2, [{"type": "text", "text": f"echo {KEY}"}])],
    )
    await gather(agent, environment, **{"/state/sessions/s-123.db": db})
    assert KEY not in (agent.logs_dir / "trajectory.json").read_text()


async def test_text_evidence_is_scrubbed_by_value_before_it_reaches_the_logs(agent, environment, tmp_path):
    """Under jail=container model-run code can read the daemon's environment, the key included."""
    leaky = f"loomd started with {KEY}\nand a Bearer abc.def-123 token\n"
    await gather(agent, environment, **{
        "/state/harbor-out/loom-run.json": REPORT.replace("completed", "completed") + "\n",
        "/state/harbor-out/loom-run.stderr.txt": leaky,
        "/state/harbor-out/loomd.log": leaky,
        "/state/daemon.log": leaky,
        "/state/sessions/s-123.db": sample_db(tmp_path),
    })
    for name in ("loom-run.stderr.txt", "loomd.log", "daemon.log"):
        text = (agent.logs_dir / name).read_text()
        assert KEY not in text and "abc.def-123" not in text and "<redacted>" in text, name
    # Nothing raw is left in the logs directory: no database, no write-ahead log.
    assert not list(agent.logs_dir.rglob("*.db")) and not list(agent.logs_dir.rglob("*.db-wal"))


async def test_the_raw_database_is_fetched_to_scratch_and_discarded(agent, environment, tmp_path):
    seen = []
    scripted = Scripted(files={"/state/sessions/s-123.db": sample_db(tmp_path)})

    async def spy(source, target):
        seen.append(Path(target))
        await scripted.download_file(source, target)

    environment.exec = scripted
    environment.download_file = spy
    await agent._gather_evidence(environment)
    assert seen and not any(path.exists() for path in seen)
    assert not list(agent.logs_dir.glob("**/*.db"))


async def test_the_run_pass_orders_stop_then_fetch_then_restore(agent, environment, tmp_path):
    environment.exec = Scripted(bwrap="unusable", files={"/state/sessions/s-123.db": sample_db(tmp_path)})
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    order = [("collect" if script_of(c["command"]) == scripts.COLLECT_SCRIPT else "other")
             for c in environment.exec.calls if is_script(c["command"])]
    assert "collect" in order
    assert environment.exec.downloads, "fetching happens after the collect pass listed the files"
    assert bwrap_scripts(agent)[-1] == scripts.bash_command(scripts.BWRAP_RESTORE)


def test_the_trajectory_records_the_installed_release_as_the_agent_version(make_agent, tmp_path):
    built = make_agent(version="0.3.2")
    document = sessiondb.sample_session(tmp_path / "s.db")
    assert built._write_trajectory(None, document)
    assert json.loads((built.logs_dir / "trajectory.json").read_text())["agent"]["version"] == "0.3.2"
    assert built.to_agent_info().version == "0.3.2"


# ------------------------------------------------- construction and quoting


def test_a_non_native_provider_can_be_constructed_with_an_endpoint(make_agent, monkeypatch):
    """Harbor's own base_url needs a model-connection spec; endpoint_url is this adapter's."""
    monkeypatch.setenv("TOGETHER_API_KEY", "together-key-value-4444")
    built = make_agent(model_name="together/meta-llama/Llama-3.3-70B", endpoint_url="https://api.together.example/v1")
    text = built.render_catalogue()
    assert 'base_url = "https://api.together.example/v1"' in text and 'api_key_env = "TOGETHER_API_KEY"' in text
    assert built.api_key() == ("TOGETHER_API_KEY", "together-key-value-4444")


def test_harbors_own_base_url_is_refused_clearly_rather_than_half_supported(make_agent):
    with pytest.raises(ValueError, match="inference connection overrides"):
        make_agent(model_name="together/llama", base_url="https://x.example/v1")


def test_a_non_native_provider_without_an_endpoint_is_refused_at_render(make_agent, monkeypatch):
    monkeypatch.setenv("TOGETHER_API_KEY", "together-key-value-4444")
    with pytest.raises(ValueError, match="base_url"):
        make_agent(model_name="together/llama").render_catalogue()


@pytest.mark.parametrize("bad", ["relative/dir", "/", "/opt/a b", "/opt/$(id)", "/opt/../etc", "/opt/a;b"])
def test_an_unsafe_install_dir_is_refused(make_agent, bad):
    with pytest.raises(ValueError, match="install_dir"):
        make_agent(install_dir=bad)


def test_install_dir_is_quoted_wherever_it_reaches_a_command(make_agent):
    built = make_agent(install_dir="/opt/loom+harbor~x")
    assert built.get_version_command() == "/opt/loom+harbor~x/client/bin/loom version" or "'" in built.get_version_command()
    assert shlex.split(built.get_version_command())[0] == "/opt/loom+harbor~x/client/bin/loom"


async def test_the_platform_preflight_quotes_the_helper_path(make_agent, environment):
    built = make_agent(jail="platform", install_dir="/opt/loom+x")
    environment.exec = Scripted(selftest=(0, "enforced (11):\nskipped (0)\nRESULT: OK\n"))
    await run_agent(built, environment)
    command = next(c["command"] for c in environment.exec.calls if "--self-test" in c["command"])
    assert shlex.split(command)[0] == "/opt/loom+x/server/bin/loom-exec"


# ------------------------------------------------------ platform tolerance

FULL_ISOLATION = (
    "enforced (10):\n  + a\nskipped (1) \u2014 NOT verified in this environment:\n"
    "  - unvetted beam denied host write, secret, and network: no erl on PATH\n\nRESULT: OK (skips are environmental)\n"
)


async def test_platform_mode_accepts_docker_mds_ten_of_eleven_row(make_agent, environment):
    """docs/docker.md: full isolation enforces 10 of 11, skipping only the unvetted-beam probe."""
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, FULL_ISOLATION))
    await run_agent(built, environment)
    assert built.jail_record(None)["preflight"] == "degraded"
    assert built.jail_record(None)["preflight_skipped"] == ["unvetted beam denied host write, secret, and network"]


async def test_platform_mode_still_refuses_any_other_skip(make_agent, environment):
    built = make_agent(jail="platform")
    other = FULL_ISOLATION.replace("unvetted beam denied host write, secret, and network", "fork bomb capped by pids limit")
    environment.exec = Scripted(selftest=(0, other))
    with pytest.raises(RuntimeError, match="unexpected skips: fork bomb"):
        await run_agent(built, environment)


@pytest.mark.parametrize(
    "url",
    [
        "https://api.together.example/v1",
        "http://127.0.0.1:8080/v1",
        "http://localhost:4000",
        "http://10.1.2.3/v1",
        "http://192.168.0.5:11434/v1",
        "http://[::1]:8000/v1",
    ],
)
def test_endpoints_over_https_or_to_a_local_proxy_are_accepted(make_agent, url):
    assert make_agent(endpoint_url=url).options.endpoint_url == url


@pytest.mark.parametrize(
    ("url", "why"),
    [
        ("http://api.together.example/v1", "https"),
        ("http://8.8.8.8/v1", "https"),
        ("ftp://x.example/v1", "http"),
        ("https://user:pw@api.example/v1", "credentials"),
        ("https://user@api.example/v1", "credentials"),
        ("https://api.example/v1#frag", "fragment"),
        ("https:///v1", "host"),
        ("api.example/v1", "http"),
    ],
)
def test_unsafe_endpoints_are_refused(make_agent, url, why):
    with pytest.raises(ValueError, match=why):
        make_agent(endpoint_url=url)


# ------------------------------------------- through Harbor's real env merging


class HarborLikeEnvironment:
    """`exec` that merges env exactly as Harbor's BaseEnvironment does, then builds the
    `docker compose exec -e KEY=VALUE` argument list the Docker environment builds.

    `_merge_env` and `scoped_exec_env` are Harbor's own functions, not copies, so the
    overlay Trial applies (`scoped_exec_env(agent.extra_env)`) reaches the argv exactly
    as it does in a real trial. The mock `environment.exec` used elsewhere sits below
    that merge and could not see it.
    """

    default_user = None
    _merge_env = BaseEnvironment._merge_env
    scoped_exec_env = BaseEnvironment.scoped_exec_env

    def __init__(self, scripted):
        self._persistent_env = {}
        self._exec_env_overlays = contextvars.ContextVar("overlays", default=())
        self.scripted = scripted
        self.argv: list[list[str]] = []
        self.download_file = scripted.download_file
        self.upload_file = AsyncMock()

    async def exec(self, command, cwd=None, env=None, timeout_sec=None, user=None):
        merged = self._merge_env(env)
        argv = ["exec"]
        for key, value in (merged or {}).items():
            argv += ["-e", f"{key}={value}"]
        self.argv.append(argv + [command])
        return await self.scripted(command, env=merged, timeout_sec=timeout_sec)


async def test_the_key_is_on_no_docker_argv_when_agent_env_carries_other_variables(make_agent):
    """The exact path of the original leak: Trial scopes agent.extra_env over every exec."""
    built = make_agent(extra_env={"LOOM_RELEASE": "0.3.2"})
    built.exec_as_root = AsyncMock()
    built._upload_config_text = AsyncMock()
    scripted = Scripted()
    environment = HarborLikeEnvironment(scripted)
    with environment.scoped_exec_env(built.extra_env):
        await run_agent(built, environment)
    assert environment.argv, "the run must have gone through the merge"
    assert not any(KEY in " ".join(argv) for argv in environment.argv)
    assert any("LOOM_RELEASE=0.3.2" in " ".join(argv) for argv in environment.argv)  # the overlay did apply


async def test_the_key_in_agent_env_would_reach_the_argv_which_is_why_it_is_refused(make_agent):
    built = make_agent(extra_env={"ANTHROPIC_API_KEY": KEY})
    environment = HarborLikeEnvironment(Scripted())
    with environment.scoped_exec_env(built.extra_env):
        await environment.exec("true")
    assert any(KEY in " ".join(argv) for argv in environment.argv)  # Harbor itself does this
    with pytest.raises(ValueError, match="agent-env"):
        await run_agent(built, environment)


# ------------------------------------------- classification: recovered errors


def db_with(tmp_path, messages):
    """A session whose assistant messages carry the given errorMessage (or None), in order."""
    entries = [sessiondb.user_entry("e1", 1, "go")]
    for index, text in enumerate(messages):
        entry = sessiondb.assistant_entry(f"e{index + 2}", index + 2, [{"type": "text", "text": "x"}])
        if text is not None:
            entry["message"].update(stopReason="error", errorMessage=text)
        entries.append(entry)
    return sessiondb.write(tmp_path / "s.db", entries)


async def test_a_recovered_429_followed_by_a_local_failure_is_not_a_rate_limit(agent, environment, tmp_path):
    db = db_with(tmp_path, [PROVIDER_ERRORS["rate-limit"], None])  # retried, then a good answer
    environment.exec = Scripted(
        run_stdout=failed_report("the run failed: interrupted"), files={"/state/sessions/s-123.db": db}
    )
    await run_agent(agent, environment)


async def test_a_provider_error_report_with_a_recovered_history_is_not_blamed_on_the_old_error(
    agent, environment, tmp_path
):
    db = db_with(tmp_path, [PROVIDER_ERRORS["rate-limit"], None])
    environment.exec = Scripted(run_stdout=failed_report(), files={"/state/sessions/s-123.db": db})
    await run_agent(agent, environment)  # the final answer did not fail, so there is nothing to classify


async def test_only_the_final_answers_error_counts(agent, environment, tmp_path):
    db = db_with(tmp_path, [PROVIDER_ERRORS["rate-limit"], PROVIDER_ERRORS["auth"]])
    environment.exec = Scripted(run_stdout=failed_report(), files={"/state/sessions/s-123.db": db})
    with pytest.raises(AgentAuthenticationError):
        await run_agent(agent, environment)


@pytest.mark.parametrize("code", ["interrupted", "invalid_deferred_handle"])
async def test_non_provider_failure_codes_are_never_classified(agent, environment, tmp_path, code):
    db = db_with(tmp_path, [PROVIDER_ERRORS["rate-limit"]])
    environment.exec = Scripted(
        run_stdout=failed_report(f"the run failed: {code}"), files={"/state/sessions/s-123.db": db}
    )
    await run_agent(agent, environment)


async def test_context_overflow_is_classified_from_the_code_alone(agent, environment):
    environment.exec = Scripted(run_stdout=failed_report("the run failed: context_overflow"))
    with pytest.raises(ContextWindowExceededError):
        await run_agent(agent, environment)


# Strings from provider/retry_test.gleam's overflow_patterns_match_real_provider_wording_test,
# inside the http error text describe_error writes around them.
OVERFLOW_WORDINGS = PROVIDER_ERRORS["overflow"]


@pytest.mark.parametrize("index", range(len(OVERFLOW_WORDINGS)))
async def test_every_wording_loom_treats_as_overflow_is_classified_as_overflow(agent, environment, tmp_path, index):
    db = db_with(tmp_path, [OVERFLOW_WORDINGS[index]])
    environment.exec = Scripted(run_stdout=failed_report(), files={"/state/sessions/s-123.db": db})
    with pytest.raises(ContextWindowExceededError):
        await run_agent(agent, environment)


@pytest.mark.parametrize("key", ["throttling-tokens", "rate-limit-tokens"])
async def test_throttling_that_mentions_tokens_is_a_rate_limit_not_an_overflow(agent, environment, tmp_path, key):
    db = db_with(tmp_path, [PROVIDER_ERRORS[key]])
    environment.exec = Scripted(run_stdout=failed_report(), files={"/state/sessions/s-123.db": db})
    with pytest.raises(ApiRateLimitError):
        await run_agent(agent, environment)


async def test_a_lost_drain_proof_is_deliberately_not_a_retry(agent, environment, tmp_path):
    db = db_with(tmp_path, [PROVIDER_ERRORS["drain-proof-lost"]])
    environment.exec = Scripted(run_stdout=failed_report(), files={"/state/sessions/s-123.db": db})
    await run_agent(agent, environment)


async def test_a_failed_exec_does_not_carry_the_key_into_the_exception(agent, environment):
    class Leaky(Scripted):
        async def __call__(self, command, **kwargs):
            if is_script(command) and script_of(command) == scripts.RUN_SCRIPT:
                return result(41, "", f"loomd said {KEY} and died")
            return await super().__call__(command, **kwargs)

    environment.exec = Leaky()
    with pytest.raises(NonZeroAgentExitCodeError) as raised:
        await run_agent(agent, environment)
    assert KEY not in str(raised.value) and "<redacted>" in str(raised.value)
