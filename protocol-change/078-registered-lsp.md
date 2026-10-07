# 078: Registered LSP service and exact native leases

Status: approved 2026-10-06; implementation and executable acceptance pending.

Numbering note (2026-10-07): this approved proposal was originally numbered 076. It is renumbered 078 because current main already assigns 076 to model profiles. Approval and normative requirements are unchanged.

## Problem

Registered sessions need the existing LSP query, observation, rename and post-write
behavior when the checkout exists only on the executor. Ordinary native feed and output
journals cannot carry a session-long JSON-RPC stream: their forwarding acknowledgements
prove no helper consumption, and their finite-output profiles are too small for a
language server. A query timeout also cannot authorize a replacement server while
original helper custody remains unresolved.

## Decision

Use one session-scoped executor LSP manager behind a closed finite semantic route, with
a separate owner-cleared native ServerLease. JSON-RPC stays between the manager and its
local helper. Semantic requests cross the authenticated BEAM endpoint using the
identities, admission limits and original timing custody below. Protocol 067's unchanged
native, workspace, Compile and Launch rules still apply. Protocol 079 supplies
deployment, generation links and historical access.

The capitalized requirement words have their usual normative meaning. The state
transitions, codec shapes, limits and acceptance controls below are requirements,
including where they are stated in ordinary declarative prose.

## Identity and authority

Add a separate closed identity family, without widening the existing Compile/Launch
constructors:

```gleam
pub opaque type LspServiceKey
pub opaque type LspInvocation
pub opaque type LspInvocationKey
pub type ExactLeaseKey = LspServiceKey
pub type OriginalFiniteInvocation = LspInvocationKey
pub opaque type CheckedProfileOrdinal
pub opaque type CheckedSearchRoot
pub opaque type OriginalParentControlRef
pub opaque type FiniteCapture
pub opaque type FiniteAnchor
pub type LspStartupRole { Probe Prepare ServerLease }
pub type LspCommandParent {
  Startup(ExactLeaseKey)
  Search(OriginalFiniteInvocation, CheckedProfileOrdinal, CheckedSearchRoot)
}
pub opaque type LspCommandRef
pub opaque type LspProtocolAttachment
pub opaque type FiniteTimingProposal
pub opaque type AdmittedFiniteControl

// Smart constructors require validated identities and digests.
lsp_service_key(SystemOrigin, Scope, OpId, StepId, RequestId,
                InputDigest, EnrollmentDigest, ContractDigest)
  -> Result(LspServiceKey, IdentityError)
lsp_startup_command(ExactLeaseKey, LspStartupRole)
  -> Result(LspCommandRef, IdentityError)
lsp_search_command(OriginalFiniteInvocation, CheckedProfileOrdinal,
                   CheckedSearchRoot)
  -> Result(LspCommandRef, IdentityError)
lsp_capture(AdmittedOrigin, Scope, OpId, StepId, RequestId,
            Request, OriginalParentControlRef, EnrollmentDigest, ContractDigest)
  -> Result(FiniteCapture, IdentityError)
lsp_invocation(AdmittedOrigin, Scope, OpId, StepId, RequestId,
               Request, OriginalParentControlRef, FiniteTimingProposal,
               EnrollmentDigest, ContractDigest)
  -> Result(LspInvocation, IdentityError)
```

SystemOrigin is the existing validated `remote_tool.system_child(session, "lsp", ordinal)` family (`core/remote_tool.gleam`). A lease service key retains the complete
original configured-server name, canonical project root and incarnation in its canonical
input digest. The slot is `(full Scope, configured server name, canonical root)`; it has
at most one unretired incarnation. Scope includes both authority epochs. RequestId, OpId
and StepId are retained before dispatch. Exact retry compares the whole key and
unchanged canonical bytes. Neither a timeout nor a peer-selected ordinal creates another
server.

Finite requests retain the original admitted tool/capability origin, or the existing
system origin for an actual post-write observation. ApplyRename requires the original
approved mutation authority. Role, configured server, executable, argv, environment,
roots, mounts and preparation sequence come from administrative enrollment and the
executor's checked placement. A peer cannot choose them. The opaque command constructors
have two closed parent forms: Startup permits Probe, the configured Prepare recipe and
ServerLease beneath an exact real lease; Search has only an original finite invocation
parent, checked enrolled profile ordinal and checked search root.

No Search constructor takes a lease, and no invocation parent can construct ServerLease.
Command addresses include the complete parent, profile ordinal/root where applicable and
the derived role, so later queries cannot reuse an earlier Search association. The
ordinary native `verify` function remains unchanged.

The existing cold resolver searches sequentially over every configured profile before
selecting a project (`manager.gleam`). Registered enrollment therefore admits at most
sixteen configured LSP profiles, in immutable enrolled order, with at most one Search
per profile for one original cold invocation. Sixteen is the Registered administrative
cap; the local manager retains its existing behavior. It preserves complete resolution
over every admitted profile; an oversized configuration is rejected before registration
rather than truncated. This keeps a modest language table while bounding the existing
200-hit/50-file projection to at most 3200 hits and 800 profile-local file slots.

A warm invocation captures the manager's actual selected identity and searches that one
enrolled profile/root. A cold invocation searches the checked canonical enrolled
workspace root for each profile using its existing separator/extension rules; the peer
supplies neither a new root nor a profile ordinal. Only after `by_project` selects one
real server/project is its real lease reserved. Cross-project ambiguity remains an
answer without a fabricated lease.

Each Search keeps its separate immutable offer/native/terminal/projected-hit
association, charged before its effect. Execute one raw collector at a time, release its
at-most-eight-MiB raw buffers after retaining the checked projection, then charge the
aggregate hit projection before admitting the next Search. Hit accounting is UTF-8
canonical path bytes plus 32 bytes per row; with paths at most 8192 bytes, the explicit
worst-case ceiling is `16 * 200 * (8192 + 32) = 26,316,800` bytes. Grouping/admission
has its own charge for each projected hit's canonical path, owning project root,
configured label and 64 bytes of row/index overhead. Its ceiling is
`3200*(8192+8192+128+64) = 53,043,200` bytes even if each root spelling is separately
allocated.

Enrolled argv/environment/profile bodies remain the already bounded immutable
enrollment, referenced rather than copied per hit. Grouping cannot silently append
canonical aliases. At most the prior retained projection, one grouping projection and
one raw collector are live, with logical content at most `26,316,800 + 53,043,200 + 8,388,608 = 87,748,608` bytes before the separately bounded source/result inventories.
Each per-search reserved projected body is at most `200*(8192+32) = 1,644,800` bytes,
plus its bounded header/terminal/offer. All command rows count against the shared 4096
permanent identities and 256-MiB logical store budget.

Exhaustion yields a checked limit failure, never a prefix search claimed as complete.
Replay inspects these retained associations and launches none again.

The trusted Registered Jailed adapter produces one of four checked native plans. Probe
uses the existing fixed `/bin/sh -c 'exit 0'`, the session base's positive CPU
allowance, the existing ten-second execution deadline and the ordinary 256 KiB output
ceiling. Search uses the existing fixed rg command, session base's positive CPU
allowance, ten-second wall/deadline and unchanged 4 MiB per-stream output allowance.
Prepare preserves the approved fixed Gleam dependency recipe, sixty-second CPU/wall and
1 MiB per-stream output, including its separately approved network authority.
ServerLease alone uses the existing session CPU/wall zeros, original twelve-hour pooled
deadline and 64 MiB output per stream. A missing positive session CPU allowance refuses
finite preparation before any offer. These finite CPU/profile normalizations are the
Registered admission profile; other CallSpec consumers retain their existing behavior.

