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
persisted argument digest and reserved result-entry identity. A persisted
child-request map distinguishes
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


## Addendum: bounded semantic workspace content

Semantic workspace invocations use canonical positional MessagePack, retaining
the complete scope, physical operation/step, original tool or explicit system
origin, reserved request UUID and typed request. Completions retain both the
typed response and optional post-write diagnostics. Their decoders require the
original request to reject a response of a different kind or projection.

Invocation content is at most nine MiB. Completion content is at most
thirty-two MiB: a maximal anchored edit can return an eight-MiB preimage and
nearly sixteen-MiB postimage, plus diagnostics and envelope overhead. A
reservation of exactly twenty-four MiB does not cover that producer. Decode
admits lengths before allocation and limits nesting to 32, each container to
8,192 elements and the complete value to 65,536 nodes. Runtime terms are not
serializable results. A failure to encode after an effect must remain unknown;
it cannot become a pre-effect refusal or permission to replay.

These ceilings do not enlarge the 256-KiB TLS frame limit. Workspace content
uses a fixed 41-byte header: ASCII `LWC`, version byte 1, direction byte
(0 invocation, 1 completion), unsigned big-endian 32-bit total length, and
32-byte SHA-256. Each data frame has ASCII `LWD`, version and direction bytes,
an unsigned big-endian 32-bit content offset, then exactly 65,536 bytes or the
remaining final bytes. There are at most 144 invocation or 512 completion
frames. Wrong offsets, truncated/extra data, direction mismatch and a final
digest mismatch refuse the transfer. Discard the connection after a failure.
Application scope authentication precedes this content exchange; the digest
is integrity evidence, not authority.

The entire exchange runs under one finite supervised deadline, with a bounded
number of connection credits. Individual frame deadlines are insufficient.
The receiver retains chunks and concatenates once, so peak temporary memory
can include both chunks and the completed binary. These content limits do not
claim an equal resident-memory ceiling. Semantic validation and durable
reservation still precede any effect.

The workspace journal reserves the exact invocation size plus the full
completion allowance before returning admission. `Started` commits before an
opaque live claim can be returned. Duplicate or recovered `Started` returns
Unknown and never a second claim. Only that live claim may finish with a
validated completion. The owner must retain exact completion bytes durably
before acknowledging their digest. Acknowledgement permits payload collection
but retains the original UUID, request digest/size and result digest/size as a
permanent replay fence. Cancellation before claim also fences the identity.
Logical retained bytes and lifetime rows are finite; this is not a physical
SQLite/WAL disk bound. The journal never performs a filesystem effect itself.

The codec, journal and transfer are separate components until production
assembly binds them together. Their component tests do not satisfy the
remote-workspace product gate above.


## Addendum: semantic effects and owner receipt custody

The owner reserves a distinct Workspace child ordinal before sending canonical
invocation content. Direct tool children MUST match their original ToolKey's
operation, step, source index and argument digest. Explicit system children
retain their named system provenance. Derived compiler or capability operations
need a separate trusted binding; they MUST NOT bypass this comparison with
caller-supplied coordinates.

A retry reads its retained UUID before encoding and compares the complete
candidate against retained bytes. Concurrent candidates may conflict; a loser
MUST NOT adopt a fresh execution identity. Recovery reads the original request
and optional exact receipt without running a tool. Receipt admission validates
the typed response against the original request and rechecks the full retained
invocation. Only successful durable receipt commit creates acknowledgement
authority. Final parent ToolOutcome custody remains a separate obligation.

Workspace requests and receipts use typed 9-MiB and 32-MiB payload boundaries.
Ordinary owner Payload values retain their 2-MiB ceiling, native request entry
points retain their smaller bound, and the aggregate owner reservation ceiling
remains 256 MiB. Named Parrot/sqlc queries enforce the configured row and payload limits.
Transaction and connection setup retain the existing SQLite control statements.

Workspace journal format 2 records Open or Sealed authority. Admission and first
claim MUST check this mode within the same serialized transaction that would
create permission. Seal prevents new admission and first claims from retained
Accepted rows, including through independently opened connections. Retained
query, finish and acknowledgement may still reconcile evidence after seal.
Old or mismatched formats are refused; this change supplies no migration.

The semantic service admits at most four active managed tasks. It commits the
first claim before creating the concrete workspace-local worker, commits encoded
completion before reporting success, and returns task capacity only after the
managed run's final drain report. Encoding failure, task death and lost commit
answers preserve uncertainty. Close attempts durable seal before cancelling and
joining workers. An untrappable kill cannot execute a shutdown hook and therefore
requires reconciliation; neither process death nor cancellation proves rollback.

