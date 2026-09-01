//// The repository boundary (pi §2.8): administrative operations *over*
//// sessions rather than inside one — forks (pi §2.7), the precise rewrite
//// (pi §2.9), and the text-erasure transform the rewrite exists for.
////
//// A fork copies one coherent view of a source session into a fresh
//// destination session and never mutates the source. It copies selected
//// entries (keeping their ids), strand configuration, and semantic facts;
//// it never copies operation or pending registers, terminal results, or
//// usage-ledger rows — the destination is idle and its cost ledger starts
//// at zero (entry-local display usage stays on the copied entries'
//// messages). Orphaned tool calls left behind by the fork boundary are
//// *not* patched here: request construction heals them at projection time
//// (`session.project_entries` rule 4).
////
//// Snapshot coherence: the copy reads the source through its storage
//// actor, which serializes every operation — but a fork interleaved with
//// live commits from the session's writer could still observe two
//// half-states across successive reads. Fork and rewrite are therefore
//// defined over a *quiescent* source: the caller (an admin surface, never
//// the harness hot path) must ensure no writer is committing. The SQLite
//// rewrite enforces this by holding the writer lease for its whole
//// duration — a concurrent open is refused with `LeaseHeld` — while the
//// in-process operations trust their caller.

import core/clock.{type Clock}
import core/codec as core_codec
import core/corruption.{type CorruptionReport}
import core/entry.{type Entry}
import core/ids.{type EntryId, type Generator, type SessionId}
import core/json.{type JsonValue}
import core/register
import core/tx.{
  type CommitError, Expect, InsertEntry, InsertUsage, SetRegister, Tx,
}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import machine/codec
import machine/strand.{StrandState}
import session/session.{type Session}
import storage/sqlite
import storage/storage.{type StorageError}

/// The strand every fork destination boots with, matching pi's destination
/// `main` lane.
const main_strand = "main"

/// What a fork copies (pi §2.7's two scopes).
pub type ForkScope {
  /// Copy one path: the ancestor chain of `at` (any entry may be the fork
  /// point), inclusive. The destination gets a single `main` strand whose
  /// leaf is `at`; `strand` names the source strand whose total
  /// configuration seeds it (copied only if the source strand is
  /// configured — an unconfigured source forks to an unconfigured `main`,
  /// seeded on first attachment). Entry labels are copied only for copied
  /// entries.
  ForkBranch(strand: String, at: EntryId)

  /// Copy the whole tree: every entry, every strand's configuration and
  /// leaf, every entry label. Each destination strand starts with a fresh
  /// `StrandState`.
  ForkTree
}

/// Where the forked session lives. The destination must be fresh: forking
/// into a session that already holds entries is refused.
pub type ForkDestination {
  /// A fresh in-memory session.
  ForkIntoMemory

  /// A fresh SQLite session file (created at `path`), opened with the
  /// writer lease held by `owner` — the forked session is returned open,
  /// per pi §2.8.
  ForkIntoSqlite(path: String, owner: String, lease_ttl_ms: Int)
}

/// Why a fork failed. The source session is never modified; a failure
/// after the destination opened closes it (best effort) before returning.
pub type ForkError {
  /// Reading the source failed.
  ForkSourceRead(error: session.SessionError)

  /// The branch-scope fork point names no committed entry.
  ForkPointUnknown(id: EntryId)

  /// The destination backend refused to open.
  ForkDestinationOpen(error: session.OpenError)

  /// Probing the freshly opened destination failed.
  ForkDestinationRead(error: StorageError)

  /// The destination already holds entries — forking must never splice
  /// two histories together.
  ForkDestinationNotEmpty

  /// The single copy transaction was refused by the destination. A
  /// `StaleExpectation` on `session/id` means the destination was already
  /// identified by an earlier open — entry-empty but not fresh, which a
  /// fork must not overwrite.
  ForkCopyFailed(error: CommitError)
}