Search and Prepare use a closed local finite-output collector, with consumed chunks and
respective 8 MiB/2 MiB combined raw stdout/stderr bounds, followed by their existing
checked result projection. Probe can use ordinary bounded output. Raw Search/Prepare
bytes are not put into the one-MiB ordinary native stdout journal. The LSP command row
retains the immutable offer, exact native terminal and its bounded projected result; a
crash before that result commits is Unknown and never recreates the effect. Search still
returns at most 200 hits in 50 files with four hits per file. Preparation still verifies
generated dependency metadata. There is no arbitrary native request accepted through
this path.

Before a native effect, the executor commits its complete immutable offer and returns it
to the owner. The owner checks enrollment, original identity and exact offer, clears it
through the existing broker policy/demand boundary, and retains the resulting native
association before forwarding. Grants and RefuseNarrowed remain owner decisions. A
durable owner offer is not an execution permission. The executor may bind a local
attachment only to the owner-returned native association for that retained
LspCommandRef. Binding never calls Submit or Hello and never returns `native.Running`.

The closed control vocabulary is CaptureFinite(original finite coordinates, original
semantic request, retained parent-control reference), ReserveLease(original_input),
InspectLease(original_key), InspectOffer(original_command_ref),
Associate(original_command_ref, checked_owner_native_association),
CloseLease(original_key) and InspectCleanup(original_key). CaptureFinite supplies the
timing anchor specified below, with no effect permission. ReserveLease creates
metadata/startup custody only. Associate records exact owner clearance, but the original
native service still owns its single first-submit permission. Repeating it compares
retained bytes and never dispatches again.

InspectOffer works for either checked command parent and returns only a retained
immutable offer or a closed NoOffer/Pending disposition. Association cannot carry an
argv, closure, native process or arbitrary role. A semantic Submit may report checked
Pending while its bounded original managed continuation awaits this clearance; finite
Query observes that continuation/result. Returning Pending and consuming its endpoint
reply frees transport credit only, not the continuation, helper reservation or native
lease. All continuations stay with the original scoped custodian/deadline, so owner
offer clearance does not depend on holding a data endpoint credit forever.

## Immutable finite timing and clock custody

The owner uses the original managed parent's existing deadline and trusted local clock:
tool/capability run control, `observation.Control` for Observe, or the original write's
post-write control for AfterWrite. These are local construction inputs, not peer/model
arguments. A retained parent-control reference names that exact original control
alongside its admitted origin. Parent-control provenance is checked before constructing
a FiniteTimingProposal; ChildOrigin alone is not timing authority. All finite LSP
invocations use a positive remaining allowance capped by the existing native finite
allowance ceiling 86,400,000 ms (`remote/wire.gleam`, `remote/service.gleam` at the
source base). Observe additionally uses its existing 75,000 ms ceiling measured from the
owner's original observation admission, including its initial transport/control wait. No
other operation is silently given a new seventy-five-second ceiling that could discard
cold multi-profile search or preparation behavior.

Each executor-scoped native clock has an opaque immutable ClockEra: the concrete host/VM
clock-incarnation identity installed by trusted assembly, distinct even when a reboot
repeats Scope or monotonic numbers. The injected clock supplies local monotonic
milliseconds only. Negative clock values are valid; zero deadline is invalid as in 067.
ClockEra is never a globally comparable time or a peer-selected clock function.

First capture is `Absent → Captured`: CaptureFinite atomically retains the complete
original finite coordinates, exact semantic request bytes/digest, parent-control
reference, native ClockEra, anchor tick E0 and one 32-byte single-use nonce. It charges
the permanent original identity and full reservation before returning a checked anchor.
There is only one anchor for that content-independent original invocation address. Exact
duplicate CaptureFinite returns the same historical anchor; changed
coordinates/request/parent-control reference conflicts. Recovery cannot mint another
anchor or live claim. An unspent anchor uses the existing native short-challenge ceiling
of 1000 ms in that executor clock (`remote/wire.gleam`); an expired anchor is a retained
refusal/fence, never renewed. This is one LSP-specific first-capture step, not a
reusable challenge framework.

After receiving that anchor, the owner samples its original parent clock and computes `R = min(parent_deadline - parent_now, 86,400,000)`. For Observe it also clamps R to
`75,000 - elapsed_since_original_owner_observation_admission`. Nonpositive R refuses
dispatch. FiniteTimingProposal contains `[1, executor_clock_era, nonce, R, parent_control_digest]`; it contains no owner absolute timestamp. The owner retains
those exact bytes before sending the original Submit. A later remaining value, different
nonce/era or different parent-control reference for that same invocation is a conflict,
not a revised deadline.

First timed admission is `Captured → Accepted/Started`: in one transaction, validate the
exact original request, parent reference, nonce/window and current ClockEra; retain
immutable AdmittedFiniteControl `(era, E0, R, deadline = E0 + R, timing_proposal_digest)` before returning the only finite live claim. E0 is the earlier
executor anchor, not the later arrival/clearance time. Refuse if the computed deadline
is zero, expired, outside the selected finite allowance or the clock era differs. Exact
duplicates return original control/history without a claim. SQL uncertainty returns
Unknown and fences fresh authority. The same control is held by the scoped custodian and
each of its original managed continuations, never reconstructed by owner reply arrival.

The anchor reply precedes the owner's R sample by causal message order. Using the
earlier E0 conservatively consumes the control round trip and subsequent
transfer/admission delay, without comparing absolute values from different hosts. The
first finite transfer must finish inside both the anchor window and computed deadline; a
late transfer is refused. This provides authority in the original parent's remaining-duration units and the executor's one local monotonic era, following 067's elapsed-deadline rule. It does not claim synchronized clocks, a global UTC deadline or liveness
during suspended/broken host clocks.

Production clock adapters must supply the same trusted monotonic millisecond duration
semantics; the owner's independent original parent deadline/cancellation remains live.
If that parent control or its original reference is unavailable, refuse new admission
rather than inventing a default. Query/receipt reconcile historical data without
renewing timing.

Pending offer waits, all cold Search commands, finite Probe/Prepare performed for this
invocation, bounded source reads, readiness/semantic requests and every rename landing
consume this same D. Before each finite native authorization, clamp its challenge-derived deadline to D in the original native era, retaining that cap through
association, run-before checks and watchdog. Selected command wall/CPU policy stays
unchanged; if less than the native minimum admission interval remains, refuse rather
than round the budget up. Associate can retain historical clearance after expiry but
cannot use it to launch a finite command or write. Source reads/native starts/writes
check D immediately before their physical action; cancellation drains the original
managed child, with Unknown if an effect may already have crossed that boundary.
AfterWrite does not renew the referenced write's control and uses its separately
admitted finite child only while that original parent grants a post-write interval.

ServerLease has a separate first-captured twelve-hour local deadline under the original
session lease authority. Creating/querying a finite invocation cannot mint or extend it.
Probe/Prepare may use the invocation's remaining finite allowance to establish that
session resource; pending finite cancellation withdraws the original finite work and
cannot renew startup. Once the shared server is validly session-owned, later callers
receive their own finite controls while reusing that existing lease. Restart reads old
timing and outcomes as history only: a new ClockEra cannot subtract old ticks or
reconstruct live authority from an old Accepted/Started row. It fences that continuation
as Unknown and follows original cleanup custody.

## Closed finite request and result vocabulary

