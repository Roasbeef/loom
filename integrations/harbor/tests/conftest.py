"""Shared fixtures: a Harbor-shaped mock environment and a ready agent."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

REPORT = (
    '{"session_id":"s-123","session_db":"/home/u/.loom-harbor/sessions/s-123.db",'
    '"state_dir":"/home/u/.loom-harbor","outcome":"completed","turns":3,'
    '"usage":{"input":100,"output":20,"cacheRead":10,"cacheWrite":5,"cacheWrite1h":null,'
    '"reasoning":null,"totalTokens":135,"cost":{"input":0.1,"output":0.2,"cacheRead":0.0,'
    '"cacheWrite":0.0,"total":0.3},"evidence":{"version":1,"tokens":"complete",'
    '"billing":"api","cost":{"kind":"estimated","coverage":"complete","basis":"api-rates"}}},'
    '"elapsed_ms":4200,"jail":{"posture":"degraded","selftest":{"enforced":6,"skipped":4}},'
    '"model":{"provider":"harbor","model_id":"claude-opus-4-5"}}'
)


def result(return_code: int = 0, stdout: str = "", stderr: str = "") -> SimpleNamespace:
    return SimpleNamespace(return_code=return_code, stdout=stdout, stderr=stderr)


@pytest.fixture
def logs_dir(tmp_path: Path) -> Path:
    path = tmp_path / "agent-logs"
    path.mkdir()
    return path


@pytest.fixture
def api_key(monkeypatch: pytest.MonkeyPatch) -> str:
    for name in (
        "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "LOOM_RELEASE",
        "LOOM_RELEASE_BASE_URL", "LOOM_SERVER_TARBALL", "LOOM_CLIENT_TARBALL",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test-0123456789abcdef")
    return "sk-ant-test-0123456789abcdef"


@pytest.fixture
def make_agent(logs_dir: Path, api_key: str):
    # Imported here so the pure modules' tests need not import Harbor's agent base.
    from loom_harbor.agent import LoomAgent

    def build(model_name: str | None = "anthropic/claude-opus-4-5", **kwargs) -> LoomAgent:
        return LoomAgent(logs_dir=logs_dir, model_name=model_name, **kwargs)

    return build


@pytest.fixture
def environment():
    """The slice of `BaseEnvironment` an installed agent touches."""
    env = AsyncMock()
    env.default_user = None
    env.exec.return_value = result()
    env.upload_file.return_value = None
    return env
