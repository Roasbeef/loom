"""Session database to ATIF, checked against Harbor's own validator."""

import json
import subprocess
import sys

import pytest
from harbor.models.trajectories import Trajectory
from harbor.utils.trajectory_validator import TrajectoryValidator

from loom_harbor import trajectory
from tests import sessiondb


def convert(path, **kwargs):
    defaults = dict(session_id="s-123", agent_version="0.3.2", model_name="anthropic/claude-opus-4-5")
    return trajectory.from_session_db(path, **{**defaults, **kwargs})


@pytest.fixture
def sample(tmp_path):
    return sessiondb.sample_session(tmp_path / "s-123.db")


def test_steps_are_contiguous_from_one_and_sourced(sample):
    document = convert(sample)
    assert [step.step_id for step in document.steps] == [1, 2, 3]
    assert [step.source for step in document.steps] == ["user", "agent", "agent"]
    assert document.steps[0].message == "make /app/hello.txt contain hi"
    assert document.steps[2].message == "Done."


def test_results_join_the_step_that_issued_their_call(sample):
    step = convert(sample).steps[1]
    assert [call.tool_call_id for call in step.tool_calls] == ["c1", "c2"]
    assert step.tool_calls[0].arguments == {"command": "echo hi > /app/hello.txt"}
    assert [(r.source_call_id, r.content) for r in step.observation.results] == [("c1", ""), ("c2", "hi\n")]


def test_thinking_is_never_exported(sample):
    text = json.dumps(convert(sample).to_json_dict())
    assert "SECRET REASONING" not in text
    assert convert(sample).steps[1].reasoning_content is None


def test_a_call_id_reused_later_joins_its_most_recent_issuer(tmp_path):
    entries = [
        sessiondb.user_entry("e1", 1, "go"),
        sessiondb.assistant_entry("e2", 2, [sessiondb.tool_call("c1", "bash", {"command": "a"})]),
        sessiondb.result_entry("e3", 3, "c1", "first"),
        sessiondb.assistant_entry("e4", 4, [sessiondb.tool_call("c1", "bash", {"command": "b"})]),
        sessiondb.result_entry("e5", 5, "c1", "second"),
    ]
    document = convert(sessiondb.write(tmp_path / "x.db", entries))
    assert [s.observation.results[0].content for s in document.steps[1:]] == ["first", "second"]


def test_an_orphan_result_is_dropped_and_counted(tmp_path):
    entries = [sessiondb.user_entry("e1", 1, "go"), sessiondb.result_entry("e2", 2, "ghost", "x")]
    document = convert(sessiondb.write(tmp_path / "x.db", entries))
    assert len(document.steps) == 1
    assert document.extra["entries_not_exported"] == 1


def test_step_metrics_come_from_ledger_rows_tied_to_the_entry(sample):
    steps = convert(sample).steps
    # e2 has one row (100 + 10 cached + 0 written = 110 prompt); its adjustment row is not a step cost.
    assert (steps[1].metrics.prompt_tokens, steps[1].metrics.completion_tokens) == (110, 20)
    assert steps[1].metrics.cached_tokens == 10 and steps[1].metrics.cost_usd == 0.5
    assert steps[0].metrics is None


def test_final_metrics_sum_every_row_including_untied_and_adjustments(sample):
    final = convert(sample).final_metrics
    # prompt: (100+10) + (50+60) + 7 + 1 ; completion: 20 + 5 + 0 + 1
    assert (final.total_prompt_tokens, final.total_completion_tokens) == (110 + 110 + 7 + 1, 26)
    assert final.total_cached_tokens == 70
    assert final.total_cost_usd == pytest.approx(0.76)
    assert final.total_steps == 3


def test_unpriced_runs_report_no_cost_rather_than_zero(tmp_path):
    entries = [
        sessiondb.user_entry("e1", 1, "go"),
        sessiondb.assistant_entry("e2", 2, [{"type": "text", "text": "ok"}]),
    ]
    ledger = [("u1", "e2", False, sessiondb.usage(cost=None))]
    document = convert(sessiondb.write(tmp_path / "x.db", entries, ledger))
    assert document.steps[1].metrics.cost_usd is None
    assert document.final_metrics.total_cost_usd is None


