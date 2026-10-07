# executor

## Purpose

The executor service as a process of its own (issue #696, phase S4). The
service, pool and `Dispatcher` live in `packages/broker`
(`broker/executor`, `broker/dispatch`); this package is the thin
entrypoint that boots them without the harness. It exists as a package
for one reason: its dependency list is the compile-time proof that the
service needs no session runtime, provider, web view or daemon. It depends on
`broker`, `core`, `codemode` and `telemetry` (for `log.discard()`), plus `weft`, `argv`,
`envoy`, `gleam_json`, `gleam_time`, `gleam_erlang`, `simplifile` and
`sqlight_loom`, `parrot`, `tools`, `lsp` and `codemode`, and never on `host` or `client`.
`tools` supplies the closed semantic workspace host and codec; it imports
`broker` but does not depend on this package, so this edge has no cycle.

The remote components now join pinned TLS, registration, native execution
and durable custody in component fixtures. The shipped daemon still needs
explicit remote deployment assembly. The pure
`executor/remote/{identity,admission}` modules provide validated names and a
bounded admission/custody reducer for #697. `executor/remote/journal` adds
serialized SQLite persistence over that reducer. The native service consumes
its decisions through the existing broker executor; local deployment defaults
remain unchanged.
A standalone executor has no caller until the distributed-runtime epic
(#697) supplies a transport, and that work implements
`broker/dispatch.Dispatcher`, which is the whole adapter: a remote
transport is a `Dispatcher` whose `start` forwards a `Dispatch` to a peer.
No second type names it.

## Trusted TLS BEAM transport

`remote/distribution.Config` describes finite administrative node names, exact
certificate pins and private credential paths. `start` admits a fresh TLS-only
OTP VM before endpoint publication. Its opaque `Membership` owns the installed
finite node table; `peer` resolves an opaque `Peer` from that table without
connecting. The erlexec child starts with its private cookie directory as HOME;
boot arguments restore the operator's OS HOME after OTP captures its init home.
The private cookie is checked before a listener starts. A successful membership
exposes the canonical certificate, key, CA, cookie and TLS-options paths through
`protected_membership_paths`; embedding sandbox registration must protect them.
Membership itself does not establish that sandbox assembly performed this step.

`remote/beam_endpoint.Registration` binds that original owner Peer to concrete
native, optional semantic-workspace and optional whole-Compile service handles,
and their original local lifetime owner PID. The endpoint installs that owner's
monitor before making the registration eligible. Only trusted local `register`
adds a binding. One literal node-wide rendezvous
owns at most sixteen lifetime registrations, sharing four data and two control
credits across all scopes. `remote/internal/beam_protocol` selects a closed
native, workspace, Compile or original-command route with the unchanged full
scope, generation and canonical payload. No peer supplies a closure or MFA.

Each credit has stable service-reply Subjects. Its managed transport task sends
one chunk and waits for consumption before sending another. Caller death ends
transport observation, but a service ask already queued keeps its credit until
an actual service answer and the transport's `weft.AllDelivered` witness both
arrive. A lost service or run retires that credit; endpoint restart alone cannot
reclaim native custody. The embedding subtree must be Temporary and separately
prove native quiescence before replacing a generation against retained journals.
There is no in-place generation update or registration removal.

`fence(server, exact_row)` permanently closes that original row to new exchanges.
An observed lifetime-owner DOWN performs the same transition. The six canonical
credit records retain Available, Assigned(original row and correlation), or
Unusable(original assignment, when one existed); there is no replacement credit.
A delayed release must match both the original row and correlation. Normal
credit death while idle reduces capacity; death while assigned keeps that scope's
uncertainty even if a later release arrives.

`inspect_drain` reports Busy for an active row or its outstanding assignments,
DrainUncertain for a fenced row with an unusable outstanding assignment, and
Drained only for a fenced row without either. An unavailable endpoint returns
Error(Uncertain). This snapshot covers transport and queued service asks. It
does not establish native retirement, physical resource cleanup or journal
release. Host assembly must still order those obligations before generation
replacement.

`remote/dispatcher` now uses this BEAM endpoint. The old socket modules and their
fixtures remain during migration; they are not an additional supported deployment
transport. Package gates remain incomplete until all affected fixtures migrate.
See the [transition record](../../docs/review/distributed-beam-transport-transition.md)
for exact tested and open boundaries. Shipped daemon assembly, separate-host
routing and actual satellite credential exclusion remain open.

An admitted executor is a fully trusted distributed runtime member. TLS and
closed application messages do not contain a compromised member. Executor
membership does not make it a Raft voter, and model-authored satellites must
remain outside distribution.

## Permanent generation custody

`generation_registry.Store` retains the original connection-owning weft actor,
its incarnation and fixed limits. The native SQLite connection stays in private
`Context`; typed work messages serialize transactions, and release waits for
both the original close acknowledgement and normal actor exit. Closed or dead
handles return Uncertain. No registry address resolves a replacement actor.

`admit` returns `Fresh(StartupClaim)` only after the first insertion commits;
exact retries return historical `Retained`. `prepare_publication` commits
Publishing before returning its original `PublishingPermit`. Close commits a
permanent fence even before first activation, in which case it retains a
NeverStarted record. Recovery marks unavailable original startup custody Unknown
and keeps its live slot charged. History grants no new startup permission.

`retire_started` validates original physical witnesses before committing and
reading back `RetirementRecord`. `remove` additionally requires the exact
original endpoint removal acknowledgement before the Removed commit releases a
claimed live slot. `attest_predecessor` retains the original owner's close
attestation; only the checked immediate successor can cite both owner and node
records. Limits are sixteen live or unretired generations, 4096 permanent
identities and 256 MiB of reserved logical metadata. Tombstones retain row and
byte charges. Named SQL and its generated bindings own all durable transitions.

The DAL's trusted witness callbacks are integration obligations. Production
`scope_admin` must authenticate the configured owner, consume each original
claim and permit once, order register/fence, verify actual original physical
joins and endpoint removal, and validate full owner attestations. This registry
component does not implement deployment, history transport or that assembly.

## Registered LSP content (protocol 076)

`remote/lsp_wire` encodes all ten finite Request variants and thirteen complete
Result variants using `lsp/query` and `lsp/observation`. Header, request and result
profiles run before MessagePack term allocation. Complete results retain shared
row and byte accounting, including nested sites and partial rename landings.
Observation separately charges its bounded scope shell and preserves every
original outline entry, including aliases resolving to the same document.

Lease, capture, timed invocation and command adapters retain the complete
`core/lsp_command` identities. Timed encoders hash the actual canonical parent;
result envelopes compare the exact retained timed header. AfterWrite compares
the body's original write against its full PostWriteControl reference. Decoding
history grants no effect authority. Durable capture, clock authentication,
consumed helper joins and endpoint assembly remain separate implementation work.

The existing local collector fills omitted Observe server/root fields before
returning Batch.requested. The registered adapter must restore the original
request echo while retaining the canonical Batch.root and selected profile.

## Closed native command routing

`remote/wire.CommandEnvelope` carries exactly one full `core/command.CommandRef`
and the unchanged native Envelope as a MessagePack value. Its canonical shape is
`[1, "loom.remote.command/1", canonical_ref_json, native_value]`. Native schema and
body tags are unchanged; the aggregate still has a 256-KiB frame, 2048 nodes and
depth 16, while Prepared has its existing separate 128-KiB encoding bound.
`command_envelope` checks native role, full scope, operation and Submit step;
Hello, CloseScope and ScopeRetirement cannot be wrapped. `command_ref` and
`native_envelope` expose the validated values, and `encode_command`/
`decode_command` enforce bounded canonical framing. These checks establish shape
correspondence, not durable ownership of the native UUID or Prepared digest.
Authenticated server assembly must prove the complete retained association before
forwarding every key-bearing control or returning another native request's bytes.

`remote/beam_endpoint.exchange_command(config, ref, body)` uses the closed
command route over authenticated distribution. Its request header retains the
original owner, full scope and generation. Replies must carry the exact full ref
and generation; plain replies and changed refs are uncertain. The endpoint
forwards the unchanged command envelope to the concrete native service, which
checks the retained resource association before accepting key-bearing controls.

`remote/dispatcher.CommandReserved(key:, prepared:, ref:)` retains the complete
service command route beside the original native UUID and immutable Prepared.
The existing `Reserved(key:, prepared:)` callers keep the native lane. Worker and
parked guarantor retain the same closed route through Challenge, Submit, Query,
Stdin, output, detached Cancel and DurableReceipt. The command reservation's
native ChildOrigin must equal the original Dispatch context, and physical
correspondence is validated before the guarantor permits the first send. No
retry creates another identity, clearance, grant or deadline.

`command_route_test` uses fixed transport-only peers over real TLS BEAM to check all routed bodies and both dispatcher paths. Those peers do
not admit a service or launch native work. Existing native fixtures exercise the
production native server separately; production Compile assembly remains open.

## Closed Compile completion

`remote/compile_completion.CompileCompletion` retains the original whole Compile
ServiceKey and a closed pre-native error, native-associated error or successful
executor artifact. Success accepts admitted `service_resources.CompileLocations`,
actual native RequestKey/Digest and exact terminal bytes, plus physical
`compile.BuildProducts`; it derives every ExecutorArtifact field and the complete
`enforcement.of_call` report. There is no local Artifact or separate report
argument. The native exit must have zero code/signal and no timeout/cancellation.
Products use the exact admitted root plus `build.beam_directory` and a canonical
`sha256-` fingerprint; the opaque issuer ID is the original Compile UUID.

The canonical versioned MessagePack frame embeds core's complete ServiceKey and
reuses journal_codec.Admit bytes solely as native identity/digest encoding, with
scope supplied by the checked whole original key. This reuse applies no reducer
and proves no admission. The native UUID is independent of the original Compile
UUID; its scope/operation must match. Its Prepared digest never substitutes for
an input or terminal digest. Native terminal bytes remain exact and canonical.
Outer preflight limits are 256 KiB, 2048 nodes, depth 16, containers 128, strings
8 KiB and binaries 128 KiB; terminal bytes stop at 32 KiB and every CompileError
text at 8000 bytes before retention. Native-derived Unreported text is also bounded.

`decode(enrolled, expected, bytes)` pins the complete expected original identity
and enrollment, reuses the native terminal decoder and readmits the closed
outcome, then checks exact canonical bytes. `original`, `native_association` and
`compiled` expose historical comparison evidence. The actual authenticated native
journal readback, matching Prepared step, physical hashing and live allocation
custody remain caller duties. Recovery grants neither a claim nor authority to
reissue an artifact. The codemode dependency supplies these existing concrete
product/report/Ready types and fixed layout; codemode has no executor dependency.
No resource effects, journal transitions or production service wiring occur here.

## Physical Compile observation

`remote/compile_observation.observe(resources, original)` derives full native
association, pinned enrollment and retained CompileReady from one resource
journal. Its opaque Observation captures the original ServiceKey, exact Ready
allocation, independent native key/Prepared digest, unchanged terminal bytes and
ordered `tools/tool.Collected`. Callers cannot substitute another root or key at
`finalize(observation)`. Missing association is pending. Missing original input
and journal errors remain typed failures; Uncertain must end continuation polling.
Associated without Ready and committed terminal evidence without its exact payload
refuse. Terminal payload retained before the reducer COMMIT remains pending.

The adapter folds the native sink's zero-based contiguous Output ordinals per
stream, preserving arbitrary bytes and sticky truncation, including terminal
truncation flags. Existing native decoders plus canonical re-encoding check the
frames. A matching committed Terminal/Refused/Retired/RetiredRefusal digest is
read before its immutable payloads and required before exposing Observation. This
order avoids a terminal COMMIT racing an earlier empty payload read. No native
output or terminal receipt bytes
are rewritten. The existing journal inventory bounds decoded aggregate material;
this module introduces no queue, database, transport or admission authority.

`finalize` calls the shared physical `codemode/build.finalize` and constructs
`compile_completion.successful` or `failed_native` from the captured evidence.
Only the original live continuation may consume it once and commit completion
before publishing success. Gleam values are copyable: this is a caller obligation,
not linear permission supplied by Observation. Queries and recovery must never
perform finalization. Source/filesystem custody after cancellation stays with the
original continuation. The internal `bounded_error` preserves all CompileError
variants while bounding completed human-readable text to 8000 UTF-8 bytes,
including a visible truncation marker. Native receipt material stays exact.

`compile_observation_test` uses real SQLite journals and a compiler-produced fixed
`loom_satellite` test module, then the actual product flattening and independent
fingerprint path. It covers the terminal-payload/COMMIT gap, missing or changed
committed payload, ordinal gaps, binary stream/truncation preservation, cancelled
zero and other failed verdicts despite valid products, partial products, and
Unicode/prefixed seed errors. These are component fixtures with synthetic native
verdicts; they do not establish jailed compiler execution or whole remote Compile
assembly. The original whole Compile actor owns that integration boundary.

## Resource preparation and closed service custody

`remote/resource_journal` owns one SQLite actor/database for original preparation,
immutable native association and closed Compile or Launch completion. Format 3 reserves
663826 bytes plus exact address/header/input lengths per lifetime row before the
first preparation Claim: full Ready, 8-KiB CommandRef, canonical 106-byte native
Admit identity, independent 36-byte native UUID, 128-KiB Prepared, 256-KiB outer
completion and its digest. Released rows and receipts never return capacity.
These logical limits do not bound SQLite pages/WAL, RSS or scheduler delay.

`fresh` and `recover` pin enrollment, row/byte limits and a concrete native
`journal.Journal` with the same full scope. Recovery reads a guarded format scalar
before new columns and explicitly refuses formats 1 and 2; this unreleased component has
no silent migration. Native identity encoding omits scope, so the pinned scope is
checked separately. Recovery never creates another preparation or native permit,
wall, token, UUID, clearance or original whole-service deadline. Trusted physical
assembly still owns source re-vetting, artifact verification, live caller authority
and at-most-once consumption of Gleam's copyable Claim.

`associate_native` reads canonical retained Request and actual exact-key admission
from the pinned native journal before acquiring the resource writer lock, then
revalidates the original row and independent native UUID uniqueness. Prepared's
full step, scope/operation, registration, closed CommandRef, literal argv/cwd and
ordered environment bind the retained input and Ready via the shared pure compiler
factory. The actual cleared policy remains unchanged; the existing pure policy
meet refuses widening against compiler requirements, with order-insensitive
comparison only for protected paths and policy environment permissions. This is
neither filesystem canonicalization nor a second clearance.

`commit_compile` requires the retained association and exact canonical native
Terminal bytes plus matching committed terminal/refusal/retired reducer evidence.
Request without Admit and terminal payload before reducer settlement cannot
advance custody. Prepared, terminal and completion have separate hashes.
`fail_preparation` accepts a Before-native result only through the original live
Preparing Claim before Ready, atomically retaining completion and fencing late
Ready. Missing native evidence after Ready remains uncertainty, never a proof
that Submit was impossible.

`inspect_compile` returns `CompileRetained(RetainedCompile, OuterReceipt)`, including
recoverable Before-native bytes after a lost reply. Exact association/completion/
ACK retries use committed resource history before requiring a live native endpoint.
The opaque retention handle follows COMMIT and checked historical recovery only.
`acknowledge_compile` records an authenticated original-owner durable exact-byte
receipt; the adapter must commit before sending that ACK. It creates no native
receipt or retirement. Resource cleanup, native receipt/retirement and outer ACK
stay separate. This component creates no physical resources and enables no remote
production service by itself. Compile-specific APIs remain role guarded.

`remote/launch_completion` retains the full original Launch key and either a
witnessed before-native refusal or exact independently settled native terminal.
Enforcement derives from those canonical terminal bytes, bounded to 32 KiB,
inside the existing 256-KiB completion slot. The codec stores no program outcome,
report artifact, token, PID, socket, Claim or activation permission.

The private retained slot is `NoCompletion | CompileCompletion | LaunchCompletion`.
`inspect_launch`, `commit_launch`, `fail_launch_preparation` and
`acknowledge_launch` expose typed `LaunchStatus`/`RetainedLaunch` data. A definite
refusal uses the original live Claim and atomically closes phase 1 or 2 while
requiring no retained association. The native Command route must commit its
association before receiving the opaque permit and launching. That ordering
excludes an existing permit when refusal wins and denies every future association,
including a concurrent readback. The owner still owes an actual definite refusal
continuation; missing replies, caller loss and timeouts remain uncertainty.
Post-Ready Launch refusal preserves the exact original Ready paths for cleanup.
Compile retains its stricter pre-Ready refusal invariant.

Shared native association dispatches on the original role. Launch follows one
bounded producer edge on the same SQLite connection, restricted to Compile
before reading its body. Full original input, enrollment and retained canonical
successful completion must pass `service_input.admit_launch`; a supplied
`compile.Compiled` cannot replace that readback. `service_command.launch` derives
the actual finite-wall SatelliteCommand from retained Launch resources. Exact
Prepared, policy, argv, ordered environment, cwd, step, scope, registration and
UUID ownership checks apply to both roles. Historical association supplies data
and never a second permit. Native terminal readback releases the resource writer
transaction before asking the native actor, then revalidates on the same original
resource row. No resource actor synchronously asks itself for a producer.

Named Parrot/sqlc queries persist all rows and enforce checked RETURNING cardinality;
handwritten SQL is confined to transaction/PRAGMA control and generated schema
installation. SQLite fault controls exercise split commits, suppressed writes and
real deferred-FK COMMIT failure. A discarded reply control is a simulation, not
power-loss testing or a two-host acceptance result.

## Key Types

- `executor.main()` — the entrypoint (`gleam run`). Helper path from
  argv[0], else `LOOM_EXEC_HELPER`, else `bin/loom-exec`. Boots, prints the
  census as one JSON line (after the smoke, so the features are the
  helper's own hello), runs `true` jailed through the broker and service,
  drains, prints `drain: ok`, and exits 0 only if every step succeeded.
  `smoke` refuses a degraded result, so a host without bwrap fails it. Failure exits 1 by the entry process killing itself, which
  adds no `@external`.
- `executor.{Config, Standalone}` — `Config(helper, scratch, pool_size)`;
  `Standalone` is opaque (pool, service, broker, incarnation).
- `executor.{boot, census, smoke, drain, incarnation, service_of}` — the
  steps. `drain` is `broker.stop` then `broker/executor.close`, and its
  answer is the pool's native-exit verdict unchanged.
- `executor.{choose_helper, base_policy, census_line, mint_incarnation}` —
  the pure parts: argv, env, default; scratch writable with network off;
  the JSON line; wall-clock microseconds.

- `executor/remote/identity.{ExecutorId, WorkspaceId, RequestId, Epoch,
  Digest, Scope, RequestKey}` are opaque and smart-constructed. Scope binds
  a core session ID, provisioned workspace/executor labels and both epochs;
  RequestKey adds a core operation ID and a validated UUIDv7 request. Names
  grant no authority. The module generates no IDs and uses no clocks.
- `executor/remote/admission.{Book, Capacity, Evidence}` are opaque.
  `admit` reserves a lifetime evidence slot; `reduce` applies typed
  lifecycle events; `inspect` retrieves retained evidence; `close`
  irreversibly blocks new admissions and first launches. Phase separates
  Admitted, LaunchIntent, Refused, Terminal, Retired and RetiredRefusal.
  Launched work keeps independent NativeCustody and OwnerReceipt facts;
  Refused proves NativeRetired by construction and still keeps OwnerReceipt.

## Relationships

Depends on `broker` (`broker`, `budget`, `census`, `exec`, `executor`,
`policy`, `token`), `core` (`clock`, `ids`) and `telemetry` (`log`).
`client` consumes its remote dispatch boundary for owner-side assembly. The pure identity and admission modules import only `core/ids`, each other
and pure stdlib modules, with no I/O, processes, FFI or Dynamic. The journal
imports those modules, generated `executor/sql`, `sqlight`, `parrot`,
`simplifile` and `weft/actor`; its private
actor owns the database connection. None of these modules implements or
changes the `broker/dispatch.Dispatcher` seam.
`make executor-smoke` builds the helper and runs the entrypoint; CI runs it in the jail job and `scripts/signoff.sh` in its
enforcement lane, both of which have bwrap.

## Traffic

The pure remote foundation has no actor, store or wire traffic. Typed
`admission.Event` values reduce an already admitted key into a
`Transition(next: Book, evidence: Evidence, effect: Effect)`.
`Effect.Launch(RequestKey)` is a decision for a future adapter, not a
native action. The journal persists these decisions but does not perform their native effects.

## Pure remote admission contract

An executor/workspace label is a case-sensitive 1..128-byte ASCII label
(`[A-Za-z0-9._-]`); provisioning must ensure uniqueness. Request IDs use
core's UUIDv7 representation without an entry-row meaning. Epochs are
positive and bounded to 2147483647; capacity is 1..65536 lifetime retained
keys. Digests are exactly 256 bits, supplied by a future adapter over
canonical request or result content. Arbitrary payloads are not retained.

Every request checks the entire scope, including both epochs. Exact
duplicates recover existing evidence even when full or closed; changed
request or terminal digests conflict. Only an open Admitted row can emit
Launch, and its successor already records LaunchIntent. Restored intent
never authorizes another launch. Native retirement may arrive before the
terminal result, but a connection drop is neither result nor retirement.

RefuseBeforeLaunch settles an Admitted row even after epoch closure. It
records the exact refusal digest with ReceiptPending in Refused, whose
absence of any launch intent proves NativeRetired. The owner must still
confirm its durable receipt before Compact produces RetiredRefusal. Once
launch intent exists, refusal returns LaunchAlreadyAuthorized, including
after recovery, native retirement, terminal settlement and compaction.
An unknown native-start outcome can never become a definite refusal.

Exact refusal retries preserve Refused or RetiredRefusal; changed refusal
or receipt digests conflict. ObserveTerminal is only for launched work and
is rejected against refusal evidence, even with a matching digest. The
separate compacted origins keep these compatibility checks meaningful.

Compact requires a terminal result, proven native retirement and the
owner's durable receipt of that exact result. It retains the key and both
digests in Retired or RetiredRefusal, never freeing capacity or enabling
replay. Saturation refuses new keys. No per-key deletion or epoch-reopening
API exists.

The future durable adapter must serialize against the latest committed
Book (or use successful CAS), persist each returned next state before any
admission/result acknowledgement or native launch, and perform a returned
Launch at most once. Transition values are duplicable; they are not linear
tokens. Recovery must load the committed book and reconcile custody without
replaying effects. A crash after committed intent but before native launch
may permanently prevent that launch. Owner receipt and native retirement
events depend on truthful evidence from the trusted adapter.

`new` is for an unused scope, never recovery. Disposing of an entire epoch
requires a permanent durable closure fence and settled custody/receipts
outside this reducer. The journal supplies the codec and database described below. Network,
authentication, scheduler and automatic failover remain outside these modules;
no remote execution is wired yet.

## Durable admission journal

`journal.fresh(path, scope, capacity)` creates only at an unused absolute
path. `recover` requires an existing exact scope/capacity binding and replays
the bounded command history through the actual reducer. Recovery exposes no
historical Launch. `release` closes the actor and its connection without
closing the authority epoch or asserting native retirement.

Static queries live in `src/executor/sql/custody.sql`; Parrot/sqlc generates
`executor/sql.gleam`. `sql/schema.sql` generates `custody_schema.gleam`. Run
`make gen-sql` after changing either source. Source parity tests catch drift;
the journal keeps only transaction and PRAGMA control as handwritten SQL.

A `weft/actor` serializes each handle. Every change also takes SQLite's
`BEGIN IMMEDIATE` writer lock, reloads a newer committed head, appends its
command and updates the metadata head in one transaction. Required WAL and
FULL synchronization precede use. The reply follows successful COMMIT;
independent opens therefore share database serialization. Exact duplicates
and no-change events append nothing. `inspect` reads current evidence under
the same writer discipline.

`journal_codec.Command` is Admit, Apply or CloseEpoch. Scope metadata binds
all identity fields and capacity, with an exact row count and encoded-byte
count. Each record is at most 138 bytes and the binding is at most 303 bytes.
A retained key reserves at most six changed records, plus one epoch-closure
record. SQL bounds rows and blob lengths before decoding. Replay checks
sequence continuity, counts, canonical encoding, valid transitions and the
absence of durable no-ops. Tombstones keep their lifetime capacity reservation.
These are encoded-history bounds, not an exact limit on SQLite page/WAL size.

Database failures close the endpoint. Uncertain may include a committed
transition; reply timeout abandons only the wait. Recovery inspects the
original key and never authorizes an execution again from retained intent.
A live returned Launch remains a duplicable value, so the trusted native
adapter must apply it at most once. The admission history stores request/result digests. The remote service also
uses the journal's typed payload API for exact requests, authorization, output,
terminal bytes and cancellation intent. Native retirement requires a live
physical witness: exact borrowed Launch helper retirement or the original
scope-owned pool drain. A recovered old incarnation remains uncertain.

The real SQLite regressions cover independent concurrent opens, restart at
each admission/custody phase, refusal provenance, corruption, bounds and
append/head-update/COMMIT failures. They establish journal behavior, not
power-loss testing, multi-host transport or native-process restart recovery.
An active WAL database requires a consistent SQLite backup cut for movement;
copying only its main file is insufficient.

## Authenticated transport primitive

`remote/tls` wraps OTP SSL with mutual PKIX verification and exact leaf pins.
Settings bound certificate sizes, handshake/frame/send budgets and a 256 KiB
frame ceiling. Prefix and body reads consume one deadline. TCP establishment
and TLS upgrade also share a deadline; expired upgrade attempts close the raw
socket. Passive framing and explicit ownership transfer do not create an
unbounded reader mailbox.

OTP native DNS can exceed its connect timeout, so a service must supervise
connection establishment with a bounded managed task. This primitive does not
claim a hard wall bound over the native resolver. Twenty-one real-network
regressions cover authentication, framing, slow peers and cumulative deadlines.
They do not establish the remote service or its end-to-end delivery guarantees.

## Remote native service

`remote/wire` defines closed versioned msgpack envelopes and total bounded
codecs. Its native payload and envelope decoders share the fixed raw
preflight in `core/bounded_msgpack`, mapping every refusal to `wire.Invalid`.
Encoding retains the existing encode-then-preflight behavior. `connection` applies
one supervised budget to pinned TLS establishment, framing and exchange. `listener` uses a fixed pool of one to four acceptors;
idle peers consume those slots until their finite deadline, without owning
native cancellation or journal custody.

`remote/registration` freezes full scope, canonical working roots, sandbox
ceiling and required enforcement into a digest. Its verifier checks the full
policy meet, canonical path spellings, environment allowlist and explicit wall
lifetime, without modifying already-cleared requests. The injected path resolver
runs on the executor. Missing optional mounts are conservatively refused.
The owner still owns approval and the pooled broker budget.

`registration.describe` projects exact `broker/enrollment.NativeFacts`, with the
full ceiling and enforcement demand but no canonicalizer callback. The total
conversion to existing `core/workspace.Scope` returns `Error(Nil)` on refusal
rather than bypassing its constructor. It preserves both original authority
epochs and changes neither registration digest bytes nor digest encoding.
Description does not establish the stricter enrollment isolation invariants;
the owner must construct and pin the exact bounded SessionEnrollment through
`broker/enrollment.new`.

`remote/service` serializes challenges, admission and native controls over an
already scoped journal and native executor. Exact payloads precede admission;
LaunchIntent precedes the single live launch. Cancellation can fence an ID
before Submit, without inventing a prepared command. Lost replies preserve the
original identity. A journal failure cannot prevent local cancellation or an
attempted witnessed drain, but never produces a durable retirement claim.

The internal `service.CommandContext` keeps the exact bounded original Input,
resource endpoint and full Compile CommandRef. `live_command_context` derives
Input from `resource_journal.original(claim)` and checks complete key equality;
`command_context` reads bounded historical Input without constructing a Claim.
Both bind the concrete native journal endpoint and full scope. The typed
`send_command_exchange` door enters the same admission engine as ordinary native
work. Tickets distinguish Native from each complete CommandRef; command Session
and historical Challenge/Submit refuse before native payload writes.

First command Submit keeps Request -> Authority -> Admit ordering, then obtains
and checks the resource actor's committed live NativeLaunchPermit before existing
AuthorizeLaunch/helper startup. The saved deadline is rechecked afterward without
renewal. Resource cancellation which wins association prevents a permit;
cancellation afterward may race OS startup. Every command Query/Cancel/Stdin/
DurableReceipt and both duplicate Submit readback branches require exact retained
ref/key/digest association. Unassociated remains uncertain; mismatches refuse.
Historical contexts can recover exact native evidence after reopen, without new
launch eligibility. `command_native_service_test` uses actual SQLite journals,
real fixed compiler execution and guarded helper checkout; it supplies component
evidence, while the listener/whole Compile assembly remains root-owned.

`remote/native` dispatches through the existing executor with strict native
start-window checks. Its Publisher factory starts the persistence sink inside
the native control actor. Linked parent lifetime handles startup failure and
crash; the final serialized End acknowledgement stops the sink normally. The
sink retains only the journal handle and bounded per-request counters/evidence.
No TLS writer owns native cleanup.

`remote/dispatcher` parks a guarantor before publishing Begin. Its owner
callbacks retain the original ChildOrigin and stable request UUID before a
possible send, then commit exact ordered output/terminal bytes before remote
receipt. Release ends only transient broker custody. A lost or refused stdin
acknowledgement becomes uncertainty, and an uncertain local input ordinal
never forwards again on retry.

Requests are bounded to 128 KiB, terminal bytes to 32 KiB, and encoded output
to 64 items/1 MiB per request. Stdin admits 128 items/1 MiB, at most 8 KiB per
item. Thirty-two active controls are distinct from retained retirement evidence:
completed calls free live slots, but never delete replay fences. Protocol-stream
truncation fails; these finite lifetime caps are not yet a general long-lived
LSP transport. Product registration/configuration, all workspace consumers,
and separate-host end-to-end assembly remain unfinished.

## Invariants

- No `client` dependency. A change that adds one defeats the package.
- The TLS FFI is confined to `internal/ffi_tls`; it wraps OTP SSL, which the
  available Gleam libraries cannot express. Admission remains pure.
- Helper locality: the helper is spawned by `exec.prepare_helper` on the
  machine running this process, as the harness spawns it.
- An incarnation is minted per boot from the wall clock in microseconds, so
  two boots in one VM never share one (the guarantee is per VM) and an `ExecutionId` of one boot
  never equals one of the other. The local entrypoint starts a fresh service
  on restart; it restores no executions. The remote reducer describes
  retained intent recovery, and the journal persists it. The remote service
  reconciles evidence without replaying launch intent; daemon assembly remains
  pending.
- Versions are compared with `broker/census.skew`; features are never
  refused.
- The scratch is removed only after a drain that returned `Ok`, and after a
  boot that failed before spawning; an unconfirmed drain leaves it.
- Tests skip with a `SKIP` line on stderr when the helper is absent or the
  platform cannot jail. On a host whose helper says `degraded` the real-helper
  test asserts the smoke's refusal instead of skipping. The incarnation and
  drain tests need no helper because the pool spawns lazily.
- Census features are empty (unknown) until the pool has spawned a helper.
- `skew` has no caller until #697 pairs two sides; the refusal is defined,
  not wired.

## Deep Docs

- [Executor architecture](../../docs/architecture/executor.md) describes the
  existing local service and native custody.
- [Distributed runtime](../../docs/design-notes/distributed-runtime.md) and
  [API plan](../../docs/design-notes/distributed-runtime-api.md) describe the
  intended later adapters and authority service.
- [Root guidance](../../CLAUDE.md) records package boundaries and style.


## Registered host lifetime and workspace custody

`remote/host.configure` validates service, registration and journal scope before
publishing one native route on the shared TLS BEAM endpoint. It replaces the
supplied verifier with `registration.verify`. The host owns the native service
and journal lifetime but borrows the node endpoint. Register and Fence originate
from the same host process, so an uncertain registration acknowledgement cannot
be overtaken by a later registration from that owner. Its supervision is
Temporary; restarting over uncertain native custody is not admission policy.

Explicit close fences the original row, quiesces the service, observes transport
drain while its producers remain alive, then requests the service's retained
original native-close proof and joins that service. Cleanup is attempted even
when an earlier fence or drain observation fails. Only success at every boundary
releases the journal. A lost original service also loses its in-memory native-close
witness; a second independent close cannot recreate it. Uncertain cleanup keeps
the journal and sibling registrations keep the shared endpoint. This owner
currently covers the native service; whole Compile and workspace lifetimes
remain separate assembly obligations.

`remote/workspace_journal` owns a separate SQLite connection through weft.
The source schema is `sql/workspace.sql`, queries are named under
`src/executor/sql/workspace.sql`, and `scripts/gen-sql.sh executor` regenerates
the Parrot/sqlc binding and embedded schema. There is no production SQL string
construction in the journal. BEGIN IMMEDIATE serializes independently opened
connections. Header/type/length checks precede reading retained bodies.

Admission binds exact canonical bytes to the entire workspace scope and
reserves the full 32-MiB completion allowance. A first claim commits Started;
recovery and duplicate claims return Unknown. Exact completions survive a lost
reply. Owner acknowledgement of their digest collects only payloads, retaining
permanent identity/digest/size fences. Quotas count lifetime rows and logical
reserved bytes; they do not bound physical WAL growth.

`remote/workspace_transfer` preserves the existing TLS frame ceiling by
transferring fixed chunks. Its opaque sender/receiver cursors enforce direction,
length, offset and final digest. Its closed direction tags preserve Invocation
(0, nine MiB) and Completion (1, thirty-two MiB); CompileCompletion (2) adds the
closed Compile codec's 256-KiB aggregate bound, at most four existing 64-KiB
chunks. The aggregate limit is independent of the TLS frame ceiling. Sender and
header checks refuse excess before hashing/retaining transfer state. Integrity
only releases bytes: the caller must still decode `compile_completion` against
its exact enrollment/original key and retain custody independently. The caller
owes authenticated application
scope, a whole-exchange deadline and bounded connection credits. Content
transfer grants no permission to execute or acknowledge durable receipt.

## Semantic workspace service and exchange

`remote/workspace_service.configure` requires identical local-host and journal
scopes, one to four active tasks, and a finite task deadline. Each newly claimed
invocation runs the concrete `tools/workspace_local` host in a managed weft task.
Exact completion bytes commit before the task reports success. Lost replies,
crashes and encoding or persistence failures preserve Unknown; they never
permit a second effect. Task capacity returns only after the final drain report.

Workspace journal format 2 adds Open/Sealed metadata. Seal commits before close
cancels and joins workers. Each admission or first claim rereads metadata in its
transaction, so an independent connection cannot claim after sealing. Query,
finish and acknowledgement may reconcile retained evidence after sealing. Older
formats are refused without migration. An untrappable kill cannot run the seal
hook; the enclosing owner must reconcile that uncertain shutdown.

`remote/workspace_connection` authenticates a domain-separated hello against the
configured peer and complete scope, then transfers the exact invocation for
Submit, Query or Acknowledge. A single weft deadline covers the whole exchange.
`remote/listener.configure_workspace` uses the existing bounded acceptor pool.
Connection loss ends transport ownership, not the separately owned effect task.
The embedding host must close listener admission before sealing the service and
release the journal only after its own retirement obligations are satisfied.


## Physical preparation journal

`remote/resource_journal` uses the already permitted codemode dependency for
canonical Compile/Launch syntax and historical Ready locations. This introduces
no client/daemon edge. Source inputs are decoded data, never wire `Vetted` or
proofs of successful Compile. Trusted physical services must re-vet Compile or
admit exact retained successful Compile evidence for Launch before requesting a
preparation claim. Format 2 now reserves the full closed completion allowance before that claim,
as described above; it does not turn Ready into a successful outcome.

`fresh` and `recover` pin the entire exact SessionEnrollment and immutable Limits.
Named queries live in `src/executor/sql/resources.sql`; `sql/resources.sql` and
`resource_schema.gleam` hold the separately embedded schema. Parrot/sqlc generates
all data queries. Only transaction and PRAGMA control remains handwritten.
`reserve` retains full canonical key/body and reserves its input/header/address
bytes, UUID and both digest slots plus 256 KiB Ready allowance permanently.
Limits count logical encoded reservations, excluding snapshot metadata and SQLite
page/WAL/RSS overhead. No release, uncertainty or seal returns that capacity.

The logical address is existing `remote_tool.child_address(service_origin(key))`.
Physical step, input digest, UUID and original parent argument/result evidence
are compared through the complete canonical header and exact body; they cannot
select a different slot beneath that same logical child. UUID reuse at another
address also conflicts. Every transaction rereads metadata and bounded scalar
headers under BEGIN IMMEDIATE; recovery checks one body at a time and retains
only bounded addresses while checking their uniqueness.

Only committed Reserved->Preparing returns an opaque Claim. A duplicate or
recovered Preparing row is Unknown and cannot claim again. Gleam claims are
copyable, so the trusted adapter still owes at-most-once use. `commit_ready`
requires the original full key and Launch producer; explicit uncertainty or
witnessed resource cleanup permanently blocks late commits. Historical Ready
survives Unknown and Released, and grants no listener/recreation authority.
`mark_released(..., ResourceOwnerCleaned)` trusts the actual resource owner's
cleanup witness; it asserts neither Compile success nor native retirement.
`seal` fences independent opens; `release_endpoint` closes only this connection.
SQL errors poison the endpoint and lost replies remain uncertain. Tests establish
real SQLite transitions/recovery, not power-loss durability or physical assembly.


## Live Compile association and historical input

`remote/resource_journal.retained_input(book, full_service_key)` reads the existing
logical-child slot through guarded `ResourceAddress`, `ResourceHeaders` and
`ResourceBodies` queries. It compares the complete canonical key, body digest and
pinned enrollment before returning `Input`. This is historical data only, usable
when the native endpoint is dead or after reopen/sealing; it constructs no Claim,
clearance, deadline or physical resources. A changed parent/result, physical step,
UUID, scope or input/registration/contract digest conflicts at the same slot.

`associate_native` remains historical Request/Admit reconciliation. The distinct
`associate_live_native(original_claim, ref, native_key, prepared_digest)` shares
its actual pinned-journal readback and fixed-template checks, but additionally
requires the canonical finite Authority tuple. It checks open scope, Prepared
state, full original equality and Unassociated inside the final resource writer
transaction. Only the first association COMMIT returns opaque `NativeLaunchPermit`.
Duplicate calls, historical association, lost replies and recovery never regenerate
that permit. Readback occurs outside the writer transaction, followed by full live
revalidation; no cross-journal transaction or permission column is introduced.

Cancellation which fences the row first blocks live eligibility. Cancellation
after association follows the exact retained native tuple as in-flight work and
cannot promise no effect or cancellation before OS start. `native_launch_binding`
exposes only the original journal/ref/key/digest to the live native continuation;
`@internal native_endpoint` and `claim_journal` expose fixed local handles so trusted
routing rejects mismatched endpoints before persisting native input. They make no
actor ask and reconstruct no authority. Gleam values remain copyable: the adapter
uses its original continuation at most once, while native AuthorizeLaunch separately
limits the effect. Expiration stays with the original native clock/deadline; the
Authority deadline can be negative in that clock era and is never renewed here.

This component supplies the admission/cancellation ordering for the next physical
adapter. It does not wire transport, perform compilation, forward cancellation or
prove whole-service retirement. See [remote custody](../../docs/architecture/remote-custody.md)
for custody layers and the remaining routing/physical assembly obligations.


## Atomic original preparation admission and cancellation

`@internal resource_journal.admit_preparation` returns `FirstAdmission` under the
same BEGIN IMMEDIATE lock as bounded original reservation. `FreshClaim` is issued
only by this transaction's absent-row insertion, phase 1 transition and successful
COMMIT. `Retained(Status)` grants no new authority, including Reserved after
reopen. Existing explicit `reserve` and `claim_preparation` remain unchanged for
trusted component callers. Original finite authority, re-vetting and one use of
the copyable Claim remain the physical adapter's responsibility.

`@internal resource_journal.fence_preparation` returns `PreparationFence` only
after COMMIT. A missing open original reserves full lifetime capacity and commits
Unknown atomically. The named `FenceResourcePreparation` query additionally
covers Reserved; existing phases 0/1/2 advance to Unknown without discarding Ready,
native association or completion, and phases 3/4 remain idempotent history. An
absent row under sealed scope returns `ScopeFenced`, without inventing row evidence.
Full identity/body/address comparison precedes existing-row dispositions even
when sealed; absent address collisions still conflict. Uncertain commits never
issue a Claim or assert a successful fence.

The cancellation writer lock is the same lock used by live native association.
Fence-first blocks late Ready and eligibility. Association-first remains in flight
through its exact retained native tuple. Neither result proves cleanup, native
retirement or cancellation before OS startup. Real independent-open tests join
managed peers and inspect committed phases; they establish component ordering,
not whole Compile or listener assembly.

## Original Compile elapsed cap at native admission

`remote/service.live_command_context(service, original_claim, ref,
original_compile_deadline_ms)` retains the original executor-local Compile
deadline alongside live preparation custody. Trusted Compile assembly copies
that deadline once from its original admission in `Config.now`'s monotonic era;
it never derives another deadline from service input, a Claim, owner wall time
or retransmitted remaining budget. Zero refuses; negative values can represent
valid future deadlines in a negative monotonic era.

Finite command authorization validates the existing native challenge, then clamps
its derived deadline to the original Compile cap before retaining Request/Authority
and Admit. The exact clamped deadline reaches the existing post-association wall-fit
check and native watchdog. Preparation, association and startup consume that same
authority. A later owner Unix-clock rollback can inflate the proposed remaining
budget but cannot enlarge this cap. Incoming Prepared, cleared policy, selected
wall and budget bytes remain unchanged; ordinary Native routes keep their previous
deadline semantics.

Historical `command_context` has no deadline or live permission. Exact associated
Query/Cancel/receipt and duplicate Submit reconcile retained data independently of
fresh authorization; they cannot regenerate a ticket, permit or deadline. This
boundary supplies no original Compile admission clock itself, cross-actor atomic
spawn/cancel promise or whole-service assembly. The real continuation still owns
original admission and at-most-once use. See [remote custody](../../docs/architecture/remote-custody.md)
for those separate ownership and recovery duties.


## Whole Compile actor

`remote/compile_service.configure` pins exact resource/native endpoints, complete
administrative scope and an opaque trusted CompilationContract. It accepts one to
four original continuations and the same independent bound for metadata tasks.
The opaque Service retains that exact native endpoint; `native_service` exposes
its identity without an ask so enclosing listener assembly can reject another
same-scope endpoint. `enrolled` exposes the original checked resource enrollment
for canonical listener input/Ready decoding, without a separately supplied snapshot.
Both start and temporary supervised construction preserve those original values.
Source admission uses the actual effective policy and generated catalogue before
journal admission or effects; peer seam/policy records never select authority.
UnusedImportRewrite reads the exact retained Original input and committed
BuildRejected completion before shared `service_input.admit_rewrite` checks the
deterministic source and unchanged contract facts. The resource journal checks
structural lineage and definite predecessor failure on insertion and readback.
Each physical Compile retains one immutable native association; uncertain Original
completion cannot authorize Rewrite.
`resource_journal.pid` is metadata-only endpoint identity for this monitor. Its
death establishes neither allocation liveness nor cleanup/native retirement.

The closed local `Caller`, `Operation` and `Reply` door independently compares
owner role, labels, generation and full scope. Header-only 32-byte tickets expire
at 1000 milliseconds, with at most 32 unused tickets. Original Submit consumes its
ticket and records full Input plus one native-clock deadline before managed
admission. Atomic `admit_preparation` is the sole fresh Claim. The worker must pass
the actor-owned BeginPreparation handoff before exclusive UUID mkdir, workspace
and seed preparation, then commit_ready. Historical Reserved never restarts work.
The original Claim and permit are copyable values; trusted assembly owes one use.

The actor remains responsive while journal asks wait. Query, ACK, cancellation
and historical command lookup use bounded managed metadata tasks. A live route
uses its actor-owned Claim and unchanged whole-service cap. Both routes hand the
listener's original final reply subject directly to the existing native engine;
a metadata report/forwarding handoff does not discharge that native exchange.
This module owns no listener, ingress credits or alternate native admission.
Successful answers and definite resource-journal Missing/Conflict refusals
release metadata capacity after the actual final drain. Ambiguous errors and
lost reports retain it and fence admission through one shared classification.
The native command-context lookup maps a definite missing or conflicting
historical identity to Invalid. The whole Compile route uses that same definite
classification; a real managed-task drain must still arrive before the metadata
slot is reusable. Journal loss and ambiguous replies retain uncertainty.

The original continuation polls `compile_observation.observe` only until its
unchanged cap. Missing association or uncommitted terminal is Pending; errors end
the run and fence admission. Its sole finalization call consumes actual retained
terminal evidence and physical products, then commit_compile precedes successful
outer observation. Query/recovery only reads committed result/receipt evidence.
Known failure before Ready settles Before through the original Preparing claim;
after Ready, absent association cannot establish safe nonexecution.

Cancel first admits metadata capacity in the same actor turn that stops the
original phase. Capacity refusal preserves its original held Claim and live route.
An admitted Cancel commits a full-input fence before inspecting actual native association,
following exact native Cancel and cancelling the continuation. Uncertain asks,
endpoint death and lost drain proofs permanently fence fresh admission and retain
unresolved capacity. A committed fence plus confirmed managed cancellation can
join normally; a failed/ambiguous fence cannot. One exclusive seal/fence barrier
remains available during close even when metadata slots are occupied. Close joins
this component, retains both journals and proves neither resource cleanup nor
native retirement. Temporary supervision never reconstructs claims after death.
An untrappable kill cannot promise that its shutdown hook wrote a durable fence.

`compile_service_test` uses real journal actors, exact source/seed preparation,
actual original Broker clearance, native helper/compiler terminal and independent
artifact fingerprints. Its stopped-handoff control pauses the original worker
with the trusted fixture clock after Claim COMMIT, holds a real SQLite fence lock,
and proves cancellation prevents mkdir before the fence reply. This actor-local
fixture does not claim ordinary-tool or registered separate-host acceptance.

The actor preserves weft's existing linked relay ownership instead of trapping
abnormal relay exits and attempting another lifecycle ledger. Loss of that relay
terminates the temporary Compile endpoint; the enclosing listener must retire
unresolved credits. The endpoint-kill test observes the actual original worker's
death and an independent journal reopen returning history without a Claim.
Broker fixture peers are monitored through their actual Dispatcher owner identity
and joined after explicit native settlement. Cancellation signals are released
after final managed reports; no completed run leaves an idle signal behind.


## Original native close disposition

`remote/service` retains NativeOpen, NativeRetired or NativeUncertain inside its
original actor. Close first quiesces admission and clears challenge tickets. It
attempts native pool retirement once, retaining the result even if the original
epoch fence or a covered-key confirmation fails. A repeated close retries only
those original durable confirmations. NativeUncertain stays uncertain; process
death cannot turn it into retirement.

A successful physical close alone is insufficient for ScopeRetirement: the
original epoch fence and every covered-key retirement confirmation must also
succeed. `shutdown` terminates the service only after that complete result. The
enclosing host must consume this service-owned proof rather than invoking the
same native close independently.


## Whole Launch local custody

`remote/launch_service` owns a finite original Launch continuation over the
existing resource journal and native command service. `configure` admits one
through four active entries, with a separate equally bounded metadata lane.
`resource_owner` exposes only the exact original writer PID for same-row
registration checks. Authenticated `Caller` facts bind Owner, executor, full
scope and transport generation before any local control operation.

`PlaceToken(original, nonce, budget_ms, token)` is the closed token placement
operation. It checks exactly 32 bytes against the original SHA-256 commitment,
reads the retained successful Compile producer, calls `service_input.admit_launch`,
and physically fingerprints the original producer's `ebin` directory. Those
checks precede Claim admission and every Launch file or socket effect. The actor
retains the fresh Claim, then retains the original `launch_channel.Owner`, before
allowing exclusive canonical directory, token and listener creation. An existing
allocation refuses; partial effects retain their original cleanup custody.

The finite placement reply is `Observed(preparation, LaunchStatus)`. It can report
Claim custody before Ready, so the owner can query the later historical Ready and
clear its exact SatelliteCommand without holding a request credit while socket
accept waits. `send_command_exchange` gives the existing native engine the exact
live Claim and unchanged executor deadline. Historical routes use only checked
native contexts. `Query` never grants preparation, native execution or connection
activation permission.

`install_host` accepts a trusted local HostEndpoint for the original active entry
exactly once. Its finite `Installed(deadline_ms)` receipt carries the immutable
active original deadline on the native clock. Repeated installation and history
cannot mint another deadline. The separate handoff subject receives
one paused `run_channel.Connection` after socket acceptance and adoption of both
reader and writer by weft. The caller installs original send, close, incarnation
and grants before activation. The socket owner independently mirrors the pure
one-frame window and charges its lifetime allowance before body reads or writer
publication. One inbound producer orders frames and End. Final consumption passes
through the original owner before reader teardown. `launch_observation` reads the
committed native phase before exact terminal payloads and never publishes cap End.

`RefuseBeforeNative` is restricted to a definite original owner clearance refusal.
It retains the original Claim and answers only after `fail_launch_preparation`
atomically fences phases 1/2 and commits the closed refusal. Association winning
first rejects that refusal. Timeout, caller loss and BrokerUnavailable use
cancellation or uncertainty. A committed refusal plus actual transport joins and
original preparation join and directory removal can commit ResourceOwnerCleaned.
Cancellation may establish the same no-dispatch cleanup custody through a
successful original fence followed by exact same-row Unassociated readback.
That witness never fabricates a RefusedBeforeNative history result. Lost fence,
readback or join remains unresolved. Associated native terminal evidence alone
cannot release resources. The original shared pool retirement seam separately
witnesses the exact Launch helper's native boundary and normal owner exit. Neither
node reporting nor transport join substitutes for that native resource witness.

Validated Launch dispatch uses `broker/executor.start_with_retirement` and the
original pool's `exec.prepare_borrowed_retirement` seam; Compile and raw native
dispatch retain reuse. The remote native service installs its original Row and
adapter monitor before Begin. That Row retains the exact callback proof despite
adapter loss, then confirms its immutable native key and Prepared digest through
one managed task. At most two asks share the original deadline plus six seconds;
actual AllDelivered precedes promotion or another ask. Per-Launch retirement
notification comes only from that drained original Row. Scoped retirement proof
is separate and emits no duplicate per-Launch notification. Scope closure refuses
before journal writes while confirmation remains in flight or its drain is lost.

Associated channel close waits within its existing fixed Closing lifetime for
that original native retirement obligation. Resource release also requires
original preparation and transport joins, original directory removal,
ResourceOwnerCleaned COMMIT and continuation report drain. A cancelled observer
may release actual physical capacity without fabricating missing terminal or
completion evidence in immutable history. See
[exact-helper retirement](../../docs/architecture/launch-native-retirement.md).

Cancellation and watchdog closure independently close the original accepted
socket and listener before joining blocked I/O. Active slots remain occupied
through unresolved native, resource or transport custody. Effect-owning entries
require a completed original continuation, actual child joins and
ResourcesReleased before releasing their slot. A drained historical observation
owns no Claim or channel and releases its observation-only slot directly.
The original execution deadline is immutable. A separate six-second observation
grace can retain settlement and join evidence but cannot authorize dispatch.
Each active original owns one cancellation lane independent of metadata credits.
Closed local channel observations expire after six seconds; historical journal
queries never recreate those callbacks or sockets. BEAM control/stream binding,
owner client wiring and default daemon assembly are separate integration work.

## Finite Launch stream installation

`beam_endpoint.bind_launch(Config, launch_beam.Offer)` reserves route five on the
same four-Data, two-Control table and returns a checked `launch_beam.Acceptance`.
Only bounded canonical bytes and unnamed doors cross nodes. The same registered
Launch owner receives the original host installation; the fixed credit actor
waits only for bounded local Installed, while socket acceptance and live stream
work remain in `launch_beam`. Its transport task retains the exact acceptance
through ACK, then requires AllDelivered before restoring capacity. Definite
pre-install Invalid can release after retirement; uncertain installation retains
the original assignment permanently. A lost transport answer after known Installed
can release the finite credit after actual network retirement, while the caller
remains Uncertain and original stream resources remain retained. There is no automatic bind retry or acceptance cache.
`inspect_drain` observes finite metadata credits, never live-stream drain.
