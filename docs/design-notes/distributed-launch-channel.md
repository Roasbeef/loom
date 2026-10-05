# Executor Launch and capability-channel ownership

Status: accepted implementation plan under protocol 067; production wiring is
pending. This design follows the independent Launch/duplex review. It refines
how the existing owner-hosted capability router drives a satellite beside the
executor's workspace. It does not change the trusted TLS BEAM membership domain.

## Follow one program

A phone or laptop submits a program to the session owner. The owner vets it and
asks the registered executor to compile it beside its workspace. Successful
Compile returns an executor artifact, its original producer identity and actual
build evidence. The owner then mints the program's capability token and starts
its capability host. The whole Launch boundary receives that artifact, original
run authority, token and host endpoint together.

The executor checks the original Compile association before creating a token
file or listener. Its resource journal records preparation intent first, grants
one live continuation, and records the resulting resources before replying.
Only that continuation can create the channel and submit the cleared native
satellite command. Historical queries return evidence; they never recreate a
listener, token, preparation claim or execution.

The model-authored satellite has distribution disabled and remains in the native
jail. Its local Unix channel reaches an executor-owned transport that forwards
bounded frames to the owner. Filesystem and language-server calls use executor
workspace services. Notes, strand operations and report history retain owner
session authority. Provider secrets and BEAM membership credentials never enter
the satellite's environment, readable mounts or inherited handles.

## Keep placement inside whole Launch

The existing single-shot implementation writes the token before the launcher
receives the compiled artifact. A remote workspace needs the opposite ordering:
the artifact and original service identity determine where token and socket
resources may exist. One whole Launch callback owns that placement, submission
and cleanup. Splitting those steps across closures with a mutable artifact cache
would make their association implicit.

The local adapter accepts only local artifacts and owns its local token/listener
operations. The remote adapter accepts only matching executor artifacts and
retains the original Launch input before sending. Token bytes travel through a
closed authenticated placement operation that checks their retained commitment;
ordinary Launch metadata contains that commitment, not raw token bytes.

Launch failure distinguishes a witnessed refusal before dispatch from an unknown
outcome after possible dispatch. A lost reply cannot become a claim that no node
launched. Channel cleanup, native retirement, outer service receipt and complete
report COMMIT remain separate observations. Persistent extension hosts retain
their existing lifecycle while the foreground path is migrated.

## Transfer custody before receiving frames

Launch returns a prepared live connection with inbound delivery paused. The
owner host installs the original send/close handles, acknowledges that custody,
and only then activates frame delivery. A host that dies before that handoff
leaves the original launch owner responsible for destruction.

This ordering removes the foreground host's pre-connection output queue. It also
prevents a satellite from making calls before the owner host possesses the
handle that must tear it down. Activation belongs to the original live
continuation; a query or reconnect cannot repeat it.

## A consumed frame returns one credit

Each direction has one frame window. Its identity includes the original live
channel incarnation, direction and monotonically increasing sequence. A remote
binding additionally authenticates the original Launch key, scope and transport
generation. A local channel cannot invent a remote service identity.

A send reserves the window and byte allowance before mailbox delivery. The
recipient validates the exact frame and eventually acknowledges consumption of
that original sequence. Stale, duplicate and wrong-direction acknowledgements
change nothing. Observer timeout does not free the window; loss of its owner
retires the channel. Reconnect does not restore its credit.

The meaning of consumption depends on the direction:

| Direction | Event that returns the credit |
|---|---|
| Executor to owner | The actual capability host validates and admits the complete frame into bounded state. A relay receiving chunks is insufficient. |
| Owner to executor | The executor's bounded socket writer consumes the complete frame. This does not claim the satellite program handled it. |

The owner remains runnable while a write is pending. A callback cannot wait for
an acknowledgement that requires the same host actor to process another message.
Transport chunk acknowledgement is separate from final frame consumption.

## Retain bounded replies in their original slots

