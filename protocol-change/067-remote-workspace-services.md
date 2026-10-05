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
imports the client package. The original transport proposal excluded executor
nodes from Erlang distribution; the **Trusted executor distribution** addendum
below supersedes that choice under the owner's explicit authorization. Its
implementation and acceptance gates remain in progress.

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

This section records the original socket transport. The **Trusted executor
distribution** addendum supersedes its inter-node TLS/socket mechanics. Its
durable identity, original deadline and bounded consumption requirements remain.

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

The accepts envelope list contains at most eight distinct ASCII names of
1..64 bytes, each byte in `0x21..0x7e` (no spaces or controls). Only the exact
`registered_workspace_v1` name changes behavior.
An authorized bounded list or get that would return registered metadata also
requires this feature; an unsupported caller receives `unsupported_workspace`,
not filtered rows or a registered key disguised as a path. Rename, archive and
restore MUST check support before mutating a registered row, after existing
membership and epoch checks. `operations.get` MUST check support before
returning a registered view. Local-only legacy catalogues retain their wire
representation. A mixed catalogue therefore needs
an updated client; compatibility does not promise that an old decoder can read
new registered rows. Native resident upgrades independently assert the exact
`x-loom-accepts: registered_workspace_v1` header before resolving an instance.
This is a feature assertion, never an authentication or authorization grant.
Browser attachment needs its own bounded assertion before that path is enabled,
since browser WebSockets cannot set arbitrary request headers.

Attaching to an already resident session grants access to owner-held session
state under existing membership checks; it does not renew executor authority.
An executor outage MUST NOT by itself prevent that attachment. Creation and
reopen revalidate the retained binding, and effect admission rechecks current
registration authority independently of an attached client's presence.

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

## Addendum: pinned enrollment and preparation before wall selection

This refines command construction and extends preparation custody to Compile
as well as Launch. The owner pins one exact per-session enrollment snapshot
under the persisted scope and both authority epochs. It includes native
registration facts and the configured workspace, allocation areas, compiler,
BEAM executable, seed, toolchains, host mounts and build PATH. Trusted
provisioning canonicalizes those paths on the executor. An unchanged digest
claim cannot authorize different snapshot contents on reopen.

Compile and Launch allocations use their original service UUIDs beneath
separate enrolled areas. Both areas are disjoint from ordinary workspace
write authority, and seed/toolchain inputs remain immutable. Paths derive
from the retained identity and fixed layout; a collision refuses preparation
rather than choosing another suffix. Owner code compares literal path data
without probing its own filesystem.

Both services reserve their original exact input and completion capacity
before preparation. The executor commits Preparing before any directory,
source, token or socket creation. Only the first live claim performs creation;
queries and recovery never produce another claim. Ready evidence commits
before reply. For Launch, the usable socket remains in the supervised resource
owner's custody: persisted lease metadata alone cannot rebind it after that
owner dies. Compile completion, resource cleanup, native retirement and owner
receipt remain distinct facts.

The initial service input retains the owner-selected wall ceiling. The final
native wall is selected only after durable preparation has completed. Selecting
it earlier would reserve compilation time that cold preparation then consumes,
causing the unchanged command to fail its first admission check.

Let R be the original remaining authority in milliseconds at Ready, C the
positive original native wall ceiling, and S the sum of bounds on the remaining
control path. Select `w = min(C, floor((R - 1100 - S) / 1000))` and refuse when
w is less than one. The 1,100 ms is the existing native attempt allowance.
S must derive from the actual serial custody, clearance, exchange and startup
calls; it is not another configurable margin. Already elapsed preparation
and completed control calls must not be deducted twice. Expiry checks remain
authoritative during scheduler delays; bounded calls are not hard real-time
guarantees.

The Ready receipt supplies canonical resource facts. The owner derives the
complete final command with the shared closed template, retains its exact
bytes in the existing CommandRef offer slot, then clears directly. No extra
executor confirmation exchange is required. A retained offer is neither
clearance nor native admission. Only actual retained native key/digest and
admission evidence may associate the physical service with its native child.

