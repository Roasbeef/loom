# 067: Remote workspace and execution services

Status: implementation proposal for issue #697, within the distributed-runtime
work authorized by the owner. This extends [066](066-distributed-runtime-foundations.md).
A protocol document does not establish that the remote runtime works. The
implementation must pass the two-host acceptance tests below before enablement.

## Problem and boundary

A remote process dispatcher alone moves Bash but leaves native file tools,
code-mode preparation, and LSP resolution on the owner's disk. The session
would then read one checkout and execute against another. We bind the session
to one registered workspace and perform every physical workspace operation at
that executor.

The owner keeps the provider, session SQLite, runtime, approvals, broker,
code-mode capability router, and client gateway. The executor keeps the
registered checkout, toolchain, jailed compiler and satellite, language
servers, native pool, and durable execution evidence. The executor never
imports the client package or joins native Erlang distribution.

This proposal changes the internal Dispatch handoff and introduces explicit
remote workspace, command-preparation, compilation, launch-resource and LSP
service contracts. The local deployment implements the same service interfaces.
The existing native helper wire remains a separate versioned protocol.

## Workspace identity and operations

Session creation accepts either a local directory or a registered workspace
selection. The latter resolves through owner-controlled configuration to an
executor ID, workspace ID, workspace epoch and session authority epoch. Only
executor administration maps that identity to a physical root. The binding
commits before the session starts and is revalidated on reopen. Missing or
unavailable registrations produce an explicit unavailable state.

Wire paths are bounded component-validated relative paths under a workspace
or an explicitly registered additional region. Absolute paths, traversal,
NULs and malformed components are rejected. Executor-side resolution checks
symlinks, protected paths and region authority immediately before use. A host
path printed in an error or command result does not become a valid region.
The existing pathname-based filesystem implementation does not promise an
atomic snapshot against concurrent shell writes or race-free descriptor
containment; the remote service must not claim either property without the
corresponding implementation and tests.

Workspace calls use a closed vocabulary: read, write, anchored edit, listing,
structured search, file metadata, Git observations, guidance and workspace
initialization. An anchored edit resolves, reads, checks its digest and lands
on the executor in one service operation. Reuse the existing file tool
semantics, including stale-content results and fresh anchors. This is not a
network implementation of low-level FileSystem callbacks.

Every mutation carries the full scope, operation, step and stable request ID.
Before acknowledgement or mutation, the executor reserves evidence capacity
and persists the exact immutable request. Retry with the same identity and
digest returns retained evidence; a changed digest conflicts. A connection
failure after possible submission yields an unknown outcome, never an
automatic fresh mutation. Read retry policy is separate and explicit.

## Remote outcome evidence

`broker/exec.LossCause` adds `RemoteOutcomeUncertain` for an exchange that
cannot establish a definitive result. It remains an `ExecutionLost`, so callers
must reconcile the original retained request instead of treating it as a start
refusal. It proves neither native retirement nor permission to replay. This
separates remote uncertainty from a local output relay death in diagnostics.

## Clearance and physical execution

Dispatch gains operation and step context copied from the actual cleared
CallSpec, plus optional opaque `core/remote_tool.ChildOrigin` provenance.
`broker.clear_call_from` supplies that provenance; the existing `clear_call`
entry supplies `None` for unmanaged local execution. Congestion retries retain
it unchanged. Remote reservation requires an explicit durable origin and
validates its full immutable parent identity before transmission. Provenance
is not authorization and does not change the broker's pooled budget key.
Derived build phases and detached jobs keep the original parent ToolKey while
retaining their distinct physical operation/step in the immutable child request;
the trusted adapter validates that relationship rather than rewriting the key.
Explicit system children identify durable service invocations, not fabricated
tool calls. Sequence numbers, random token bytes and connection generations
cannot substitute for that context. Session and workspace authority come from
the configured adapter binding. The owner durably allocates each logical
request identity before making it sendable.

