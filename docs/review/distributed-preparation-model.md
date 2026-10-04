# Physical preparation model review

This extension of the [product P model](../../protocol/models/remote-execution/PRODUCT.md)
checks the preparation and command ordering in
[protocol 067](../../protocol-change/067-remote-workspace-services.md).
It keeps the original native model unchanged.

Preparing commits before resource creation. Recovery cannot reconstruct its
one live claim. Issued Ready data remains distinct from live resource custody,
and Launch checks the actual retained successful Compile association. The owner
constructs its command after Ready, using the original remaining authority and
pending control bounds. Continuations preserve its selected wall, original
deadline and native identity. Clearance alone cannot establish native admission.

## Review corrections

The first independent Astra high review found two mutation-evidence defects,
without finding a reachable safety defect in the unmodified model. One mutation
announced a second clearance without entering the clearance path. Another changed
the digest sent to a monitor instead of delivering a foreign terminal input.
Their passing mutation gates did not support the claimed protocol coverage.

The repaired recovery mutation routes into the real `clearOffer` function and
removes its two blocking guards. Its unchanged instrumentation now detects the
second attempt. It does not prove successful second clearance: the unchanged
remaining-budget check would also refuse that delayed attempt.

The foreign-terminal scenario now delivers the same native key with digest 2
to the real handler. Its control requires actual refusal before genuine Compile
completion; the mutant removes only that equality check. It fails the intended
association assertion without fabricating a monitor payload. A focused Astra
follow-up verified both repairs and found no remaining actionable issue.

## Independent validation

Root independently ran `run.py --schedules 1000 --probe-schedules 2000 --seed 697`
and `mutate.py --schedules 100 --seed 697` on the repaired freeze. Both wrappers
exited 0: safety took 188.682 seconds; all mutation controls and compilations
took 656.659 seconds. Every one of 31 normal cases completed 1,000 schedules
without a bug. All 40 reachability probes reached their registered assertion
within the 2,000-schedule bound. Each of 27 controls passed 100 schedules, and
each compiled mutant failed its intended assertion at schedule 1. Expected
probe/mutant checker exit 1 is distinct from the successful wrapper verdict.

The 24-file manifest matched before and after these runs. Its canonical files-map
digest was `83615949ef9417f0c1df5f10016eefe0438f94f07a2b554d8be42ca23fe47b8c`.
A subsequent README wording correction describes the recovery mutation's three
exact replacement sites; no model or runner changed. The eight original native
files remain byte-identical to the earlier model.

These are bounded schedule-based checks at one seed, with explicit step, time
and memory limits. They establish neither exhaustive exploration nor production
refinement, serialized database behavior, kernel cleanup or two-host acceptance.
This slice changes no PlusCal or Lean model and makes no new claim about those
separate verification results.