Every continuation retains the same selected wall, offer and original
deadline. Before first clearance, insufficient remaining authority refuses
without allocating a native UUID. Once native transmission is possible,
recovery queries that original UUID; it cannot select another wall, re-clear
or renew authority. The extended preparation model checks these transitions;
production resource custody and separate-host acceptance must establish their
implementation separately.

## Addendum: concrete compiler and launch inputs

Remote program compilation uses a provisioned contract for each enabled
Workspace or Orchestration program seam. That contract pins the complete
enrollment, the host's actual effective vetting policy, the fixed ordered
dependency table and the approved generated-module catalogue. The owner and
executor receive those values through trusted setup. A peer-selected seam
name or import list cannot widen them. Extension and resident loaders retain
their separate admission contracts.

Compile input contains the exact program text, its ordered selection of
generated module names and source, dependencies, original policy seed and
positive build timeout. The executor re-vets the source with the provisioned
policy. It filters the trusted catalogue by the resulting imports and requires
exact ordered equality with the submitted generated selection. Comparing
module names alone would admit changed privileged prelude code. The fixed
entry module, project table and seed layout remain implementation-owned.

The input body has a version byte, a closed role byte, a big-endian u32
enrollment length and canonical enrollment bytes, then a big-endian u32
metadata length and canonical MessagePack metadata. Compile source bodies
follow in metadata-declared order as exact UTF-8 bytes. Launch has no source
bodies. The enrollment and metadata together may occupy at most 256 KiB;
each segment passes its bounded decoder before any body is parsed. Selected
generated modules are limited to 128, and launch environment pairs to 64.

The existing service envelope remains limited to 9 MiB, including its
four-byte header length and canonical service-key header of at most 8 KiB.
Every source body consumes that aggregate allowance. A source body is not a
metadata string and therefore does not inherit the metadata string ceiling.
The decoder checks declared counts, lengths and their exact sum before UTF-8
conversion or vetting. Unknown versions, noncanonical segments, truncation,
invalid UTF-8 and trailing bytes refuse. The request digest covers the exact
canonical input body, excluding the outer header that contains that digest.

Launch input retains the complete producing Compile service key, every field
of its executor-issued artifact, original environment, relative cwd, policy
seed and the commitment to the original 32-byte capability token. It contains
no raw token, local Artifact, owner grants, budget or renewed deadline. Before
preparation, admission requires the original retained successful Compile
completion and exact artifact equality. Prepared compile locations alone are
insufficient. Artifact operation and step match the Compile service's physical
coordinates; Compile and Launch must share the complete original parent but
may have different physical steps.

Syntax validation and input decoding grant no resource or execution authority.
The resource service must recompute the input digest, enforce the pinned
contract, commit preparation intent and retain the original successful Compile
evidence. It resolves the artifact only in the producing allocation and checks
the physical fingerprint before launch. Input limits bound retained bytes;
they do not establish an equal BEAM memory bound or a parser CPU bound.
Managed preparation remains subject to the original service deadline.

## Addendum: bounded Compile completion transfer

Compile completion transport uses closed content tag 2 in the existing version-1
workspace chunk framing. Tags 0 and 1 retain their current meanings and bounds.
A Compile body is at most 262,144 bytes in at most four 65,536-byte data chunks,
plus its fixed header. This aggregate is independent of the TLS frame ceiling;
placing the maximum body inside a single native envelope would exceed that
ceiling once envelope overhead is included.

The receiver checks aggregate length before retaining chunks, then exact
direction, offsets, lengths and final digest. Authentication of application scope,
canonical semantic decode against original identity, a finite whole-exchange
deadline, bounded connection credits and commit-before-ACK remain required.
Independent review found no production framing defect. Its scanner test-specificity
finding was corrected and the focused real-TLS gate rerun; the
[review record](../docs/review/distributed-compile-transfer.md) separates byte
transport evidence from production service acceptance.

## Addendum: Compile completion custody

The preparation journal also owns exact Compile completion custody. A fresh
resource-format-2 reservation charges the full bounded input, Ready receipt,
native association and 256-KiB completion allowance before the first preparation
claim. Reservations remain charged after receipt, cleanup and recovery. Existing
format-1 stores are refused explicitly before querying format-2 columns; recovery
must neither silently upgrade old evidence nor remove its fences.