The executor prepares a bounded declarative command description using
registered workspace, toolchain, scratch and artifact regions. The description
includes the exact native request and policy materialization,
its canonical digest and the declared registered-region mapping. The owner
validates the requested access and clears that exact command through its
existing broker. The executor cannot rewrite it after clearance. Executor
admission independently checks that clearance
against its registered ceiling and current epochs. Arbitrary argv, shell or
environment strings are never rewritten to guess which paths they contain.
Unmapped resources are refused. Provider credentials and ambient environments
are not copied to the executor.

The native executor checks the cleared wall policy against the frozen local
admission deadline after helper checkout and again when the helper actor
consumes its queued Run. It MUST NOT shorten, refresh or otherwise rewrite the
cleared policy to make it fit. Expiry before native dispatch sends no start
frame. The existing relay still enforces aggregate cancellation, and native
retirement remains a separate obligation. These checks do not constitute a
hard real-time guarantee across scheduler suspension or native port delivery.

Physical compilation is abstracted above compile preparation, because source
materialization and seed checks already access disk before the existing
Builder callback. The remote compiler prepares, builds and hashes artifacts
beside the registered workspace. A remote Launcher owns the executor-local
Unix listener, private token file and jailed satellite. Its resource callbacks
return typed artifact references, not owner-local paths.

The existing satellite capability host/router and broker stay on the owner.
The channel forwards bounded ordered cap frames without losing outcome or
hook variants. Capability calls retain the admitted execution, operation,
step and invocation ordinal. Owner routing still validates the token, active
execution, allowlist and caller. Filesystem and LSP capabilities use the bound
workspace services; notes, agency, schedules and other owner state remain on
the owner. Nested process calls consume the existing pooled broker budget.

The complete LSP host runs at the executor: root discovery, document reads,
dependency fingerprints and preparation, server launch, URI validation,
rename landing and diagnostics after writes. Moving server stdin/stdout alone
would still resolve documents against the wrong disk. Extract reusable host
code with injected clearance and administrative toolchain/profile facts;
keep session and extension administration on the owner.

## Custody and receipts

Remote start establishes a local guarantor and durable outgoing record before
any possible send. A prepared sender that cannot hand back its handle must be
revoked and joined before StartRefusal is returned. After transmission becomes
possible, loss of acknowledgement cannot become NotStarted.

The executor commits admission before acknowledgement and launch intent
before calling the existing native service. Recovery never replays a launch
effect. The exact bounded terminal payload and any promised output replay
commit before terminal evidence is advertised. A journal containing only
hashes cannot satisfy lost-result recovery.

The owner commits the exact result in a bounded durable receipt store before
acknowledging it to the executor. Broker settlement/release alone is not that
commit. Receipt state survives the original callback and process lifetime.
Later reconciliation updates retained remote evidence without invoking an
already settled tool callback a second time. Runtime recovery must consume
that evidence under the original durable operation identity.

Tool recovery uses a complete ToolKey: session, operation, step, source index
and persisted argument digest. A persisted child-request map distinguishes
compile, launch and nested capability calls within that tool. System-origin
broker calls have an explicit system origin. Operation ID alone cannot key
result recovery.

A ToolSurface recovery callback runs before strand_runtime reports an orphan.
It distinguishes unmanaged local tools, an exact recovered ToolOutcome,
pending bounded reconciliation, and an unknown outcome with retained evidence.
Only unmanaged tools follow existing orphan/replay policy. Recovered outcomes
use the existing durable settlement path; reconciliation never reruns a
code-mode program to reconstruct its final report. The owner persists the
exact final ToolOutcome before returning it from the live tool. If only child
results survived, the final tool result remains unknown.

Owner-journal collection requires the reserved session result-entry identity
and verified commit/readback, or an equivalent explicit durable handoff. A
broker release cannot free the only copy of an uncommitted result. Reconciliation
runs under supervision with completion wakes; it does not ask a model to poll.

Native retirement is independent from process outcome. Initially the scoped
native pool must drain with witnessed retirement before covered executions
can be recorded retired. A terminal exit, dead socket or empty diagnostic
snapshot is insufficient. Collection retains replay fences and requires both
native retirement and exact durable owner receipt. Bounded capacity exhaustion
refuses admission rather than discarding unacknowledged evidence.

## Authenticated transport and bounds