/// Forks a session (pi §2.7): copies the scope's entries (ids preserved;
/// destination storage re-stamps `seq`/`ts` at its own commit), the
/// scope's strand configuration and leaves, and the semantic facts —
/// `fact.name` always, `fact.label` for copied entries — into a fresh
/// destination, as one atomic destination transaction. Every destination
/// strand starts with a fresh `StrandState`; operation, pending, and
/// terminal-result registers are never copied; the usage ledger starts at
/// zero. Custom facts (`fact.custom`) are application-defined and are not
/// copied by the generic fork — a consuming feature must add an explicit
/// policy first (pi's rule for application values).
///
/// The returned destination session is open (pi §2.8: fork returns its
/// destination already open); the caller owns closing it.
///
/// **The destination is born identified** (`protocol-change/008`): its own
/// canonical `SessionId` is minted from `generator` and written in the
/// same destination transaction as the copy, and the source's id — read,
/// never minted, because a fork must not mutate its source — is written
/// beside it as the parent. This is the one path in Loom that creates a
/// session from a session: the client protocol's `fork` makes a strand in
/// the *same* session, and the Agency's children are strands too, so this
/// is the only place a parent-session edge exists to record.
///
/// ## Examples
///
/// ```gleam
/// // repo.fork(source, scope: repo.ForkBranch(strand: "main", at: leaf),
/// //   into: repo.ForkIntoMemory, clock:, generator:)
/// ```
///
pub fn fork(
  source source: Session,
  scope scope: ForkScope,
  into into: ForkDestination,
  clock clock: Clock,
  generator generator: Generator,
) -> Result(Session, ForkError) {
  use entries <- result.try(collect_entries(source, scope))
  use registers <- result.try(collect_registers(source, scope, entries))
  use parent <- result.try(
    session.id(source) |> result.map_error(ForkSourceRead),
  )
  let #(minted, _generator) = ids.mint_session(generator)
  use destination <- result.try(open_destination(into, clock))
  let copy = {
    use Nil <- result.try(require_empty(destination))
    let writes =
      list.append(
        list.map(entries, fn(entry) { InsertEntry(entry:) }),
        list.append(registers, identity_writes(minted, parent)),
      )

    // The destination must be unidentified as well as entry-empty:
    // `require_empty` only looks at entries, and a session file that a
    // prior open identified but never wrote an entry into would other-
    // wise have its id silently re-minted here. Expecting the cell
    // absent turns that misuse into a `ForkCopyFailed(StaleExpectation)`
    // with the destination's own id left standing.
    storage.commit(
      destination.store,
      Tx(writes:, expected: [
        Expect(ns: register.FactCustom, key: session.session_id_key, seq: None),
      ]),
    )
    |> result.map_error(ForkCopyFailed)
    |> result.replace(destination)
  }
  case copy {
    Ok(forked) -> {
      // The catalog projection is written after the copy commits, so a
      // refused copy leaves no identity behind. It failing is not a fork
      // failure: the register cells are the truth and the next open
      // repairs the row. The discard is deliberate and the silence is
      // accepted — this package depends on `core`, `storage` and
      // `machine` and has no logger to reach, and threading one through
      // an admin surface to narrate a self-repairing write would cost
      // more than the breadcrumb is worth.
      let _ = forked.record_identity(minted, parent)
      Ok(forked)
    }
    Error(error) -> {
      let _ = session.close(destination)
      Error(error)
    }
  }
}

// The destination's two identity cells. The parent cell is written only
// when the source has an id of its own: a source that predates
// `protocol-change/008` forks to a destination that records no parent,
// because minting one into the source would be a mutation the fork
// contract forbids.
fn identity_writes(
  minted: SessionId,
  parent: Option(SessionId),
) -> List(tx.Write) {
  let own =
    SetRegister(
      ns: register.FactCustom,
      key: session.session_id_key,
      value: register.value(json.String(ids.session_id_to_string(minted))),
    )
  case parent {
    None -> [own]
    Some(parent) -> [
      own,
      SetRegister(
        ns: register.FactCustom,
        key: session.parent_session_id_key,
        value: register.value(json.String(ids.session_id_to_string(parent))),
      ),
    ]
  }
}