```gleam
pub type Request {
  Definition(SymbolQuery)
  References(SymbolQuery)
  Hover(SymbolQuery)
  Outline(AdmittedPath)
  Calls(SymbolQuery, CallDirection)
  Diagnostics(Option(AdmittedPath))
  PrepareRename(SymbolQuery, NewName)
  ApplyRename(SymbolQuery, NewName, ApprovedMutation)
  AfterWrite(AdmittedPath, OriginalWriteRef)
  Observe(ObservationRequest)
}
pub type ResultValue {
  Definitions(Served(List(Site)))
  ReferenceSites(Served(List(Reference)))
  Hovered(Served(Hover))
  Outlined(Served(List(SymbolEntry)))
  Called(Served(List(Call)))
  Diagnosed(Served(Diagnostics))
  RenamePrepared(Served(List(FileEdit)))
  RenameApplied(Served(RenameReport))
  WriteObserved(Option(Diagnostics))
  Observed(Batch)
  QueryFailed(QueryError)
  ObservationFailed(ObservationError)
  LimitExceeded(LimitKind)
}
pub type Disposition {
  Refused(RefusalKind)       // Checked refusal before a first claim/effect.
  Unknown                  // Original claim/effect may have happened.
  Retained(ResultDigest)   // Exact immutable result is separately retrievable.
}
```

Existing query result meanings remain unchanged (`lsp/query.gleam`): one-based codepoint
sites, Started/Warm, Unsupported, withheld locations, Settled/Unsettled and file-by-file
rename landings. Result tags must match the retained request tag; an arbitrary result
union is not an accepted reply. Paths are canonical admitted executor paths with a
checked workspace-relative wire spelling. Returned paths are readmitted before physical
reads or writes. Absolute external paths are accepted only if existing enrolled readable
authority admits them; no owner filesystem resolution occurs.

The endpoint operations are the closed `CaptureFinite`, `Submit`, `Query`, `Cancel`,
`Acknowledge(exact_result_digest)` vocabulary. CaptureFinite retains the original timing
anchor without granting an effect. Submit commits Accepted with the immutable admitted
control, then a single Started claim. Recovery or duplicate Submit never recreates that
claim. Query reads history only.

Cancel fences the finite invocation and cancels its managed query, not the shared server
lease. Timeout after a claim returns Unknown until an exact retained result exists. A
malformed or preclaim rejected request returns definite Refused. This distinction also
applies to a lost ApplyRename reply.

AfterWrite runs after the referenced write's physical landing, on the same manager. It
may return None when no server owns the path. Filesystem completions must retain its
diagnostics with the original write result, so a lost reply does not turn a completed
write into a new write. Observe uses the existing separate observation Door and its
original deadline, not simulated calls through outline alone.

ApplyRename recomputes the server plan once within the original mutation claim. It
checks the entire plan's byte/count reservation before any write, resolves every target
through that invocation's write authority and checks every preimage before beginning. It
then uses the existing `tools/lsp.land` path (`tools/lsp.gleam`) in path order,
including per-file stale checks. It records partial Landed/Rejected/NotAttempted
outcomes and sends AfterWrite for every landed file. It does not accept peer-provided
edited file bodies as write authority, promise atomicity or replay a partially landed
rename after restart. PrepareRename remains a read-only complete preview.

## Local protocol attachment and exact consumption

Choose the opaque executor-local attachment permitted by 067. A network JSON-RPC byte
stream would add a second transport for two processes already on the same executor. The
attachment is a trusted local owner of the existing native input/output association, not
a new authority.

Add an opt-in helper feature `protocol-credit-v1`, selected only by the checked LSP
native plans that require consumption credit. Older helpers refuse this mode before
startup. Ordinary exec_start/exec_out/stdin formats and finite-command admission remain
unchanged. A distinct `ProtocolStart` body contains the existing exact cleared
argv/env/cwd/policy/token fields, with closed mode ServerProtocol or FiniteCollected; it
is accepted only after feature negotiation. The new closed messages are:

* `ProtocolInput(execution_id, ordinal, frame_id, bytes, eof)` with at most 8192 bytes.
  `ProtocolInputAccepted(execution_id, ordinal, frame_id)` is sent only after the
  existing stdinQueue.put accepted the copied bytes/EOF. Existing definite write refusal
  produces `ProtocolInputRefused(execution_id, ordinal, frame_id, closed_reason)`
  instead. Accepted means bounded helper-writer admission, not child read or execution
  success. FiniteCollected admits only its one empty EOF input; ServerProtocol admits
  the bounded ordered writer described below.

* `ProtocolOutput(execution_id, ordinal, stream, bytes, total, truncated)` with the
  existing 32 KiB producer chunk size. A single shared output credit permits one sent
  frame across stdout/stderr. `ProtocolOutputConsumed(execution_id, ordinal)` returns it
  only after the final local consumer admitted the bytes into its bounded state. Two
  pump buffers may exist, one per stream; they wait without holding cancellation/cleanup
  locks. The helper frame loop remains able to receive cancel, EOF and consumption
  replies while a pump waits.

* `ProtocolReusable(original_execution_id)` is a bounded, at-most-128-byte lifecycle
  frame for FiniteCollected only, emitted after that execution's actual waitDone closes.
  It proves helper reuse readiness separately from exec_exit and finite result
  retention. A wrong execution id, an early witness or a witness for ServerProtocol
  cannot release an original borrow or satisfy ServerLease retirement.

The exact input path is local attachment → session-protocol branch of service.feed →
native/broker helper → stdinQueue.put acknowledgement. The branch checks the exact live
key/digest, sealed input, contiguous ordinal and the one pending stable credit. It
retains one pending exact chunk and the most recent acknowledged ordinal/digest, not a
lifetime list of input bodies. Timeout or DOWN after forwarding preserves
DeliveryUncertain, closes input and cancels the original lease; it never retries bytes.
A changed payload at the same ordinal is refused. Completion of an actor send, port
write, service control reply or managed task is not InputAccepted.

The helper must not invoke blocking queue.put inline in its frame loop for the credited
mode. Start one execution-owned admission worker, with a single queued input slot and a
lifetime done signal. Its input state is Idle(next_ordinal), Pending(exact_frame),
Sealed or Failed. Admission to Pending atomically checks the live execution and ordinal
before handing the frame to that worker. A second frame while queue.put is outstanding
is refused without another worker or waiter.

The worker waits in the existing queue.put, commits the Accepted/Refused disposition
under the input-state gate, relinquishes the copied input body and publishes the
original ACK. Accepted can be followed by a later child-pipe failure; it promises queue
admission only. Native service credit permits the next input only after consuming that
exact ACK. One early queued successor can overlap the preceding ACK's final transport
flush, but there is never a second admission worker or outstanding queue.put. Timeout
never installs another worker.

For credited mode, the existing mutex-serialized connection writer runs behind a
specific bounded writer: one data frame, one general control slot and one reserved
lifecycle control slot. An input ACK or Reusable is at most 128 encoded bytes; terminal
retains its existing 32 KiB ceiling. The lifecycle slot carries terminal/shutdown first,
then FiniteCollected's Reusable after terminal flush and actual waitDone. These frames
never coexist in another pending list. The writer completion event clears that slot; it
needs no polling or delay.

There is no output history. Frame reading and cancellation do not execute a blocking
Conn.Write. ACK/error/heartbeat admission to an occupied general slot fails
nonblockingly and fences the credited execution/connection; it cannot wait for room,
grow a waiter list, overwrite an ACK or take the reserved lifecycle slot. An occupied
lifecycle slot at its required next transition likewise fences rather than queues
another frame. The frame reader can still seal/cancel while a previously admitted write
is blocked.

The original ACK must flush or become a retained transport failure; putting it in this
writer alone is not native service InputAccepted. A blocked transport may prevent the
final lifecycle witness; it cannot manufacture one.

