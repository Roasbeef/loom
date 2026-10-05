# Distributed owner-run discharge

This component retains owner-run custody until the admitting live incarnation
commits its exact final ToolOutcome and observes weft `AllDelivered`. It fixes
fresh capacity being restored after worker loss and after a custodian restart
while accepted downstream work remains unresolved. The base is
`db7b77d872bbdce22a9c92ef58aedf7d25c9e4a6` for issue #697.

## Contract

Fresh reservation commits `run_custody = 'unreleased'` in the existing tool row
before spawning. The marker is independent of retained/frozen collection state.
The live owner tracks `AwaitingReport`, `FinalCommitted(Payload)` and `Unresolved`.
Worker loss, missing or failed final commit, lost run, failed discharge and the
consumer's `fatal_fence` leave it unresolved. A later ordinary exact outcome can
be retained for recovery, but cannot overwrite that disposition.

Only `FinalCommitted` followed by complete delivery calls storage `discharge`.
The transaction compares the retained exact outcome and conditionally releases
the same tool row; failed COMMIT rolls it back. Only successful discharge drops
the live slot. Startup uses a partial index containing only rows whose marker is not Released.
The bounded existence query therefore reads no released history and makes any
unreleased journal recovery-only. The retained index predicate also fences invalid
markers if external corruption defeats the table constraint. Historical outcomes and exact late receipts
remain available. Collection requires Released in addition to reserved-session
result readback, and frozen rows preserve the release marker.

The admitted runner receives a private Handle pinned to the original actor's
Subject/PID. External admission and history retain the reclaimable registry
handle. The relayed weft run watches its original owner's death. Pinning prevents
an old runner from resolving a replacement custodian during cancellation.
The unshipped owner journal advances to format 4 and intentionally refuses prior
formats: missing release proof is never upgraded to Released.

## Executable witnesses

`storage/owner_custody_test` covers Fresh COMMIT before spawn, final COMMIT before
drain, exact-byte discharge mismatch, deferred-foreign-key failure at discharge
COMMIT, early collection, marker preservation on collection and old-format refusal.
The storage command-custody fixtures retain their prior corruption and historical
fence cases, checking refusal without mutation under the new format boundary.

`client/remote/owner_binding_test` holds a real downstream `call.try_call`, kills
the managed worker and restarts its custodian. Fresh admission remains fenced,
exact late receipt custody remains available, and the old pinned handle cannot
resolve the replacement. Further witnesses cover sticky consumer fatal followed
by normal completion, failed discharge COMMIT, normal exact finish plus drain
permitting capacity reuse, and owner death cancelling a blocked managed worker.

Eight compiling mutants fail these witnesses: Fresh marked Released, removed
exact-byte comparison, inverted collection guard, old format admitted, restart
admission reopened, sticky disposition overwritten, failed discharge freeing its
slot, and the runner resolving the registry. Removing the explicit
`cancel_when_exits` guard survives the owner-death witness: `start_relayed` already
starts a linked relay whose death cancels its detached run. The explicit guard is
retained, but this witness does not uniquely prove it. Mutant sources were restored
byte-for-byte before final controls.

## Verification and limits

The pinned server-bin toolchain and `ERL_FLAGS='+S 4:4'` ran with private caches.
Dependency source and textual application metadata were seeded only after exact
manifest parity with the integration tree; no compiled dependency artifacts were
copied. Shared sandbox/TUI prerequisites were built once, then package gates ran
through `scripts/check.sh` without concurrent prerequisite builds. The initial
global Go-cache write was refused; the build succeeded with a private GOCACHE.