// The scope's entries, oldest first, so parents precede children in the
// destination transaction.
fn collect_entries(
  source: Session,
  scope: ForkScope,
) -> Result(List(Entry), ForkError) {
  case scope {
    ForkBranch(at:, ..) ->
      storage.scan_branch(
        source.store,
        storage.branch_scan(from: at)
          |> storage.branch_order(storage.OldestFirst),
      )
      |> result.map_error(fork_branch_scan_error)
    ForkTree ->
      storage.scan_entries(source.store, storage.entry_scan())
      |> result.map_error(fn(error) {
        ForkSourceRead(error: session.StoreFailure(error:))
      })
  }
}

// A missing fork point is reported precisely (`ForkPointUnknown`); every
// other scan failure is an ordinary source read failure.
fn fork_branch_scan_error(error: StorageError) -> ForkError {
  case error {
    storage.UnknownEntry(id:) -> ForkPointUnknown(id:)
    storage.CorruptRow(..) | storage.BackendFault(..) | storage.HandleClosed ->
      ForkSourceRead(error: session.StoreFailure(error:))
  }
}

// The destination's register writes: strand bookkeeping plus semantic
// facts. Register payloads are copied verbatim (no decode) — a fork moves
// cells, it does not interpret them.
fn collect_registers(
  source: Session,
  scope: ForkScope,
  entries: List(Entry),
) -> Result(List(tx.Write), ForkError) {
  case scope {
    ForkBranch(strand: strand_name, at:) -> {
      use configuration <- result.try(read_register(
        source,
        register.StrandConfig,
        strand_name,
      ))
      let strand_writes =
        list.flatten([
          strand_config_write(configuration),
          [
            SetRegister(
              ns: register.StrandLeaf,
              key: main_strand,
              value: register.leaf_value(Some(at)),
            ),
            fresh_state(main_strand),
          ],
        ])
      use names <- result.try(copy_namespace(source, register.FactName))
      use labels <- result.try(copy_labels(source, copied_ids(entries)))
      Ok(list.flatten([strand_writes, names, labels]))
    }
    ForkTree -> {
      use configurations <- result.try(list_namespace(
        source,
        register.StrandConfig,
      ))
      use leaves <- result.try(list_namespace(source, register.StrandLeaf))
      let strand_names =
        list.map(configurations, fn(cell) { cell.0 })
        |> list.append(list.map(leaves, fn(cell) { cell.0 }))
        |> list.unique
      let strand_writes =
        list.flatten([
          copies(register.StrandConfig, configurations),
          copies(register.StrandLeaf, leaves),
          list.map(strand_names, fresh_state),
        ])
      use names <- result.try(copy_namespace(source, register.FactName))
      use labels <- result.try(copy_namespace(source, register.FactLabel))
      Ok(list.flatten([strand_writes, names, labels]))
    }
  }
}

// An unconfigured source strand forks to an unconfigured `main` (seeded
// on first attachment); a configured one carries its configuration over.
fn strand_config_write(
  configuration: Option(register.RegisterValue),
) -> List(tx.Write) {
  case configuration {
    Some(value) -> [
      SetRegister(ns: register.StrandConfig, key: main_strand, value:),
    ]
    None -> []
  }
}

fn fresh_state(strand_name: String) -> tx.Write {
  SetRegister(
    ns: register.StrandState,
    key: strand_name,
    value: register.value(
      codec.encode_strand_state(
        StrandState(current_operation: None, pending_next_run: []),
      ),
    ),
  )
}

fn copied_ids(entries: List(Entry)) -> Set(String) {
  entries
  |> list.map(fn(entry) { ids.entry_id_to_string(entry.id) })
  |> set.from_list
}

fn read_register(
  source: Session,
  ns: register.RegisterNs,
  key: String,
) -> Result(Option(register.RegisterValue), ForkError) {
  storage.get_register(source.store, ns, key)
  |> result.map(
    option.map(_, fn(cell) {
      let storage.Register(value:, ..) = cell
      value
    }),
  )
  |> result.map_error(fn(error) {
    ForkSourceRead(error: session.StoreFailure(error:))
  })
}