On cancel, shutdown, malformed traffic, owner disconnect or process exit, seal protocol
admission before asking the existing process-group cancellation to run. When the child
exits, abandon stdin to release both a blocked queue.put and the existing pipe writer;
stop and join the admission worker and pipe writer before publishing exec_exit. On
normal EOF, the admission worker stops after its final admitted item, while the existing
pipe writer drains and closes. All original ACK dispositions precede the terminal's
flush through the serialized writer. The frame-reading goroutine does not wait for queue
room or these joins.

If transport failure prevents a join/terminal flush, cleanup stays uncertain; no timeout
manufactures a successful witness. `server.reapRunning` continues to join waitDone on
every Run return (`server.go`). Helper shutdown additionally joins its bounded writer
before native exit. A blocked native pipe still permits local cancellation; if the pipe
cannot be drained, the existing force/retirement path reports uncertainty rather than a
successful exit witness.

The output state is Available(next_ordinal), Offered(exact_frame), Draining or Failed.
Under one execution-local gate, a pump acquires Available, records its
stream/ordinal/cumulative count and then writes that frame. Only a matching Consumed for
Offered returns Available; duplicate old acknowledgements are ignored, future/mismatched
acknowledgements fail the protocol, and a late acknowledgement after Failed cannot
reopen it. Each pump has its existing 32 KiB read buffer; at most one copied sent chunk
and one blocked other-stream chunk exist. The helper does not accumulate an output list.
The broker's original helper actor and native execution row check execution id before
forwarding or acknowledging, retaining their existing single-sender ordering.

Seal/abort closes the output gate before output-pump joins, waking every pump waiting
for credit. An unconsumed frame becomes a protocol-failure witness, not a consumed
prefix. Child-exit drain retains the existing 500 ms output-drain grace (`jail/run.go`);
at grace expiry it closes read ends and fails the gate as well, so a blocked sink cannot
defeat the existing pump join. execFreed is published only after all these joins;
exec_exit then carries the original native verdict plus checked protocol-disposition
metadata. Terminal must flush before release/cgroup cleanup and joining prior-execution
waitDone complete; current waitDone then closes. FiniteCollected publishes Reusable only
after observing that actual close, using the now-free same lifecycle writer slot. Forced
loss of any signal leaves the corresponding witness unconfirmed.

For FiniteCollected, the broker/native adapter has a closed
Finishing(original_execution_id, terminal) phase after terminal, not ordinary Idle. It
keeps the original helper borrow unavailable to checkin/reuse until it consumes and
validates matching ProtocolReusable. Consumption records a separate reusable disposition
against the retained original native/command association and then permits existing
finite checkin; neither finite result completion nor an owner receipt does so. A
deferred exact checkin belongs to that one original finishing state, with no spare-helper queue, timer or waiter list. Terminal and reuse witnesses are independent.

Missing/wrong Reusable leaves reuse uncertain and the original borrow charged;
cancellation/close still attempts exact original helper cleanup. An old matching witness
after fencing cannot reopen authority. ServerProtocol never uses this finite finishing-to-Idle transition: ServerLease always selects exact helper retirement. Ordinary exec
formats retain today's execFreed/terminal reuse behavior. Credited ProtocolStart also
checks actual waitDone, but the consumed Reusable gate prevents a normal sequential
caller from reaching that defensive check too early.

The existing finite-command feed limits (128 frames/1 MiB) remain unchanged. The new
session branch has a finite 64 MiB cumulative stdin allowance and at most 8192 frames,
including EOF. Its live pending chunk is at most 8 KiB. Exhaustion seals input and
cancels the lease through separate control capacity. This explicit extension is
necessary: the current one-MiB lifetime cap cannot even synchronize the accepted four-MiB observation input. No ordinal wrap, renewal or completed-frame eviction can renew
cumulative allowance.

Add a specific local `ConsumedChannelTransport` alongside existing ChannelTransport.
Client send acknowledges admission to one fixed writer window, with at most 16 MiB plus
an 8192-byte LSP header and 128 queued logical messages. Bytes and count are reserved
before enqueueing; its pump splits frames into ordered 8 KiB feed chunks and owns the
single input credit. Client send must not wait for output processing by that client
actor. Full windows fail the protocol and cancel the lease, without dropping a prefix.
The helper's existing 16 MiB stdin queue remains the final physical writer bound. The 64
MiB lifetime allowance also bounds total chunk-node creation.

For stdout, the LSP client acknowledges a chunk only after framing, total JSON decoding
and bounded-state updates complete. A process.send to TransportData is insufficient. For
stderr, admission to the existing 8 KiB ring acknowledges consumption. A truncated
stdout frame fails the client and cancels the original lease. Stderr remains a bounded
diagnostic ring.

A thirty-second pending-credit deadline, matching existing native publisher wait
(`remote/service.gleam`), fails and fences the attachment; it does not grant native
retirement. Helper cancellation and port exit join remain independent of these credits.
Lost credit never becomes another output permission.

Protocol stdout/stderr do not enter ordinary `payload.Output` slots. The exact
ServerLease admission, immutable request/authorization, terminal and retirement evidence
remain in the native journal with existing bounds. The protocol sink is a closed
trusted-local mode installed only after exact lease validation. It persists a bounded
terminal/protocol-failure witness, not the JSON-RPC transcript. The 64 MiB-per-stream
native producer caps remain intact even with consumption credit. No indefinitely growing
stdout journal is created.

## Same-slot startup, replacement and close

The slot transition is `Reserved → Offered → OwnerAssociated → Starting → Serving → Closing → Retired`, with an absorbing `Uncertain` fence for unresolved startup,
association or cleanup. First startup permission commits before launch. A lost owner-clearance or launch reply cannot create another permission. A fresh server incarnation
is allowed only after exact native retirement of the previous incarnation and all
original managed continuations have drained. It consumes a new permanent
identity/reservation.

The existing exact-retirement contract for validated Launch does not itself authorize
this LSP mode. Add an internal opaque `ServerLeaseClaim`, constructed only by the first
committed ServerLease transition with the checked owner-returned native association.
`start_lsp_server(claim, checked_plan, local_protocol_sink)` selects the existing fresh-helper preparation/retirement machinery. It has no peer-facing role selector or helper
PID argument. Raw native, Compile and Probe retain their existing helper reuse
disposition.

Search and Prepare remain reusable finite commands, with credited reuse gated by their
exact ProtocolReusable witness. The ServerLease branch alone selects mandatory
retirement of its exact helper on release, abandonment or close. A ProtocolReusable,
finite terminal or consumed protocol reply cannot take that branch or discharge its
retirement obligation.

Retain `(LspCommandRef, native key/digest, executor incarnation/sequence, original helper custody entry)` before physical startup. The original native row never returns
that helper through ordinary idle checkin. Its settlement/abandonment requests
retirement of the original entry and keeps an independently queryable disposition.
Original native exit status zero, then ForgetRetired followed by the original normal
BEAM monitor event, establish the pool's existing two retirement boundaries
(`broker/exec.gleam`). A pool census or missing entry alone is not evidence.

A lost preparation/start response holds the claimed entry and reservation;
missing/conflicting retained association is a definite refusal after metadata work
drains. A lost native/monitor witness leaves Uncertain. Actual Retired disposition
commits against that exact command before the slot pointer can advance. Owner receipt
and finite query completion cannot advance it. This reuses the scoped pool owner rather
than closing the whole pool for every LSP restart.

