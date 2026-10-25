"""Turn a finished Loom session database into an ATIF trajectory.

This is a Python port of `eval/atif.gleam`, the exporter Loom already has. The
reason it is a port and not a call is that `packages/eval` never ships in a
release: the task container holds `loom`, `loomd` and `loom-exec` and nothing
that can read a session. What a release does leave behind is the session's
SQLite file, whose entry and usage payloads are plain JSON (`core/codec`), so
the adapter copies the file out of the container and reads it here, on the
host, with the standard library.

The walk is the Gleam one, so the two exporters agree on what a trajectory is:

* A user message or an assistant message opens a step; steps are numbered from
  1 with no gaps. Compactions, branch summaries and custom entries are not
  conversation and are skipped.
* A tool result joins the step that most recently issued its call id. Ids are
  only unique within one assistant message, so "most recent" is the rule, and
  a result whose call was never seen belongs to no step and is dropped.
* Usage rows tied to an assistant entry become that step's metrics. Every row,
  tied or not, is summed into the final metrics, which is why those can exceed
  the sum of the steps.
* Thinking blocks never leave the session. They are opaque and signed by the
  provider for replay, so the trajectory carries the visible answer only.

It differs from the Gleam exporter in the ways Harbor's validator asks for:
a step's cost is omitted rather than reported as zero when no price was
configured (zero would read as "free", not as "unknown"), and the session
identity, the isolation label and the release go in `extra`.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.models.trajectories import (
    Agent,
    FinalMetrics,
    Metrics,
    Observation,
    ObservationResult,
    Step,
    ToolCall,
    Trajectory,
)

SCHEMA_VERSION = "ATIF-v1.7"
AGENT_NAME = "loom"

# The most entries read from one database; the bound the Gleam exporter and
# the trial runner share.
MAX_ENTRIES = 8192

REDACTED = "<redacted>"
_KEY_PREFIXES = ("sk-", "xai-", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_")


class SessionDatabaseError(RuntimeError):
    """The session database could not be read as a Loom session."""


def _token_character(char: str) -> bool:
    return char != "" and (char.lower() != char.upper() or char in "0123456789-_.")


def _redact_after(text: str, prefix: str, keep: str) -> str:
    """Redact the token after each standalone occurrence of `prefix`.

    An occurrence inside a longer word, or followed by nothing, is prose and
    is left alone. This is `cassette.redact_text`'s rule, copied so that the
    two exporters redact identically.
    """
    first, *rest = text.split(prefix)
    kept = first
    for part in rest:
        end = 0
        while end < len(part) and _token_character(part[end]):
            end += 1
        token, remainder = part[:end], part[end:]
        if (kept[-1:] != "" and _token_character(kept[-1:])) or token == "":
            kept = kept + prefix + part
        else:
            kept = kept + keep + REDACTED + remainder
    return kept


def scrub(text: str, secrets: tuple[str, ...] = ()) -> str:
    """Redact exact secret values, vendor key prefixes and `Bearer` tokens.

    Exact values come first so that a key the adapter knows is blanked even
    when it has no recognisable prefix. A fixed-length secret shorter than
    eight characters is skipped: blanking every occurrence of a short string
    would mangle ordinary text, and no API key is that short.
    """
    for secret in secrets:
        if len(secret) >= 8:
            text = text.replace(secret, REDACTED)
    for prefix in _KEY_PREFIXES:
        text = _redact_after(text, prefix, "")
    return _redact_after(text, "Bearer ", "Bearer ")


def _scrub_json(value: Any, secrets: tuple[str, ...]) -> Any:
    if isinstance(value, str):
        return scrub(value, secrets)
    if isinstance(value, list):
        return [_scrub_json(item, secrets) for item in value]
    if isinstance(value, dict):
        return {key: _scrub_json(item, secrets) for key, item in value.items()}
    return value


@dataclass(frozen=True)
class _Row:
    """One ledger row, reduced to what a step's metrics need."""

    entry_id: str | None
    adjustment: bool
    prompt_tokens: int
    completion_tokens: int
    cached_tokens: int
    cost: float
    priced: bool


def _iso(timestamp_ms: Any) -> str | None:
    if isinstance(timestamp_ms, bool) or not isinstance(timestamp_ms, int):
        return None
    try:
        return datetime.fromtimestamp(timestamp_ms / 1000, tz=timezone.utc).isoformat()
    except (OverflowError, OSError, ValueError):
        return None