fn list_namespace(
  source: Session,
  ns: register.RegisterNs,
) -> Result(List(#(String, register.RegisterValue)), ForkError) {
  storage.list_registers(source.store, ns, None)
  |> result.map(
    list.map(_, fn(cell) {
      let #(key, storage.Register(value:, ..)) = cell
      #(key, value)
    }),
  )
  |> result.map_error(fn(error) {
    ForkSourceRead(error: session.StoreFailure(error:))
  })
}

fn copies(
  ns: register.RegisterNs,
  cells: List(#(String, register.RegisterValue)),
) -> List(tx.Write) {
  list.map(cells, fn(cell) {
    let #(key, value) = cell
    SetRegister(ns:, key:, value:)
  })
}

fn copy_namespace(
  source: Session,
  ns: register.RegisterNs,
) -> Result(List(tx.Write), ForkError) {
  use cells <- result.map(list_namespace(source, ns))
  copies(ns, cells)
}

// Entry labels are keyed by entry id (pi: labels copy only when their
// target copies); a label whose key is not a copied entry stays behind.
fn copy_labels(
  source: Session,
  copied: Set(String),
) -> Result(List(tx.Write), ForkError) {
  use cells <- result.map(list_namespace(source, register.FactLabel))
  cells
  |> list.filter(fn(cell) { set.contains(copied, cell.0) })
  |> copies(register.FactLabel, _)
}

fn open_destination(
  into: ForkDestination,
  clock: Clock,
) -> Result(Session, ForkError) {
  case into {
    ForkIntoMemory -> session.open_memory(clock)
    ForkIntoSqlite(path:, owner:, lease_ttl_ms:) ->
      session.open_sqlite(path:, owner:, lease_ttl_ms:, clock:)
  }
  |> result.map_error(fn(error) { ForkDestinationOpen(error:) })
}

fn require_empty(destination: Session) -> Result(Nil, ForkError) {
  case
    storage.scan_entries(
      destination.store,
      storage.entry_scan() |> storage.entry_limit(1),
    )
  {
    Ok([]) -> Ok(Nil)
    Ok([_, ..]) -> Error(ForkDestinationNotEmpty)
    Error(error) -> Error(ForkDestinationRead(error:))
  }
}

// --- precise rewrite (pi §2.9) --------------------------------------------

/// The entry transform a precise rewrite applies: `Ok(None)` keeps the
/// entry untouched, `Ok(Some(new))` replaces its content — the entry's
/// id, parent, and kind must be preserved (the drivers refuse a transform
/// that moves an entry) — and `Error` aborts the whole rewrite with
/// nothing swapped.
pub type EntryRewrite =
  fn(Entry) -> Result(Option(Entry), CorruptionReport)

/// The value transform a precise rewrite applies to the stores that are
/// not entries — register payloads (queued pending messages, tool
/// arguments, compaction preparation, facts) and usage-ledger details:
/// `Ok(None)` keeps the stored value, `Ok(Some(new))` replaces it, and
/// `Error` aborts the whole rewrite with nothing swapped. A rewrite takes
/// both transforms because the audit contract covers every store a
/// needle can reach, not just entry payloads.
pub type ValueRewrite =
  fn(JsonValue) -> Result(Option(JsonValue), CorruptionReport)

/// An `EntryRewrite` that erases `needle` from every string value in an
/// entry's stored payload, replacing each occurrence with `replacement`.
/// It works on the entry's canonical JSON encoding, so it reaches every
/// text an entry can carry — message blocks, thinking, tool-call
/// arguments, tool-result details, summaries, custom payloads, and the
/// retained-tail message copies inside compaction entries. Object keys
/// are structural and are left alone.
///
/// Total at the boundary: the rewritten payload is decoded back through
/// the entry codec, so a needle that collides with structural vocabulary
/// (a stop reason, an id) aborts the rewrite as corruption instead of
/// producing an unreadable store. `replacement` must not itself contain
/// `needle`, or the audit guarantee is vacuous.
///
/// ## Examples
///
/// ```gleam
/// // repo.erase_text(needle: "s3cr3t", replacement: "[erased]")
/// ```
///
pub fn erase_text(
  needle needle: String,
  replacement replacement: String,
) -> EntryRewrite {
  fn(entry: Entry) {
    let encoded = core_codec.encode_entry(entry)
    let #(rewritten, changed) = erase_json(encoded, needle, replacement)
    case changed {
      False -> Ok(None)
      True ->
        core_codec.decode_entry(rewritten)
        |> result.map(Some)
    }
  }
}

/// The `ValueRewrite` companion of `erase_text`: erases `needle` from
/// every string value of a register payload or usage-details blob. These
/// payloads are free-form JSON at the storage boundary, so there is no
/// codec to collide with here — but a needle that overlaps an id a
/// register carries (a strand leaf, an operation id) will surface as
/// corruption when the machine codecs next read that cell, the same
/// deferred failure an id collision inside an entry has at the entry
/// codec. Pass both erasers, built from the same needle, to a rewrite.
///
/// ## Examples
///
/// ```gleam
/// // repo.erase_value(needle: "s3cr3t", replacement: "[erased]")
/// ```
///
pub fn erase_value(
  needle needle: String,
  replacement replacement: String,
) -> ValueRewrite {
  fn(value: JsonValue) {
    let #(rewritten, changed) = erase_json(value, needle, replacement)
    case changed {
      False -> Ok(None)
      True -> Ok(Some(rewritten))
    }
  }
}

// Replaces the needle in every string *value*; keys are structural.
// Returns the rewritten value and whether anything changed.
fn erase_json(
  value: JsonValue,
  needle: String,
  replacement: String,
) -> #(JsonValue, Bool) {
  case value {
    json.String(text) -> {
      use <- bool.guard(
        when: !string.contains(does: text, contain: needle),
        return: #(value, False),
      )
      #(
        json.String(string.replace(in: text, each: needle, with: replacement)),
        True,
      )
    }
    json.Array(items) -> {
      let #(rewritten, changed) =
        list.fold(over: items, from: #([], False), with: fn(step, item) {
          let #(accumulator, changed) = step
          let #(item, item_changed) = erase_json(item, needle, replacement)
          #([item, ..accumulator], changed || item_changed)
        })
      #(json.Array(list.reverse(rewritten)), changed)
    }
    json.Object(fields) -> {
      let #(rewritten, changed) =
        list.fold(over: fields, from: #([], False), with: fn(step, field) {
          let #(accumulator, changed) = step
          let #(name, inner) = field
          let #(inner, inner_changed) = erase_json(inner, needle, replacement)
          #([#(name, inner), ..accumulator], changed || inner_changed)
        })
      #(json.Object(list.reverse(rewritten)), changed)
    }
    json.Int(_) | json.Float(_) | json.Bool(_) | json.Null -> #(value, False)
  }
}