Finite caller cancellation withdraws only that caller's outstanding protocol request; it
does not cancel a server shared by other callers. Session owner death, registration
fence, scope epoch change, session close, manager loss or authenticated distribution
disconnect closes attachment input and starts cancellation of the original session
lease. A partition does not keep an apparently detached server useful indefinitely.
Reconnection reconciles retained evidence; it cannot attach to a stale fenced row or
remint the lease. The original twelve-hour deadline continues independently of queries
and reconnects.

Restart recovery can report retained outcomes and retirement history. It cannot recover
a live opaque attachment or claim a new native server from old Starting/Serving
metadata. Recovery fences those rows, attempts cleanup only through retained exact
original association, and remains Uncertain if that custodian/witness is unavailable.
Manager previous_ms expiry, helper relay/client DOWN, endpoint AllDelivered and owner
receipt are separate facts. None replaces original helper retirement. Three reserved
helper slots remain unavailable to LSP, and an uncertain LSP lease continues to charge
its slot until native retirement is proved.

Shutdown ordering is: fence registration and slot input; cancel/drain semantic managed
children; close consumed transport; attempt EOF/grace then exact abort; observe original
native terminal and original helper retirement; drain endpoint assignments; retain
result/retirement witnesses and owner receipts; close manager/journals last. Every phase
attempts original native cleanup even if an earlier journal fence fails. Cleanup
outcomes must be retained separately: input fence, semantic-child drain, terminal,
native retirement, endpoint drain and exact owner result receipt. A single `Closed` Bool
cannot express them.

## Canonical codecs and budgets

The following constants are production admission rules. Existing observation and native
producer limits are retained. Display caps such as code mode's 200 items/64 KiB hover
(`codemode/lsp.gleam`) are not complete semantic-result limits.

The closed semantic body is positional MessagePack with canonical UTF-8 strings, nil
optionals and checked signed integer ranges. Outline is encoded flat in preorder with
parent indices; decoding checks acyclic backward parents and depth at most 256 before
constructing SymbolEntry. Request/result tags and ordering are fixed and canonical re-encoding must equal the received bytes. Existing native bounded_msgpack stays unchanged;
a separate LSP preflight profile uses the existing raw scanner before term decoding.

| Boundary | Ceiling and accounting |
| --- | --- |
| Semantic request body | 131,072 bytes; depth 8; 1024 total nodes; Observe retains the existing 16/32 scope counts. Configured labels at most 128 bytes, path/root spellings at most 8192 bytes. Positive positions and complete SymbolQuery optional combinations are checked. |
| Cold resolver inventory | At most 16 enrolled profiles, 3200 hits/800 profile-local file slots, sequential raw collectors. Hit projection at most 26,316,800 bytes, checked grouping at most 53,043,200 bytes, one raw collector at most 8,388,608 bytes; all are charged independently. |
| Complete finite semantic result | 10,000 rows and 4,194,304 accounted bytes across all strings, source/preimage/edited texts and conservative row overhead. Interactive overflow is LimitExceeded, not a silent truncated list. Rename reserves base plus edited bodies and all reports before writing. Hover's complete wire payload participates in this budget. |
| Observation | Existing 10,000 facts/4 MiB accounting and 128 semantic requests/75 seconds. Exact fact payload includes existing +128 document, +64 symbol/target and +32 reference overhead, plus +64 Site accounting. Row tuples are bounded below those conservative charges; source text is charged even though the returned Document contains its digest rather than that text. No partial batch is published. |
| Result body preflight | At most 200,000 total nodes, depth 16 for flat wire rows, arrays at most 10,000 entries, total UTF-8/binary allocation constrained by the byte ceiling. Integer fields use at most nine encoded bytes. Semantic depth of reconstructed outlines remains at most 256. |
| Live local LSP JSON | Existing 16,777,216-byte JSON-RPC body and 8192-byte header caps (`lsp/framing.gleam`). Add a registered bounded parse profile: 200,000 aggregate nodes and depth at most existing JSON maximum 256. Retained document texts at most 4 MiB combined; retained diagnostic strings/sites at most 4 MiB combined; other retained runtime metadata/progress strings at most 4 MiB combined. Preserve existing 64 documents, 512 URIs, 200 diagnostics/URI and 64 progress tokens, and admit at most 128 outstanding protocol requests. Overflow fails the protocol rather than publishing clean diagnostics. |
| Native process resources | Exact enrolled memory/pids/fsize policy, no wider than existing workspace defaults 2 GiB/512/1 GiB per file; three-helper reservation. Server lease stays network off with 64 MiB producer output per stream and its original twelve-hour deadline. Probe/Search have positive CPU copied from the session base and ten-second deadlines; Prepare retains its approved sixty-second CPU/wall and network profile. Session CPU is lifetime-owned, as existing policy specifies, rather than charged to each query. |
| Semantic concurrency/deadline | One semantic managed child per scoped LSP service, no detached queue/fanout. The four data/two control endpoint credits remain node-wide; managed registration capacity follows protocol 079's sixteen live/unretired slots. Original invocation deadline is checked before every physical step and clamps Observe to 75 seconds. Defaults retain start 60 s, request 5 s, settle 1.5 s, readiness 60 s and quiet 300 ms (`manager.gleam`). |
| Journal reservations | Maximum 4096 permanent LSP identities and 256 MiB total logical retained/reserved content per scoped store, reduced by configured existing shared custody limits. Input plus full result capacity reserves before effects. Tombstones remain charged. Native Request/Authority/Terminal remain 128 KiB/1 KiB/32 KiB. No protocol stdout payload is reserved on disk. |

The observation body is bounded by `4,194,304 + 131,072 + (16 * 8192) + 8192 + 256 = 4,464,896` bytes. The first term covers the existing fact budget; the echoed canonical
Request occupies at most 131,072 bytes; the extra sixteen canonical outlined paths are
at most 131,072 bytes; root spelling occupies at most 8192. The outlined list is an
additional occurrence of those paths and must not be mistaken for their Document/Site
fact accounting. The final 256 covers fixed outer tuple/list tags, counts, timestamps,
generation spelling and their MessagePack headers. Document digests and every row's
string/tag/integer headers fit the existing per-row conservative charges. The outlined-path occurrence is charged independently of fact rows.

Use an envelope of `uint32 header_length || canonical_identity_header || canonical_body`. Header is nonempty and at most 8192 bytes, checked before identity
decoding. Therefore maximum semantic content is `4 + 8192 + 4,464,896 = 4,473,092`
bytes. Reuse workspace_transfer's bounded header/chunk mechanism with new closed
LspInvocation and LspResult directions and their exact ceilings, not its 32 MiB
workspace ceiling. The invocation ceiling is `4 + 8192 + 131,072 = 139,268` bytes.

The current transfer header is 41 bytes; each 64-KiB chunk has nine bytes of framing.
Maximum result uses 69 chunks and adds `41 + 69*9 = 662` bytes, for at most 4,473,754
transfer bytes. Maximum invocation uses three chunks and adds 68 bytes. The BEAM binding
route header remains separately at most 1024 bytes; authenticated distribution
transport/VM overhead is not semantic content. The receiver rejects declared oversize
before retaining chunks.

One frame per direction remains pending until actual consumption. Exact bytes commit on
the owner before its result ACK.

These are logical allocation/content and native policy bounds, not claims that BEAM
resident memory or SQLite pages equal the encoded count. A transfer can temporarily
retain chunks plus joined binary, at most twice its content ceiling; decoded values and
client state add their own bounded inventories. Native memory is bounded by the admitted
kernel policy and admitted server count. Existing storage has no aggregate filesystem-byte quota for LSP caches or workspace writes; the explicit owner acceptance below
addresses this inherited boundary.