The semantic endpoint prefixes its existing versioned, role-checked full-scope
hello with `LWS` and version byte 1. A control frame contains `LWQ`, version 1,
and command byte 0 (Submit), 1 (Query), or 2 (Acknowledge, followed by its 32-byte
digest). Canonical invocation chunks follow every command. The status frame uses
`LWR`, version 1, and byte 0 (Accepted), 1 (Unknown), 2 (Finished, followed by
completion chunks), 3 (Acknowledged, followed by digest), 4 (Cancelled), or 5
(refused). Connection generation is correlation only; it renews no workspace
claim or sealed authority. The existing TLS certificate pin and peer identity
checks remain required.

A finite whole-exchange deadline covers DNS, TLS and every content frame.
Admission credits MUST also cover requests already handed to a service: closing
or timing out their sockets MUST NOT release credits while those requests remain
unconsumed. The embedding host closes listener admission before sealing the
service and releases journals only after its separate retirement obligations.

The owner consumer applies one managed deadline to the complete invocation or
recovery call, including custody reads, reservation, completion decoding,
receipt commit and transport. Expiry ends observation; an already queued owner
write may still commit. ObservationExpired and ObservationLost retain the
original ChildOrigin and MUST NOT authorize a new UUID, a replay or an ACK.
The caller recovers the same child to establish its durable outcome. The
embedding session still owns a finite aggregate caller-admission limit; a
bounded observer wait alone does not bound another actor's mailbox.

## Addendum: native filesystem tool consumers

`tools/workspace_tools` supplies service-backed `fs_read`, `fs_write` and
`fs_edit` constructors. Its trusted Service callback receives the original
`tool.Ctx` and one closed `workspace.Request`, returning
`Result(workspace_local.Completed, workspace.ServiceError)`. The adapter does
not mint request IDs or derive authority from a pathname. Owner assembly binds
that callback to the original durable tool and workspace child.

The constructors reuse the existing tool schemas, argument validation and pure
result rendering. Narrow internal callback doors in `tools/fs` keep those
projections shared without importing workspace contracts back into the lower
filesystem module. Existing local constructors retain their current behavior
and Safe replay metadata. Remote constructors declare Never: recovery belongs
to durable original-child reconciliation, not a repeated tool body.

Virtual read schemes are resolved by the existing owner-supplied Scheme list
before ordinary path dispatch. Unknown schemes refuse without falling back to
a filesystem. Ordinary remote paths must pass RelativePath validation before
the semantic callback runs. The adapter must not resolve `Ctx.workspace` or
invoke the owner's FileSystem for those paths. Completion variants must match
the requested operation, and retained images, anchors, stale-edit evidence and
post-write diagnostics keep their existing projections.

OutcomeUnknown reports that an effect may have happened and the original
request needs recovery. It must not describe a pre-effect refusal or suggest
issuing a new mutation. These constructors become shipped remote behavior only
when daemon selection and owner custody install the concrete callback.

## Addendum: production owner and executor assembly

The first product binds one owner to one administratively enrolled remote
workspace. Pools, clustered ownership and migration remain later phases. The
contracts below govern implementation; their presence in this proposal does
not claim that the shipped daemon already installs the components.

### Persisted identity and local compatibility

The owner MUST persist the resolved workspace Binding before workspace startup.
An internal session Creation carries this Binding. A repeated creation key
reads the retained registration first, compares immutable requested identity
and metadata, and revalidates its original epochs. It MUST NOT resolve new
epochs and silently substitute them after partial creation. Reopen of stale or
unavailable enrollment refuses without local fallback.

WorkspaceKey groups defaults and shared domains by canonical local path or
validated registered selector; epochs remain in each session Binding. Existing
local SQL workspace keys and domain IDs retain their exact representation.
Registered keys use `registered:<executor>:<workspace>` with validated labels
that cannot contain colons. This is a catalogue key, never a filesystem path.
Registrations add nullable canonical JSON TEXT binding content, and total DAL
decoders require exact agreement between key and content. Local rows retain
NULL content and their original pathname. The schema version advances so older
daemons refuse the new database. Named Parrot/sqlc queries and regenerated
bindings own persistence; no handwritten row SQL substitutes for them.

Legacy local wire frames remain compatible. Tagged registered selections carry
only selector identity, never endpoints, roots, pins or epochs. Clients MUST
assert `registered_workspace_v1` in a bounded per-request accepts list before
creating, opening or selecting a registered session. Server advertisement alone
is not negotiation. Registered replies carry a typed binding and omit the
legacy local pathname. Administrative configuration owns enrollment and pins.

`tool.Ctx.workspace` becomes a closed WorkspaceAccess: LocalWorkspace retains
its root and FileSystem; RegisteredWorkspace retains only the validated scope.
Local-only consumers MUST project LocalWorkspace before resolution, I/O or
clearance, otherwise return an explicit unsupported-local-operation result.
OwnerBlobs separately retains owner output storage root and FileSystem. No
fake local pathname or refusal-stub filesystem represents remote access. Remote
constructors capture semantic service callbacks; WorkspaceAccess contains no
callback dependency cycle. Owner state, clock and original tool coordinates
remain distinct from physical workspace access.