The resource actor pins the actual native journal under the same complete scope.
Associating a native child requires canonical retained Prepared bytes and actual
committed admission for that exact native key and Prepared digest. Request bytes
alone are insufficient because request retention precedes native admission. The
association is immutable, and one native UUID cannot serve two outer invocations
in the same scoped resource database. Trusted provisioning must select that
single database for the scope.

Compiler expectation data comes from the retained original input, exact Ready
locations and pinned enrollment. Historical reconstruction does not create source
admission or invent a compilation contract. Native argv, environment order and
cwd must match exactly. The cleared policy may narrow requested authority and
add protected paths; it must not broaden the compiler's fixed requirements.
Comparison uses the existing policy composition without grants, preserves the
recorded Prepared unchanged and performs no new filesystem resolution or
clearance. The original stage and policy ceilings still bound its finite wall.

A new native-backed completion requires both exact retained terminal bytes and
matching committed terminal reducer evidence. The Prepared digest, native
terminal digest and outer completion digest identify different objects. Retaining
terminal bytes can precede reducer settlement, so that intermediate state remains
pending. Positive admission and terminal facts survive native retirement and
payload retention; the resource actor can read those facts before taking its own
SQLite writer lock, then revalidate the exact resource row under that lock.

Before-native failure is narrower. Only the original live Preparing claim can
retain it, while no Ready or native association exists. Its transaction commits
the error and fences late Ready together. Once Ready has been published, missing
native evidence cannot prove that submission was impossible. This version adds
no post-Ready no-submit proof or replay permission.

Completion retention commits before returning its opaque retained-result handle.
Checked historical inspection can reconstruct that handle, including after a
Before-native reply is lost. Exact already-retained retries need no live native
endpoint; new association or settlement still requires authenticated readback.
Failed COMMIT or unchecked update cardinality must return no positive receipt.
An uncertain endpoint is fenced until explicit recovery.

The original owner retains exact completion bytes before acknowledging their
digest. That outer receipt remains separate from native owner receipt, native
retirement and resource cleanup. None can substitute for another or renew a
claim, deadline, wall selection, UUID or clearance. Launch rows reserve the same
fixed outcome allowance, but Compile-only settlement APIs refuse Launch until a
closed Launch completion and its admission checks exist.

## Addendum: Indexed historical command offers

The owner MAY recover a complete retained command offer by its managed native
origin through the existing lifetime-unique index. It MUST validate the original
session, full parent, canonical command reference and retained service before
returning the offer. Bounded scalar headers and reserved capacity MUST be checked
before transferring retained bodies. Invalid SQLite reservation types MUST be
projected as a scalar refusal value rather than materialized for the decoder.

This read preserves exact cancelled evidence but refuses frozen evidence and
collected parents. It grants no live clearance, reservation, UUID allocation or
execution authority. The existing atomic native reservation retains its original
cancellation checks. Independent review and corrected verification are recorded
in [the lookup review](../docs/review/distributed-command-lookup.md).

## Addendum: Original-claim native admission

Fresh Compile command admission MUST retain the original live preparation Claim.
Historical Input lookup MUST validate the complete canonical service key and body,
but MUST NOT reconstruct that Claim, renew its deadline or grant launch authority.

The native service MUST commit actual Request, Authority and Admit evidence before
calling live resource association, and MUST receive the exact committed permit
before AuthorizeLaunch or helper startup. Native readback occurs outside the
resource writer transaction. The final transaction MUST revalidate the original
input, open scope, Ready state and absence of association, then commit before
returning the permit bound to the resource endpoint, full ref, native key and
digest. Duplicate, recovered and lost-reply paths MUST NOT issue another permit.

This transaction orders admission against the resource cancellation fence. If the
fence wins, live association refuses. If association wins, cancellation MUST read
and follow the retained exact native key after fencing the resource. It MUST NOT
claim that cancellation necessarily preceded process startup. The native reducer
still owns at-most-once launch intent; the original native continuation still
checks its original elapsed deadline after association.

Finite native Authority is canonical generation, deadline and budget data.
Generation is positive and bounded; budget is at least one second and strictly
below the retained finite ceiling. The absolute monotonic deadline MUST be
nonzero, but may be negative. These syntax checks do not establish freshness.
Copyable Gleam permit values remain local to the trusted first-Submit continuation.

