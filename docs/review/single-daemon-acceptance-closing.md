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