### Closed positional shapes and boundary proof

The identity header is `[1, kind, scope, origin, op_uuid, step, request_uuid, input_digest, enrollment_digest, contract_digest, timing_or_nil, parent_control_ref_or_nil]`. Kind is Lease or Invocation; scope is the existing complete
five-coordinate Scope representation. Origin is the validated closed System/Admitted
origin encoding, never an arbitrary string interpreted as a role. Digests are exactly
32-byte binaries. Lease requires nil timing/control reference.

Preliminary CaptureFinite coordinates require nil timing and the checked original
parent-control reference. A timed Invocation requires that unchanged reference and the
exact positional proposal `[1, executor_clock_era, nonce, remaining_ms, parent_control_digest]`: era is a canonical 36-byte UUID installed by trusted executor
assembly, nonce/digest are 32-byte binaries, and remaining_ms is a checked positive
signed integer at most 86,400,000. Including tags/string/binary/integer headers, timing
adds at most 128 encoded bytes. InputDigest remains the exact semantic Request-body
digest so CaptureFinite can name it before timing is returned; the admission record
separately commits the TimingProposal digest and compares both. No cyclic identity
hashing or changed timing under an unchanged address is permitted.

CommandRef is `[1, parent]` with exactly two parent shapes: Startup is `[0, lease_header, startup_role]`, where role is Probe/Prepare/ServerLease; Search is `[1, timed_invocation_header, enrolled_profile_ordinal, canonical_search_root]`. Ordinal must
name the immutable enrollment and checked manager selection; root must equal that
derived root. A Search has no role selector or lease header. The whole CommandRef,
including its root and parent header, must fit 8192 bytes; an individually legal long
root is not permission to exceed this aggregate header cap. CaptureFinite's body is the
unchanged semantic Request, at most 131,072 bytes.

OriginalParentControlRef in the header is `[0, original_admitted_child_ref]` for a
tool/observation or `[1, original_write_ref, admitted_post_write_child_ref]` for
AfterWrite, using the existing checked original identity encodings; its own complete
encoded ceiling is 1024 bytes. It contains no executable clock or callback. Its
canonical digest binds the existing owner's original control provenance. A capture reply
is `[1, executor_clock_era, nonce, parent_control_digest]`, at most 128 encoded bytes;
E0 never needs to cross the wire. Cancel/receipt/control replies retain the checked
original identity and closed fixed dispositions.

All header bytes, including timing, parent-control reference and complete CommandRef
parent forms, count toward the existing 8192-byte envelope header ceiling. Header
preflight permits depth 8 and at most 1024 nodes; semantic construction checks exact
arity, canonical equality and discriminants.

The at-most-128-byte timing addition and at-most-1024-byte original control reference
are inside the fixed header reservation, not outside the envelope. Thus the maximum
result body, content envelope and transfer totals remain 4,464,896, 4,473,092 and
4,473,754 bytes respectively; CaptureFinite and timed Submit keep the unchanged
131,072-byte semantic Request ceiling and 139,268-byte envelope ceiling. The admitted
control's E0/deadline/ClockEra are executor-local custody fields. The owner's local
absolute deadline is not a wire field, and historical executor ticks never become a
reconstructed live control at another era.

Request is `[tag, ...fields]`, with tags 0–9 in the Request order above. `SymbolQuery = [symbol, path_or_nil, line_or_nil]`, and `ObservationRequest = [server, root, outline_paths, targets]`. Optional path/line combinations, positive one-based positions
and exact request/result compatibility are total semantic checks. The approval/write-reference fields are checked original identity references, not booleans or arbitrary
capability strings.

Result is `[1, result_tag, result_payload]`. Served wraps `[warmth, value]`, with Warm
`[0]` or Started `[1, configured_server]`. Each row uses these fixed shapes:
`Site=[path,line,column,text]`; `Document=[path,digest,version_or_nil]`;
`ObservationSymbol=[id,parent_or_nil,name,kind,detail_or_nil,site]`;
`Target=[id,asked,site]`; `RawReference=[target_id,site]`. Batch is `[requested,root,generation,started_ms,finished_ms,outlined,documents,symbols,targets,references,[requests,withheld,facts,fact_bytes]]`. Generation and document digest spellings are exactly the
existing 71-byte SHA256 content-address spelling. IDs are nonnegative, unique and refer
to existing rows; parents precede children and target ids match original request
indices.

Interactive rows are `Reference=[site,container_or_nil]`, `Hover=[site,contents]`, flat
`SymbolEntry=[parent_or_nil,name,kind,detail_or_nil,site]`, `Call=[name,site,at_sites]`,
`Diagnostic=[site,severity,message]`, `FileEdit=[path,base,edited,edit_count]` and
tagged Landing arrays `[0,path,edits]`, `[1,path,reason]` or `[2,path]`. Diagnostics is
`[0,rows]` for Settled or `[1,rows]` for Unsettled; AfterWrite is nil or that exact
Diagnostics. RenameReport is `[landings,diagnostics]`. All nested
site/at/diagnostic/landing rows count toward the one 10,000-row result budget.
Query/observation errors have closed tags in existing source-variant order; bounded
strings and candidate rows use the same result accounting. Unknown data never becomes
QueryFailed or an empty successful result.

For Batch, worst non-string row overhead including a 71-byte digest is at most 88 bytes
per Document, 63 per ObservationSymbol, 59 per Target and 39 per RawReference, using
five-byte string headers and nine-byte integers. These fit the existing respective
conservative charges 128, 128 (symbol plus Site), 128 (target plus Site) and 96
(reference plus Site). The top-level non-fact overhead is at most 152 bytes: outer tags,
root string header, 71-byte generation and its header, timestamps, six collection/count-array headers and four count integers. Reserving 256 covers it. At most 12 raw
MessagePack nodes occur in any fact row, plus at most 256 fixed/request/list nodes;
`12*10,000 + 256 < 200,000`. UTF-8 byte sizes, not graphemes or JSON escaped lengths,
govern these calculations. Flat rows keep the wire well below depth 16.

The codec vectors must pin: exact max-length canonical outlined paths distinct from
short input spellings; a full fact budget plus that echoed/canonical-path overhead; one
oversized declared envelope; header length 8192 versus 8193 with timing included; both
complete CommandRef parent forms and rejected crossed role/parent forms; exact
CaptureFinite/TimingProposal arity and changed timing under the same original address;
69 exact-offset result chunks and wrong final offset/digest; 10,000 versus 10,001 nested
rows; backward versus forward/cyclic parent ids; and a string/node bomb refused by raw
preflight before MessagePack terms are allocated. These are bounded codec tests, not an
E2E proof from arithmetic alone.

## Storage, service allocations and compatibility

Add named SQL in each owning package, with generated schema/query modules through the
existing generation path. Do not use ad-hoc SQL or alter the frozen session store. Use
one new LSP custody database at the owner and one at the executor, both under the
retained binding's existing approved custody directory. Their leases and finite-result
tables share one immutable reservation ledger. The minimum owner lease table is
`lsp_lease(address PK, slot, identity BLOB, input BLOB, command_ref BLOB UNIQUE, offer BLOB, offer_digest, native_key BLOB, native_digest, state, reserved_bytes)`.

Slot may have only one unretired row; retain an indexed current-slot pointer in the same
transaction rather than a timeless UNIQUE slot that would prohibit witnessed
replacement. State is the closed slot vocabulary above. NULL offer/association is
permitted only in the preceding typed state; total readback checks state/fields
together.

