#!/usr/bin/env python3
"""Prove guard mutations fail their intended monitors in isolated model copies."""
import argparse
import hashlib
import json
from datetime import datetime, timezone

from runner import ROOT, check_case, compile_model, record, snapshot_model

# These alter actual state/effect decisions, leaving monitor code unchanged.
MUTATIONS = {
    'compile-late-ready-after-before': ('PSrc/ProductExecutor.p', 'if (!(id in claims) || phases[id] != Preparing || !(id in created)) {', 'if (!(id in created)) {', 'tcCompileFailPreparationLateReady', 'ready committed after before-native completion'),
    'compile-before-native-after-ready': ('PSrc/ProductExecutor.p', 'if (phases[id] != Preparing || !(id in claims) || id in leases || id in associated) {', 'if (id in associated) {', 'tcCompileReadySubmitUnassociated', 'before-native completion followed durable ready'),
    'compile-settle-terminal-payload-only': ('PSrc/ProductExecutor.p', 'if (read.evidence.phase != Terminal || read.evidence.terminalDigest != read.payload.digest) {', 'if (false) {', 'tcCompileTerminalPayloadPending', 'outer completion preceded exact native terminal commit'),

    "preparation-foreign-issued-artifact": ("PSrc/ProductExecutor.p", "s.association == producer.resultDigest && s.artifact == producer.artifact &&", "s.association == producer.resultDigest &&", "tcProductForeignArtifact", "launch ready changed retained compile or launch input"),
    'preparation-compile-offer-before-ready': ('PSrc/ProductExecutor.p', 'announce mProductAdmission, s;', 'announce mProductAdmission, s;\n      if (s.id == 1) { send owner, eProductConstruct, 1; }', 'tcProductLifecycle', 'wall selected before resource ready'),
    'preparation-compile-recreate': ('PSrc/ProductExecutor.p', 'claims -= (id);\n      if (id in claims) { createResource(rows[id]); }', 'claims += (id);\n      if (id in claims) { createResource(rows[id]); }', 'tcProductCompileUnknown', 'resource created without original live claim'),
    'preparation-dead-issued-lease': ('PSrc/ProductExecutor.p', 'if (id in leases && (id == 1 || resourceOwnerAlive) && phases[id] == PreparedResource)', 'if (id in leases)', 'tcProductDeadResource', 'dead resource owner restored launch authority'),
    'preparation-foreign-compile-association': ('PSrc/ProductExecutor.p', 'return producer.provenance == NativeCompletion && s.association == producer.resultDigest && s.artifact == producer.artifact && s.compileRequest == producer.service.requestDigest &&\n      s.scope == producer.service.scope && s.enrollment == producer.service.enrollment &&\n      s.tokenCommitment == 1;', 'return true;', 'tcProductForeignAssociation', 'launch ready changed retained compile or launch input'),
    'preparation-bad-fingerprint': ('PSrc/ProductExecutor.p', 'if (id == 2 && fingerprint != rows[id].artifact)', 'if (false)', 'tcProductBadFingerprint', 'launch fingerprint mismatch admitted'),
    'preparation-initial-budget': ('PSrc/ProductOwner.p', 'w = productWall(retained[id].deadline - elapsed, retained[id].ceiling);', 'w = productWall(retained[id].deadline, retained[id].ceiling);', 'tcProductBudgetBelowCap', 'selected wall exceeded original remaining authority'),
    'preparation-round-up-wall': ('PSrc/ProductTypes.p', 'w = (remaining - 1100 - productAllowance()) / 1000;', 'w = (remaining - 1100 - productAllowance() + 999) / 1000;', 'tcProductBudgetBelowCap', 'selected wall exceeded original remaining authority'),
    'preparation-clearance-as-admission': ('PSrc/ProductOwner.p', 'announce mProductCleared, o;', 'announce mProductCleared, o;\n    send service, eProductNativeAdmission, (prepared = (offer = o, native = request(id, 1, 1)), evidence = (request = request(id, 1, 1), answer = Prior, row = (request = request(id, 1, 1), phase = Admitted, launchBoot = 0, retired = false, receipt = false, outcome = NoOutcome, terminalDigest = 0), connection = 1, boot = 1));', 'tcProductLifecycle', 'service admission lacked actual native evidence'),
    'preparation-foreign-native-terminal': ('PSrc/ProductExecutor.p', 'if (candidate.native != associated[n.key.execution].native) {\n        announce mProductTerminalRefused, n;\n        return;\n      }', '', 'tcProductForeignNativeTerminal', 'outer completion used a different native child'),
    'preparation-reselect-retained-wall': ('PSrc/ProductOwner.p', 'o = offers[id];', 'o = offers[id];\n    o.wall = productWall(retained[id].deadline - elapsed, retained[id].ceiling);', 'tcProductExpiredOffer', 'retained offer or original deadline changed'),
    'preparation-renew-retained-deadline': ('PSrc/ProductOwner.p', 'o = offers[id];', 'o = offers[id];\n    o.deadline = o.deadline + elapsed;', 'tcProductExpiredOffer', 'retained offer or original deadline changed'),
    'preparation-reclear-native-child': ('PSrc/ProductOwner.p', ('on eProductRecoverCommand do (id: int) {\n      if (id in nativeRows) {\n        queryNative(id);', '    if (id in nativeRows) { queryNative(id); return; }\n', '    if (id in cleared) { return; }\n'), ('on eProductRecoverCommand do (id: int) {\n      if (id in nativeRows) {\n        clearOffer(id);', '', ''), 'tcProductPostSendDelay', 'native custody authorized a second clearance'),

    'product-change-cleared-offer': ('PSrc/ProductOwner.p', 'candidate.commandDigest = accepted.commandDigest;', 'candidate.commandDigest = 2;', 'tcProductLifecycle', 'native command differed from owner-cleared offer'),
    'product-remint-uncertain': ('PSrc/ProductOwner.p', 'original.key.execution = nativeRows[id].key.execution;', 'original.key.execution = 3;', 'tcProductLaunchLoss', 'uncertain command allocated replacement identity'),
    'product-cap-name-alias': ('PSrc/ProductOwner.p', 'address.name = p.logical.name;', 'address.name = 0;', 'tcProductChildAddresses', 'distinct product children shared an address'),
    'product-recreate-resource': ('PSrc/ProductExecutor.p', 'claims -= (id);\n      if (id in claims) { createResource(rows[id]); }', 'claims += (id);\n      if (id in claims) { createResource(rows[id]); }', 'tcProductResourceUnknown', 'resource created without original live claim'),
    'product-foreign-lease': ('PSrc/ProductExecutor.p', 'if (candidate.artifact == rows[candidate.service.id].artifact && candidate.scope == rows[candidate.service.id].scope &&\n        candidate.compileRequest == rows[1].requestDigest && candidate.resources == rows[candidate.service.id].resources)', 'if (sizeof(created) > 0)', 'tcProductOfferConflict', 'issued resource did not match admitted artifact'),
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
        replacements = [(old, new)] if isinstance(old, str) else list(zip(old, new, strict=True))
        for before, after in replacements:
            if content.count(before) != 1:
                raise RuntimeError(f"{name}: expected exactly one mutation site in {path}: {before!r}")
            content = content.replace(before, after)
        source.write_text(content)
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
