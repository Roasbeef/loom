#!/usr/bin/env python3
"""Prove guard mutations fail their intended monitors in isolated model copies."""
import argparse
import hashlib
import json
from datetime import datetime, timezone

from runner import ROOT, check_case, compile_model, record, snapshot_model

# These alter actual state/effect decisions, leaving monitor code unchanged.
MUTATIONS = {
    'beam-scope-no-gate': ('PSrc/BeamCredits.p', 'if (scopes[p.scope] == CreditScopeFenced)', 'if (false)', 'tcBeamScopeFence', 'credit granted after its scope fence'),
    'beam-scope-down-as-drain': ('PSrc/BeamCredits.p', '// DOWN loses observation; it supplies neither answer nor producer drain.\n        slot.retired = true; slots[p.slot] = slot;\n        announce mCreditRetired, p.run;', '// Mutant incorrectly treats DOWN as answer and successful drain.\n        slot.network = false; slot.pending = false; slots[p.slot] = slot; maybeRelease(p.slot);', 'tcBeamScopeLost', 'credit released before transport AllDelivered'),
    'beam-scope-forget-retired': ('PSrc/BeamCredits.p', 'if (slots[i].scope == scope && slots[i].retired) { drain = CreditUncertain; break; }', '', 'tcBeamScopeLost', 'scope reported drained after retired credit'),
    'beam-scope-stale-completion': ('PSrc/BeamCredits.p', '(p.action == CreditAnswer || p.action == CreditDrain) && slot.run != p.run', 'false', 'tcBeamScopeStale', 'stale completion changed current assignment'),
    'beam-stale-handoff': ('PSrc/BeamCredits.p', 'p.action == CreditHandoff && slot.run != p.run', 'false', 'tcBeamCreditStale', 'stale handoff admitted against a reused credit'),
    'beam-release-pending': ('PSrc/BeamCredits.p', ' && !slots[index].pending', '', 'tcBeamCreditPending', 'queued service ask released without actual answer'),
    'beam-release-before-drain': ('PSrc/BeamCredits.p', '!slots[index].network && ', '', 'tcBeamCreditStale', 'credit released before transport AllDelivered'),
    'beam-revive-lost-credit': ('PSrc/BeamCredits.p', ' && !slots[index].retired', '', 'tcBeamCreditLost', 'lost run restored retired credit'),
    'beam-reopen-ingress': ('PSrc/BeamCredits.p', 'if (!open) {', 'if (false) {', 'tcBeamCreditShared', 'credit granted after ingress closed'),
    'beam-fifth-data-credit': ('PSrc/BeamCredits.p', 'i = 0; end = 4;', 'i = 0; end = 5;', 'tcBeamCreditShared', 'scope multiplied the shared credit bound'),
    'owner-marker-before-start': ('PSrc/OwnerDischarge.p', 'rows[p.key] = (custody = RunUnreleased, collection = RunRetained, outcome = 0);', 'rows[p.key] = (custody = RunReleased, collection = RunRetained, outcome = 0);', 'tcOwnerDischargeHappy', 'Fresh COMMIT omitted unreleased custody'),
    'owner-release-before-drain': ('PSrc/OwnerDischarge.p', ('if (live[pin.key] != RunFinalCommitted || !(pin.key in drained)) { return; }', '      reply(p.pin.key, RunFinalStored);'), ('if (live[pin.key] != RunFinalCommitted) { return; }', '      discharge(p.pin, RunCommitOk);\n      reply(p.pin.key, RunFinalStored);'), 'tcOwnerDischargeHappy', 'owner custody released before AllDelivered'),
    'owner-startup-reset': ('PSrc/OwnerDischarge.p', 'if (hasUnreleased()) { admission = RunRecoveryOnly; }', 'if (hasUnreleased()) { admission = RunAdmitting; }', 'tcOwnerDischargeCrashBeforeStart', 'owner startup reopened unreleased admission'),
    'owner-fatal-overwrite': ('PSrc/OwnerDischarge.p', 'if (live[p.pin.key] == RunWaiting) {', 'if (live[p.pin.key] == RunWaiting || live[p.pin.key] == RunUnresolved) {', 'tcOwnerDischargeFatalSticky', 'sticky unresolved disposition was overwritten'),
    'owner-collect-before-release': ('PSrc/OwnerDischarge.p', 'if (!(id in rows) || rows[id].custody != RunReleased) {', 'if (!(id in rows)) {', 'tcOwnerDischargeHappy', 'collection erased unreleased outcome or marker'),
    'owner-final-failed-commit': ('PSrc/OwnerDischarge.p', 'if (p.commit == RunCommitFailed ||\n          (rows[p.pin.key].outcome != 0 && rows[p.pin.key].outcome != p.outcome)) {', 'if (rows[p.pin.key].outcome != 0 && rows[p.pin.key].outcome != p.outcome) {', 'tcOwnerDischargeFinalCommitFailed', 'final outcome committed after failed or changed transaction'),
    'owner-discharge-failed-commit': ('PSrc/OwnerDischarge.p', 'if (commit == RunCommitFailed) {', 'if (false) {', 'tcOwnerDischargeDischargeCommitFailed', 'failed discharge COMMIT released owner custody'),
    'owner-pinned-rebind': ('PSrc/OwnerDischarge.p', 'if (origin.incarnation != incarnation) {', 'if (false) {', 'tcOwnerDischargeWorkerLost', 'old pinned runner rebound to replacement owner'),
    'owner-final-changed-bytes': ('PSrc/OwnerDischarge.p', 'rows[p.pin.key].outcome = p.outcome;', 'rows[p.pin.key].outcome = p.outcome + 1;', 'tcOwnerDischargeHappy', 'final outcome committed after failed or changed transaction'),

    'live-launch-before-association': ('PSrc/Executor.p', ('    if (!(k in commandRoutes)) { send this, eLaunch, (key = k, boot = boot); }', '      if (p.key in commandRoutes && (!(p.key in launchPermits) || launchPermits[p.key].boot != boot)) { return; }'), ('    send this, eLaunch, (key = k, boot = boot);', ''), 'tcCompileReadySubmitUnassociated', 'command Intent preceded exact association and original live permit'),
    'live-permit-from-history': ('PSrc/ProductExecutor.p', ('        !(id in liveClaims) || liveClaims[id] != a.command.claim ||', '        a.command.resource != this || id in associated ||'), ('', '        a.command.resource != this ||'), 'tcLiveAssociationLoss', 'fresh association lacked original live Claim'),
    'live-ignore-claim-incarnation': ('PSrc/ProductExecutor.p', 'liveClaims[id] != a.command.claim', '(liveClaims[id].issuer != a.command.claim.issuer || liveClaims[id].service != a.command.claim.service)', 'tcLiveAssociationClaim', 'permit lacked unique original live Claim and exact committed association'),
    'live-duplicate-association-permit': ('PSrc/ProductExecutor.p', '    id = a.command.prepared.offer.service.id;', '    id = a.command.prepared.offer.service.id;\n    if (id in associated && associated[id] == a.command.prepared) { announce mCommandPermitIssued, a; send a.executor, eCommandPermit, a; return; }', 'tcLiveAssociationClaim', 'permit lacked unique original live Claim and exact committed association'),
    'live-stale-boot-permit': ('PSrc/Executor.p', ('    pendingCommands = default(map[tKey, tAssociationRequest]);', ' || a.boot != boot'), ('    pendingCommands = pendingCommands;', ''), 'tcLiveAssociationLoss', 'native launch consumed absent stale or duplicate original permit'),
    'live-launch-after-lost-answer': ('PSrc/Executor.p', '      pendingCommands -= (a.command.prepared.native.key);\n      announce mCommandReplyLost, a;', '      launchPermits[a.command.prepared.native.key] = a;\n      send this, eLaunch, (key = a.command.prepared.native.key, boot = boot);\n      announce mCommandReplyLost, a;', 'tcLiveAssociationLoss', 'command Intent preceded exact association and original live permit'),
    'live-foreign-control': ('PSrc/ProductExecutor.p', 'associated[id] == c.command.prepared &&', '', 'tcLiveAssociationControls', 'command control lacked exact retained association'),

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
    'preparation-clearance-as-admission': ('PSrc/Executor.p', ('      admit(p.wire);', '      if (!(k in rows) || rows[k].request != p.wire.request || rows[k].phase != Admitted) { return; }', 'row = rows[k], connection = p.wire.connection, boot = boot'), ('', '', 'row = (request = p.wire.request, phase = Admitted, launchBoot = 0, retired = false, receipt = false, outcome = NoOutcome, terminalDigest = 0), connection = p.wire.connection, boot = boot'), 'tcProductLifecycle', 'command continuation preceded actual native Admit'),
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
