# executor

## Purpose

The executor service as a process of its own (issue #696, phase S4). The
service, pool and `Dispatcher` live in `packages/broker`
(`broker/executor`, `broker/dispatch`); this package is the thin
entrypoint that boots them without the harness. It exists as a package
for one reason: its dependency list is the compile-time proof that the
service needs no session runtime, provider, web view or daemon. It depends on
`broker`, `core` and `telemetry` (for `log.discard()`), plus `weft`, `argv`,
`envoy`, `gleam_json`, `gleam_time`, `gleam_erlang` and `simplifile`, and
never on `host` or `client`.

It defines no socket, listener, frame or registration service. The pure
`executor/remote/{identity,admission}` modules provide validated names and a
bounded admission/custody reducer for #697, without transport or persistence.
They have no production callers yet and do not change local executor behavior.
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
`policy`, `token`), `core` (`clock`, `ids`) and `telemetry` (`log`). Nothing
depends on it. The new remote modules import only `core/ids`, each other
and pure stdlib modules, with no I/O, processes, FFI or Dynamic. They do
not implement or change the `broker/dispatch.Dispatcher` seam.
`make executor-smoke` builds the helper and runs the entrypoint; CI runs it in the jail job and `scripts/signoff.sh` in its
enforcement lane, both of which have bwrap.

## Traffic

The remote foundation has no actor, store or wire traffic. Typed
`admission.Event` values reduce an already admitted key into a
`Transition(next: Book, evidence: Evidence, effect: Effect)`.
`Effect.Launch(RequestKey)` is a decision for a future adapter, not a
native action. No code persists or performs it in this wave.

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
outside this reducer. This foundation supplies no codec, database, network,
authentication, scheduler or automatic failover, and wires no remote execution.

## Invariants

- No `client` dependency. A change that adds one defeats the package.
- No `@external`, no socket, no wire. Remote trust and transport are #697.
- Helper locality: the helper is spawned by `exec.prepare_helper` on the
  machine running this process, as the harness spawns it.
- An incarnation is minted per boot from the wall clock in microseconds, so
  two boots in one VM never share one (the guarantee is per VM) and an `ExecutionId` of one boot
  never equals one of the other. The local entrypoint starts a fresh service
  on restart; it restores no executions. The remote reducer describes
  retained intent recovery, but no durable adapter implements it yet.
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