Executor LSP lease rows retain the same complete service identity, original
input/offer/native association, state and independent cleanup witness fields. Finite
semantic rows are separate: `lsp_finite(request_id PK, original_identity BLOB, request_digest, request BLOB, parent_control_ref BLOB, parent_control_digest, clock_era, anchor_tick, nonce BLOB, timing_proposal BLOB, timing_digest, remaining_ms, deadline_tick, phase, result BLOB, result_digest, receipt, reserved_bytes)`. Captured is
the new preclaim phase; Accepted/Started/Unknown/Finished/Acknowledged/Cancelled retain
the existing workspace-journal single-claim discipline. Captured requires
era/anchor/nonce and forbids a live claim; Accepted/Started additionally require
unchanged timing bytes, remaining/deadline and the matching original native clock era.
Total readback checks this pairing.

Expired/fenced capture retains its original identity and cannot be overwritten with a
new nonce. Owner finite custody retains the same request, original parent reference and
exact received anchor/proposal bytes, but uses only its own original live parent
control; executor clock values are not interpreted as owner deadlines. One
transaction/readback is required before either side returns its respective
authority/result receipt.

Add `lsp_command(command_address PK, parent_kind, parent_address, parent BLOB, startup_role, search_profile_ordinal, search_root, offer BLOB, offer_digest, native_identity BLOB, native_prepared BLOB, terminal BLOB, reusable_witness BLOB, projected_result BLOB, phase, reserved_bytes)` for physical startup/search associations.
Startup requires an exact lease parent and one of three startup roles, with nil search
fields. Search requires the exact finite parent, checked ordinal/root and nil
startup_role; no fabricated lease address is stored. FiniteCollected's terminal and
matching reusable witness are independent fields: Finishing permits terminal without
reusable; reusable completion requires both and never denotes Retired. ServerLease
forbids that reuse transition and retains its exact native retirement fields through the
lease row.

Every command consumes the same permanent identity/byte budget; queries cannot create an
uncounted command family. Named SQL operations capture once, admit timed control once,
retain original offer/association, retain terminal, retain matching reusable, fence,
retain result and record exact receipt; none refreshes nonce/deadline or remints a
claim. Owner finite-child custody retains a bounded checked LspResultRef to this store
rather than duplicating the full result in another new blob inventory. Commit the exact
LSP result first, then retain the checked reference under the original admitted child;
only readback of both permits the network receipt. A crash between commits leaves
unacknowledged retained bytes.

Lease rows have no ToolKey parent and require new named owner operations. Payload
deletion follows exact receipt only; permanent identity/timing/uncertainty/native
cleanup fences remain. The slot pointer cannot advance on receipt alone.

The named store profile uses SQLite's existing engine through sqlight, with 4096-byte
pages, `max_page_count=131072` (512 MiB per database), rollback `journal_mode=DELETE`,
`temp_store=MEMORY` and no ATTACH/VACUUM or external long-lived reader transaction. Read
back these settings before opening admission. This is an explicit new LSP store profile;
existing owner/native/workspace stores are unchanged. The configured logical reservation
ceiling is at most 256 MiB and includes all body/header/association bytes and index-key
duplication. Reserve input, full eventual completion, offer/native association and
bounded tombstone capacity before effects; SQLite allocation/commit refusal never
returns a claim. Result write failure after an effect remains Unknown. Named mutations
touch only the original finite row, command row or slot/lease association; exact
duplicates inspect and write nothing.

Database physical allocation is capped by max_page_count. DELETE journaling prevents a
held reader from indefinitely extending a WAL. A rollback journal contains preimages of
at most the capped page inventory per transaction, plus the engine's bounded
record/sector-header overhead, and is removed before the next mutation. Thus the new
service has a bounded database and one bounded rollback file, rather than claiming that
logical content equals on-disk bytes. The storage profile test must pin the linked
SQLite rollback-format overhead and built-in VFS assumptions; custom VFS/extensions or a
failed setting readback are unsupported. Native journal input/terminal retention
continues through its existing bounded store and is not mirrored as a new raw-output
archive. No periodic compaction, unbounded append file or protocol transcript is
introduced.

Service-owned protocol/input memory is bounded by the declared writer window, single
pending feed, actual 16 MiB stdin queue, two 32 KiB producer buffers, one sent output
frame, two helper control slots, client text/node inventories and finite collectors.
Nothing spools those streams to disk. All source reads use an admitted bounded UTF-8
read, requesting at most the remaining text reservation plus one detection byte; stat-before/read-all/postcheck alone is insufficient against a growing file. The observation
still charges all retained source texts to its four-MiB budget. Dependency metadata
retains its existing 128 KiB/file, 64-package graph and three-level inventory bounds
(`dependency_state.gleam`); the Registered read path must enforce the byte limit during
the read. Metadata is folded one file at a time into retained digests, not copied into
another preparation corpus.

Preparation adds only bounded path/offer/terminal metadata and directory creation at the
existing deterministic scratch/cache spellings. There is no per-query checkout, copied
toolchain, renamed workspace snapshot or new artifact tree. Directory paths and counts
come from the finite enrolled profile, checked against the 128 KiB command-input and
path bounds before mkdir. Repeated starts use the same checked directory spellings, not
an unbounded sequence of UUID directories. The server/preparation's actual build
packages and cache contents are the existing executor-owned writes described below, not
uncounted service journals.

Each cold startup admits at most one Probe, one configured Prepare and one ServerLease;
restarts consume a new charged incarnation. A cold finite invocation admits at most
sixteen sequential Search commands, one per configured profile; a warm invocation
searches its one selected profile. All use that original invocation's timing control and
charged aggregate projection. Observe retains its 128 semantic-request bound. All
effects still belong to original retained offers.

Every table has immutable schema/profile version and limits metadata, checked before
reading bounded bodies; conflicting version refuses recovery. The canonical LSP contract
digest distinguishes it from Compile/Launch and from future vocabularies. Add closed
endpoint LSP service registration and route tags; old routes retain exact bytes. An
unsupported route/version/helper feature is a pre-effect refusal, with no fallback to
local execution or older unacknowledged streaming. A fresh scoped LSP database is
required for this initial schema; no automatic migration of unknown live leases is
claimed.

Default Registered assembly must supply the retained SessionEnrollment/Scope/contract
digest, owner offer-clearing and finite-child custody doors, exact native
service/journal, shared helper pool/retirement owner, concrete executor workspace/write
authority, configured LSP placements and the real manager Jailed backend. It installs
the returned owner-side `query.Door`, `codemode/lsp.Seam.rename`, observation Door and
post-write observer into ordinary tools/code mode. It supplies no owner checkout path.
Registration is published only after all scoped service owners and cleanup custody
exist.

## Executable acceptance shapes

1. Boot the shipped daemon and shipped full executor with a Registered workspace whose
   path is absent on owner disk. Ordinary
   def/references/hover/outline/calls/diagnostics, code-mode LSP, finite observations
   and fs AfterWrite use a real configured language server and return checked results.
   In a cold workspace with two configured profiles, find a bare symbol present only in
   the second profile, then exercise symbols in distinct projects and preserve the
   existing Ambiguous result. Both sequential searches have separate retained original
   associations before any real lease is selected; replay launches neither again. Reject
   a seventeenth configured profile at enrollment before effects. No owner
   Git/toolchain/guidance/source probe is required.

2. Lose the owner-clearance/start reply after the original effect. Repeat exact startup
   and race another query: one original native server exists, no new command identity or
   slot is created, and changed argv/role/root/digest is definitely refused. Cross
   Startup/Search parent forms or alter the checked cold profile/root: identity
   construction refuses before an offer. Charge the complete multi-profile hit/grouping
   projections and test limit exhaustion without reporting a truncated search as
   complete.

