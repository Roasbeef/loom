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

## Shipped identity recovery follow-up

The second shipped crash fixture received a separate fresh adversarial
review. It covers identity publication before catalogue confirmation using
an actual MCP initialize barrier, VM-only loss and postmortem durable
assertions. Recovery waits for the unchanged writer lease to expire
naturally; it never rewrites a lease timestamp or forces garbage collection.

The review found no high-severity issue. Its medium finding was a coverage
weakness: `Saved` and an unchanged lease alone could also follow an earlier
configuration or helper failure. The accepted correction requires the same
session's `storage_open_failed` event, with a bounded wait for log flushing.
That establishes the refusal stage, not the exact storage error. Original
lease identity and the later higher fence remain explicit assertions.

Other accepted corrections reuse `endpoint.observe`, make result patterns
explicit and explain the lock-holder and retirement ordering. Safety
assertions and the helper's independent watchdog remain. No additional PID
tracker was added for orderly MCP shutdown: the existing transport retains
the native port until exit is observed, and session retirement retains that
custody. VM departure alone is not that proof. These small corrections did
not warrant another full review pass.

The combined check, distribution, shipped bootstrap, multiplayer and soak
gate at `563f3573` exited 0 in 494.21 seconds, including 1,324 client tests,
206 TUI tests and all three enabled shipped fixtures in the dedicated
target. After the review correction, the focused identity fixture exited 0
in 61.59 seconds; most of that time is intentional natural lease expiry.

Remote CI at the earlier `ffacaa5b` failed independently: Linux passed check,
bootstrap and documentation before a Hex API rate limit broke shipment;
macOS failed the unchanged paired soak at 498 ms against 370 ms. Both shipped
fixtures available at that head passed in ordinary check. Neither a causal
timing fix nor green platform acceptance is claimed by this follow-up.

## Shipped presence recovery follow-up

The next test-only increment extends the existing three-terminal fixture
through Bob's detach and rejoin. A fresh source review found no high- or
medium-severity issue. Each surviving terminal must first capture the exact
two-principal roster; all three then capture the exact recovered roster
with Bob's new daemon-minted attachment identity and Alice's unchanged
configuration and author. An original driver monitor is not used as proof
of server detach.

The review confirmed that the coherent-cut decoder already rejects duplicate
attachment IDs. The explicit uniqueness and old-ID assertions are retained
as named acceptance observations, not additional production defenses. The
factored shutdown helper preserves the original monitor, Normal-exit check
and deadline. No further review or timeout expansion was needed.

At `86d7b7ec`, the focused fixture passed in 2.49 seconds. All three enabled
shipped fixtures passed together in 64.80 seconds, with six total matches
under the package filter. This establishes presence recovery, not ordered
prompt replay or a queued command's revocation boundary.

## Shipped provider and durable ordering follow-up

The finite loopback provider and the two-turn native-TUI extension received
one fresh source review. It found no high-severity issue or false-pass path.
The shipped daemon uses its ordinary HTTP transport and a public dummy key.
The peer compares the latest user text against the next script step, not
against a substring of accumulated history. It accepts the production
human-attribution block, and records any refused, repeated or missing request
as a failing report. All three terminals compare exact durable records and
user authors, rendered answers and idle completion across Bob's reconnect.

The medium finding was possible hosted-runner exposure in the eight-second
per-terminal await, not an observed miss. The deadline and its diagnostics
remain unchanged: the focused whole drive passed in 3.46 seconds and its
combined-gate invocation in 3.32 seconds. A measured miss would justify
revisiting that stage's budget; an outer timeout increase would not fix it.

Accepted corrections annotate the helper's public and private contracts,
retain the decoded model in request evidence, clarify callback failure
reporting, and explain port publication. Script bounds and explicit safety
assertions remain. The small chunked-response actor is intentional coverage
of chunked HTTP through the shipped transport; replacing it with a finite
Content-Length response would remove that wire case. No general provider
server or new production process machinery was added.

Before those small clarity corrections, the combined check, distribution,
shipped bootstrap, multiplayer and soak gate exited 0 in 497.05 seconds,
with 1,332 client tests and 206 TUI tests. All three shipped fixtures ran in
the dedicated target. The documentation gate reported zero errors and 137
warnings. The separate helper suite passed eight cases, including actual
socket closure after callback failure. The final focused correction results
are recorded in the handoff; no second review pass was needed.

## Shipped invitation boundaries

The next increment checks one invitation against a second resident session
in another workspace. A fresh review found no high- or medium-severity issue.
Both invited principals receive exact foreign-access refusals. The owner
then reads the same incarnation and operation and upgrades the same route,
so an absent target cannot explain those refusals. A raw observer mutation
reaches the gateway independently of the terminal's local guard.

