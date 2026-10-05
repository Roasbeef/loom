#!/usr/bin/env python3
"""Compile and check safety plus nonvacuity, with explicit bounded schedules."""
import argparse
import hashlib
import json
from datetime import datetime, timezone
import re

from runner import ROOT, check_case, compile_model, record, snapshot_model

PROBES = {
    "tcProbeBeamScopeIdle": "witness: idle credit death reduced capacity without scope obligation and busy death retained original uncertainty",
    "tcProbeBeamScopeOwner": "witness: applied owner DOWN fenced idle and busy rows while prior assignment stayed uncertain and sibling progressed",
    "tcProbeBeamScopeFence": "witness: scoped fence refused original traffic while sibling progressed and late handoff stayed stale",
    "tcProbeBeamScopePending": "witness: scoped drain stayed busy until actual answer and original producer drain",
    "tcProbeBeamScopeLost": "witness: service DOWN and later answer drain retained scoped uncertainty while sibling drained",
    "tcProbeBeamScopeStale": "witness: stale answer and drain preserved reused sibling assignment before exact completion",
    "tcProbeBeamCreditStale": "witness: stale handoff refused after same credit reuse and current work completed",
    "tcProbeBeamCreditPending": "witness: caller loss and drain retained service ask until its actual answer",
    "tcProbeBeamCreditShared": "witness: two scopes shared four data and two control credits and closure refused admission",
    "tcProbeBeamCreditLost": "witness: lost run remained retired after actual answer and drain",
    "tcProbeOwnerDischargeHappy": "witness: exact live finish and drain released collected custody and admitted next run",
    "tcProbeOwnerDischargeCrashBeforeStart": "witness: Fresh commit before spawn survived crash and refused admission and old start",
    "tcProbeOwnerDischargeCrashAfterFinal": "witness: final commit before drain remained historical after restart without release",
    "tcProbeOwnerDischargeWorkerLost": "witness: held downstream survived worker loss restart late receipt and pinned refusal",
    "tcProbeOwnerDischargeFatalSticky": "witness: consumer fatal stayed sticky after exact final drain and restart",
    "tcProbeOwnerDischargeFinalCommitFailed": "witness: failed final COMMIT retained unreleased custody across drain and restart",
    "tcProbeOwnerDischargeDischargeCommitFailed": "witness: failed discharge COMMIT retained slot and fenced restart admission",
    "tcProbeOwnerDischargeFreshCommitFailed": "witness: failed Fresh COMMIT spawned no worker and genuine later admission completed",

    "tcProbeLiveOrder": "witness: original live association permit preceded actual native Intent and start",
    "tcProbeLiveFenceBefore": "witness: resource fence before live association refused permit and duplicate controls",
    "tcProbeLiveFenceAfter": "witness: association before fence retained exact native cancellation route",
    "tcProbeLiveLostReply": "witness: lost association reply retained history without recreating original permit",
    "tcProbeLiveStaleReply": "witness: stale boot permit refused and recovered association remained data only",
    "tcProbeLiveClaim": "witness: changed original Claim and duplicate association refused before genuine launch",
    "tcProbeLiveControls": "witness: four foreign controls refused while exact second native row remained unchanged",

    "tcProbeCompileFailPreparationLateReady": "witness: original Preparing failure fenced late Ready and recovered exact acknowledged error",
    "tcProbeCompileReadySubmitUnassociated": "witness: Request-only and Ready in-flight Submit refused Before then exact native association settled",
    "tcProbeCompileTerminalPayloadPending": "witness: recovered terminal payload refused before reducer commit then exact native terminal settled",
    "tcProbeCompileIndependentReceipts": "witness: outer ACK cleanup native receipt and retirement retained independently",

    "tcProbeProductForeignNativeTerminal": "witness: same-key foreign native terminal refused before genuine completion",
    "tcProbeProductForeignArtifact": "witness: foreign issued artifact refused before launch preparation",
    "tcProbeProductBudgetReduced": "witness: ready remaining 150000 selected immutable wall 100",
    "tcProbeProductCompileUnknown": "witness: compile creation crash retained original unknown preparation",
    "tcProbeProductCompileReadyRecovery": "witness: original compile locations recovered after ready reply loss",
    "tcProbeProductDeadResource": "witness: issued launch lease became unusable after resource owner death",
    "tcProbeProductForeignAssociation": "witness: foreign compile completion refused before launch preparation",
    "tcProbeProductBadFingerprint": "witness: physical fingerprint refused after resource ready before native launch",
    "tcProbeProductBudgetOne": "witness: ready remaining 50100 selected immutable wall 1",
    "tcProbeProductBudgetBelowCap": "witness: ready remaining 229099 selected immutable wall 179",
    "tcProbeProductBudgetCap": "witness: ready remaining 229100 selected immutable wall 180",
    "tcProbeProductBudgetCold": "witness: ready remaining 270000 selected immutable wall 180",
    "tcProbeProductBudgetZero": "witness: ready remaining 0 refused before native reservation",
    "tcProbeProductBudgetBelowOne": "witness: ready remaining 50099 refused before native reservation",
    "tcProbeProductExpiredOffer": "witness: delayed immutable offer refused again on original identity recovery",
    "tcProbeProductPostSendDelay": "witness: delayed post-start recovery queried original native child without clearance",
    "tcProbeProductColdRun": "witness: cold preparation control and native compile completed under original authority",
    "tcProbeProductActualServiceAdmission": "witness: owner-derived launch completed through actual native admission association",

    "tcProbeProductMixedFaults": "witness: mixed faults reached live launch resource cleanup",
    "tcProbeProductComplete": "witness: product completion retained before outer receipt",
    "tcProbeProductClearedPending": "witness: command cleared before native admission",
    "tcProbeProductOfferConflict": "witness: changed command offer refused without replacement",
    "tcProbeProductResourceUnknown": "witness: resource creation remained unknown after reply loss",
    "tcProbeProductLeaseRecovered": "witness: issued lease recovered under original service identity",
    "tcProbeProductLaunchUnknown": "witness: lost launch reply preserved possible native work",
    "tcProbeProductDistinctChildren": "witness: equal ordinals from distinct capabilities reserved distinct children",
    "tcProbeProductFinalUnknown": "witness: retained children did not reconstruct final tool outcome",

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
    (out / "source-hashes.json").write_text(json.dumps({str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(project.rglob("*")) if p.is_file()}, indent=2) + "\n")
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