The [live-admission review](../docs/review/distributed-live-compile-admission.md)
records the independent gate and corrected prose finding. Production native
routing and physical service assembly remain required before product acceptance.

## Addendum: Complete command routes on native exchanges

An owner reservation for a physical command MUST retain its complete CommandRef
alongside the native key and exact Prepared value. Challenge, Submit, Query,
Stdin, Cancel and DurableReceipt MUST use that same route, including cancellation
after the original network worker stops.

The command frame wraps the canonical full reference and existing native
envelope under `loom.remote.command/1`. Its decoder MUST enforce the existing
aggregate frame bound, native Prepared bound, authenticated scope and operation
correspondence. A response MUST carry the original full reference and transport
generation. A plain native response or changed reference is uncertain, never an
implicit fallback to the ordinary native lane.

Framing establishes correspondence only. The server MUST separately enforce the
original live-claim admission rule and exact retained association for historical
controls and duplicate Submit readback. The owner codec and dispatcher implement
this route; the current server reader remains native-only until that admission
assembly is installed. The [routing review](../docs/review/distributed-physical-command-routing.md)
records the real TLS controls and their integration limits.

## Native command admission retains live preparation custody

The native admission engine accepts physical Compile commands through an internal
context bound to the complete command reference and concrete resource/native
journal endpoints. A live context MUST derive its original input from the actual
preparation claim. A historical context MUST NOT create a challenge or submit
fresh native work. Compile commands MUST retain finite original authority.

First submission retains the native request and authority and commits native
admission before asking for the resource association. The engine MUST obtain the
original claim's committed live permit and compare its exact endpoint, reference,
key and digest before native launch intent. Waiting for that permit MUST NOT
renew the original deadline. Cancellation committed before association prevents
the permit; cancellation afterward can race native startup.

Every historical Query, Cancel, Stdin and DurableReceipt, and both duplicate
Submit paths, MUST validate the exact retained resource association before
returning native evidence or applying an effect. Matching physical coordinates
alone are insufficient when two services have different parents. Challenge
tickets MUST retain the closed native/command route and complete command
reference. Server-side forwarding and whole Compile ownership remain separate
assembly obligations.

## Addendum: Atomic first preparation and cancellation

The original whole Compile service MUST admit preparation through one transaction
that inserts absent input, reserves its complete lifetime capacity, and enters
Preparing before returning a live Claim. Only a successful commit of that absent
row may return fresh authority. Every matching existing row, including Reserved,
MUST return historical status without a Claim. Recovery MUST NOT combine the
separate reservation and claim APIs to reconstruct a live continuation.

Cancellation MUST fence the original input before following a retained native
association. Missing input requires bounded insertion and an Unknown phase in
the same transaction. Existing Reserved, Preparing and Ready rows become Unknown
without discarding Ready, native association or completion evidence. Existing
Unknown and Released rows return their checked history. A sealed scope may
satisfy absent-input cancellation only after excluding an address collision.

Both transactions MUST compare the complete immutable identity and input before
returning history. Failed or ambiguous COMMIT MUST return uncertainty and fence
the endpoint, never a fresh Claim or positive fence acknowledgement. A committed
resource fence does not establish native retirement: association may have won
the race, and cancellation must then follow that exact retained native command.

## Addendum: Preserve the original Compile elapsed deadline

The live Compile owner MUST capture one deadline at original admission in the
native service's monotonic clock era. Every live command context MUST retain that
same value. Native authorization MUST clamp its challenge-derived deadline to
the original Compile deadline before retaining Request or Authority, then use
the clamped value through association, launch checks and the native watchdog.
Preparation and custody waits consume that same lifetime.

Zero is invalid; negative values are allowed in a negative monotonic clock era.
A later remaining-budget value, owner wall-clock adjustment, duplicate exchange
or recovered record MUST NOT renew this cap. Selected native wall and cleared
Prepared bytes remain unchanged. Ordinary native requests retain their existing
deadline rules; historical contexts grant no fresh authority.

## Addendum: Trusted executor distribution