def test_no_ledger_means_no_metrics_at_all(tmp_path):
    entries = [sessiondb.user_entry("e1", 1, "go")]
    document = convert(sessiondb.write(tmp_path / "x.db", entries))
    assert document.final_metrics.total_prompt_tokens is None


def test_scalar_tool_arguments_are_kept_under_a_key(tmp_path):
    entries = [
        sessiondb.user_entry("e1", 1, "go"),
        sessiondb.assistant_entry("e2", 2, [sessiondb.tool_call("c1", "bash", "ls -la")]),
    ]
    call = convert(sessiondb.write(tmp_path / "x.db", entries)).steps[1].tool_calls[0]
    assert call.arguments == {"value": "ls -la"}


def test_tool_errors_are_flagged_on_the_observation(tmp_path):
    entries = [
        sessiondb.user_entry("e1", 1, "go"),
        sessiondb.assistant_entry("e2", 2, [sessiondb.tool_call("c1", "bash", {})]),
        sessiondb.result_entry("e3", 3, "c1", "boom", is_error=True),
    ]
    result = convert(sessiondb.write(tmp_path / "x.db", entries)).steps[1].observation.results[0]
    assert result.extra == {"is_error": True}


def test_compaction_and_custom_entries_are_not_conversation(tmp_path):
    entries = [
        sessiondb.user_entry("e1", 1, "go"),
        {"id": "e2", "parentId": None, "seq": 2, "timestamp": sessiondb.T0, "type": "compaction",
         "summary": "s", "retainedTail": [], "tokensBefore": 1, "fromHook": False},
        {"id": "e3", "parentId": None, "seq": 3, "timestamp": sessiondb.T0, "type": "custom",
         "customType": "x", "data": {}},
    ]
    document = convert(sessiondb.write(tmp_path / "x.db", entries))
    assert len(document.steps) == 1 and document.extra["entries_not_exported"] == 2


def test_an_empty_session_has_no_trajectory(tmp_path):
    assert convert(sessiondb.write(tmp_path / "x.db", [])) is None


def test_timestamps_are_iso_8601_utc(sample):
    assert convert(sample).steps[0].timestamp.startswith("2025-10-09T")


def test_provenance_lands_in_agent_and_root_extra(sample):
    document = convert(
        sample, agent_extra={"jail": {"requested": "container"}}, extra={"loom_run": {"outcome": "completed"}}
    )
    assert document.agent.extra == {"jail": {"requested": "container"}}
    assert document.extra["loom_run"] == {"outcome": "completed"}
    assert document.extra["storage_branches"] == 1
    assert document.agent.name == "loom" and document.agent.version == "0.3.2"
    assert "system prompt" in document.notes


def test_the_original_database_is_never_opened(sample):
    before = sample.stat().st_mtime_ns, sample.read_bytes()
    convert(sample)
    assert (sample.stat().st_mtime_ns, sample.read_bytes()) == before
    assert not list(sample.parent.glob("*-shm"))


def test_a_write_ahead_log_beside_the_file_is_read_too(tmp_path):
    import sqlite3

    path = tmp_path / "live.db"
    connection = sqlite3.connect(str(path))
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA wal_autocheckpoint=0")
    connection.executescript(sessiondb.SCHEMA)
    entry = sessiondb.user_entry("e1", 1, "in the log only")
    connection.execute(
        "INSERT INTO entries VALUES (?, NULL, 1, 'message', NULL, ?, ?)",
        ("e1", entry["timestamp"], json.dumps(entry).encode()),
    )
    connection.commit()
    assert (tmp_path / "live.db-wal").stat().st_size > 0
    # Copy while the writer is still open, as the adapter copies from a container.
    copy = tmp_path / "out" / "live.db"
    copy.parent.mkdir()
    copy.write_bytes(path.read_bytes())
    (tmp_path / "out" / "live.db-wal").write_bytes((tmp_path / "live.db-wal").read_bytes())
    connection.close()
    assert convert(copy).steps[0].message == "in the log only"


