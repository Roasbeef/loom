#!/usr/bin/env python3
"""Bounded P invocation and strict evidence validation shared by local gates."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent


def p_binary() -> str:
    candidate = os.environ.get("P_BIN") or shutil.which("p")
    if not candidate:
        candidate = str(Path.home() / ".dotnet/tools/p")
    if not Path(candidate).is_file():
        raise RuntimeError("P is not installed; set P_BIN to the installed tool")
    return candidate


def invoke(args: list[str], project: Path, timeout: int) -> dict:
    started = time.monotonic()
    completed = subprocess.run(
        [p_binary(), *args], cwd=project, capture_output=True,
        text=True, timeout=timeout,
    )
    return {"command": [p_binary(), *args], "cwd": str(project),
            "exit": completed.returncode,
            "seconds": round(time.monotonic() - started, 3),
            "output": completed.stdout + completed.stderr}


def snapshot_model(destination: Path, source: Path = ROOT) -> Path:
    destination.mkdir(parents=True)
    shutil.copy2(source / "RemoteExecution.pproj", destination)
    for folder in ("PSrc", "PSpec", "PTst"):
        shutil.copytree(source / folder, destination / folder)
    return destination


def compile_model(project: Path, output: Path) -> dict:
    result = invoke(["compile", "--pproj", "RemoteExecution.pproj"], project, 120)
    output.mkdir(parents=True, exist_ok=True)
    (output / "compile.log").write_text(result["output"])
    if result["exit"] != 0 or "Compilation succeeded." not in result["output"]:
        raise RuntimeError(f"P compile failed: exit={result['exit']}; see {output / 'compile.log'}")
    return result


def check_case(project: Path, output: Path, case: str, schedules: int,
               seed: int, marker: str | None = None) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    result = invoke([
        "check", "--testcase", case, "--schedules", str(schedules),
        "--max-steps", "1000", "--fail-on-maxsteps", "--seed", str(seed),
        "--timeout", "60", "--memout", "1", "--outdir", str(output),
    ], project, 65)
    (output / "checker.log").write_text(result["output"])
    bugs = re.search(r"Found (\d+) bugs?\.", result["output"])
    explored = re.search(r"Explored (\d+) schedules?", result["output"])
    errors = []
    for trace in sorted((output / "BugFinding").glob("RemoteExecution_*.txt")):
        errors.extend(line.strip() for line in trace.read_text().splitlines()
                      if "<ErrorLog>" in line)
    result.update(case=case, requested_schedules=schedules,
                  explored=int(explored[1]) if explored else None,
                  bugs=int(bugs[1]) if bugs else None, errors=errors,
                  trace_directory=str(output / "BugFinding"))
    if marker is None:
        valid = result["exit"] == 0 and result["bugs"] == 0 and result["explored"] == schedules
    else:
        valid = (result["exit"] == 1 and result["bugs"] == 1 and
                 result["explored"] is not None and len(errors) == 1 and
                 "Assertion Failed:" in errors[0] and marker in errors[0])
    result["valid"] = valid
    if not valid:
        raise RuntimeError(f"{case}: invalid evidence exit={result['exit']} "
                           f"bugs={result['bugs']} schedules={result['explored']} "
                           f"errors={errors}; see {output / 'checker.log'}")
    return result


def record(path: Path, results: list[dict]) -> None:
    path.write_text(json.dumps(results, indent=2) + "\n")
