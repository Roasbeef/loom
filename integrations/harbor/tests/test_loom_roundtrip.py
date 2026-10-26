"""Compare the port with Loom's own exporter on a database Loom really wrote.

`tests/fixtures/loom-session.db` and its `-wal` were written by Loom's
`storage/sqlite` package (generator: `fixtures/generate_session.gleam.txt`),
copied while the writer was still open exactly as the adapter copies a live
session, so the entries sit in the write-ahead log and not in the main file.
`loom-session.gleam-atif.json` is what `eval/atif.gleam` exported from the same
session. The port must agree with it on everything the Gleam exporter says.
"""

import json
import shutil
from pathlib import Path

from harbor.utils.trajectory_validator import TrajectoryValidator

from loom_harbor import trajectory

FIXTURES = Path(__file__).parent / "fixtures"


def exported(tmp_path: Path):
    shutil.copy(FIXTURES / "loom-session.db", tmp_path / "s.db")
    shutil.copy(FIXTURES / "loom-session.db-wal", tmp_path / "s.db-wal")
    return trajectory.from_session_db(
        tmp_path / "s.db", session_id="s", agent_version="0.3.2", model_name="harbor/claude-test"
    )


def comparable(step: dict) -> dict:
    """The fields the Gleam exporter writes, without the ones only the port adds."""
    keep = {k: step[k] for k in ("step_id", "source", "message") if k in step}
    for call in step.get("tool_calls", []):
        keep.setdefault("tool_calls", []).append(
            {k: call[k] for k in ("tool_call_id", "function_name", "arguments")}
        )
    if "observation" in step:
        keep["observation"] = [
            {"source_call_id": r["source_call_id"], "content": r["content"]}
            for r in step["observation"]["results"]
        ]
    if "metrics" in step:
        keep["metrics"] = {
            k: step["metrics"][k] for k in ("prompt_tokens", "completion_tokens", "cached_tokens", "cost_usd")
        }
    return keep


def test_entries_that_live_only_in_the_wal_are_read(tmp_path):
    assert len(exported(tmp_path).steps) == 3


def test_the_port_agrees_with_the_gleam_exporter_step_for_step(tmp_path):
    ours = exported(tmp_path).to_json_dict()
    theirs = json.loads((FIXTURES / "loom-session.gleam-atif.json").read_text())
    assert [comparable(s) for s in ours["steps"]] == [comparable(s) for s in theirs["steps"]]
    assert ours["final_metrics"] == theirs["final_metrics"]


def test_the_credential_in_a_tool_call_is_redacted_exactly_as_loom_does(tmp_path):
    text = json.dumps(exported(tmp_path).to_json_dict())
    assert "sk-livekey123" not in text and "SECRET REASONING" not in text


def test_the_real_export_validates_against_harbor(tmp_path):
    validator = TrajectoryValidator()
    assert validator.validate(exported(tmp_path).to_json_dict()), validator.errors