def _text_of(blocks: Any) -> str:
    """The visible text of a content array; an image is named, never embedded."""
    if not isinstance(blocks, list):
        return ""
    parts: list[str] = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"])
        elif block.get("type") == "image":
            parts.append(f"[image: {block.get('mimeType', 'unknown')}]")
    return "\n".join(parts)


def _assistant_text(blocks: Any) -> str:
    """Answer text only. Thinking is dropped here, at the one place text is read."""
    if not isinstance(blocks, list):
        return ""
    return "\n".join(
        block["text"]
        for block in blocks
        if isinstance(block, dict)
        and block.get("type") == "text"
        and isinstance(block.get("text"), str)
    )


def _row_of(entry_id: Any, adjustment: Any, usage_blob: Any) -> _Row | None:
    try:
        usage = json.loads(usage_blob) if usage_blob is not None else None
    except (TypeError, ValueError):
        return None
    if not isinstance(usage, dict):
        return None

    def count(key: str) -> int:
        value = usage.get(key)
        return value if isinstance(value, int) and not isinstance(value, bool) else 0

    cost = usage.get("cost")
    total = cost.get("total") if isinstance(cost, dict) else None
    evidence = usage.get("evidence")
    cost_evidence = evidence.get("cost") if isinstance(evidence, dict) else None
    priced = isinstance(cost_evidence, dict) and cost_evidence.get("kind") == "estimated"
    return _Row(
        entry_id=entry_id if isinstance(entry_id, str) else None,
        adjustment=bool(adjustment),
        prompt_tokens=count("input") + count("cacheRead") + count("cacheWrite"),
        completion_tokens=count("output"),
        cached_tokens=count("cacheRead"),
        cost=float(total) if isinstance(total, (int, float)) and not isinstance(total, bool) else 0.0,
        priced=priced,
    )


def _sum_metrics(rows: list[_Row]) -> Metrics:
    priced = [row for row in rows if row.priced]
    return Metrics(
        prompt_tokens=sum(row.prompt_tokens for row in rows),
        completion_tokens=sum(row.completion_tokens for row in rows),
        cached_tokens=sum(row.cached_tokens for row in rows),
        cost_usd=sum(row.cost for row in priced) if priced else None,
    )


def from_entries(
    entries: list[dict[str, Any]],
    ledger: list[_Row],
    *,
    session_id: str,
    agent_version: str,
    model_name: str | None,
    secrets: tuple[str, ...] = (),
    extra: dict[str, Any] | None = None,
    agent_extra: dict[str, Any] | None = None,
) -> Trajectory | None:
    """Walk decoded entries, oldest first, into a trajectory.

    Returns `None` for a session with no conversation in it, because ATIF
    requires at least one step and an empty document would be invalid.
    """
    by_entry: dict[str, list[_Row]] = {}
    for row in ledger:
        if row.entry_id is not None and not row.adjustment:
            by_entry.setdefault(row.entry_id, []).append(row)

    steps: list[Step] = []
    owners: dict[str, int] = {}
    skipped = 0
    first_model: str | None = None

    for entry in entries:
        if entry.get("type") != "message" or not isinstance(entry.get("message"), dict):
            skipped += 1
            continue
        message = entry["message"]
        role = message.get("role")
        step_id = len(steps) + 1
        timestamp = _iso(message.get("timestamp", entry.get("timestamp")))

        if role == "user":
            steps.append(
                Step(
                    step_id=step_id,
                    timestamp=timestamp,
                    source="user",
                    message=scrub(_text_of(message.get("content")), secrets),
                )
            )
        elif role == "assistant":
            model = message.get("model") if isinstance(message.get("model"), str) else None
            first_model = first_model or model
            calls: list[ToolCall] = []
            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "toolCall":
                    arguments = block.get("arguments")
                    if not isinstance(arguments, dict):
                        # ATIF wants an object; keep a scalar rather than lose it.
                        arguments = {"value": arguments}
                    call = ToolCall(
                        tool_call_id=str(block.get("id", "")),
                        function_name=str(block.get("name", "")),
                        arguments=_scrub_json(arguments, secrets),
                    )
                    calls.append(call)
                    owners[call.tool_call_id] = step_id
            rows = by_entry.get(str(entry.get("id")))
            steps.append(
                Step(
                    step_id=step_id,
                    timestamp=timestamp,
                    source="agent",
                    model_name=model,
                    message=scrub(_assistant_text(message.get("content")), secrets),
                    tool_calls=calls or None,
                    metrics=_sum_metrics(rows) if rows else None,
                    llm_call_count=1,
                )
            )
        elif role == "toolResult":
            call_id = str(message.get("toolCallId", ""))
            owner = owners.get(call_id)
            if owner is None:
                # A result whose call was never seen belongs to no step.
                skipped += 1
                continue
            step = steps[owner - 1]
            result = ObservationResult(
                source_call_id=call_id,
                content=scrub(_text_of(message.get("content")), secrets),
                extra={"is_error": True} if message.get("isError") is True else None,
            )
            if step.observation is None:
                step.observation = Observation(results=[result])
            else:
                step.observation.results.append(result)
        else:
            # A custom message is application data with no ATIF source.
            skipped += 1

    if not steps:
        return None

    total = _sum_metrics(ledger) if ledger else None
    final = FinalMetrics(
        total_prompt_tokens=total.prompt_tokens if total else None,
        total_completion_tokens=total.completion_tokens if total else None,
        total_cached_tokens=total.cached_tokens if total else None,
        total_cost_usd=total.cost_usd if total else None,
        total_steps=len(steps),
    )
    trajectory_extra = dict(extra or {})
    trajectory_extra["entries_not_exported"] = skipped
    return Trajectory(
        schema_version=SCHEMA_VERSION,
        session_id=session_id,
        agent=Agent(
            name=AGENT_NAME,
            version=agent_version,
            model_name=model_name or first_model,
            extra=agent_extra,
        ),
        steps=steps,
        final_metrics=final,
        notes=(
            "Exported from the Loom session database by loom_harbor, a port of "
            "eval/atif.gleam. Not present: the system prompt and tool "
            "definitions (the session store does not hold them) and thinking "
            "blocks (opaque and provider-signed, never exported)."
        ),
        extra=trajectory_extra,
    )


