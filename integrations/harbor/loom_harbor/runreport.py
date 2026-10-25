"""Read what `loom run -p` prints, and what `loom-exec --self-test` prints.

`loom run` writes exactly one JSON object to standard output and everything a
person might read to standard error; its exit status is the verdict (`0`
completed, `1` failed or aborted, `2` bad arguments, `3` no daemon, `124`
deadline). The object's shape is the one `tui/run.render` writes:

    {"session_id": ..., "session_db": ..., "state_dir": ..., "outcome": ...,
     "reason": ..., "turns": N, "usage": {...} | null, "elapsed_ms": N,
     "jail": {"posture": "enforced|degraded|unverified", "selftest": {...}},
     "model": {"provider": ..., "model_id": ...} | null}

The `jail` member is mandatory in Loom's own contract, because a score earned
with a degraded jail means something different from one earned with all of it.
This reader holds the adapter to the same rule: a report without it is
malformed, not merely incomplete.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

OUTCOMES = ("completed", "failed", "aborted", "timeout")
POSTURES = ("enforced", "degraded", "unverified")

# `loom run`'s exit statuses, by what they mean to a harness.
EXIT_COMPLETED = 0
EXIT_FAILED = 1
EXIT_BAD_ARGUMENTS = 2
EXIT_NO_DAEMON = 3
EXIT_TIMEOUT = 124

# The statuses that mean "the agent ran and this is how it ended". Anything
# else means no run happened, which is the adapter's problem, not the model's.
RAN_EXIT_CODES = (EXIT_COMPLETED, EXIT_FAILED, EXIT_TIMEOUT)


class RunReportError(ValueError):
    """The output of `loom run` is not a report the adapter can trust."""


@dataclass(frozen=True)
class Usage:
    """The session's cumulative usage, as `core/codec.encode_usage` writes it."""

    input: int
    output: int
    cache_read: int
    cache_write: int
    total_tokens: int
    cost_total: float
    # How much of the token count the provider actually reported:
    # `complete`, `partial` or `unknown`. `unknown` means the numbers are
    # zeros that stand for "nobody told us", so they must not be reported
    # as measurements.
    token_coverage: str
    # `estimated` when a configured price produced `cost_total`, anything
    # else (`unavailable`, `no-expense`) when the cost is not a measurement.
    cost_kind: str

    @property
    def prompt_tokens(self) -> int:
        """Input tokens as ATIF counts them: uncached plus both cache buckets."""
        return self.input + self.cache_read + self.cache_write

    @property
    def tokens_reported(self) -> bool:
        return self.token_coverage != "unknown"

    @property
    def cost_reported(self) -> bool:
        return self.cost_kind == "estimated"


@dataclass(frozen=True)
class Jail:
    """The label `loom run` earned for the sandbox helper beside the server."""

    posture: str
    enforced: int | None
    skipped: int | None
    reason: str | None


@dataclass(frozen=True)
class RunReport:
    session_id: str
    outcome: str
    reason: str | None
    turns: int
    elapsed_ms: int
    jail: Jail
    usage: Usage | None
    model: dict[str, str] | None
    session_db: str | None
    state_dir: str | None


def _integer(document: dict[str, Any], key: str) -> int:
    value = document.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise RunReportError(f"report field {key!r} must be an integer, got {value!r}")
    return value


def _usage(value: Any) -> Usage | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise RunReportError("report field 'usage' must be an object or null")
    cost = value.get("cost")
    evidence = value.get("evidence")
    if not isinstance(cost, dict) or not isinstance(evidence, dict):
        raise RunReportError("usage must carry 'cost' and 'evidence' objects")
    evidence_cost = evidence.get("cost")
    kind = evidence_cost.get("kind") if isinstance(evidence_cost, dict) else None
    total = cost.get("total")
    if not isinstance(total, (int, float)) or isinstance(total, bool):
        raise RunReportError("usage cost has no numeric total")
    return Usage(
        input=_integer(value, "input"),
        output=_integer(value, "output"),
        cache_read=_integer(value, "cacheRead"),
        cache_write=_integer(value, "cacheWrite"),
        total_tokens=_integer(value, "totalTokens"),
        cost_total=float(total),
        token_coverage=str(evidence.get("tokens", "unknown")),
        cost_kind=str(kind) if kind is not None else "unavailable",
    )


