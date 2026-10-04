# Distributed product model review

The new P product model composes the existing native Owner, Executor and Helper
actors with compile, resource, launch and owner-completion transitions. It checks
exact command offers, distinct child roles, retained resource identity, uncertain
launch outcomes and separate native/outer receipts. Existing native monitors
remain active; product actors cannot manufacture native launch or retirement.

The Channel PlusCal model checks one in-flight frame in each direction. Network
drainage, final consumption and acknowledgement are distinct actions. Timeout
closes admission without returning the pending credit. Credit-owner death
retires that lane. Cumulative byte accounting includes ordered outcome and hook
frames, and separate control capacity permits cancellation under data pressure.

## Review findings and repairs

Independent review found two coverage defects despite green checker results.
The P mixed-fault driver began fault injection after Compile's first Running
reply and could never progress to Launch. The corrected workload completes a
reliable Compile bootstrap, then begins its twelve bounded fault actions only
after actual native Launch start. Retry, query and replay name that original
Launch identity. A new reachability probe reads independent resource-intent,
creation, issued-lease and Helper-start histories before observing cleanup of
the same native key while retirement is still absent. The separate directed
ResourceUnknown case retains coverage before lease issue; the mixed workload
does not claim an interleaving inside one atomic handler.

The original Channel late-ACK probe could consume a frame before timeout and
acknowledge it afterward. The repair records the exact pending item consumed
after timeout, then requires its matching ACK while admission remains closed.
The six-state witness now queues at state 3, times out with the original item
unconsumed at state 4, consumes at state 5, and acknowledges at state 6. The
probe no longer passes when only acknowledgement is late.

Focused independent re-review verified both repairs against the actual source,
snapshot hashes and raw traces. No actionable finding remains within that
review's scope. Earlier passing evidence remains valid for its earlier source;
it did not establish these two stronger reachability claims.

## Recorded checks and limits

The final P run passes 36 cases: fourteen normal cases at 1,000 schedules each
and twenty-two exact reachability assertions. All fourteen mutation controls
pass 100 schedules; each compiling mutant fails its registered assertion.
Compiler errors, unrelated assertions and exhausted checker budgets do not
count as expected failures. The nine product probes reach their intended
assertions on schedule 1.

All 47 TLC cases pass their expected verdicts, including the original 33 cases
and fourteen Channel cases. Translation equality is checked for all four model
sources. ChannelSafety exhausts 7,737 distinct states and the smaller quota
case exhausts 4,025, with empty exploration queues. Each positive control and
mutation requires its exact named counterexample. The final Channel source
SHA-256 is `f385e6305714e83a266e48d62250b0662c8dbc935edd9acdbf82a168c099675a`.
Root independently reran the full P gate (including all mutations) and the
complete TLC suite; both returned exit 0 on the frozen source. Model-local
READMEs document commands, bounds and retained evidence paths.

These checks concern finite abstract durable stores and trusted actors. P
samples schedules; TLC exhausts only its declared finite bounds. They do not
prove wire decoding, authentication, physical resource ceilings, liveness or
model-to-production refinement. The existing Lean admission proof remains a
separate reducer bridge. Shipped owner/executor assembly and separate-host
end-to-end acceptance remain outstanding.
