# storage

## Purpose

One session's durable store behind a uniform, backend-agnostic handle:
the `Storage` behaviour of the frozen contract (spec Part 1.2) plus its two
implementations — `memory` (pure maps in an actor) and `sqlite` (one
database file per session, writer lease, private segmented branch index,
migrate-on-open, and the offline precise rewrite). Both pass the same
conformance suite; that suite is the definition of correct. WP-B, extended
by WP-C-full.

## Key Types

- `storage/internal/history_source.{Source, Cut}` binds a read-only native
  connection to its canonical source path. `inspect` reads identity, generation,
  and high-water in one short transaction on that retained connection; `page`,
  `entry`, and `fragment` reuse the snapshot descriptor and byte bounds. Acquire
  never creates a missing conversation or claims its writer lease. The owning
  actor must retain the handle after a failed close; this raw capability is
  linear, not a reusable read-after-close interface.
- `storage/domain.{Domain, Scope}` stores daemon-owned domain configuration and
  memory/index paths separately from session admission. `reserve_session`
  atomically reserves identity and its mapping; `isolate` replaces a private
  mapping with a fresh session-only record without opening or copying files.
  `sources` pages only saved registrations and validates their mapped workspace.
  Existing domain references and repeated isolation retain their original paths.
  The catalogue also reserves `digest_beside(memory_path)` and checks memory,
  index, and digest paths against every destination column in one transaction.
  A client-side parity test pins the derived sidecar to the memory module's
  convention, so imported destinations cannot silently overlap its digest.

- `storage/sqlite_policy.{Options, ForeignKeys, Journal}` centralizes connection
  and journal tuning for sessions, the catalogue and search. Record updates
  override a database's busy timeout, foreign-key enforcement, journal mode or
  optional cache target. Connection configuration precedes admission; journal
  configuration follows successful file validation and ownership acquisition.
- `storage/access.{Principal, PrincipalKind, Digest, Role, Authority}` holds
  stable daemon identities, current display names, SHA-256 credential digests,
  and per-session operator/observer membership. `bootstrap_owner` creates the
  one owner or verifies its existing active credential; `owner` reads identity
  without changing credentials. `rotate_credential` changes credentials, not
  principal identity. This is an internal DAL, not invitation or gateway policy.
  `invite_member` atomically creates a reserved principal ID, credential, and
  first membership. `rotate_member` revokes all active member credentials and
  inserts one replacement; `revoke_member` retains the identity and grants.
  These member operations refuse the owner principal.
- `storage/catalogue.{Catalogue, Registration, State, Page}` holds daemon
  metadata in a separate SQLite file. `Reserved` and `Saved` describe file
  initialization, not runtime liveness. `reserve` is idempotent by creation
  key; `by_request_key` recovers the original registration before a retry
  allocates an id, path, or timestamp. `workspace_default` reads a workspace's
  saved choice; `set_workspace_default` changes it only to a registration in
  that workspace. `member_page` applies membership in SQL before its 100-row
  limit, so a continuation never exposes an unrelated session identity.
  The catalogue revision advances only on registration, default or membership changes,
  not on identical retries.
- `storage/snapshot.{Reader, Plan, Cut, Descriptor}` supplies bounded client
  reads without changing the frozen `Storage` record. A declarative plan
  selects register namespaces/prefixes or `ExactKey(namespace, key)` and follows
  bounded references. Missing exact keys are omitted; a caller needing absence
  reports must compare requested keys with returned cells. Exact selection uses
  the existing indexed header lookup, accounts before payload fetch, and never
  scans prefix neighbors. Capture
  copies a coherent high-water, stats and metadata; later descriptor pages and
  raw entry fragments retain no transaction. The existing backend actor owns
  every read. This capability creates neither a reader process nor a lease.
  Each function takes a final wait budget in milliseconds, capped at 5,000.
  The shared monitored exchange in `internal/snapshot_call` returns
  `ReadTimedOut` or `ReaderUnavailable` instead of panicking.
- `storage/sql` contains parrot/sqlc-generated catalogue and snapshot queries.
  `storage/sql_schema` embeds catalogue `sql/schema.sql`; `session_schema`
  embeds conversation `sql/session.sql`. Generation loads both schemas for
  query checking, but each database executes only its own schema. `make gen-sql`
  regenerates these artifacts, and tests pin them to their sources.
- `storage/catalogue.{query, statement, atomic}` are internal generated-query
  adapters for access metadata. They reuse the catalogue connection and its
  existing daemon owner; they introduce neither a connection nor an actor.
- `storage/storage.Storage(handle)` — a record of functions closed over a
  backend handle: `commit`, `get_entries`, `get_register`,
  `list_registers`, `scan_branch`, `scan_entries`, `scan_usage`, `stats`,
  `close`. `session` erases the handle type to `Storage(Nil)`.
