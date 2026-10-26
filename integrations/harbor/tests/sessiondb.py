"""Build a session database shaped like the one Loom's storage package writes.

The schema is `packages/storage/sql/session.sql` and the payloads are what
`core/codec.encode_entry` and `encode_usage` produce, so the converter is
tested against the real wire shapes. `tests/test_loom_roundtrip.py` checks the
same converter against a database the Gleam storage package really wrote,
when a Gleam toolchain is present.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS entries(
  id TEXT PRIMARY KEY, parent_id TEXT, seq INTEGER, type TEXT,
  custom_type TEXT, ts INTEGER, payload BLOB) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS usage_ledger(
  id TEXT PRIMARY KEY, seq INTEGER, entry_id TEXT, adjustment INTEGER,
  usage BLOB, details BLOB) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS branch_meta(
  branch_id TEXT PRIMARY KEY, tip_entry_id TEXT, tip_seq INTEGER,
  base_branch_id TEXT, base_seq INTEGER);
"""

T0 = 1_760_000_000_000  # an arbitrary Unix-millisecond instant


def usage(
    input: int = 100,
    output: int = 20,
    cache_read: int = 10,
    cache_write: int = 0,
    cost: float | None = 0.5,
    tokens: str = "complete",
) -> dict[str, Any]:
    """A usage object as `core/codec.encode_usage` writes it."""
    priced = cost is not None
    return {
        "input": input,
        "output": output,
        "cacheRead": cache_read,
        "cacheWrite": cache_write,
        "totalTokens": input + output + cache_read + cache_write,
        "cost": {
            "input": 0.0,
            "output": 0.0,
            "cacheRead": 0.0,
            "cacheWrite": 0.0,
            "total": cost or 0.0,
        },
        "evidence": {
            "version": 1,
            "tokens": tokens,
            "billing": "api",
            "cost": (
                {"kind": "estimated", "coverage": "complete", "basis": "api-rates"}
                if priced
                else {"kind": "unavailable"}
            ),
        },
    }


def user_entry(entry_id: str, seq: int, text: str) -> dict[str, Any]:
    return {
        "id": entry_id,
        "parentId": None,
        "seq": seq,
        "timestamp": T0 + seq * 1000,
        "type": "message",
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": text}],
            "timestamp": T0 + seq * 1000,
            "origin": {"kind": "human"},
        },
    }


def assistant_entry(
    entry_id: str,
    seq: int,
    content: list[dict[str, Any]],
    model: str = "claude-test",
) -> dict[str, Any]:
    return {
        "id": entry_id,
        "parentId": None,
        "seq": seq,
        "timestamp": T0 + seq * 1000,
        "type": "message",
        "message": {
            "role": "assistant",
            "content": content,
            "api": "anthropic-messages",
            "provider": "harbor",
            "model": model,
            "usage": usage(),
            "stopReason": "toolUse" if any(b.get("type") == "toolCall" for b in content) else "stop",
            "timestamp": T0 + seq * 1000,
        },
    }


def tool_call(call_id: str, name: str, arguments: Any) -> dict[str, Any]:
    return {"type": "toolCall", "id": call_id, "name": name, "arguments": arguments}


def result_entry(
    entry_id: str, seq: int, call_id: str, text: str, is_error: bool = False
) -> dict[str, Any]:
    return {
        "id": entry_id,
        "parentId": None,
        "seq": seq,
        "timestamp": T0 + seq * 1000,
        "type": "message",
        "message": {
            "role": "toolResult",
            "toolCallId": call_id,
            "toolName": "bash",
            "content": [{"type": "text", "text": text}],
            "isError": is_error,
            "timestamp": T0 + seq * 1000,
        },
    }


def write(
    path: Path,
    entries: list[dict[str, Any]],
    ledger: list[tuple[str, str | None, bool, dict[str, Any]]] | None = None,
    branches: int = 1,
) -> Path:
    """Write entries and `(id, entry_id, adjustment, usage)` ledger rows."""
    connection = sqlite3.connect(str(path))
    try:
        connection.executescript(SCHEMA)
        for entry in entries:
            connection.execute(
                "INSERT INTO entries(id, parent_id, seq, type, custom_type, ts, payload) "
                "VALUES (?, ?, ?, ?, NULL, ?, ?)",
                (
                    entry["id"],
                    entry["parentId"],
                    entry["seq"],
                    entry["type"],
                    entry["timestamp"],
                    json.dumps(entry).encode(),
                ),
            )
        for seq, (row_id, entry_id, adjustment, usage_value) in enumerate(ledger or [], 1):
            connection.execute(
                "INSERT INTO usage_ledger(id, seq, entry_id, adjustment, usage, details) "
                "VALUES (?, ?, ?, ?, ?, NULL)",
                (row_id, seq, entry_id, int(adjustment), json.dumps(usage_value).encode()),
            )
        for index in range(branches):
            connection.execute(
                "INSERT INTO branch_meta(branch_id, tip_entry_id, tip_seq) VALUES (?, ?, ?)",
                (f"b{index}", f"tip{index}", index),
            )
        connection.commit()
    finally:
        connection.close()
    return path


def sample_session(path: Path) -> Path:
    """A user turn, an answer that calls a tool twice, both results, a final answer."""
    entries = [
        user_entry("e1", 1, "make /app/hello.txt contain hi"),
        assistant_entry(
            "e2",
            2,
            [
                {"type": "thinking", "thinking": "SECRET REASONING", "thinkingSignature": "sig"},
                {"type": "text", "text": "I will write the file."},
                tool_call("c1", "bash", {"command": "echo hi > /app/hello.txt"}),
                tool_call("c2", "bash", {"command": "cat /app/hello.txt"}),
            ],
        ),
        result_entry("e3", 3, "c1", ""),
        result_entry("e4", 4, "c2", "hi\n"),
        assistant_entry("e5", 5, [{"type": "text", "text": "Done."}]),
    ]
    ledger = [
        ("u1", "e2", False, usage(100, 20, 10, 0, 0.5)),
        ("u2", "e5", False, usage(50, 5, 60, 0, 0.25)),
        ("u3", None, False, usage(7, 0, 0, 0, 0.01)),
        ("u4", "e2", True, usage(1, 1, 0, 0, 0.0)),
    ]
    return write(path, entries, ledger)