Accepted corrections replace string dispatch with typed roles, separate the
test's stages, and describe invitations as owner-only. The invitation probe
uses the already-shared session because its guard does not consult the target.
The observer guard also refuses unknown command names; Alice's successful
configuration command is the positive control for the probe's wire name.
The per-principal checks remain in one loop. Splitting that loop would add
structure without preserving a different property.

The pre-correction combined gate exited 0 in 499.78 seconds. The final
focused drive at `d3a647b9` exited 0 in 3.87 seconds. Those results establish
the named acceptance observations, not the validity of earlier skip counts.

## Visible skip diagnostics

Published `0bc46d32` reached the final macOS skip census, which failed on an
apparently stale `/proc` declaration. Source inspection showed that the
prerequisite still existed. A direct EUnit reproduction explained the missing
marker: a passing test's stdout is captured, while stderr remains visible.
The test did not acquire process-observation coverage on macOS. Its existing
declaration remains necessary.

The repair follows the native TUI fixture's existing stderr convention.
Thirty-five emitters in ten Gleam test files change only from `io.println`
to `io.println_error`, with ordinary formatting. Marker text, prerequisites,
assertions and declarations remain unchanged. No reporter, new Erlang module
or EUnit capture change is introduced.

Direct review approved the repair. The new regression runs stock EUnit and
feeds its visible marker through the actual census: an undeclared skip fails,
a declared skip passes, and an unused declaration fails. Its source guard
recognizes multiline and shared emitters without treating comments or string
examples as calls. The documented literal-first convention bounds that check;
it does not track values stored in variables. All twelve Python deadline and
reporting tests passed in 3.53 seconds under the existing twenty-second bound.

Earlier census results on both platforms are unverified until the repaired
reporting path runs there. A test command's zero exit status is distinct from
proof that all its conditional cases executed. The handoff records the first
completed rerun and its remaining declared skips.

## Live membership revocation

The next shipped increment revokes Bob after the shared turns and reconnect.
A fresh independent pass found no high-severity issue and one medium: the
terminal's pre-revocation sample did not prove it was still connected. The
fixture now waits for a live, writable cut before revocation, using the
existing bounded helper so an ordinary capture cannot cause a false failure.

The close assertion now requires the exact normal WebSocket close code 1000,
followed by the native `closed` result. Mist's normal-stop path and Gramps'
encoding establish that frame; a handler-crash close no longer satisfies it.
The fixture explains that Bob disconnects when his own refresh is refused,
not from a broadcast. Both record comparisons remain at their separate
barriers. The existing one-second raw read bounds are unchanged.

The owner acknowledgement follows the synchronous catalogue transaction.
Consuming it before sending Bob's next command supplies causal ordering
across the two connections without comparing clocks. Surviving clients'
complete configuration and author are the positive control for Bob's retained
view; control authentication distinguishes membership loss from credential
revocation. No separate configuration revision exists in that view type.
The admission/delivery interval is explicitly left to the scripted authority
test. The nearby variant review found no other live issue.

The pre-correction combined gate exited 0 in 566.05 seconds. Final focused
`0606cb89` passed in 4.33 seconds; the strict local census passed with only
the existing macOS `/proc` skip. No second independent pass was needed for
these small corrections. The earlier published `33aa9ef1` independently
passed both remote platform censuses and all four jobs in run 34043916766.

## Failed selector preservation

A fresh pass over the next shipped selector increment found no high- or
medium-severity issue. The model's actual highlighted row supplies Enter's
target; a consumed owner acknowledgement orders target-only revocation before
selection. The exact refusal cannot be an earlier notice or a transport error.
Structural identity and socket comparisons, an owner-positive target attachment,
and later configuration traffic cover both sides of the failed replacement.

Accepted cleanups correct the previous paragraph's stage name, add stanza
boundaries and remove two redundant assertions already guaranteed by the
returned sample's await predicate. The correct repeated retirement setup stays
local instead of mixing a refactor into the assertion change. The exact notice
could be overwritten by future metadata traffic, but this stage deliberately
changes no original-session metadata until after the refusal is observed.
No workaround or wider timeout was added for that hypothetical false failure.

The package gate exited 0 in 290.78 seconds with 1,332 tests and all shipped
fixtures enabled. Its strict local census passed. Final focused `e8ec249e`
passed in 4.78 seconds after the small cleanups; no second review was needed.
The separate published revocation head's macOS soak failure is recorded in
the handoff and is not presented as a green platform result for this increment.

## Paired-latency observations

Direct independent review approved a bounded sampler after the recurring
macOS soak failure. The original caller still measures the wire operations.
A linked Weft run publishes its own stop inbox, samples four fixed original
PIDs, and returns its bounded observation before `AllDelivered` witnesses
worker retirement. Caller-failure cleanup follows that existing Weft ownership
contract; this increment did not independently inject that failure.

