#!/usr/bin/env python3
"""Run bounded safety controls and exact effect-history reachability probes."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
from pathlib import Path
import re
from runner import ROOT, SHARED, check, compile_model, hashes, record, snapshot

PROBES = {
 'tcProbeRetirement': 'witness: cancellation retired consumed but unacknowledged original writer without resurrection',
 'tcProbeStartup': 'witness: custody preceded single activation and historical read never recreated delivery',
 'tcProbeReply': 'witness: stalled writer retained running ready sending slots until exact consumption',
 'tcProbeImmediate': 'witness: immediate input withheld ACK while earlier writer consumption remained runnable',
 'tcProbeStale': 'witness: stale direction scope generation incarnation and service ACKs preserved genuine reservation',
 'tcProbeIdentity': 'witness: stale direction scope generation incarnation and service ACKs preserved genuine reservation',
 'tcProbeTerminal': 'witness: validated final ACK preceded destroy join and never granted another frame',
 'tcProbeCancel': 'witness: independent cancellation closed stalled writer with every endpoint metadata credit occupied',
 'tcProbeDeath': 'witness: original owner death retained uncertainty while exact recipient cleanup released only sibling',
 'tcProbeByte': 'witness: both directions reached exact lifetime bytes and first excess retired without refund',
 'tcProbeActive': 'witness: four unresolved Launch entries refused fifth until original close joins and native proof',
 'tcProbeReport': 'witness: known report never authorized directory deletion before independent safe cleanup',
 'tcProbeLocal': 'witness: local incarnation did not fabricate remote Launch authority',
 'tcProbeBoundary': 'witness: semantic malformed frame and excessive completed reply retired without silent drop',
 'tcProbeEnd': 'witness: single inbound producer EOF followed exact frame consumption and never replaced native proof',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schedules', type=int, default=1000)
    parser.add_argument('--probe-schedules', type=int, default=2000)
    parser.add_argument('--seed', type=int, default=697)
    parser.add_argument('--case', action='append')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    tests = re.findall(r'^test (\w+)', (ROOT / 'PTst/Tests.p').read_text(), re.MULTILINE)
    if args.schedules <= 0 or args.probe_schedules <= 0 or args.seed < 0:
        parser.error('positive schedules and nonnegative seed required')
    if args.case:
        if set(args.case) - set(tests) or len(args.case) != len(set(args.case)):
            parser.error('unknown or repeated case')
        tests = args.case
    out = args.output or ROOT / 'PCheckerOutput' / datetime.now(timezone.utc).strftime('gate-%Y%m%dT%H%M%S%f')
    project = snapshot(out / 'project')
    (out / 'source-hashes.json').write_text(json.dumps(hashes(project), indent=2) + '\n')
    (out / 'shared-runner-hash.json').write_text(json.dumps(hashlib.sha256(SHARED.read_bytes()).hexdigest()) + '\n')
    results = []
    try:
        results.append(compile_model(project, out))
        print('compile: exit=0', flush=True)
        for case in tests:
            marker = PROBES.get(case)
            if case.startswith('tcProbe') and marker is None:
                raise RuntimeError(f'probe has no exact marker: {case}')
            result = check(project, out / case, case, args.probe_schedules if marker else args.schedules, args.seed, marker)
            results.append(result)
            print(f"{case}: exit={result['exit']} bugs={result['bugs']} schedules={result['explored']} valid", flush=True)
    finally:
        record(out / 'results.json', results)
    print(f'evidence: {out / "results.json"}', flush=True)


if __name__ == '__main__':
    main()