3. Exercise a source/result at the fact boundary, including long UTF-8 text and 10,000
   rows. The valid fact budget plus enclosing headers transfers intact; one
   byte/node/count beyond any actual boundary refuses before a result or mutation is
   advertised. Four-MiB facts are not rejected merely because their enclosing envelope
   is larger. Grow a source during a bounded read; fill the LSP reservation/page budget;
   reject mismatched SQLite store settings before admission; prove repeated
   Query/duplicate Submit adds no append archive or renewed allocation.

4. Block the LSP stdin consumer and withhold one helper acknowledgement. The local
   writer/queue bounds hold; cancellation still reaches original cleanup; caller timeout
   leaves Unknown and a closed pending credit. Actor-send or port-send success cannot
   release that credit or replay its bytes. Fill the general ACK/error/heartbeat slot
   and prove nonblocking fencing without frame-reader blockage or a waiter list. For
   FiniteCollected, hold release/cgroup cleanup after terminal flush and request the
   next sequential finite command: the original helper stays unavailable, with no
   premature checkin or busy-refusal race. Release the hold and consume matching post-waitDone Reusable; only then may normal finite reuse proceed. A missing, wrong-id or
   late-after-fence witness cannot release the borrow; ServerLease cannot substitute it
   for exact retirement. Ordinary helper-format fixtures retain their current behavior.

5. Withhold stdout consumption while producing legal protocol output, then cross the
   producer cap or send malformed/oversized JSON. At most one output frame plus bounded
   pump/client/writer state exists, no durable stdout growth occurs, and no retained
   prefix becomes a successful reply. Stderr retains only its ring.

6. Preview then apply a real multi-file rename with approved mutation authority. A
   changed preimage rejects all prechecks before writes; a later per-file failure
   reports partial landings exactly. Lose the apply reply/restart after a write:
   reconciliation returns retained/Unknown evidence and never reruns rename. AfterWrite
   preserves Unsettled rather than reporting clean code.

7. Cancel one finite query while another later query uses the same healthy lease. Hold
   valid original owner clearance beyond that finite invocation's retained deadline,
   then deliver it: no finite native effect, source read or rename write begins and no
   new seventy-five-second interval appears. Exact duplicate
   CaptureFinite/Submit/Associate retains the same nonce/control/deadline; changed
   timing under the same original address conflicts. Expire the unspent capture window
   and prove it cannot be renewed. Then partition, change epoch, kill manager or close
   session with a lost native-retirement reply. Input fences and native cleanup is
   attempted, but same-slot restart and helper-slot reuse remain blocked until
   independent original retirement is proved. Three helper reservations remain available
   to other work.

8. Refuse old endpoint versions and helpers without protocol-credit-v1 before startup.
   Exercise recovery with mismatched schema/profile/association; run owner and executor
   clocks with distinct numeric origins, including valid negative executor ticks, and
   show only causally captured remaining duration is admitted. Change executor ClockEra
   across restart and prove historical capture/Started rows cannot reconstruct live
   authority even if monotonic numbers repeat. Query historical result and exact receipt
   after fencing; prove neither result receipt, ProtocolReusable nor endpoint
   AllDelivered substitutes for ServerLease native retirement.

## Filesystem boundary

The approved executor checkout/cache policy remains in force. Existing policy bounds
memory, pids and individual-file size but provides no aggregate byte quota across
writable workspace/cache/scratch roots. Warm caches, the approved dependency downloader
and configured server project/cache writes remain available on the executor. These files
do not become owner files or LSP protocol/preparation copies. A twelve-hour deadline and
a one-GiB fsize limit do not prove aggregate disk usage.

Every new custody, protocol, input and preparation inventory is bounded by this
contract. An aggregate cache/workspace disk-space guarantee is outside this phase. Such
a guarantee would require a separate provisioning contract covering a finite filesystem
volume and every admitted writable root; neither a logical workspace label nor a post-write size check establishes that guarantee.

## Compatibility, generation links and costs

The new helper frame kinds require the protocol-version bump on both sides mandated by
protocol 006. The envelope remains unchanged unless its shape changes. Feature
negotiation must refuse a helper lacking `protocol-credit-v1` before startup; ordinary
exec formats and their finite admission behavior remain unchanged. Ordinary finite
native admission retains positive CPU, at most 256 KiB output, 128 input frames/1 MiB,
and at most 64 durable output records/1 MiB. The credited LSP protocol path does not
widen those ordinary profiles or store its transcript in that native output inventory.

Protocol 079's exact generation_key/enrollment_digest fields commit atomically with the
first original lease, finite invocation and command reservations in each LSP custody
database. Commands compare their actual lease/invocation parent's generation; admitted
child references compare the companion's complete ChildOrigin link. Result references
include generation. Exact LSP result COMMIT/readback then original child/reference
COMMIT/readback still precede ACK. Historical lookup never selects the latest generation
or reconstructs live timing, attachments or effects.

The timing capture costs one round trip and one Captured record before effects. Credited
transport adds one input admission worker and a bounded connection writer; finite reuse
waits for its consumed post-waitDone witness. ServerLease release retires its exact helper through the existing
`exec.prepare_borrowed_retirement`, `exec.retire_borrowed`,
`executor.start_with_retirement` and
`executor.dispatcher_retiring_with_native_deadline` APIs. The validated LSP caller is
additional; raw native and Compile callers retain their existing behavior. Each replacement charges a new permanent identity, and uncertain custody remains
charged. The service adds one bounded LSP database per end; it does not add a protocol
transcript or raw-output archive.

A network JSON-RPC stream was considered. The opaque consumed local attachment keeps the
two cooperating executor processes local and avoids another network transport.
Fabricated ToolKeys, query-owned server timing, renewable captures and receipt-based
retirement cannot express the approved authority and custody rules. No generic timing
service, automatic failover, workspace migration, quota poller, new dependency or FFI is
introduced.

### Original native attachment implementation mechanics

The executor-local native foundation uses `lsp_journal.reserve_lease_live` to
separate original first reservation from retained lease history. Its opaque
`LeaseStartupClaim` retains the original Store and trusted clock era internally;
`reserve_lease` preserves its prior readback projection. The existing original
offer CAS returns FreshPlacement only after COMMIT/readback. RetainedPlacement
cannot install another Service-owned pending context, including after a lost
first installation reply or across competing actual Service actors.

A checked plan freezes the actual descriptor, registration, full generation
binding and enrollment, declared profile, placement, original policy and trusted
environment. It grants no Broker clearance. The original native Service consumes
one pending installation before Request/Authority/Admit and exact command
association. Coverage begins before the first possibly committed Request write.
One real consumed sink precedes Begin and first native AuthorizeLaunch. The
existing credited retiring dispatcher and weft managed custodian preserve the
original helper borrow and independent exact pool observer. A closed output join
retains actual consumer success plus AllDelivered until the original native
handle arrives; it returns the original ordinal once. No lease retirement is
inferred from terminal, receipt, consumption, reusable or managed drain.

The protocol-specific elapsed check at both broker checkpoints preserves the
ServerLease's approved zero CPU/wall Session policy. Zero wall requires positive
original remaining elapsed time bounded by twelve hours and refuses a zero
sentinel deadline. The helper permits zero wall only in ProtocolServer, since its
frame contains no clock proof. Finite collection keeps positive wall at most
sixty seconds; positive server wall remains at most twelve hours. Network,
output, enforcement, policy composition and exact helper retirement are unchanged.
This split implements the already approved lifetime policy without changing wire
or normative authority. Owner route/clearance, semantic timing, finite collectors
and complete full-host installation remain separate joins.