The call site selects six process-info fields and never reads messages,
arguments or process dictionaries. Formatting follows the measurement.
Both conditions use the same sampler, with 25 ms spacing, 128 samples, a
3.2-second observation horizon and a separate five-second worker deadline.
Termination reasons are typed and serialized explicitly. No production code,
FFI, workload, latency bound or VM-global monitoring flag changed.

Accepted review cleanups clarify the call-site allowlist and coarse resolution,
type the completion reason and separate the sampling stanzas. The first run
reported one to three observations per condition, with measured batch durations
of 0–3 ms, not all zero as the initial review summary said. Those durations
include the sampler's own scheduling; they do not establish zero perturbation.
Heap growth is not itself a collection, and no sampled state establishes a
host or native-I/O cause. Final focused `4744fe7a` passed in 11.75 seconds.

Direct review then found that passing EUnit captures the report's stdout,
while CI did not upload the fixture's JSONL. Commit `8089a4b9` adds only those
reports to both existing always-upload artifacts. It changes no measurement.
Run `34048567159` at `00076858` verified those files on both Linux success
and macOS failure. It retained 18 current Linux pairs and two current macOS
pairs, all with completed samplers. None of those stressed credits exceeded
250 ms. Older cached fixture directories were also uploaded and are excluded
from attribution. Missing samples from earlier green runs do not establish
an absence of slow credits.

The macOS failure measured 461 ms against 342 ms, with 398 ms in subscription
setup. Sampling continued with gaps of 26 to 110 ms, and registry reductions
advanced between samples. SQLite step frames and collection counters narrow
the investigation, but the samples do not establish host descheduling, BEAM
starvation or a collection's duration. The handoff records the exact phase
times and platform results. No threshold was relaxed.

A proposed rollback-journal diagnosis was rejected and retracted after
following `catalogue.initialize` into `sqlite_policy`. The catalogue already
applies the shared five-second busy timeout and verifies WAL admission.
Authority reads use a deferred transaction, and no second catalogue writer
was found in this soak path. Subscription also waits on the separate
conversation snapshot reader, which these four sampled PIDs do not cover.
The registry's sampled SQLite activity remains a hypothesis to investigate,
not a reason to change journal policy or cache authorization.

## Successful switching with an active peer

A fresh review of the four-turn shipped fixture found no high- or
medium-severity issue. The extracted selector navigation preserves every
failed-switch assertion, and the shared-history helper retains exact records
and the observer's read-only check. Alice selects B and returns to A while
Reader stays attached to A. Return compares the server-decoded epoch and
incarnation against Reader's original attachment, not a reminted identity.

The provider requests are sequenced by B's completion before the A request.
Both runtimes coexist, but simultaneous inference is not claimed. After A
completes, a fresh attributed configuration round-trip on B precedes exact
B-only history checks. All three A terminals then compare complete records
after Alice returns. The owner's expected principal comes from authenticated
control and is checked against the owner's terminal attachment.

Accepted low-severity suggestions add stanza comments and a final comparison
of Reader's attachment. Earlier explicit identity and record equalities stay
because they localize failures to the preceding stage. No deadline changed.
The full client gate before those small review edits passed 1,332 tests in
292.67 seconds, including all shipped fixtures, with a clean strict local
census apart from the declared macOS prerequisite. The final focused result
is recorded in the handoff.

## Pending native selection across VM loss

A fresh pass over the identity fixture's native-client addition found no
high- or medium-severity issue. The driver is freshly selecting the session
when control confirms its original opening operation. Actual VM departure
precedes the failed-candidate observation. Only exact public control-loss
outcomes pass; timeouts, startup expiry and unexpected reply shapes do not.
The observed focused and composed runs reported disconnection.

The pre-crash and failed models agree on session, channel, captured snapshot
and records. Existing reservation, database identity, lease and metadata-only
restore assertions remain at the same boundaries. After explicit recovery,
the replacement terminal's epoch matches a separately authenticated control
hello, differs from the old epoch and carries the current resident incarnation.
Epochs are random identities, not ordered counters. The reused owner token
also checks credential persistence across restart.

Accepted low-severity edits shorten a diagnostic, remove the misleading word
"original" from the shared driver-retirement message and clarify failure-class
coverage. Explicit pre-crash equalities stay for failure localization. A
driver round-trip does not prove that another scheduled worker already ran,
so the exact allowlist retains handshake loss without claiming it was observed.
No public type was expanded to expose the candidate worker's internal operation.

The tightened focused run passed in 61.80 seconds. Root independently ran the
composed shipped filter: six tests passed in 67.86 seconds. The final edits at
`376da701` change comments and diagnostic labels only; format passes and the
assertions and 200/230/270-second bounds remain unchanged. No further review
was needed for those edits.