/// Precisely rewrites a **closed** SQLite session file (pi §2.9): the
/// rewrite claims and holds the writer lease in the original for its
/// whole duration (a concurrent open is refused with `LeaseHeld`),
/// retires the original's WAL so no pre-rewrite page can be replayed into
/// the result, copies the file coherently with `VACUUM INTO`, runs every
/// entry payload through `rewrite` and every register payload and
/// usage-details blob through `rewrite_value`, vacuums the copy so no
/// replaced bytes survive, re-verifies the lease, and atomically renames
/// the copy over the original. The generation counter in the session
/// metadata is bumped so external indexes (WP-K search) detect the
/// invalidation; `sqlite.generation` reads it. An unexpired writer lease
/// refuses the rewrite.
///
/// This is the sole sanctioned exception to "entries are never modified":
/// compliance-grade erasure, branch pruning, id re-minting. It is tooling
/// above the harness — no harness surface exposes it.
///
/// ## Examples
///
/// ```gleam
/// // repo.rewrite_sqlite(path:, clock:,
/// //   rewrite: repo.erase_text(needle: "s3cr3t", replacement: "[gone]"),
/// //   rewrite_value: repo.erase_value(needle: "s3cr3t", replacement: "[gone]"))
/// ```
///
pub fn rewrite_sqlite(
  path path: String,
  clock clock: Clock,
  rewrite rewrite: EntryRewrite,
  rewrite_value rewrite_value: ValueRewrite,
) -> Result(sqlite.Rewrite, sqlite.RewriteError) {
  sqlite.rewrite_into(path:, clock:, rewrite:, rewrite_value:)
}