**Decision: accepted by the owner, implementation pending.** Executors join
TLS-protected Erlang distribution within the orchestrators' administrative
trust domain. TLS BEAM is the single supported inter-node executor transport.
This supersedes the executor-distribution prohibition and custom socket TLS
mechanics above. The satellite's local Unix capability socket and the native
sandbox-helper protocol remain separate boundaries.

### Trust and membership

An enrolled executor VM is a fully trusted runtime peer. A compromise of its
runtime or OS account can reach the connected owner runtime through ordinary
distributed Erlang facilities, including remote process creation. TLS protects
the connection against outsiders; a closed Loom endpoint, an executor role or
a hidden node does not isolate the owner from a malicious connected executor.
Administrative enrollment MUST make that trust explicit.

Both ends MUST use `inet_tls_dist`, validate the certificate chain and require
the configured peer identity and certificate pin. The server MUST require a
client certificate. Nodes MUST reject plaintext distribution, unconfigured
peers and a wrong peer certificate issued by the same CA. Node names and the
finite allowed peer set come from administrative configuration; model or
request content MUST NOT create atoms or change membership. Connections are
explicit, with hidden executor nodes and no automatic mesh expansion.

An executor role starts workspace/execution services and their journals. It
does not start a provider or session owner, and membership does not make the
executor a Raft voter. Raft membership requires separate administrative action.
Model-authored satellites MUST remain distribution-disabled. Their launch
environment, arguments, readable mounts and inherited handles MUST expose no
distribution cookie, private key or other membership credential.

### The endpoint and durable identity

The endpoint accepts a closed, versioned message vocabulary. Requests retain
their full immutable service/command/native identity and canonical input bytes.
No message ships an arbitrary function, closure or module/function invocation.
PID/reference correlation identifies one live endpoint incarnation only; it
MUST NOT replace a durable request identity or grant authority after reconnect.

Canonical request, completion and receipt encodings remain stable where they
define durable identity. Inter-node socket length prefixes and passive-read
loops are removed after all consumers move to BEAM. Bounded transfer reducers
may carry large payloads in chunks; they do not create a second effect identity.
There is no dual-transport selector or automatic fallback. A future executor
written outside the BEAM would need an explicit adapter or another reviewed
transport proposal, not an untested compatibility path in this implementation.

Every sender MUST validate aggregate bytes and structural bounds before send.
Receivers MUST validate the closed shape and canonical content before service
admission. These are cooperative application limits: a compromised connected
VM can allocate distribution terms before the receiver validates them. The
limits MUST NOT be described as a hostile-peer memory-isolation boundary.

### Credits, observation and recovery

Endpoint admission MUST bound outstanding operations and retained request and
reply bytes. A caller timeout or process DOWN does not prove the service has
consumed or withdrawn its queued request, and MUST NOT return that credit.
Control traffic has reserved capacity independent of ordinary data consumption.
The actor managing cancellation MUST NOT block on a distribution send.

Admitted capability calls retain their original reply reservations through
Running, ReplyReady and Sending until the final recipient consumes the exact
reply. A full transport window leaves a ready result in its existing bounded
slot; it is neither a stream failure nor permission to drop a result. A stale
ACK or duplicate completion cannot release another delivery's capacity.
Logical frame limits, cumulative stream quotas and original deadlines still
apply. Terminal success MUST NOT discard preceding admitted replies.

A successful BEAM send is not durable admission or consumption. `nodedown`,
remote process DOWN and observer expiry establish loss of observation only.
Original executor deadlines continue locally; native cancellation and witnessed
retirement remain independent obligations. Reconciliation queries the original
retained identity and cannot repeat preparation, renew a deadline, replay an
effect or recreate a satellite token. Owner receipt still commits before ACK.

### Replacement gates

The implementation MUST exercise actual TLS-distributed BEAM nodes, including
missing/wrong certificates, same-CA wrong identity, plaintext refusal, incompatible
endpoint versions, bounded concurrent admission, delayed consumption, disconnect
after possible submission and exact historical reconciliation. Satellite launch
tests MUST establish credential exclusion and distribution-disabled execution.
Existing socket fixtures remain historical component evidence until replaced;
their passes do not validate this new transport.

