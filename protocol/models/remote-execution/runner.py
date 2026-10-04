#!/usr/bin/env python3
"""Bounded P invocation and strict evidence validation shared by local gates."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import tempfile

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
    command = [p_binary(), *args]
    # The P child and measurement wrapper retain distinct statuses. A wrapper
    # failure remains a gate failure even when the actual P child succeeds.
    measured = os.environ.get("MODEL_MEASURE_MEMORY") == "1" and sys.platform == "darwin" and Path("/usr/bin/time").is_file()
    with tempfile.TemporaryDirectory(prefix="loom-p-status-") as telemetry:
        exit_file = Path(telemetry) / "p-exit"
        if measured:
            helper = "import pathlib, subprocess, sys\nr = subprocess.run(sys.argv[2:])\npathlib.Path(sys.argv[1]).write_text(str(r.returncode))\nraise SystemExit(r.returncode)\n"
            command = ["/usr/bin/time", "-l", sys.executable, "-c", helper, str(exit_file), *command]
        completed = subprocess.run(command, cwd=project, capture_output=True,
                                   text=True, timeout=timeout)
        model_exit = int(exit_file.read_text()) if measured and exit_file.is_file() else completed.returncode if not measured else None
    memory = re.search(r"(\d+)\s+maximum resident set size", completed.stderr) if measured else None
    return {"command": command, "cwd": str(project),
            "model_exit": model_exit,
            "measurement_exit": completed.returncode if measured else None,
            "measurement_valid": not measured or (memory is not None and model_exit == completed.returncode),
            "peak_resident_bytes": int(memory[1]) if memory else None,
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
    if result["model_exit"] != 0 or result["exit"] != 0 or not result["measurement_valid"] or "Compilation succeeded." not in result["output"]:
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
    steps = re.search(r"Number of scheduling points in terminating schedules: ([\d.]+) \(min\), ([\d.]+) \(avg\), ([\d.]+) \(max\)", result["output"])
    result.update(case=case, requested_schedules=schedules,
                  scheduling_points={"min": float(steps[1]), "avg": float(steps[2]), "max": float(steps[3])} if steps else None,
                  limits={"max_steps": 1000, "checker_seconds": 60, "outer_seconds": 65, "checker_memory_gib": 1},
                  explored=int(explored[1]) if explored else None,
                  bugs=int(bugs[1]) if bugs else None, errors=errors,
                  trace_directory=str(output / "BugFinding"))
    if marker is None:
        valid = result["exit"] == 0 and result["bugs"] == 0 and result["explored"] == schedules
    else:
        valid = (result["exit"] == 1 and result["bugs"] == 1 and
                 result["explored"] is not None and len(errors) == 1 and
                 "Assertion Failed:" in errors[0] and marker in errors[0])
    valid = valid and result["model_exit"] == result["exit"] and result["measurement_valid"]
    result["valid"] = valid
    if not valid:
        raise RuntimeError(f"{case}: invalid evidence exit={result['exit']} "
                           f"bugs={result['bugs']} schedules={result['explored']} "
                           f"errors={errors}; see {output / 'checker.log'}")
    return result


def record(path: Path, results: list[dict]) -> None:
    path.write_text(json.dumps(results, indent=2) + "\n")