/// The outcome of a memory-backend rewrite: the rebuilt session and how
/// many entries the transform replaced. Memory stores persist nothing, so
/// there is no generation counter to bump — the rebuilt session *is* a
/// new handle, which is invalidation enough for anything in-process.
pub type MemoryRewrite {
  MemoryRewrite(session: Session, entries_rewritten: Int)
}

/// Why a memory-backend rewrite failed. The source session is never
/// modified.
pub type RewriteError {
  /// Reading the source failed.
  RewriteSourceRead(error: session.SessionError)

  /// The entry transform reported corruption, or changed an entry's id,
  /// parent, or kind.
  RewriteEntryFailed(report: CorruptionReport)

  /// The value transform reported corruption for a register payload or a
  /// usage-details blob.
  RewriteValueFailed(report: CorruptionReport)

  /// The rebuilt destination refused to open.
  RewriteDestinationOpen(error: session.OpenError)

  /// The rebuild transaction was refused.
  RewriteCopyFailed(error: CommitError)
}

/// Precisely rewrites a memory-backed session by rebuilding it: entries
/// run through `rewrite` and register payloads and usage details through
/// `rewrite_value` (same contracts as the SQLite path), and — unlike a
/// fork — *everything else* is retained: every register cell is carried
/// over (transformed, not dropped) and the usage ledger is re-appended
/// row for row, since a rewrite erases content, not history. Returns the
/// rebuilt session as a new handle; the source is untouched and remains
/// open.
///
/// ## Examples
///
/// ```gleam
/// // repo.rewrite_memory(source:, clock:,
/// //   rewrite: repo.erase_text(needle: "s3cr3t", replacement: "[gone]"),
/// //   rewrite_value: repo.erase_value(needle: "s3cr3t", replacement: "[gone]"))
/// ```
///
pub fn rewrite_memory(
  source source: Session,
  rewrite rewrite: EntryRewrite,
  rewrite_value rewrite_value: ValueRewrite,
  clock clock: Clock,
) -> Result(MemoryRewrite, RewriteError) {
  use entries <- result.try(
    storage.scan_entries(source.store, storage.entry_scan())
    |> result.map_error(fn(error) {
      RewriteSourceRead(error: session.StoreFailure(error:))
    }),
  )
  use #(rewritten_entries, rewritten) <- result.try(
    list.try_fold(over: entries, from: #([], 0), with: fn(step, entry) {
      apply_entry_rewrite(step, entry, rewrite)
    }),
  )
  use usage_rows <- result.try(
    storage.scan_usage(source.store, storage.usage_scan())
    |> result.map_error(fn(error) {
      RewriteSourceRead(error: session.StoreFailure(error:))
    }),
  )

  // Usage details are opaque JSON and can carry the needle (provider
  // echoes, request annotations); they go through the value transform on
  // the way into the rebuild, matching the SQLite path's audit scope.
  use usage_rows <- result.try(
    list.try_map(usage_rows, fn(row) { rewrite_usage_row(row, rewrite_value) }),
  )

  // Every register cell is retained — a rewrite erases content, not
  // history — but its payload runs through the value transform first:
  // pending messages, tool arguments, and preparation copies are exactly
  // where an erased secret also lives.
  use register_writes <- result.try(
    list.try_fold(over: every_namespace(), from: [], with: fn(writes, ns) {
      rewrite_namespace_registers(source, rewrite_value, writes, ns)
    }),
  )
  use destination <- result.try(
    session.open_memory(clock)
    |> result.map_error(fn(error) { RewriteDestinationOpen(error:) }),
  )
  let writes =
    list.flatten([
      list.map(list.reverse(rewritten_entries), fn(entry) {
        InsertEntry(entry:)
      }),
      list.map(usage_rows, fn(row) { InsertUsage(row:) }),
      list.reverse(register_writes),
    ])
  case storage.commit(destination.store, Tx(writes:, expected: [])) {
    Ok(_) ->
      Ok(MemoryRewrite(session: destination, entries_rewritten: rewritten))
    Error(error) -> {
      let _ = session.close(destination)
      Error(RewriteCopyFailed(error:))
    }
  }
}