A capability call already owns an admitted invocation slot. Completion settles
its call-log observation at the original completion time, then changes that slot
from running to reply-ready. Writer admission changes it to reply-sending. Only
exact consumed-write acknowledgement releases it. Removing the slot at computation
completion would permit new calls while old responses accumulated elsewhere.

The writer selects ready responses from that bounded table; it adds no separate
unbounded completion queue. A response is encoded and size-checked before writer
admission. Encoding failure or excessive size fails the channel explicitly.

Some replies have no invocation slot: token, route and budget denials, and
heartbeat responses. These share one immediate-response slot. While it is occupied,
the host withholds the current inbound frame's consumption acknowledgement.
A malformed frame can retire the channel without receiving an error response.
This rule prevents invalid requests from bypassing the normal outstanding-call
bound.

## Finish a terminal without waiting on itself

After validating a terminal outcome, the host holds it in a terminating state
and acknowledges that final consumed frame before waiting for teardown. The
acknowledgement marks the frame final, so it does not authorize another delivery.
Acknowledging only after teardown would deadlock if teardown joined the reader
that was waiting for that same acknowledgement.

Cancellation wins over a late acknowledgement and cannot revive the window.
The same inbound producer orders close after all its bytes. A separate native
observer reports physical settlement to resource custody; it cannot emit a
racing channel close that overtakes the outcome. The owner retains the complete
report before publishing its bounded transcript result, independently of these
transport observations.

## Cancellation has its own path

The resource owner can close the original accepted socket and listener directly,
then join reader/writer work and collect native evidence separately. A shutdown
message queued behind a blocking socket write cannot cancel that write.

Finite Launch admission bounds live channel owners using the existing whole-
service pattern, with one through four active entries. Entries remain held while
physical or resource custody is unresolved. Historical journal row capacity is
not live stream capacity. The six shared endpoint request credits serve finite
control exchanges; channel-long reads cannot occupy them and block their own
writes. Original executor watchdog and owner cancellation do not require a fresh
endpoint credit to perform cleanup.

Processes use existing weft state machines, managed/prepared tasks and exact
monitor selectors. Postponing an unbounded stream of actor messages is not
producer backpressure. No new generic streaming framework or quota actor is
needed.

## Byte contract

The cap protocol permits a 16,777,216-byte MessagePack frame payload, including
its envelope. The four-byte prefix is additional, so one maximum wire frame is
16,777,220 bytes. Exact 65,536-byte transport chunks need at most 257 chunks per
frame. Validate its declared length and reserve cumulative capacity before
reading or accepting the body; concatenate checked chunks once.

Each direction has a fixed 67,108,864-byte lifetime allowance, counting prefixes
and terminal/hook traffic. Original admission debits it once; uncertainty never
refunds it. Exhaustion fails the stream, never reports a successful prefix.
One maximum report-read allowance and one maximum terminal frame fit, but this
is a hard limit, not a guarantee that arbitrary additional work fits. Native
wire and report-storage limits retain their separate meanings.

## Evidence required before completion

The implementation must exercise pre-activation input, concurrent completed
calls behind a stalled writer, invalid-call and heartbeat bursts, and a terminal
whose reader waits for acknowledgement while teardown joins it. Real socket
controls must show independent close interrupting a blocked write. Test owner
and recipient death, stale acknowledgement, cumulative exhaustion, and both
held-call count and mailbox/frame bounds.

A bounded P model must distinguish admission, actual recipient consumption,
native retirement and report COMMIT. Reachability probes and compiling mutations
must expose premature credit return, slot release at completion, stale credit
reuse, channel resurrection, close overtaking terminal and cancellation blocked
behind data. The existing endpoint model covers request custody and cannot stand
in for this channel model. Bounded model checks do not establish liveness or an
implementation refinement.

The actual satellite gate must compile, execute, retain a large report and read
it in a later execution; it must also witness distribution disabled and denied
membership-credential access. Independent VMs on one host prove component
ordering. The product gate still requires separate physical hosts and an absent
owner checkout, followed by remote LSP and the registered daemon path.