- `storage/storage.{BranchScan, EntryScan, UsageScan}` — the three query
  shapes, built with the pipeline builders (`branch_scan`,
  `branch_stop_at_kind`, `branch_cursor`, `entry_seq_range`, ...).
- `storage/storage.StorageError` — the read-path error type, deliberately
  distinct from `core/tx.CommitError` which the commit path keeps frozen.
- `storage/memory.MemoryState` — the storage model as pure data (entries, a
  children index, registers, the usage ledger, the stats projection, next
  seq). Every mutation is a pure function over it, so the conformance suite
  can drive the model with no process involved.
- `storage/sqlite.{Config, OpenError, Segment}` — file path, lease owner,
  lease TTL, busy timeout; the segmented branch-index window type.
  `OpenError.UnsupportedVersion(found, supported)` is the fail-closed
  answer to a file this build cannot read.
- `storage/sqlite.transfer_startup(handle)` unlinks the original SQLite actor
  only after cleanup publication is acknowledged, and returns that actor's PID.
  A failed builder cannot discard the published actor's lease-release proof.
- `storage/sqlite.Migration(from_version, statements)` — one migrate-on-open
  step, run by `open_with_migrations`; the chain itself is owned by
  `session.migration_chain`. `sqlite.storage_version` is 1, so the chain is
  empty today.
- `storage/sqlite.{record_identity, identity}` — the catalog row's
  identity projection (`protocol-change/008`): `record_identity` writes
  the session's canonical id into the metadata blob and its parent's into
  the long-reserved `parent_session_id` column, and `identity(path:)`
  reads both back without taking the writer lease, the way
  `generation(path:)` does. Both are a **projection** — the session's
  `session/id` / `session/parent` register cells are the truth — so it
  needs no schema version bump and a failed write costs only a repair on
  the next open.
- `storage/sqlite.read_entry` — a path-based, read-only lookup for exact
  history recall. It checks canonical session identity and uses the total
  entry decoder without acquiring a writer lease. Missing files are not
  created; source paths must come from the host, never a model argument.
- `storage/sqlite.{Rewrite, RewriteError, rewrite_into, generation}` — the
  offline precise rewrite (pi §2.9) over a **closed** file, and the
  rewrite-generation counter external indexes key their cursors on.
  `rewrite_into` takes two transforms: an entry rewrite for `entries`
  payloads and a value rewrite for register payloads and usage-ledger
  details, because the audit contract covers every store a needle can
  reach.
- `storage/internal/branch.Refine` — the shared incremental
  truncate/filter/cursor/limit pipeline, fed page by page by SQLite and
  whole by Memory.

## Relationships

- **Depends on**: `core` (ids, entries, registers, tx, codecs,
  corruption), `sqlight` (the SQLite binding, ADR-002), `simplifile` (the
  rewrite's copy/rename/unlink), `gleam_erlang` + `gleam_otp` (both
  backends are actors), `parrot` (typed catalogue queries, ADR-004).
