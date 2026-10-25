"""JSON-line parsing: success, failure, malformed, missing jail label."""

import json

import pytest

from loom_harbor.runreport import RunReportError, parse_run_output, parse_self_test
from tests.conftest import REPORT


def test_a_completed_report_parses_every_field():
    report = parse_run_output(REPORT + "\n")
    assert (report.session_id, report.outcome, report.turns, report.elapsed_ms) == ("s-123", "completed", 3, 4200)
    assert report.jail.posture == "degraded"
    assert (report.jail.enforced, report.jail.skipped) == (6, 4)
    assert report.model == {"provider": "harbor", "model_id": "claude-opus-4-5"}
    assert report.session_db.endswith("s-123.db")
    usage = report.usage
    assert usage is not None
    assert usage.prompt_tokens == 115  # input + cacheRead + cacheWrite, as ATIF counts them
    assert (usage.output, usage.cache_read, usage.cost_total) == (20, 10, 0.3)
    assert usage.tokens_reported and usage.cost_reported


def test_a_failed_report_carries_its_reason():
    document = json.loads(REPORT)
    document.update(outcome="failed", reason="provider rejected the request: 429 rate limit")
    report = parse_run_output(json.dumps(document))
    assert (report.outcome, report.reason) == ("failed", "provider rejected the request: 429 rate limit")


@pytest.mark.parametrize("outcome", ["aborted", "timeout"])
def test_every_outcome_word_loom_prints_is_accepted(outcome):
    assert parse_run_output(json.dumps({**json.loads(REPORT), "outcome": outcome})).outcome == outcome


def test_a_null_usage_is_allowed_because_a_run_can_end_before_any_cut():
    assert parse_run_output(json.dumps({**json.loads(REPORT), "usage": None})).usage is None


def test_unpriced_usage_is_not_reported_as_a_cost():
    document = json.loads(REPORT)
    document["usage"]["evidence"]["cost"] = {"kind": "unavailable"}
    document["usage"]["evidence"]["tokens"] = "unknown"
    usage = parse_run_output(json.dumps(document)).usage
    assert not usage.cost_reported and not usage.tokens_reported


def test_a_missing_jail_label_is_malformed_not_incomplete():
    document = json.loads(REPORT)
    del document["jail"]
    with pytest.raises(RunReportError, match="jail"):
        parse_run_output(json.dumps(document))


def test_an_unknown_jail_posture_is_refused():
    document = json.loads(REPORT)
    document["jail"]["posture"] = "fine"
    with pytest.raises(RunReportError, match="posture"):
        parse_run_output(json.dumps(document))


def test_an_unverified_label_carries_its_reason():
    document = json.loads(REPORT)
    document["jail"] = {"posture": "unverified", "selftest": {"reason": "self-test exited 2"}}
    jail = parse_run_output(json.dumps(document)).jail
    assert (jail.posture, jail.reason, jail.enforced) == ("unverified", "self-test exited 2", None)


@pytest.mark.parametrize("text", ["", "   \n", "plain words", "starting daemon...\n"])
def test_output_with_no_json_object_is_refused(text):
    with pytest.raises(RunReportError, match="no JSON report"):
        parse_run_output(text)


def test_truncated_json_is_refused():
    with pytest.raises(RunReportError, match="not valid JSON"):
        parse_run_output(REPORT[:60])


@pytest.mark.parametrize("field", ["session_id", "outcome", "turns", "elapsed_ms"])
def test_a_missing_mandatory_field_is_refused(field):
    document = json.loads(REPORT)
    del document[field]
    with pytest.raises(RunReportError):
        parse_run_output(json.dumps(document))


def test_a_wrong_type_is_refused_rather_than_coerced():
    with pytest.raises(RunReportError, match="turns"):
        parse_run_output(json.dumps({**json.loads(REPORT), "turns": "3"}))


def test_a_notice_before_the_report_is_tolerated_and_the_last_object_wins():
    assert parse_run_output("starting\n" + REPORT + "\n").session_id == "s-123"


ENFORCED = "  ENFORCED  a\n==== enforcement summary ====\nenforced (11):\n  + a\nskipped (0) — NOT verified in this environment:\n\nRESULT: OK (skips are environmental, not passes)\n"
DEGRADED = ENFORCED.replace("skipped (0)", "skipped (1)")
CONTAINER = "  FAILED    bwrap (userns)\n" * 9 + "enforced (0):\nskipped (2) — NOT\n\nRESULT: FAIL (an enforceable probe did not enforce)\n"


def test_self_test_labels_follow_tui_run_posture_of():
    assert parse_self_test(0, ENFORCED).posture == "enforced"
    assert parse_self_test(0, DEGRADED).posture == "degraded"
    assert parse_self_test(0, DEGRADED).skipped == 1
    # A nonzero status or a missing RESULT: OK earns nothing.
    assert parse_self_test(1, ENFORCED).posture == "unverified"
    assert parse_self_test(0, "garbage").posture == "unverified"


def test_a_plain_docker_self_test_counts_its_failures():
    result = parse_self_test(1, CONTAINER)
    assert (result.posture, result.enforced, result.skipped, result.failed) == ("unverified", 0, 2, 9)


def test_lines_printed_by_loom_runs_own_renderer_parse():
    """`fixtures/loom-run-reports.jsonl` is `tui/run.render` output for four verdicts."""
    from pathlib import Path

    lines = (Path(__file__).parent / "fixtures" / "loom-run-reports.jsonl").read_text().splitlines()
    reports = [parse_run_output(line) for line in lines]
    assert [r.outcome for r in reports] == ["completed", "failed", "timeout", "aborted"]
    assert [r.jail.posture for r in reports] == ["degraded", "enforced", "unverified", "enforced"]
    assert reports[1].reason == "the run failed: provider_error"
    assert reports[2].usage is None and reports[2].model is None
    assert reports[0].usage.prompt_tokens == 115 and reports[0].usage.cost_reported