Owner assembly chooses local or registered workspace before any local Git,
toolchain, guidance, seed, home or temporary-root probe. Only the local branch
may resolve those physical facts on owner disk. The registered branch obtains
executor facts through enrolled services. Conversation, catalogue, memory,
index and owner blobs remain owner-local independently of workspace selection.

### Exact command clearance and provenance

Each physical service reserves its exact bounded ServiceKey before send. A
CommandRef adds a closed command role; the retained CommandOffer includes the
full scope, registration digest, bounded registered region mappings and exact
argv, environment, cwd and requirements. It carries no owner grants, fresh
budget or broker token. The owner validates the offer against the admitted
service purpose, exact original input and administrative mapping ceiling,
then constructs AcceptedCommand with its original ChildOrigin and authority.
Paths are literal executor command data, never owner filesystem inputs. No
substring rewriting guesses paths inside shell, argv or environment strings.

Native UUID allocation stays in the existing durable Prepared reservation,
where the exact cleared envelope is retained before first send. An offer does
not preallocate another native UUID or reserve partial content in that slot.
Recovery follows the original child and never re-clears with a new token to
recover an uncertain command. CommandCleared reports owner clearance only;
CommandAdmitted requires retained native admission evidence. Native and outer
service completions have separate commit-before-receipt obligations.

Compile and Launch remain outer service roles. CompileCommand and
SatelliteCommand are disjoint native roles. A new admitted capability role
uses the bounded canonical tuple of trusted capability name, its existing
per-capability ordinal and closed semantic/native purpose. Legacy Capability
addresses and decoding remain intact. No global counter is introduced. Child
reservation happens after trusted capability admission, and the existing
64-child-per-parent ceiling remains. Managed nested proc clearance carries
ChildOrigin through the broker rather than merely copying operation/step.

Shared command types reside below executor codecs; codemode MUST NOT import
executor wire types. Owner-derived demand, stream policy and lifetime stay out
of the executor's command offer. Preparation, clearance and exchange consume
the original finite authority. Transport generations grant no renewal.

### Resources, launch and stream custody

Resource preparation belongs to the original retained Launch invocation. Its
intent commits before creation; the issued lease commits before reply. An
executor lease binds full scope, original service identity and admitted compile
artifact. Local resource adapters accept only local artifacts/resources.
Executor adapters accept only matching remote artifacts/resources. Lost replies
after possible creation remain ResourceOutcomeUnknown under the original ID.

Launcher returns typed LaunchRefused or LaunchOutcomeUnknown. Only a witnessed
pre-dispatch refusal can claim that no node launched. Cleanup status remains
separate from the program result, native retirement and owner receipt; neither
resource release nor channel death proves native retirement. Compilation must
likewise preserve possible execution after a lost reply.

Both capability channel directions use bounded frames and consumption credit.
A naked Subject or successful network write is not recipient consumption.
The first product permits one frame in flight per direction. Credit returns
only after the final recipient consumes the frame into bounded state; observer
timeout does not remint it. Credit-owner death retires the channel. Delivery
success means admission to its fixed bounded writer window; a host callback
must not block waiting on processing that depends on that same host. Ordered
outcome and hook frames share cumulative accounting. Separate bounded cancel
capacity and independent native cleanup prevent a blocked writer from owning
retirement. Dropped or exhausted streams cannot report prefix success.

The complete LSP host may attach an opaque executor-local input handle to the
exact owner-returned native key/digest associated with its retained CommandRef.
Attachment validates that association and the live row. The handle can only
feed ordered bytes/EOF through the existing service.feed reducer and its
quotas, with one stable pending credit. It cannot Submit, Hello, renew, change
identity or expose native.Running. Uncertain delivery fences and closes input;
a Nil-returning stdin callback is not consumption proof. If this exact scoped
attachment cannot be established, use the closed owner-mediated input protocol
instead, after reviewing that implementation choice.

### Verification boundary

Executable bounded models must cover changed offers, distinct child roles,
lost resource/launch replies, separate native/outer receipts and both-direction
consumption credit. Mutation controls must violate the intended invariant with
an actual trace, not pass through setup failure. Existing P admission, launch,
receipt and cancellation invariants and PlusCal ingress custody remain binding.
These finite checks do not claim liveness or implementation refinement.

The product gate remains a shipped owner and shipped executor on disjoint
hosts/filesystems, with no owner copy or bind of the target checkout. Ordinary
session admission must exercise remote files, mutations, foreground and Auto
Bash, Git/guidance, compilation, satellite launch, workspace and owner-state
capabilities, and LSP. Reopen, original-identity recovery and cleanup faults
require independent evidence. Component tests, full gates, hosted CI and this
separate-host acceptance must be reported separately.