def _jail(value: Any) -> Jail:
    if not isinstance(value, dict):
        raise RunReportError(
            "report has no 'jail' member; Loom labels every run's isolation, so "
            "an unlabelled report is not one the adapter will score"
        )
    posture = value.get("posture")
    if posture not in POSTURES:
        raise RunReportError(f"jail posture {posture!r} is not one of {POSTURES}")
    selftest = value.get("selftest")
    selftest = selftest if isinstance(selftest, dict) else {}
    return Jail(
        posture=posture,
        enforced=selftest.get("enforced") if isinstance(selftest.get("enforced"), int) else None,
        skipped=selftest.get("skipped") if isinstance(selftest.get("skipped"), int) else None,
        reason=selftest.get("reason") if isinstance(selftest.get("reason"), str) else None,
    )


def _model(value: Any) -> dict[str, str] | None:
    if not isinstance(value, dict):
        return None
    provider, model_id = value.get("provider"), value.get("model_id")
    if isinstance(provider, str) and isinstance(model_id, str):
        return {"provider": provider, "model_id": model_id}
    return None


def _optional_text(document: dict[str, Any], key: str) -> str | None:
    value = document.get(key)
    return value if isinstance(value, str) else None


def parse_run_output(stdout: str) -> RunReport:
    """Parse the JSON line `loom run` printed.

    The contract is one object and nothing else, but a launcher wrapper could
    print a notice first, so the last line that looks like an object is the
    report. Anything that does not decode, or lacks a mandatory member, raises
    `RunReportError` naming what is wrong.
    """
    candidates = [line for line in stdout.splitlines() if line.strip().startswith("{")]
    if not candidates:
        raise RunReportError("loom run printed no JSON report on standard output")
    try:
        document = json.loads(candidates[-1])
    except json.JSONDecodeError as exc:
        raise RunReportError(f"loom run's report is not valid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise RunReportError("loom run's report is not a JSON object")

    session_id = document.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        raise RunReportError("report has no 'session_id'")
    outcome = document.get("outcome")
    if outcome not in OUTCOMES:
        raise RunReportError(f"report outcome {outcome!r} is not one of {OUTCOMES}")

    return RunReport(
        session_id=session_id,
        outcome=outcome,
        reason=_optional_text(document, "reason"),
        turns=_integer(document, "turns"),
        elapsed_ms=_integer(document, "elapsed_ms"),
        jail=_jail(document.get("jail")),
        usage=_usage(document.get("usage")),
        model=_model(document.get("model")),
        session_db=_optional_text(document, "session_db"),
        state_dir=_optional_text(document, "state_dir"),
    )


@dataclass(frozen=True)
class SelfTest:
    """The verdict of `loom-exec --self-test`, labelled the way `loom run` does."""

    posture: str
    enforced: int
    skipped: int
    failed: int
    exit_code: int


# The helper prints `enforced (N):` and `skipped (N) ...` summary lines, and one
# `  FAILED    <probe>` line per probe that tried to enforce and could not.
_COUNT = re.compile(r"^\s*(enforced|skipped)\s*\((\d+)\)", re.MULTILINE)
_FAILED = re.compile(r"^\s*FAILED\s", re.MULTILINE)


def parse_self_test(exit_code: int, output: str) -> SelfTest:
    """Label a self-test the way `tui/run.posture_of` does.

    Only a clean exit carrying the helper's own `RESULT: OK` line earns a
    label better than `unverified`; then any skipped probe makes it
    `degraded`. The counts come from the helper's `enforced (N)` and
    `skipped (N)` summary lines, zero when absent; `failed` counts the
    `FAILED` probe lines, which is what an unprivileged container prints when
    bubblewrap cannot create a user namespace.
    """
    counts = {name: int(number) for name, number in _COUNT.findall(output)}
    enforced = counts.get("enforced", 0)
    skipped = counts.get("skipped", 0)
    failed = len(_FAILED.findall(output))
    if exit_code != 0 or "RESULT: OK" not in output:
        posture = "unverified"
    elif skipped:
        posture = "degraded"
    else:
        posture = "enforced"
    return SelfTest(posture, enforced, skipped, failed, exit_code)