The separate-host product gate remains unchanged: ordinary tools, Compile,
Launch, owner capabilities and LSP must use one executor-resident workspace,
with owner canary files proving no local fallback. Formal-model correspondence
must identify the new transport events and preserve the admission, receipt,
discharge and retirement distinctions. No transport fixture alone completes #697.


## Addendum: scoped endpoint and native lifetime

**Decision: accepted by the owner; implementation and real-peer verification
remain required.** One node endpoint owns six transport credits and at most
sixteen immutable scope registrations. A temporary local scope owner is part of
each concrete registration. Closing that scope MUST acknowledge its permanent
admission fence before orderly service teardown. Applied owner DOWN also fences
the row. A reservation that precedes the applied fence can retain uncertainty;
no crash path promises zero capacity loss.

The six credit records are the sole allocation state. Available means no original
run owns the credit. Assigned retains the exact row and original correlation.
Unusable retains that assignment when custody is unresolved, or no assignment
when an idle credit dies. A completion MUST match both concrete credit and
original correlation. Only an actual service answer plus managed transport
AllDelivered, or a joined run with no service handoff, can release an assignment.
Timeout, DOWN and an unrelated completion MUST NOT reconstruct capacity.

The local administrative fence operation acknowledges the exact immutable row.
The bounded drain snapshot is Busy for an active row or an assigned original
run, Uncertain for unresolved unusable custody, and Drained only for a fenced row
without either obligation. These results establish transport/ask state only.
They do not establish native retirement, physical cleanup or journal release.
Closed rows remain tombstones; no unregister, rebind or automatic restart is
introduced.

A scope close MUST keep reply-producing services alive while waiting for original
transport drain. Its finite budget reserves time for continuation cancellation,
physical cleanup and native retirement even after a failed fence or expired
poll. Journal release follows all required witnesses. Closing one scope MUST NOT
stop the shared endpoint or a sibling's native pool.

The native service MUST retain its original close disposition independently of
later durable-confirmation failures. A successful native close ends its actor;
subsequent remote shutdown uses that retained result instead of closing the dead
actor again. An outward error after native success MUST NOT discard the result.
Repeated close may finish only the original durable confirmations. Native
uncertainty stays uncertain, and native DOWN is never a retirement witness.

Historical missing or conflicting command identity MUST be a definite refusal
after its metadata worker has drained. Genuine journal, transport or native
uncertainty remains conservative. The regression MUST pass through the actual
command endpoint and prove that a later valid operation can still use its
metadata slot and transport credit.

The [lifetime design](../docs/design-notes/distributed-scope-lifetime.md) and
[bounded model review](../docs/review/distributed-scoped-drain-model.md) record the
rationale, failure traces and proof limits. Actual TLS peers must connect those
modeled events to concrete queued asks, producer joins and native outcomes.


## Addendum: complete code-mode reports

**Decision: the owner accepted bounded previews with durable complete-value
references. The following mechanics passed independent design review;
implementation and executable correspondence remain required.** Managed
code-mode results retain a complete canonical report in their original owner
SQLite tool row. Ordinary tools keep their existing final codec and allowance.

The report MUST separate the program's Outcome body from owner-produced metadata.
The Outcome preserves the existing success value or error message/details,
including binary values and non-string map keys. It contains no capability token
or authenticated channel envelope. Typed metadata retains the manifest hash,
build/node enforcement and complete existing bounded call log. Program content
MUST NOT supply those owner observations.

The version-1 bundle is `LOOMRV01`, two big-endian u32 segment lengths, then
canonical terminal and metadata bytes, with no trailing data. Terminal bytes are
bounded at 16,777,216, metadata at 262,144, and the whole bundle at 17,039,376.
SHA-256 binds all bundle bytes. The original cap frame limit remains unchanged;
its enclosing frame still consumes part of that ceiling.

Before fresh admission, trusted assembly MUST pin `CodeModeReportV1` and reserve
17,301,648 final bytes under the existing global owner quota: the complete bundle,
262,144 final JSON bytes and 128 stored digest/profile bookkeeping bytes. The
reference URI itself is part of final JSON. Original request, identity and child
allowances remain separately charged. No later result or retry can enlarge the
profile. Original call ID/name together MUST fit an 8-KiB encoded allowance before
admission, and the final timestamp is a nonnegative u64. Arbitrary extra details
cannot enter this closed final schema. Ordinary profile admission remains
unchanged.

