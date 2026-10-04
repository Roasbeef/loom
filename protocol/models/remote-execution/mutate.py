#!/usr/bin/env python3
"""Prove guard mutations fail their intended monitors in isolated model copies."""
import argparse
import hashlib
import json
from datetime import datetime, timezone

from runner import ROOT, check_case, compile_model, record, snapshot_model

# These alter actual state/effect decisions, leaving monitor code unchanged.
MUTATIONS = {
    'product-change-cleared-offer': ('PSrc/ProductOwner.p', 'candidate.commandDigest = accepted.commandDigest;', 'candidate.commandDigest = 2;', 'tcProductLifecycle', 'native command differed from owner-cleared offer'),
    'product-remint-uncertain': ('PSrc/ProductOwner.p', 'original.key.execution = nativeRows[2].key.execution;', 'original.key.execution = 3;', 'tcProductLaunchLoss', 'uncertain command allocated replacement identity'),
    'product-cap-name-alias': ('PSrc/ProductOwner.p', 'address.name = p.logical.name;', 'address.name = 0;', 'tcProductChildAddresses', 'distinct product children shared an address'),
    'product-recreate-resource': ('PSrc/ProductExecutor.p', 'liveClaim = false;\n        if (liveClaim) { createResource(rows[2]); }', 'liveClaim = true;\n        if (liveClaim) { createResource(rows[2]); }', 'tcProductResourceUnknown', 'resource created without original live claim'),
    'product-foreign-lease': ('PSrc/ProductExecutor.p', 'if (candidate.artifact == rows[2].artifact && candidate.scope == rows[2].scope &&\n        candidate.compileRequest == rows[1].requestDigest && candidate.resources == rows[2].resources)', 'if (created)', 'tcProductOfferConflict', 'issued resource did not match admitted artifact'),
    'product-loss-as-refusal': ('PSrc/ProductOwner.p', 'neverLaunched = false', 'neverLaunched = true', 'tcProductLaunchLoss', 'possible native launch reported never launched'),
    'product-early-outer-receipt': ('PSrc/ProductExecutor.p', 'announce mProductCompleted, p;', 'announce mProductReceipt, p;\n        announce mProductCompleted, p;', 'tcProductLifecycle', 'outer receipt preceded exact owner completion'),
    'product-final-from-children': ('PSrc/ProductOwner.p', 'if (finalResult != 0) {', 'if (sizeof(completions) == 2) {', 'tcProductChildOnlyRecovery', 'child evidence fabricated final tool outcome'),
    'product-cleanup-as-retirement': ('PSrc/ProductOwner.p', 'retired = false', 'retired = true', 'tcProductLaunchLoss', 'resource cleanup fabricated native retirement'),

    "relaunch-uncertain": (
        "PSrc/Executor.p",
        "        route[k] = p;\n        reply(p, Prior);",
        "        rows[k].phase = Admitted;\n        send this, eLaunch, (key = k, boot = boot);\n        route[k] = p;\n        reply(p, Prior);",
        "tcUncertain", "uncertain launch was automatically retried",
    ),
    "stale-cancel": (
        "PSrc/Helper.p", "if (busy && asked == active)", "if (busy)",
        "tcLifecycle", "stale cancel acted on reused helper's newer execution",
    ),
    "gc-without-receipt": (
        "PSrc/Types.p", "row.phase == Terminal && row.retired && row.receipt",
        "row.phase == Terminal && row.retired",
        "tcReceiptPending", "terminal GC without owner durable receipt acknowledgement",
    ),
    "gc-without-retirement": (
        "PSrc/Types.p", "row.phase == Terminal && row.retired && row.receipt",
        "row.phase == Terminal && row.receipt",
        "tcRetirementPending", "terminal GC without native retirement",
    ),
    "forget-closed-epoch": (
        "PSrc/Executor.p", "    boot = boot + 1;",
        "    closed = false;\n    boot = boot + 1;",
        "tcLifecycle", "same logical execution admitted again after GC",
    ),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--schedules", type=int, default=100)
    parser.add_argument("--seed", type=int, default=697)
    parser.add_argument("mutations", nargs="*", choices=list(MUTATIONS))
    args = parser.parse_args()
    if args.list:
        print("\n".join(MUTATIONS))
        return
    if args.schedules <= 0 or args.seed < 0:
        parser.error("schedule count must be positive and seed nonnegative")
    out = ROOT / "PCheckerOutput" / datetime.now(timezone.utc).strftime("mutations-%Y%m%dT%H%M%S%f")
    baseline = snapshot_model(out / "control-project")
    (out / "source-hashes.json").write_text(json.dumps({str(p.relative_to(baseline)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(baseline.rglob("*")) if p.is_file()}, indent=2) + "\n")
    results = [compile_model(baseline, out)]
    for name in args.mutations or MUTATIONS:
        path, old, new, case, marker = MUTATIONS[name]
        control = check_case(baseline, out / name / "control", case, args.schedules, args.seed)
        project = out / name / "project"
        snapshot_model(project, baseline)
        source = project / path
        content = source.read_text()
        if content.count(old) != 1:
            raise RuntimeError(f"{name}: expected exactly one mutation site in {path}")
        source.write_text(content.replace(old, new))
        compilation = compile_model(project, out / name)
        mutant = check_case(project, out / name / "mutant", case,
                            args.schedules, args.seed, marker)
        results.append({"mutation": name, "control": control,
                        "compile": compilation, "mutant": mutant})
        print(f"{name}: control_exit={control['exit']} mutant_exit={mutant['exit']} "
              f"schedules={mutant['explored']} {mutant['errors'][0]}", flush=True)
    record(out / "results.json", results)
    print(f"evidence: {out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