Use mutually authenticated TLS with certificate-chain verification and an
exact configured peer certificate pin. The client also verifies the endpoint
hostname. A peer with another certificate from the same CA cannot impersonate
the configured executor or owner. Application identity is bound to the
verified peer. There is no insecure transport fallback.

OTP ssl requires a small fixed-option FFI: existing dependencies do not expose
both mandatory client-certificate verification and the needed client/server
peer inspection. Keep the bridge in executor/internal and expose typed errors,
finite timeouts and ownership transfer. Do not accept arbitrary Erlang options
or intern names from remote input.

Read a four-byte length header before a bounded body in passive binary mode.
The initial maximum frame is 256 KiB; zero/oversized frames are refused before
body allocation. Prefix and body share one finite frame deadline. Explicit
service and helper-version negotiation rejects incompatible peers before
admission. Connection generation fences transport mutations without erasing
old evidence or changing a logical request's identity.

Bound peer/scope connections, handshakes, outstanding requests, pending bytes,
stdin, retained output and durable result bytes independently. Reserve control
capacity. A bounded network writer runs separately from native cancellation
and cleanup. Queue admission uses credits or bounded request/reply, not an
unlimited cast followed by a size check. The final consumer's mailbox is part
of the bound; limiting only a TLS queue is insufficient.

The first wire-stream contract has a finite cumulative byte allowance and an
explicit failed-stream outcome on exhaustion. LSP and cap streams must never
report successful completion after dropping protocol bytes. Indefinite streams
require end-to-end consumption credits; a larger queue is not that mechanism.

## Finite deadlines across hosts

Convert the existing owner deadline once into a monotonic remaining budget.
Wall-clock jumps cannot renew that budget. Before first admission, the executor
issues a single-use challenge with local lifetime W. The owner receives it,
computes its current remaining budget R, and submits B = R - W. Nonpositive
B is refused. The executor accepts only before the challenge expires, then
sets its local deadline to receipt time plus B and subtracts subsequent local
preparation time from the same deadline.

If the challenge was issued at real time e0 and received by the owner at t1,
then e0 <= t1. Receipt by the executor is at most e0 + W. Its deadline is
therefore at most e0 + W + R - W <= t1 + R, the owner's deadline. This argument
requires the stated monotonic elapsed-clock-rate assumptions; it requires no
agreement about clock offsets. Tests use independent clock origins, delayed
challenge delivery, delayed submission, expiry and wall-clock jumps.

The challenge binds the authenticated scope, generation, request identity and
content digest. The implementation deducts a declared clock-rate and timer
margin from B. Native helper seconds must fit the remaining milliseconds; a
positive subsecond budget is refused rather than rounded to zero/unlimited.
The executor also enforces its local millisecond watchdog.
It and the remaining duration describe attempt authorization, not stable
request content. An existing admitted key always returns its original budget
and deadline; a later challenge cannot renew either. Recovery never recreates
a fresh clock for uncertain launch intent. Deadline expiry initiates native
cancellation; cleanup grace and proof of descendant retirement remain separate.

Session-lifetime work uses an explicit lifetime variant with recorded owner
authority and finite resource ceilings. Disconnection alone does not revoke
that authority. The service must not promise immediate remote revocation while
partitioned or introduce a periodic inference-driven renewal loop.

## Verification and remaining phases

The first transport tests use real TLS and helpers, including absent/foreign
certificates, same-CA wrong identity, version skew, fragmented frames, oversized
headers and a nonreading peer. Lost admission/result replies and restart tests
must show one actual filesystem mutation under the original identity.

The product fixture uses a shipped owner and a separately hosted Linux
executor. Its target checkout exists only on the executor. Through the real
session/tool path it reads, edits and searches that checkout, runs Bash and
Git, compiles and runs code mode, forwards an owner-state capability, and uses
LSP against the same files. It checks durable reopen, partitions, cancellation,
stale epochs, permission refusal, output bounds and truthful cleanup evidence.
Owner-side canary files prove absence of local fallback. No prerequisite skip
counts as this gate passing.

Executor scheduling, trusted-node metadata/routing, durable cross-node
messaging and planned ownership handoff remain later dependent stack slices
of #697. Passing the first remote-workspace fixture does not complete those
phases. Automatic failover and workspace snapshot migration remain deferred.