def test_a_file_that_is_not_a_session_is_a_clear_error(tmp_path):
    bogus = tmp_path / "bogus.db"
    bogus.write_text("not sqlite")
    with pytest.raises(trajectory.SessionDatabaseError, match="bogus.db"):
        convert(bogus)


def test_a_non_json_payload_is_a_clear_error(tmp_path):
    path = tmp_path / "bad.db"
    sessiondb.write(path, [sessiondb.user_entry("e1", 1, "x")])
    import sqlite3

    connection = sqlite3.connect(str(path))
    connection.execute("UPDATE entries SET payload = ?", (b"\xff\xfe",))
    connection.commit()
    connection.close()
    with pytest.raises(trajectory.SessionDatabaseError, match="not JSON"):
        convert(path)


# ---------------------------------------------------------------- validity

def test_the_document_validates_against_harbors_validator(sample):
    document = convert(sample).to_json_dict()
    validator = TrajectoryValidator()
    assert validator.validate(document), validator.errors
    # And round-trips through Harbor's model, the path Harbor itself reads it with.
    assert Trajectory.model_validate_json(json.dumps(document)).steps[1].tool_calls[0].function_name == "bash"


def test_the_written_file_passes_harbors_validator_cli(sample, tmp_path):
    out = tmp_path / "trajectory.json"
    out.write_text(json.dumps(convert(sample).to_json_dict(), indent=2))
    run = subprocess.run(
        [sys.executable, "-m", "harbor.utils.trajectory_validator", str(out)],
        capture_output=True, text=True,
    )
    assert run.returncode == 0, run.stdout + run.stderr


# ------------------------------------------------------------------- scrub

@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("key sk-abc123", "key <redacted>"),
        ("commit 3f9a1c2b and test_names_are_kept", "commit 3f9a1c2b and test_names_are_kept"),
        ("ghp_AbC123 and github_pat_XyZ-9", "<redacted> and <redacted>"),
        ("Authorization: Bearer abc.def-123", "Authorization: Bearer <redacted>"),
        ("task-sk-inside-a-word", "task-sk-inside-a-word"),
        ("trailing sk-", "trailing sk-"),
    ],
)
def test_scrub_follows_the_replay_lanes_prefix_rule(text, expected):
    assert trajectory.scrub(text) == expected


def test_exact_secrets_are_blanked_but_short_strings_are_not():
    assert trajectory.scrub("use hunter2-longer-secret now", ("hunter2-longer-secret",)) == "use <redacted> now"
    assert trajectory.scrub("a cat sat", ("cat",)) == "a cat sat"


def test_secrets_are_scrubbed_in_every_place_text_lands(tmp_path):
    key = "sk-ant-live-key-0123456789"
    entries = [
        sessiondb.user_entry("e1", 1, f"my key is {key}"),
        sessiondb.assistant_entry("e2", 2, [sessiondb.tool_call("c1", "bash", {"command": f"echo {key}"})]),
        sessiondb.result_entry("e3", 3, "c1", f"out {key}"),
    ]
    text = json.dumps(convert(sessiondb.write(tmp_path / "x.db", entries)).to_json_dict())
    assert key not in text and "sk-ant" not in text


# ------------------------------------------------------- provider error text


def test_the_provider_error_is_read_from_the_last_failed_answer():
    fixtures = __import__("pathlib").Path(__file__).parent / "fixtures"
    text = trajectory.last_error_message(fixtures / "failed-session.db")
    assert text.startswith("provider returned http 429 (rate_limit_error):")


def test_a_session_without_a_failed_answer_has_no_error_text(tmp_path):
    assert trajectory.last_error_message(sessiondb.sample_session(tmp_path / "ok.db")) is None


def test_an_unreadable_database_has_no_error_text_rather_than_an_error(tmp_path):
    (tmp_path / "x.db").write_text("nope")
    assert trajectory.last_error_message(tmp_path / "x.db") is None