Terminal admission and final retention MUST use the same separate fixed report
profile: depth 254, 65,536 total nodes including map keys, at most 65,536 array
elements or 32,768 map entries, and scalar/aggregate bytes within the terminal
ceiling. These are new shape constraints beyond the earlier cap frame byte/depth
limits. Raw scanning precedes decoding; structural bounds precede encoding.
Canonical equality, UTF-8, finite numbers, unique keys and complete consumption
are required. The smaller native MessagePack profile MUST NOT be widened.

Metadata has depth 16, at most 8,192 nodes, 128 entries per container and
8,192-byte strings. Each enforcement stage has at most 128 applied/skipped
entries together and 65,536 canonical bytes. The call log keeps its existing
128-record and bounded field contract, with nonnegative u64 counters/times.
Its schema is typed; only the program's value/details remain arbitrary values.
Invalid producer metadata cannot be silently truncated into successful custody.

The original pinned owner first commits the complete report and returns an
internal reference. The renderer then creates a preview of at most 4,096 UTF-8
bytes without rendering the full value as JSON. Final commit MUST independently
validate the exact original identity, profile and report reference before
acknowledging the final ToolOutcome. A crash between these two commits leaves
unknown final outcome with retained report history, never reconstructed final
authority or permission to rerun the program. Retention failure MUST keep the
original run unresolved; a later generic diagnostic cannot discharge it.

The report-bearing final has exactly
`{kind: "code_mode_report_v1", reference: <canonical URI>}` in its structured
details. Its original call ID and name are unchanged; `is_error` MUST agree
with the retained Outcome. A trusted refusal before any terminal Outcome uses
exactly `{kind: "code_mode_not_run_v1", stage: "vet"}` or stage `"compile"`.
Only the actual host vetting or compilation refusal branch may produce that
variant. It MUST have bounded text, `is_error` true, and no retained report.
An arbitrary ToolFailed, satellite failure or program Errored result MUST NOT
be recast as this no-terminal refusal. These variants preserve the existing
independent wrapper-drain and physical-child cleanup requirements.

Owner format 5 stores the profile, allowance, report and digest. Scalar headers
and quota checks precede large BLOB reads. Reopen validates each report's complete
canonical bytes, digest and original binding, then the custodian validates its
final-reference association before publishing admission. Format-4 files are
refused unchanged. The owner connection sets and reads back
`PRAGMA synchronous=FULL` alongside WAL; process-crash tests do not establish
physical power-loss behavior.

Exact session readback plus the existing run/physical discharge prerequisites
allow collection to release unused reservation. Collection MUST retain the
report, digest, identity and actual byte charge with the permanent fence. Unknown
rows retain their full allowance. The owner database remains a durable session
companion for the lifetime of transcript references, including close, archive,
reopen and compaction. Transcript-only export does not transfer its contents.

The fixed reference is
`result://<session-uuid>/<result-entry-uuid>/<sha256>/<byte-length>`, bounded at
160 bytes. It is not a filesystem path or read credential. The proposed
`cap/report.load_result` uses an authenticated owner-local `report.result_chunk`
door, including with registered remote workspaces. Session, original entry,
digest and length MUST agree before a bounded SQL chunk read. Known metadata
returns through closed public types rather than arbitrary value maps.

At most 261 chunk calls may be admitted across all references in one invocation.
Each response carries at most 65,536 payload and 512 envelope bytes, for at most
17,238,528 aggregate serialized reply bytes. Existing deadlines, credits and
pooled budgets remain authoritative and are never refreshed by retrieval. The
helper concatenates its bounded chunk list once and performs bounded decoding.
Only hosts with the real owner door installed may advertise this capability.

The [complete-report design](../docs/design-notes/distributed-final-results.md)
records tests and the OwnerDischarge model extension. Report commit, final owner
acknowledgement, channel consumption ACK, child receipt, producer drain, native
retirement and exact session commit remain separate facts. No one of them
substitutes for the others.