def _read_database(path: Path, label: str) -> tuple[list[dict[str, Any]], list[_Row], int]:
    """Read entries, ledger rows and the branch count from a copy of the file.

    `label` is the original file's name, because the copy's is an implementation detail.
    """
    try:
        connection = sqlite3.connect(str(path))
        try:
            connection.execute("PRAGMA query_only = ON")
            rows = connection.execute(
                "SELECT payload FROM entries ORDER BY seq LIMIT ?", (MAX_ENTRIES,)
            ).fetchall()
            ledger_rows = connection.execute(
                "SELECT entry_id, adjustment, usage FROM usage_ledger ORDER BY seq"
            ).fetchall()
            branches = connection.execute("SELECT COUNT(*) FROM branch_meta").fetchone()[0]
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise SessionDatabaseError(f"cannot read {label} as a Loom session: {exc}") from exc

    entries: list[dict[str, Any]] = []
    for (payload,) in rows:
        try:
            decoded = json.loads(payload if isinstance(payload, str) else bytes(payload))
        except (TypeError, ValueError) as exc:
            raise SessionDatabaseError(f"an entry payload in {label} is not JSON: {exc}") from exc
        if isinstance(decoded, dict):
            entries.append(decoded)
    ledger = [row for row in (_row_of(*raw) for raw in ledger_rows) if row is not None]
    return entries, ledger, int(branches)


def from_session_db(
    path: Path,
    *,
    session_id: str,
    agent_version: str,
    model_name: str | None,
    secrets: tuple[str, ...] = (),
    extra: dict[str, Any] | None = None,
    agent_extra: dict[str, Any] | None = None,
) -> Trajectory | None:
    """Read a downloaded session database (and its `-wal`) into a trajectory.

    The file is copied to a private directory first, together with its
    write-ahead log when one sits beside it: the log holds commits the main
    file has not absorbed, so a copy without it would silently lose the
    newest turns, and opening the original could write a `-shm` next to the
    evidence. Only the copy is ever opened.
    """
    with tempfile.TemporaryDirectory(prefix="loom-atif-") as scratch:
        copy = Path(scratch) / "session.db"
        shutil.copyfile(path, copy)
        wal = Path(str(path) + "-wal")
        if wal.is_file():
            shutil.copyfile(wal, Path(str(copy) + "-wal"))
        entries, ledger, branches = _read_database(copy, path.name)

    merged = dict(extra or {})
    merged["storage_branches"] = branches
    return from_entries(
        entries,
        ledger,
        session_id=session_id,
        agent_version=agent_version,
        model_name=model_name,
        secrets=secrets,
        extra=merged,
        agent_extra=agent_extra,
    )