The focused storage controls pass 19 tests and the owner-binding controls pass
14, with no skips. The crash, fatal and failed-discharge witnesses observe fresh
admission refusal across a bounded 250-ms window, rather than accepting one
Capacity answer before the drain notification. The full storage gate passes
193 tests with no skips, including the final partial-index schema. Its command
exits 0 in 14.441 seconds; EUnit takes 2.91 seconds. Focused house-rule lint passes with zero errors and one existing catch-all warning;
doc-check passes with zero errors and 183 existing drift warnings. SQLc generation
completed with its explicit success marker. Source hashes, exact exits, elapsed
times, mutant reports and full logs are retained under
`/private/tmp/loom-distributed-wave2/owner-discharge-*`.

The initial full client run was permission-limited: four unchanged search fixtures
failed on HOME scratch-file Eperm, then socket-listener Eperm cancelled the run.
It passed 648 tests before cancellation and printed 31 optional SKIP lines;
EUnit's zero skipped count does not capture those lines. No hidden Error-in-process
reports appeared before that abort. The first permissioned run passed 2,831
tests and failed one unchanged socket path-length assertion: the deep private scratch root produced 154 bytes against
the 100-byte socket limit. An isolated control reproduced that environment
failure. A subsequent `/private/tmp` scratch run passed 2,830 tests and failed
two unchanged extension-profile tests because their jailed workspace refuses
the scratch tmpfs. Both controls pass with the final short repository-local
`LOOM_TEST_SCRATCH=/Users/roasbeef/gocode/src/github.com/roasbeef/loom/.od697`.
That full client gate exits 0 in 240.244 seconds and reports 2,832 passing tests
(EUnit takes 239.28 seconds). It prints 47 optional SKIP lines: 32 missing
code-mode seed, 13 unset shipped-server witnesses, one Linux `/proc` witness
and one unavailable rust-analyzer witness. No subject-ownership panic or
Error-in-process report occurs in this run. Ten panic renderings describe nine
deliberate crash-fixture incidents; the provider HTTP fixture repeats its
exception as nested reporting. An earlier permissioned run contained one
pre-existing advisor fixture subject-ownership panic despite its outer test
passing. The exact final source was rechecked after partial-index generation: the
client gate again exits 0 with 2,832 passing tests in 239.403 seconds (EUnit
237.66 seconds), and the same 47 optional skips. That exact-source run emits
two pre-existing `client/advisor_test.a_held_check` subject-ownership panics
at line 3186, while the outer tests pass. Its twelve panic renderings comprise
those two incidents plus the ten deliberate renderings above. This is recorded
as a full-suite fixture defect, not a clean peer-panic census or evidence of
owner-run discharge failure. The owner-binding witnesses have no optional skips
or hidden peer panic. Exact exits and both censuses are retained side by side.

Independent final review found no reachable production correctness defect,
small warranted simplification or nearby live variant. It found one test race:
the failed-discharge witness could succeed on a pre-drain Capacity answer.
That finding was verified and the bounded refusal window above replaced it;
the strengthened controls and their failed-discharge mutant pass and fail,
respectively. This component proves owner-run
discharge only. It does not prove native command retirement, resource cleanup,
physical Compile/Launch completion, shipped remote daemon wiring or separate-host
ordinary-tool/code-mode acceptance. The native definite-route change is excluded.

## Integration verification

The integration pass verified all 22 frozen source hashes before copying the
change onto `44b617b62`. An independent full storage run passed 193 tests in
2.547 seconds, and the 14 owner-binding controls passed in 2.059 seconds. Both
commands exited 0. The source and generated bindings are committed separately
as `cc8f2c19f` and `4be19e1f`.

The combined integration tree passed the 193-test storage gate in 3.542 seconds
and the seeded 2,832-test client gate in 319.786 seconds; both exited 0. The
client run printed 15 optional skips: 13 shipped-server controls without
`LOOM_BOOTSTRAP_E2E_SERVER`, one Linux `/proc` witness and one rust-analyzer
witness. It emitted no subject-ownership panic or `Error in process` report.
These results cover the combined source at `4be19e1f`; they do not establish
shipped remote daemon or separate-host acceptance. The formal owner-discharge
extension is still in progress and adds no proof claim to this record yet.