- **Depended on by**: `session` (wraps one open handle; owns the migration
  chain and drives the rewrite), `runtime` (the StorageWriter owns it),
  `events` (projections and the search service scan sessions through the
  `Storage` record), `client` (the gateway's catch-up scans), `conformance`
  (the suite and the instrumented simulation store).
- **FFI**: none directly; SQLite reaches the world through `sqlight`.

## Traffic

- **Actor messages** — both backends expose an opaque `Message` and
  serialize everything through one mailbox ("one writer, one queue"):
  `Commit(tx, reply)`, `GetEntries(ids, reply)`,
  `GetRegister(ns, key, reply)`, `ListRegisters(ns, prefix, reply)`,
  `ScanBranch(q, reply)`, `ScanEntries(q, reply)`, `ScanUsage(q, reply)`,
  `Stats(reply)`, `Close(reply)`. Every variant is a call. `sqlite` adds
  lease renewal, driven from `runtime/writer`'s `RenewTick`, and
  `Segments(reply)` for the branch-index diagnostics the conformance suite
  asserts on. `rewrite_into` and `generation` take a **path**, not a
  handle: they are offline operations with no actor involved.
- **Commits**: applies `core/tx.Write` — `InsertEntry`, `InsertUsage`,
  `SetRegister`, `DeleteRegister` — in list order, after evaluating every
  `SeqExpectation`. Assigns `seq` and `ts` at commit; `storage.stamp`
  writes them onto the entry.
- **Registers**: generic over all namespaces; stores `RegisterValue`
  payloads opaquely and returns them with their seq (`Register`). No
  history, no interpretation of `strand.*` / `op.*` payloads.
- **Wire**: the SQLite file schema — write-once `entries` and
  `usage_ledger`, mutable `registers`, `branch_entries` + `branch_meta`,
  a single-row `session` catalog (carrying `storage_version`, the rewrite
  `generation` and the projected `session_id` in its metadata blob, and
  the projected `parent_session_id` in its column), and `writer_lease`.
  `storage_version` is 1.

## Invariants

- **Stable identity is not a credential.** Principal IDs and current display
  names are stored independently of active/revoked credential digests. Plaintext
  bearer tokens never enter access SQL. The caller must supply SHA-256 hashes
  of cryptographically random tokens; validating a 64-hex-byte representation
  does not prove entropy. Revoked digests remain tombstones and cannot be
  reassigned or reactivated. Rotation is one immediate transaction, so a failed
  replacement leaves the previous credential active.
- **Invitation retries do not mint new identities or credentials.** A caller
  chooses its recovery ID before sending. Existing principal IDs always
  conflict, including after revocation. Explicit member rotation recovers a
  lost successful reply without reusing any tombstoned digest. Invitation and
  rotation roll back all preceding writes if a later insertion fails.
- **There is one durable owner.** A partial unique index enforces the single
  owner row. Bootstrap retries require an active credential already belonging
  to that owner; a missing, malformed, revoked, or unrelated token cannot reset
  ownership. A display-name change preserves principal identity, and readers
  can snapshot the current name without rewriting historical origins.
- **Membership is session-scoped.** `(principal_id, session_id)` is the indexed
  membership key. Operator and observer are explicit roles, not fallback values;
  a missing row grants nothing. Even owner authorization checks that the session
  exists. Foreign keys and DAL validation reject dangling references. Reads
  totally decode persisted principal kinds, credential states, and roles; an
  unknown value refuses access. No access API performs an unbounded list.
- **Catalogue metadata never opens a conversation.** Listing, request-key
  lookup, and workspace defaults read only the separate catalogue file.
  A default may name a reservation; it proves neither initialization nor
  runtime liveness. Reads reject dangling or cross-workspace defaults, and
  writes validate the target workspace before changing the mapping.
  The caller serializes
  metadata access under the daemon lifetime lock. Reservations survive
  restart without taking session leases or executing recovery. Canonical
  paths and authorization are the daemon's responsibility.
- **Actor retirement follows successful close.** `sqlite.retire_closed`
  refuses an open connection or retained close error, then observes normal
  actor exit before returning success. Ordinary `Storage.close` keeps its
  idempotent contract and does not retire the actor.
- **Snapshot bounds precede payload reads.** Capture admits at most 1,024 cells
  and 1 MiB of encoded metadata, including identifiers and referenced cells.
  SQL preflights identifier and payload lengths before transferring them to
  the BEAM. Pages contain at most 100 entry descriptors; fragments contain at
  most 190 KiB; a record above 32 MiB is refused before its payload is fetched.
  These are representation bounds, not a VM RSS limit. The memory backend
  already owns decoded entries and serializes one selected entry for slicing.
- **The snapshot cut outlives no transaction.** SQLite captures mutable cells,
  stats and `next_seq` in one short deferred transaction. Later pages stay
  below that cut and read write-once entries. The gateway, not storage, owns
  incarnation checks, transfer credit, authorization and socket deadlines.
  Metadata itself can exceed one 256 KiB wire frame and must also be chunked.
- **A snapshot timeout is not cancellation.** The read may remain queued or
  running, and its eventual reply may enter the caller's mailbox. The original
  gateway/session must fail without retrying or admitting further reads.
  Session custody must drain the original storage actor or retain
  RecoveryBlocked before reopening it. The exchange owns only its monitor,
  which is released on every outcome; it neither kills nor replaces storage.
- **All-or-none commits.** Validation completes before any state is
  replaced; a failed commit applies nothing and consumes no seq. Seqs are
  strictly increasing per session; gaps are legal.
- **Transaction intent is explicit, not inferred from generated cardinality.**
  Catalogue pages and compound default reads use `BEGIN DEFERRED`; they read a
  coherent snapshot without reserving the writer. Catalogue mutations and
  access changes use `BEGIN IMMEDIATE`, including read-then-write operations.
  A generated `:many` query is not necessarily read-only: writes can return rows.
- **Every session write transaction opens with `BEGIN IMMEDIATE`.** Allocating the
  seq range reads `session.next_seq` before writing it, so every commit
  reads before it writes; a deferred `BEGIN` takes a read snapshot it
  cannot upgrade, and `busy_timeout` cannot rescue that.
- **The writer lease is the single-writer rule.** WAL lets two processes
  alternate writes to one file; the lease makes "one process owns one
  session" enforced rather than assumed. `open` acquires expiring fenced
  ownership and may steal an expired lease with a bumped fence; every
  commit renews it; a commit whose `(owner_id, fence)` no longer matches
  fails `tx.LeaseLost(held_by:)` — naming the thief when the row names
  one, `None` when the row was cleared — and applies nothing; `close`
  deletes only its own pair, so a stale owner cannot release its
  replacement. The condition is a value rather than a `Faulted` reason
  string precisely because its remedy is opposite to every other commit
  failure's: reopen, never retry (`protocol-change/005`). The read path
  still flattens it, since `StorageError` has no lease vocabulary —
  `renew_lease` reports `BackendFault(tx.describe_lease_loss(..))`, which
  is what stops the runtime's writer.
- **Branch reads never fall back to a table scan or parent walk.**
  `scan_branch` drives from `branch_entries` via a `CROSS JOIN` that forces
  the join order and pages segment windows. `scan_branch_plan` exposes
  `EXPLAIN QUERY PLAN` so the conformance suite fails on any
  `TEMP B-TREE FOR ORDER BY` or entries-scan regression — the query plan is
  an enforced contract, not a performance note.
- **Writing an entry or usage row under an existing id is corruption**, not
  an update. Entry and usage ids share one namespace.
- **Register semantics**: set replaces, delete removes, delete-absent is a
  no-op, no history. A delete consumes a seq like any other write.
- **CAS is evaluated before anything applies.** Each `SeqExpectation` names
  the register seq the committer computed against (`None` = must not
  exist); any mismatch returns `StaleExpectation` with nothing applied.
  CAS-only commits (empty writes, non-empty expectations) are legal.
- **Parent-must-exist is enforced at commit**; in-transaction parents work
  because writes apply in order.
- **Close is idempotent** (pi §1.5): a sealed handle answers handle-closed
  on reads and faulted on commits rather than crashing. SQLite retains
  its original close result, including a failed lease deletion; a retry
  cannot turn that failure into permission to replace the writer. Both
  close and failed-open lease cleanup use the binding's busy-total exec
  path, with the owner quoted as a literal and the fence matched exactly.
- **Stats equal the ledger sum after every commit** — the conformance suite
  asserts it at each transaction, not just at the end.
- **A version is migrated or refused, never misread — and a refusal writes
  nothing.** Open runs in refuse-before-write order: one `BEGIN IMMEDIATE`
  admission transaction reads the stored version, refuses a newer file or
  an uncovered older one (`UnsupportedVersion(found, supported)`) or a held
  lease with the file byte-untouched, and otherwise claims the lease;
  schema DDL, the migration chain, and the WAL journal switch run only
  after that, under the lease (pi §2.8). A step's `statements` and its
  version bump commit in one transaction. The same admission transaction
  serializes racing creators, so N concurrent opens of a fresh path write
  exactly one catalog row and every loser gets an in-band `OpenError`.
- **The precise rewrite is the sole sanctioned exception to "entries are
  never modified"** (pi §2.9), and it is offline: an unexpired writer lease
  refuses it with `RewriteLeaseHeld`. The rewrite then *claims and holds*
  the lease in the original under the reserved owner `"rewrite"` for its
  whole duration — a concurrent open is refused `LeaseHeld` instead of
  committing into a file the swap would discard — and re-verifies the
  claim immediately before the rename, aborting if it was stolen. It works
  on a `VACUUM INTO` copy and only an atomic rename replaces the original,
  so every failure path leaves the original file's content untouched (and
  releases the lease).
