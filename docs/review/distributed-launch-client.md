# Remote Launch client review

Commit `b58370ce5` adds the owner consumer. It composes the existing whole Launch owner, finite TLS BEAM
binding, original stream bridge and native command dispatcher. Its three modules
own admission and reconciliation, the foreground connection companion, and
bounded historical receipt collection. Registered daemon assembly and per-Launch
native retirement remain separate, unfinished obligations.

## Reviewed behavior

The consumer retains the original Compile producer, artifact, canonical Launch
input and native Prepared association before admitting the satellite. Original
Broker clearance distinguishes a definite refusal from an unavailable answer.
The latter remains uncertain and grants no replacement execution.

The managed observer owns its Broker event Subject and collects that same
Subject. The companion retains the original execution handle before admission.
A normal foreground close preserves the observer long enough to collect its
receipt; abandonment cancels the original execution. The existing satellite
cleanup still aborts admitted capability work before connection closure.

That abort can cancel the native receipt dispatcher after Final. Bounded
historical collection therefore queries the exact retained native identity,
checks contiguous output ordinals and its terminal against the closed outer
completion, and commits through the existing command binding. It replays no
output to the live host and submits no native work. Bounds are 64 output chunks,
16,384 bytes per chunk, one MiB aggregate output and a 32,768-byte terminal.

Independent review found a reachable recovery gap in the first version: after
an owner crash before native receipt COMMIT, recovery always supplied no
collection deadline and could never retrieve the missing retained receipt.
The correction gives each recovery call one finite read-only observation
window. Outer Query, native history and acknowledgement share its remaining
allowance. The original execution identity, grants and deadline remain fixed.

## Verification

The independent `make check-client` gate passed all 3,082 tests on the frozen
assembled candidate, including format and warning-free compilation. Fifteen
explicit optional controls remain skipped: one Linux `/proc` witness, thirteen
shipped-server controls and one rust-analyzer control. Client lint passed with
zero errors and 533 warnings; documentation checks passed with zero errors and
184 warnings before this review record was added. Public documentation builds
passed in the component worktree. A final comment-layout-only change passed
format checking, and the corrected path control passed independently with a
nested scratch override.

Two root setup attempts remain failed evidence: the sandboxed attempt lacked
fixture-directory and listener permissions, and a direct script invocation
omitted the Make target's helper/launcher prerequisites. The recorded passing
result is the subsequent canonical Make gate. The worker's own full run also
stayed red after a missing offline seed; seed preparation and the failed Compile
module then passed. Those partial runs are not substituted for the root's full
passing gate.

The real fixture starts two TLS runtimes, builds the satellite through Compile,
executes its actual Broker command, serves a capability filesystem read and
receives Final. The restart control interrupts the exact managed native scope,
observes companion exit, checks that owner receipts are absent, reopens the
original owner database and recovers the executor's retained result. Original
UUID and Prepared bytes must match, repeated recovery is stable, and an attempted
new clearance mint fails the test.

Negative controls cover changed producer metadata, changed producer UUID,
changed enrollment, definite clearance refusal and unknown clearance. The
fixture checks ordinary-checkout and explicit scratch-parent path resolution.
It retains journals and the physical channel-path record even after a passing
control; test success does not authorize collection of unresolved resources.

Three warning-free compiling mutations failed at runtime: assigning the event
Subject to the wrong process, disabling missing-native receipt collection on
recovery, and treating unknown clearance as a definite refusal. Exact source
bytes were restored after each. An earlier recovery mutation stopped at an
unused-argument warning and is excluded from the runtime mutation evidence.

The fresh adversarial pass initially missed the restart case, then confirmed
its MEDIUM finding when the exact absent-receipt state was checked. Its bounded
recheck verified the correction and found no remaining issue in that delta.
The actual fixture proves managed scope loss followed by custodian stop/reopen;
it does not claim a full owner-VM crash or guaranteed delivery of RunLost.

## Limits

This establishes a production remote Launch consumer exercised through explicit
fixture assembly. It does not establish registration in ordinary daemon session
assembly, separate physical hosts, per-Launch native retirement, reusable active
capacity after successful Launch, full repository gates or hosted CI. A native
terminal and retained completion still cannot stand in for resource retirement.
