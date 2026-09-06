# Single-daemon acceptance follow-up review

The closing review examined `33387530..ebe0f96c` on 2026-09-06. It was a
fresh, report-only source review of idle authorization, domain revival,
worker-owned control recovery, durable creation recovery and the shipped
multiplayer fixture. It found no high-severity issue. The primary review
checked reachability before accepting a finding; no production behavior
changed in response to this pass.

## Dispositions

| Finding | Disposition |
|---|---|
| Gateway hints revalidate before their network-delivery guard. | Not reachable in shipped daemon assembly. Runtime subscribers are rules and history, not the gateway forwarder; no provider tap is installed. No production patch and no attribution of the CI latency failure to this path. |
| A registry census proves a stale account was ignored. | The comment overstated the assertion. Retained and closing domains both count as occupied, and the settlement handler ignores the `Pass` payload. Subject identity and continued cadence discriminate the fault. Corrected the prose. |
| The late-fence negative uses a 100 ms window. | Replaced it with a zero-wait check after the existing third-pass settled reply. A trigger only admits a follow-up and is not a completion barrier; the final reply is ordered after earlier fence replies from the same worker. |
| Quiescing a dormant worker can lose its initial begin. | The abstract call sequence exists, but shipped assembly sends the initial begin before publishing its services. A preparing domain with no dependents is cancelled, not quiesced. No new state or replay branch. |
| A revoked idle attachment can remain in presence. | Accepted consequence of checking authority at use. Admission and outbound delivery still revalidate. Presence is not authorization, and the protocol does not promise immediate idle eviction. |
| Fixture cleanup can lack a valid native endpoint. | No speculative fallback. Bootstrap atomically publishes the native fence before releasing its paused child; the isolated fixture never corrupts that record. A malformed record must fail rather than authorize signalling an unknown process. |
| The settle-subject accessor exposes a capability. | Intentional internal fixture seam, with no wire route or production caller. Its documentation now states that a holder can forge settlement. |
| Parked replies could be an optional single subject. | Declined. Direct internal callers can supply distinct reply subjects. Production bounds repeated close/revive cycles by withdrawing the earlier fence. |
| A withdrawn account can produce an unexpected-message warning. | Expected only when an already-decided reply arrives on the old subject. Resume normally drops parked replies, so this is not a warning on every revival. |

The shipped fixture's missing-environment path prints an explicit skip to
standard error. It is not live artifact coverage during ordinary package
tests; the shipped bootstrap target sets the executable and runs it.

## Evidence

At `ebe0f96c`, the independently run combined `make check dist
e2e-client-bootstrap e2e-multiplayer soak-daemon` gate exited 0 in 431.65
seconds. It included 1,322 client tests and 206 TUI tests, then the enabled
shipped multiplayer fixture. `make doc-check` exited 0 with zero errors and
136 warnings. The paired soak assertion was unchanged.

The registry regression passed seven tests, failed its intended identity
assertion when fresh settle-subject allocation was removed, and passed
after exact restoration and recompilation. The corrected cadence regression
also failed when resume retained the withdrawn reply; this mutation compiled
and failed a fence-reply assertion, not setup or dependency resolution.

The rebuilt native clients were also driven in two live terminals against
one packaged daemon and the Baseten example, with background extraction
disabled. Both rendered the first reply without another keypress. One
terminal created a second session and received an independent reply while
the other stayed on the first, then rejoined the first and submitted a
reply visible in both. Both clients detached, the daemon logged
`daemon.stopped`, its process departed, and the enclosing command exited 0.
This used two owner-authenticated terminals and no tools. It does not prove
distinct-principal live-tool isolation or switching during a jailed effect.

## Still required

The parent PR's macOS CI run failed the paired latency bound: 399 ms against
372 ms. Five exact local reproductions passed. Neither those passes nor
this review establishes the cause; per-credit diagnostics preserve the
unchanged bound for the next platform run.

Shipping dependency adoption of the SQLite retirement repair, excluded
filesystem confinement, the whole-VM publication crash sweep and the rest
of the combined shipped acceptance drive remain open. A reviewed follow-up
and green local gates do not complete those requirements.
## Shipped reservation recovery follow-up

The separate test-only follow-up received one fresh adversarial review.
The reviewer traced capacity refusal through committed reservation, the
birth-qualified SIGKILL, native departure and stale-endpoint takeover,
metadata-only restoration, and same-key recovery of the original SQLite
identity. No false-pass path was found. Production behavior was unchanged.

The review identified an assumption rather than a missing safety check:
VM departure does not itself prove that the separate lifetime-lock holder
has consumed port EOF. The fixture now documents that the holder should
exit while the replacement VM boots. A delayed holder makes startup fail
visibly; no lock-probe loop or retry was added.

Accepted corrections fix the cleanup-budget arithmetic, use `result.try`
while preserving close-before-assert ordering, separate the retirement
stanza and explain the slot-less `Saved` projection. Existing assertions
and deadlines remain unchanged. A larger launch budget was not justified
by an observed timeout. The fixture explicitly excludes the later
identity-before-confirmation crash boundary.

The corrected fixture passed in 1.98 seconds against the shipped daemon.
Before the prose/combinator corrections, two fresh runs passed, the full
extended bootstrap target passed in 28.26 seconds, and both enabled shipped
fixtures passed together in the package runner. The complete local client
suite passed 1,323 tests in 219.35 seconds; conditional shipped cases in
that ordinary run were separately exercised by the enabled gates.

CI at the earlier `e829a2a0` remains a failure: Linux's strict census caught
the unset shipped prerequisite during ordinary check; macOS's paired soak
took 2,062 ms against 346 ms. The CI repair supplies the built executable
before both platform gates, without declaring or hiding a skip. Five
isolated soak reproductions and the full local suite passed, but the
macOS delay's cause is unestablished and its bound remains unchanged.