- **A rewrite must leave no erased bytes behind.** The source's WAL is
  retired *before* the copy is taken (a verified TRUNCATE checkpoint —
  SQLite would replay any matching WAL into the swapped-in file on the
  next open, resurrecting the erased text), the copy is vacuumed so
  replaced content does not survive in free pages, and the leftover
  `-wal`/`-shm` siblings are unlinked after the swap with failures
  *propagated*, never discarded. The transforms reach entries, register
  payloads, and usage details alike — the audit contract is that the
  erased string appears nowhere in the new file's raw bytes.
- **A rewrite preserves each entry's id, parent, and kind**; a transform
  that moves an entry, or reports corruption, aborts the whole rewrite with
  nothing swapped. Every rewrite bumps the `generation` counter, which is
  how an external index (WP-K search) learns its cursors are invalid;
  `generation` reads it without taking the lease, and never conjures a file
  that does not exist.

## Deep Docs

- [docs/architecture/durability.md](../../docs/architecture/durability.md) —
  the plane in full: the three stores, the segmented index, query plans as
  contract, crash behavior.
- [docs/adr/002-sqlite-binding.md](../../docs/adr/002-sqlite-binding.md) —
  why `sqlight`.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-B/T": the two
  extra indexes, actor-per-backend, close idempotence, CAS-only commits.
  "From WP-C-full": rewrite scope, the memory backend's absent
  generation counter.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
