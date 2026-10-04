#!/usr/bin/env python3
"""Compile and check safety plus nonvacuity, with explicit bounded schedules."""
import argparse
from datetime import datetime, timezone
import re

from runner import ROOT, check_case, compile_model, record, snapshot_model

PROBES = {
    "tcProbeAdmissionAckLoss": "witness: admission acknowledgement lost after durable commit",
    "tcProbeLiveRestart": "witness: reboot preserved custody of actually running native execution",
    "tcProbeAdmissionLoss": "witness: admission request lost in transport",
    "tcProbeResultLoss": "witness: terminal result lost in transport",
    "tcProbeSuccess": "witness: successful receipt cleanup and epoch GC",
    "tcProbeCrashAfterSend": "witness: crash retained uncertain launch across reboot",
    "tcProbeUncertain": "witness: crash retained uncertain launch across reboot",
    "tcProbeReuse": "witness: delayed stale cancel reached reused helper",
    "tcProbePressure": "witness: evidence capacity refused new admission",
    "tcProbeClosedReconcile": "witness: closed epoch reconciled retained ID",
    "tcProbeConflict": "witness: changed request digest conflicted",
    "tcProbeReceiptLoss": "witness: durable owner receipt lost in transport",
    "tcProbeCancelLoss": "witness: cancel lost without native retirement",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schedules", type=int, default=1000)
    parser.add_argument("--probe-schedules", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=697)
    parser.add_argument("--case", action="append", help="Select exact case names; repeatable")
    args = parser.parse_args()
    if args.schedules <= 0 or args.probe_schedules <= 0 or args.seed < 0:
        parser.error("schedule counts must be positive and seed nonnegative")
    tests = []
    for source in sorted((ROOT / "PTst").glob("*.p")):
        tests.extend(re.findall(r"^test (\w+)", source.read_text(), re.MULTILINE))
    if args.case:
        if set(args.case) - set(tests):
            parser.error("unknown case name")
        tests = args.case
    if not tests or len(tests) != len(set(tests)):
        parser.error("empty or duplicate test selection")
    out = ROOT / "PCheckerOutput" / datetime.now(timezone.utc).strftime("gate-%Y%m%dT%H%M%S%f")
    project = snapshot_model(out / "project")
    results = [compile_model(project, out)]
    print("compile: exit=0", flush=True)
    for case in tests:
        probe = case.startswith("tcProbe")
        if probe and case not in PROBES:
            raise RuntimeError(f"probe has no registered assertion marker: {case}")
        result = check_case(project, out / case, case,
                            args.probe_schedules if probe else args.schedules,
                            args.seed, PROBES.get(case))
        results.append(result)
        print(f"{case}: exit={result['exit']} bugs={result['bugs']} "
              f"schedules={result['explored']} "
              f"{'witness found' if probe else 'passed'}", flush=True)
    record(out / "results.json", results)
    print(f"evidence: {out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
