#!/usr/bin/env python3
"""Source-only Launch snapshots and strict checker evidence, using existing invocation."""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import shutil

ROOT = Path(__file__).resolve().parent
SHARED = ROOT.parent / 'remote-execution' / 'runner.py'
spec = importlib.util.spec_from_file_location('loom_existing_model_runner', SHARED)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
invoke = shared.invoke
record = shared.record


def snapshot(destination):
    destination.mkdir(parents=True)
    shutil.copy2(ROOT / 'LaunchChannel.pproj', destination)
    for folder in ('PSrc', 'PSpec', 'PTst'):
        shutil.copytree(ROOT / folder, destination / folder)
    return destination


def hashes(project):
    return {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(project.rglob('*')) if p.is_file()}


def compile_model(project, output):
    output.mkdir(parents=True, exist_ok=True)
    result = invoke(['compile', '--pproj', 'LaunchChannel.pproj'], project, 120)
    (output / 'compile.log').write_text(result['output'])
    result['valid'] = (result['exit'] == result['model_exit'] == 0 and
                       result['measurement_valid'] and 'Compilation succeeded.' in result['output'])
    (output / 'compile.json').write_text(json.dumps(result, indent=2) + '\n')
    if not result['valid']:
        raise RuntimeError(f"compile failed; see {output / 'compile.log'}")
    return result


def check(project, output, case, schedules, seed, marker=None):
    output.mkdir(parents=True, exist_ok=True)
    result = invoke(['check', '--testcase', case, '--schedules', str(schedules),
        '--max-steps', '1000', '--fail-on-maxsteps', '--seed', str(seed),
        '--timeout', '60', '--memout', '1', '--outdir', str(output)], project, 65)
    (output / 'checker.log').write_text(result['output'])
    bugs = re.search(r'Found (\d+) bugs?\.', result['output'])
    explored = re.search(r'Explored (\d+) schedules?', result['output'])
    errors = []
    for trace in sorted((output / 'BugFinding').glob('LaunchChannel_*.txt')):
        errors.extend(line.strip() for line in trace.read_text().splitlines() if '<ErrorLog>' in line)
    points = re.search(r'Number of scheduling points in terminating schedules: ([\d.]+) \(min\), ([\d.]+) \(avg\), ([\d.]+) \(max\)', result['output'])
    result.update(case=case, requested_schedules=schedules, expected_assertion=marker,
        bugs=int(bugs[1]) if bugs else None, explored=int(explored[1]) if explored else None,
        errors=errors, trace_directory=str(output / 'BugFinding'),
        scheduling_points={'min': float(points[1]), 'avg': float(points[2]), 'max': float(points[3])} if points else None,
        limits={'max_steps': 1000, 'checker_seconds': 60, 'outer_seconds': 65, 'checker_memory_gib': 1})
    if marker is None:
        valid = result['exit'] == 0 and result['bugs'] == 0 and result['explored'] == schedules
    else:
        valid = (result['exit'] == 1 and result['bugs'] == 1 and result['explored'] is not None
                 and len(errors) == 1 and 'Assertion Failed:' in errors[0] and marker in errors[0])
    result['valid'] = valid and result['model_exit'] == result['exit'] and result['measurement_valid']
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if not result['valid']:
        raise RuntimeError(f"{case}: invalid evidence: exit={result['exit']} bugs={result['bugs']} explored={result['explored']} errors={errors}; see {output / 'checker.log'}")
    return result
