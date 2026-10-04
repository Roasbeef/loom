#!/usr/bin/env python3
"""Check Lean, execute the real Gleam reducer, and compare finite observations."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time

MODEL = Path(__file__).resolve().parent
ROOT = MODEL.parents[2]
SOURCES = [
    MODEL / 'Admission.lean',
    MODEL / 'lean-toolchain',
    MODEL / 'README.md',
    Path(__file__).resolve(),
    ROOT / 'packages/executor/test/remote_admission_bridge_test.gleam',
    ROOT / 'packages/executor/src/executor/remote/admission.gleam',
    ROOT / 'packages/executor/src/executor/remote/identity.gleam',
    ROOT / 'protocol-change/066-distributed-runtime-foundations.md',
]


def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in SOURCES}


def execute(command, cwd, evidence, name, env, timeout):
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout)
    (evidence / (name + '.stdout')).write_text(result.stdout)
    (evidence / (name + '.stderr')).write_text(result.stderr)
    entry = {'command': command, 'cwd': str(cwd), 'exit': result.returncode,
             'seconds': round(time.monotonic() - started, 3)}
    (evidence / (name + '.command.json')).write_text(json.dumps(entry, indent=2) + '\n')
    if result.returncode != 0:
        raise RuntimeError(f'{name} failed: {entry}\n{result.stderr}\n{result.stdout[:3000]}')
    if 'warning:' in result.stderr.lower() or 'warning:' in result.stdout.lower():
        raise RuntimeError(f'{name} emitted a compiler warning; inspect the evidence')
    return result.stdout, entry


def observations(output):
    rows = {}
    for line in output.splitlines():
        if line.startswith('BRIDGE\t'):
            fields = line.split('\t')
            if len(fields) != 6:
                raise RuntimeError(f'invalid TSV row: {line!r}')
            key = tuple(fields[1:5])
            if key in rows:
                raise RuntimeError(f'duplicate TSV key: {key}')
            rows[key] = fields[5]
    if len(rows) != 684:
        raise RuntimeError(f'expected 684 finite cases, found {len(rows)}')
    return rows


def differences(expected, actual):
    return [{'case': list(k), 'lean': expected.get(k), 'gleam': actual.get(k)}
            for k in sorted(expected.keys() | actual.keys())
            if expected.get(k) != actual.get(k)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mutation', choices=['reauthorize-intent'],
                        help='Mutate model output only; the intended mismatch exits 1.')
    args = parser.parse_args()
    evidence = Path(tempfile.mkdtemp(prefix='loom-admission-proof-'))
    summary = {'format': 'loom-admission-proof-v1', 'evidence': str(evidence),
               'bounds': {'phases': 19, 'gates': 2, 'request_digests': 2,
                          'event_representatives': 9, 'cases': 684},
               'mutation': args.mutation, 'commands': []}
    try:
        before = hashes()
        summary['sha256'] = before
        lean = str(Path.home() / '.elan/bin/lean')
        env = os.environ.copy()
        env['PATH'] = str(Path.home() / '.local/lib/loom/server/bin') + ':' + env['PATH']
        installed, entry = execute(
            [str(Path.home() / '.elan/bin/elan'), 'toolchain', 'list'],
            MODEL, evidence, 'installed-toolchains', env, 60)
        summary['commands'].append(entry)
        pin = (MODEL / 'lean-toolchain').read_text().strip()
        if not any(line.split()[0] == pin for line in installed.splitlines() if line.split()):
            raise RuntimeError(f'{pin} is not installed; obtain permission to provision it separately')
        for name, command, cwd in [
            ('lean-version', [lean, '--version'], MODEL),
            ('gleam-version', ['gleam', '--version'], ROOT / 'packages/executor'),
            ('otp-version', ['erl', '-noshell', '-eval',
                             'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'], ROOT),
            ('lean-check', [lean, 'Admission.lean'], MODEL),
            ('lean-rows', [lean, '--run', 'Admission.lean'], MODEL),
            ('gleam-rows', ['gleam', 'run', '-m', 'remote_admission_bridge_test'],
             ROOT / 'packages/executor'),
        ]:
            output, entry = execute(command, cwd, evidence, name, env, 60)
            summary['commands'].append(entry)
            if name.endswith('version'):
                summary[name] = output.strip()
            if name == 'lean-check':
                summary['axiom_report'] = output.strip().splitlines()
                for report in summary['axiom_report']:
                    if 'depends on axioms:' in report:
                        axiom_names = report.split('depends on axioms: [', 1)[1].rstrip(']').split(', ')
                        if set(axiom_names) - {'propext', 'Quot.sound', 'Classical.choice'}:
                            raise RuntimeError(f'unapproved proof axiom: {report}')
                if len(summary['axiom_report']) != 12:
                    raise RuntimeError('expected an axiom audit for all twelve named theorems')
                proof = (MODEL / 'Admission.lean').read_text()
                if re.search(r'\b(sorry|admit|axiom|unsafe)\b', proof):
                    raise RuntimeError('proof source contains an escape or custom axiom declaration')
            if name == 'lean-rows':
                expected = observations(output)
            if name == 'gleam-rows':
                actual = observations(output)
        if before != hashes():
            raise RuntimeError('mapped source changed during checking; rerun on stable bytes')
        baseline = differences(expected, actual)
        summary['baseline_differences'] = baseline
        if baseline:
            raise RuntimeError(f'production/model differences: {baseline[:8]}')
        if args.mutation:
            # This control mutates the comparator's computed model output only.
            # It neither mutates production source nor claims a production mutant.
            case = ('open', 'i0', 'equal', 'launch')
            if expected[case] != 'ok:i0:no-launch:open':
                raise RuntimeError('mutation precondition changed; maintain this control')
            expected[case] = 'ok:i0:launch:open'
            mismatch = differences(expected, actual)
            summary['mutation_kind'] = 'model-output mutation; production source unchanged'
            summary['mutation_differences'] = mismatch
            if len(mismatch) != 1 or tuple(mismatch[0]['case']) != case:
                raise RuntimeError('mutation failed for an unintended reason')
            summary['exit'] = 1
            summary['verdict'] = 'intended mismatch: model reauthorizes LaunchIntent; production returns NoLaunch'
        else:
            summary['exit'] = 0
            summary['verdict'] = 'all 684 computed cases agree'
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        summary['exit'] = 2
        summary['verdict'] = str(error)
    (evidence / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return summary['exit']


if __name__ == '__main__':
    sys.exit(main())