fn placement_preserved(old: Entry, new: Entry) -> Bool {
  old.id == new.id
  && old.parent == new.parent
  && storage.kind_of(old) == storage.kind_of(new)
}

// One step of the entry-rewrite fold: an untouched entry passes through,
// a transformed one is checked and re-stamped, and a transform failure
// short-circuits the whole rewrite.
fn apply_entry_rewrite(
  step: #(List(Entry), Int),
  entry: Entry,
  rewrite: EntryRewrite,
) -> Result(#(List(Entry), Int), RewriteError) {
  let #(accumulator, count) = step
  case rewrite(entry) {
    Ok(None) -> Ok(#([entry, ..accumulator], count))
    Ok(Some(new)) -> place_rewritten_entry(entry, new, accumulator, count)
    Error(report) -> Error(RewriteEntryFailed(report:))
  }
}

fn place_rewritten_entry(
  entry: Entry,
  new: Entry,
  accumulator: List(Entry),
  count: Int,
) -> Result(#(List(Entry), Int), RewriteError) {
  use <- bool.lazy_guard(when: !placement_preserved(entry, new), return: fn() {
    Error(
      RewriteEntryFailed(report: corruption.report(
        at: "session/repo.rewrite_memory",
        on: ids.entry_id_to_string(entry.id),
        expected: "a rewrite preserving entry id, parent, and kind",
        context: "transform changed entry placement",
      )),
    )
  })

  // Keep the stored placement even if the transform touched the
  // placeholder fields.
  let stamped = storage.stamp(new, seq: entry.seq, ts: entry.ts)
  Ok(#([stamped, ..accumulator], count + 1))
}

// Usage details are opaque JSON and can carry the needle (provider
// echoes, request annotations); they go through the value transform on
// the way into the rebuild, matching the SQLite path's audit scope.
fn rewrite_usage_row(
  row: entry.UsageRow,
  rewrite_value: ValueRewrite,
) -> Result(entry.UsageRow, RewriteError) {
  case row.details {
    None -> Ok(row)
    Some(details) ->
      rewrite_value(details)
      |> result.map_error(fn(report) { RewriteValueFailed(report:) })
      |> result.map(fn(replaced) {
        case replaced {
          None -> row
          Some(new) -> entry.UsageRow(..row, details: Some(new))
        }
      })
  }
}

// Every register cell is retained — a rewrite erases content, not
// history — but its payload runs through the value transform first:
// pending messages, tool arguments, and preparation copies are exactly
// where an erased secret also lives.
fn rewrite_namespace_registers(
  source: Session,
  rewrite_value: ValueRewrite,
  writes: List(tx.Write),
  ns: register.RegisterNs,
) -> Result(List(tx.Write), RewriteError) {
  use cells <- result.try(
    storage.list_registers(source.store, ns, None)
    |> result.map_error(fn(error) {
      RewriteSourceRead(error: session.StoreFailure(error:))
    }),
  )
  list.try_fold(over: cells, from: writes, with: fn(writes, cell) {
    rewrite_register_cell(rewrite_value, ns, writes, cell)
  })
}

fn rewrite_register_cell(
  rewrite_value: ValueRewrite,
  ns: register.RegisterNs,
  writes: List(tx.Write),
  cell: #(String, storage.Register),
) -> Result(List(tx.Write), RewriteError) {
  let #(key, storage.Register(value:, ..)) = cell
  let payload = core_codec.encode_register_value(value)
  use replaced <- result.map(
    rewrite_value(payload)
    |> result.map_error(fn(report) { RewriteValueFailed(report:) }),
  )
  let value = case replaced {
    None -> value
    Some(new) -> register.value(new)
  }
  [SetRegister(ns:, key:, value:), ..writes]
}

fn every_namespace() -> List(register.RegisterNs) {
  [
    register.StrandLeaf,
    register.StrandConfig,
    register.StrandState,
    register.StrandLastResult,
    register.OpMeta,
    register.OpState,
    register.OpToolArgs,
    register.OpPreparation,
    register.PendingEntry,
    register.FactName,
    register.FactLabel,
    register.FactCustom,
  ]
}
