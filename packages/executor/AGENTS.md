# executor

## Purpose

The executor service as a process of its own (issue #696, phase S4). The
service, pool and `Dispatcher` live in `packages/broker`
(`broker/executor`, `broker/dispatch`); this package is the thin
entrypoint that boots them without the harness. It exists as a package
for one reason: its dependency list is the compile-time proof that the
service needs no session runtime, provider, web view or daemon. It depends on
`broker`, `core` and `telemetry` (for `log.discard()`), plus `weft`, `argv`,
`envoy`, `gleam_json`, `gleam_time`, `gleam_erlang`, `simplifile` and
`sqlight_loom`, `parrot` and `tools`, and never on `host` or `client`.
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
terminal bytes and cancellation intent. Native retirement still requires a
witnessed scoped pool drain; a recovered old incarnation remains uncertain.

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
listening, and replaces the supplied verifier with `registration.verify`.
The host owns its TLS listener, linked admission actor and bounded acceptor
subtree. Its supervision specification is Temporary: restarting over the same
native custody is not an admission policy. A late startup failure may follow
peer admission and therefore cannot roll back the epoch or authorize replay.

Explicit close first stops listener admission, quiesces the service and stops
acceptors. It releases the journal only after durable epoch closure, witnessed
native retirement and owned service exit. Uncertain cleanup retains evidence.
Actor or socket death alone never establishes native retirement; an untrappable
host kill still requires reconciliation by the enclosing owner.

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
length, offset and final digest. The caller owes authenticated application
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
