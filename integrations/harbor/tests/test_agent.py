"""LoomAgent against a mocked Harbor environment, the way Harbor tests its own agents."""

from __future__ import annotations

import json
import shlex
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from harbor.agents.factory import AgentFactory
from harbor.agents.installed.base import (
    ApiRateLimitError,
    BaseInstalledAgent,
    NonZeroAgentExitCodeError,
)
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

    def __init__(self, run_stdout: str = REPORT + "\n", run_code: int = 0, selftest=(0, ""), bwrap="absent"):
        self.calls: list[dict] = []
        self.run_stdout, self.run_code, self.selftest, self.bwrap = run_stdout, run_code, selftest, bwrap

    async def __call__(self, command, **kwargs):
        self.calls.append({"command": command, **kwargs})
        if "loom-exec --self-test" in command:
            code, out = self.selftest
            return result(code, out)
        if is_script(command) and script_of(command) == scripts.RUN_SCRIPT:
            return result(self.run_code, self.run_stdout if self.run_code == 0 else "", "narration")
        if is_script(command) and script_of(command) == scripts.BWRAP_PROBE:
            return result(0, self.bwrap + "\n")
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
    assert uploads == [(server, agent_module.REMOTE_SERVER_TARBALL), (client, agent_module.REMOTE_CLIENT_TARBALL)]
    env = built.exec_as_root.await_args.kwargs["env"]
    assert "LOOM_BASE_URL" not in env and env["LOOM_SERVER_TARBALL"] == agent_module.REMOTE_SERVER_TARBALL


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


def test_the_key_comes_from_agent_env_before_the_host(make_agent, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "host-key-value-0000")
    built = make_agent(extra_env={"ANTHROPIC_API_KEY": "agent-env-key-1111"})
    assert built.api_key() == ("ANTHROPIC_API_KEY", "agent-env-key-1111")


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
    await agent.run(instruction, environment, context)
    return context


async def test_run_starts_the_daemon_with_the_chosen_posture_and_passes_the_key_by_env(agent, environment):
    scripted = environment.exec = Scripted()
    await run_agent(agent, environment)
    run_call = next(c for c in scripted.calls if is_script(c["command"]) and
                    script_of(c["command"]) == scripts.RUN_SCRIPT)
    env = run_call["env"]
    assert env["ANTHROPIC_API_KEY"] == "sk-ant-test-0123456789abcdef"
    assert env["LOOM_JAIL_FLAG"] == "--best-effort"
    assert env["LOOM_RUN_TIMEOUT_SEC"] == "1800" and env["LOOM_OUT"] == "/logs/agent"
    assert env["LOOM_CONFIG"] == agent_module.REMOTE_CONFIG
    assert "sk-ant" not in run_call["command"], "the key must never be in the command line"
    assert run_call["timeout_sec"] == 1800 + 300


async def test_platform_mode_passes_no_posture_flag(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, "enforced (11):\nskipped (0)\nRESULT: OK\n"))
    await run_agent(built, environment)
    run_call = next(c for c in environment.exec.calls if "env" in c and "LOOM_JAIL_FLAG" in c["env"])
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


@pytest.mark.parametrize(
    ("reason", "error"),
    [
        ("provider returned 429: rate limit exceeded", ApiRateLimitError),
        ("Invalid API key provided", Exception),
    ],
)
async def test_provider_failures_become_harbors_retryable_errors(agent, environment, reason, error):
    report = {**json.loads(REPORT), "outcome": "failed", "reason": reason}
    environment.exec = Scripted(run_stdout=json.dumps(report) + "\n")
    with pytest.raises(error) as raised:
        await run_agent(agent, environment)
    assert isinstance(raised.value, NonZeroAgentExitCodeError)


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


@pytest.mark.parametrize("state", ["absent", "usable"])
async def test_container_mode_leaves_absent_or_working_bubblewrap_alone(agent, environment, state):
    environment.exec = Scripted(bwrap=state)
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    agent.exec_as_root.assert_not_awaited()
    assert agent.jail_record(None)["bubblewrap"] == state


async def test_container_mode_moves_an_unusable_bubblewrap_aside_and_says_so(agent, environment):
    environment.exec = Scripted(bwrap="unusable")
    agent.exec_as_root = AsyncMock()
    await run_agent(agent, environment)
    agent.exec_as_root.assert_awaited_once()
    assert agent.exec_as_root.await_args.kwargs["command"] == scripts.bash_command(scripts.BWRAP_DISABLE)
    assert agent.jail_record(None)["bubblewrap"] == "disabled"


async def test_bwrap_keep_never_touches_it_but_records_that_it_is_unusable(make_agent, environment):
    built = make_agent(bwrap="keep")
    environment.exec = Scripted(bwrap="unusable")
    built.exec_as_root = AsyncMock()
    await run_agent(built, environment)
    built.exec_as_root.assert_not_awaited()
    assert built.jail_record(None)["bubblewrap"] == "unusable"


async def test_platform_mode_does_not_probe_or_move_bubblewrap(make_agent, environment):
    built = make_agent(jail="platform")
    environment.exec = Scripted(selftest=(0, "enforced (11):\nskipped (0)\nRESULT: OK\n"))
    built.exec_as_root = AsyncMock()
    await run_agent(built, environment)
    assert scripts.BWRAP_PROBE not in environment.exec.scripts_run()
    built.exec_as_root.assert_not_awaited()


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


def test_a_trajectory_is_written_and_valid_when_the_session_was_synced(agent):
    put_report(agent)
    put_session(agent)
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


def test_after_a_timeout_the_session_still_becomes_a_trajectory(agent):
    # No report was ever printed, but the salvage pass copied the database out.
    put_session(agent, "s-9.db")
    context = AgentContext()
    agent.populate_context_post_run(context)
    written = json.loads((agent.logs_dir / "trajectory.json").read_text())
    assert written["session_id"] == "s-9"
    assert context.metadata["loom"]["outcome"] == "no-report"
    assert context.metadata["loom"]["jail"]["requested"] == "container"


def test_with_nothing_synced_there_is_metadata_but_no_trajectory(agent):
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert not (agent.logs_dir / "trajectory.json").exists()
    assert context.metadata["loom"]["trajectory"] is None


def test_a_corrupt_session_database_does_not_fail_the_trial(agent):
    put_report(agent)
    directory = agent.logs_dir / "loom-session"
    directory.mkdir()
    (directory / "s-123.db").write_text("not sqlite")
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.metadata["loom"]["trajectory"] is None and context.n_input_tokens == 115


def test_the_api_key_is_scrubbed_from_the_trajectory(agent):
    key = "sk-ant-test-0123456789abcdef"
    directory = agent.logs_dir / "loom-session"
    directory.mkdir()
    sessiondb.write(
        directory / "s-123.db",
        [sessiondb.user_entry("e1", 1, f"the key is {key} (in prose)"),
         sessiondb.assistant_entry("e2", 2, [{"type": "text", "text": f"echo {key}"}])],
    )
    agent.populate_context_post_run(AgentContext())
    assert key not in (agent.logs_dir / "trajectory.json").read_text()


def test_the_trajectory_records_the_installed_release_as_the_agent_version(make_agent):
    built = make_agent(version="0.3.2")
    put_session(built)
    built.populate_context_post_run(AgentContext())
    assert json.loads((built.logs_dir / "trajectory.json").read_text())["agent"]["version"] == "0.3.2"
    assert built.to_agent_info().version == "0.3.2"
