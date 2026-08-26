//// Projections: rebuildable read models folded from a session's
//// durable stream (design §3.6, spec WP-K).
////
//// A projection is a pure fold over the session's committed changes in
//// seq order, together with a persisted high-water seq recording how
//// far it has folded. Catch-up is a pull: scan everything past the
//// high-water and fold it in. Rebuild is catch-up from zero on the
//// initial state. Because the fold input is the durable store itself,
//// a projection is always *rebuildable* and carries no authority.
////
//// **Events are hints; pulls are truth.** The driver actor subscribes
//// to the session's EventBus, but an event only prompts a catch-up
//// pull — it is never applied as data. Drop any subset of events and
//// the projection still converges on the next hint, sync, or restart;
//// the lost-event tests in this package assert exactly that.

import core/entry.{type Entry, type UsageRow}
import core/ids.{type Seq}
import events/bus.{type Bus}
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import storage/storage.{type SessionStats, type Storage, type StorageError}
import telemetry/field
import telemetry/log.{type Logger}

/// One committed change, as fed to a projection's fold in seq order.
/// Entries and usage rows share the session's seq namespace, so the two
/// scans merge into one totally-ordered stream.
pub type Change {
  /// An entry append, carrying the stamped entry.
  EntryAppended(entry: Entry)
  /// A usage-ledger append, carrying the stamped row.
  UsageAppended(row: UsageRow)
}

/// A projection behaviour: an initial state and a pure fold step.
///
/// Constructor invariants: `apply` is pure and total — it performs no
/// I/O and never crashes on any committed change (unknown shapes are
/// folded as no-ops); folding the same changes in the same order from
/// `initial` always yields the same state, which is what makes rebuild
/// and incremental catch-up provably equal.
pub type Projection(state) {
  Projection(initial: state, apply: fn(state, Change) -> state)
}

/// Where a driver persists its progress between restarts.
///
/// Constructor invariants: `save(state, high_water, generation)` stores
/// all three together — state without its high-water (or either
/// without the generation they were folded under) is meaningless;
/// `load` returns the most recently saved triple, or `None` to start
/// from zero. Persistence is best-effort: a checkpoint that loses writes
/// only costs a longer catch-up, never correctness.
///
/// `generation` mirrors `events/search`'s rewrite-invalidation cursor:
/// it is the store's rewrite-generation counter at the moment `state`
/// was folded (`storage/sqlite.generation`; memory sessions have none,
/// so callers pass `0`). A precise rewrite preserves seq numbering while
/// replacing payloads, so the frontier rule alone cannot see it — a
/// checkpoint whose generation no longer matches the store's current
/// one is folded over erased-or-renumbered history and must be
/// discarded, not resumed from.
pub type Checkpoint(state) {
  Checkpoint(
    /// The most recently saved triple, or `None` for a cold start.
    load: fn() -> Option(#(state, Seq, Int)),
    /// Stores a state together with the high-water and generation it
    /// corresponds to.
    save: fn(state, Seq, Int) -> Nil,
  )
}

/// A checkpoint that persists nothing: every restart rebuilds from
/// zero. The honest default for cheap projections.
///
/// ## Examples
///
/// ```gleam
/// // projection.start(projection.Options(.., checkpoint: projection.ephemeral(), ..))
/// ```
///
pub fn ephemeral() -> Checkpoint(state) {
  Checkpoint(load: fn() { None }, save: fn(_state, _high_water, _generation) {
    Nil
  })
}

/// Pulls every change past `after` from the store and folds it into
/// `state`, returning the new state and new high-water seq. This is the
/// convergence primitive: correct regardless of how many event hints
/// were lost, because it reads the store, not the events.
///
/// Concurrency: the entry and usage scans are two separate reads, and
/// the writer may commit between them. Both scans are therefore bounded
/// by a *frontier* seq read first — seqs are strictly increasing and
/// rows are write-once, so the range `(after, frontier]` is immutable
/// by the time either scan runs, and the batch is consistent no matter
/// what commits mid-pull. (Without the bound, a commit landing between
/// the two scans lets the usage scan advance the high-water past
/// entries the entry scan never saw — the lost-event test caught
/// exactly that.) Changes past the frontier are the next pull's work.
///
/// ## Examples
///
/// ```gleam
/// // projection.catch_up(store, stats_projection(), state, after: 17)
/// // -> Ok(#(state, 23))
/// ```
///
pub fn catch_up(
  store: Storage(handle),
  projection: Projection(state),
  state: state,
  after high_water: Seq,
) -> Result(#(state, Seq), StorageError) {
  use frontier_seq <- result.try(frontier(store))
  // Nothing owed: the frontier has not moved past the high-water.
  use <- bool.guard(
    when: frontier_seq <= high_water,
    return: Ok(#(state, high_water)),
  )
  let from = Some(high_water + 1)
  let to = Some(frontier_seq)
  let entries_query =
    storage.entry_scan()
    |> storage.entry_seq_range(from, to)
    |> storage.entry_order(storage.OldestFirst)
  let usage_query =
    storage.usage_scan()
    |> storage.usage_seq_range(from, to)
    |> storage.usage_order(storage.OldestFirst)
  use entries <- result.try(storage.scan_entries(store, entries_query))
  use usage <- result.try(storage.scan_usage(store, usage_query))
  let changes = merge(entries, usage)
  let state = list.fold(changes, state, projection.apply)
  Ok(#(state, frontier_seq))
}

/// The highest committed seq across both write-once streams at (or
/// after) the moment of the call — the consistent upper bound for one
/// catch-up batch.
fn frontier(store: Storage(handle)) -> Result(Seq, StorageError) {
  let newest_entry =
    storage.entry_scan()
    |> storage.entry_order(storage.NewestFirst)
    |> storage.entry_limit(1)
  let newest_usage =
    storage.usage_scan()
    |> storage.usage_order(storage.NewestFirst)
    |> storage.usage_limit(1)
  use entries <- result.try(storage.scan_entries(store, newest_entry))
  use usage <- result.try(storage.scan_usage(store, newest_usage))
  let entry_seq = case entries {
    [entry, ..] -> entry.seq
    [] -> 0
  }
  let usage_seq = case usage {
    [row, ..] -> row.seq
    [] -> 0
  }
  Ok(int.max(entry_seq, usage_seq))
}

/// Folds the whole session from seq zero on the projection's initial
/// state. `rebuild` equalling incremental catch-up is the projection
/// correctness property the WP-K exit criteria test.
///
/// ## Examples
///
/// ```gleam
/// // projection.rebuild(store, stats_projection())
/// ```
///
pub fn rebuild(
  store: Storage(handle),
  projection: Projection(state),
) -> Result(#(state, Seq), StorageError) {
  catch_up(store, projection, projection.initial, after: 0)
}

/// The seq of a change (storage-assigned, unique session-wide).
///
/// ## Examples
///
/// ```gleam
/// // projection.change_seq(projection.EntryAppended(entry)) == entry.seq
/// ```
///
pub fn change_seq(change: Change) -> Seq {
  case change {
    EntryAppended(entry:) -> entry.seq
    UsageAppended(row:) -> row.seq
  }
}

/// Merges the two seq-ascending scans into one seq-ascending change
/// stream. Both inputs come from the same commit history, so seqs never
/// collide across the lists.
fn merge(entries: List(Entry), usage: List(UsageRow)) -> List(Change) {
  merge_loop(entries, usage, [])
}

fn merge_loop(
  entries: List(Entry),
  usage: List(UsageRow),
  acc: List(Change),
) -> List(Change) {
  case entries, usage {
    [], [] -> list.reverse(acc)
    [entry, ..rest], [] -> merge_loop(rest, [], [EntryAppended(entry:), ..acc])
    [], [row, ..rest] -> merge_loop([], rest, [UsageAppended(row:), ..acc])
    [entry, ..entries_rest], [row, ..usage_rest] ->
      case entry.seq < row.seq {
        True -> merge_loop(entries_rest, usage, [EntryAppended(entry:), ..acc])
        False -> merge_loop(entries, usage_rest, [UsageAppended(row:), ..acc])
      }
  }
}

// --- the stats projection --------------------------------------------------

/// The stats projection: message-entry count plus the field-wise sum of
/// the usage ledger — the same figures the storage backends maintain
/// natively (`storage.stats`), rebuilt here through the projection path
/// so the two can be checked against each other.
///
/// ## Examples
///
/// ```gleam
/// // projection.rebuild(store, projection.stats_projection())
/// ```
///
pub fn stats_projection() -> Projection(SessionStats) {
  Projection(initial: storage.empty_stats(), apply: apply_stats)
}

fn apply_stats(stats: SessionStats, change: Change) -> SessionStats {
  case change {
    EntryAppended(entry: entry.MessageEntry(..)) ->
      storage.SessionStats(..stats, message_count: stats.message_count + 1)
    EntryAppended(entry: _) -> stats
    UsageAppended(row:) ->
      storage.SessionStats(
        ..stats,
        usage: storage.add_usage(stats.usage, row.usage),
      )
  }
}

// --- the driver actor ------------------------------------------------------

/// Where a driver's catch-up hints come from.
pub type Hints {
  /// Subscribe to every topic of `session` on `bus`; any received event
  /// prompts a catch-up pull. The events themselves are discarded.
  FromBus(bus: Bus, session: String)
  /// No subscription — the driver pulls only on `poke`/`sync` and at
  /// start. For tests and batch use.
  NoHints
}

/// Driver configuration.
///
/// Constructor invariants: `store`, called fresh on every pull, returns
/// the session's *current* open storage — never a value the caller
/// captured once, since a precise rewrite swaps the store the driver
/// must read (EV-proj-rewrite: a driver that cached its `Storage(handle)`
/// at start would keep reading a stale or closed handle forever after a
/// rewrite). `generation`, likewise called fresh, returns the store's
/// current rewrite-generation counter (`storage/sqlite.generation`;
/// `fn() { 0 }` for memory sessions, which have none) — this is what
/// lets a pull notice a rewrite happened at all, the same way
/// `events/search.sync`'s caller-supplied generation does. `projection`
/// obeys the `Projection` invariants; `checkpoint` obeys the
/// `Checkpoint` invariants; the driver assumes nothing else.
pub type Options(state, handle) {
  Options(
    store: fn() -> Storage(handle),
    generation: fn() -> Int,
    projection: Projection(state),
    checkpoint: Checkpoint(state),
    hints: Hints,
    /// Where a pull fault with no reply channel is reported. Injected
    /// (§0.2); `log.discard()` for a driver nobody is watching.
    logger: Logger,
  )
}

/// Messages understood by a projection driver. Opaque: callers use
/// `poke`, `read`, and `sync`.
pub opaque type Message(state) {
  Hinted
  Read(reply: Subject(state))
  Synchronize(reply: Subject(Result(state, StorageError)))
}

type DriverState(state, handle) {
  DriverState(
    get_store: fn() -> Storage(handle),
    get_generation: fn() -> Int,
    projection: Projection(state),
    checkpoint: Checkpoint(state),
    logger: Logger,
    state: state,
    high_water: Seq,
    /// The generation `state`/`high_water` were folded under. Compared
    /// against `get_generation()` on every pull; a mismatch means a
    /// rewrite happened underneath this checkpoint and the fold must
    /// restart from `projection.initial` at seq zero.
    generation: Int,
  )
}

/// Starts a projection driver: loads the checkpoint (or starts from
/// zero), catches up once, then applies event hints by pulling. A
/// storage fault during any catch-up leaves the last good state in
/// place; the next hint or `sync` retries — hints are lossy and pulls
/// are idempotent, so the driver converges whenever the store is
/// readable.
///
/// ## Examples
///
/// ```gleam
/// // projection.start(projection.Options(store: fn() { store },
/// //   generation: fn() { 0 }, projection: stats_projection(),
/// //   checkpoint: projection.ephemeral(), hints: projection.FromBus(bus, "s1")))
/// ```
///
pub fn start(
  options: Options(state, handle),
) -> actor.StartResult(Subject(Message(state))) {
  actor.new_with_initialiser(5000, fn(subject) {
    let selector = case options.hints {
      FromBus(bus:, session:) -> {
        bus.subscribe_all(bus, session:)
        process.new_selector()
        |> process.select(subject)
        |> bus.select_published(fn(_published) { Hinted })
      }
      NoHints ->
        process.new_selector()
        |> process.select(subject)
    }
    // A cold start has nothing checkpointed to compare a generation
    // against, so it simply records whatever generation the store is
    // at now — there is no rewrite to detect before the first fold.
    let #(state, high_water, generation) = case options.checkpoint.load() {
      Some(saved) -> saved
      None -> #(options.projection.initial, 0, options.generation())
    }
    let driver =
      DriverState(
        get_store: options.store,
        get_generation: options.generation,
        projection: options.projection,
        checkpoint: options.checkpoint,
        logger: options.logger,
        state:,
        high_water:,
        generation:,
      )
    // First convergence at start; a fault keeps the checkpointed state
    // and the next hint retries.
    let #(driver, result) = pull(driver)
    case result {
      Ok(Nil) -> Nil
      Error(error) -> surface_pull_fault(options.logger, error)
    }
    actor.initialised(driver)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// The driver as a supervision child (design §2: ProjectionSup holds
/// the rebuildable read models).
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(builder, projection.supervised(options))
/// ```
///
pub fn supervised(
  options: Options(state, handle),
) -> ChildSpecification(Subject(Message(state))) {
  supervision.worker(fn() { start(options) })
}

fn handle_message(
  driver: DriverState(state, handle),
  message: Message(state),
) -> actor.Next(DriverState(state, handle), Message(state)) {
  case message {
    Hinted -> {
      // A hint carries no reply channel to return a fault to, but the
      // fault must not vanish silently either (EV-proj-rewrite's other
      // aggravator: a driver reading a closed or stale handle would
      // otherwise serve its last good state forever with nothing ever
      // surfacing the read failure). Log it; an explicit `sync` still
      // returns it to a caller that is watching.
      let #(driver, result) = pull(driver)
      case result {
        Ok(Nil) -> Nil
        Error(error) -> surface_pull_fault(driver.logger, error)
      }
      actor.continue(driver)
    }
    Read(reply:) -> {
      process.send(reply, driver.state)
      actor.continue(driver)
    }
    Synchronize(reply:) -> {
      let #(driver, result) = pull(driver)
      case result {
        Ok(Nil) -> process.send(reply, Ok(driver.state))
        Error(error) -> process.send(reply, Error(error))
      }
      actor.continue(driver)
    }
  }
}

/// One catch-up pull; on success the checkpoint is saved. On fault the
/// previous state is kept.
///
/// Re-reads both the store and the generation fresh on every call
/// (EV-proj-rewrite) rather than trusting anything captured at start: a
/// precise rewrite swaps the store and bumps its generation, and a
/// driver that cached either at start would keep folding a stale
/// handle, or keep extending a fold that was already invalidated,
/// forever. A generation that no longer matches the one `driver.state`
/// was folded under means exactly that a rewrite happened underneath
/// this checkpoint, so the fold restarts from `projection.initial` at
/// seq zero — the same rebuild `catch_up` always does for a store with
/// nothing owed yet, just aimed at the *current* store instead of the
/// one this driver last saw.
fn pull(
  driver: DriverState(state, handle),
) -> #(DriverState(state, handle), Result(Nil, StorageError)) {
  let store = driver.get_store()
  let current_generation = driver.get_generation()
  let #(state, high_water) = case current_generation == driver.generation {
    True -> #(driver.state, driver.high_water)
    False -> #(driver.projection.initial, 0)
  }
  case catch_up(store, driver.projection, state, after: high_water) {
    Ok(#(state, high_water)) -> {
      driver.checkpoint.save(state, high_water, current_generation)
      #(
        DriverState(
          ..driver,
          state:,
          high_water:,
          generation: current_generation,
        ),
        Ok(Nil),
      )
    }
    // A fault leaves the driver exactly as it was — including its
    // recorded generation — so a rewrite detected but not yet folded
    // (the scan that would prove it failed) is retried in full on the
    // next pull rather than being half-adopted.
    Error(error) -> #(driver, Error(error))
  }
}

/// Logs a pull fault that has no reply channel to return to (the hint
/// path, and the driver's own start-time convergence pull). The
/// checkpointed state is kept either way; this only makes the fault
/// visible instead of silently swallowed.
fn surface_pull_fault(logger: Logger, error: StorageError) -> Nil {
  // The level policy's `warning`: the checkpointed state stands and the
  // next hint retries, so this is degraded rather than fatal.
  log.warn(logger, "projection.pull_failed", [
    field.text(key: "reason", value: string.inspect(error)),
  ])
}

/// Nudges a driver to catch up, fire-and-forget — what an external hint
/// source calls. Loss is legal; `sync` or the next hint converges.
///
/// ## Examples
///
/// ```gleam
/// // projection.poke(driver)
/// ```
///
pub fn poke(driver: Subject(Message(state))) -> Nil {
  process.send(driver, Hinted)
}

/// Reads the driver's current state without pulling — the local-speed
/// lookup. May lag the store until the next hint or `sync`.
///
/// ## Examples
///
/// ```gleam
/// // projection.read(driver)
/// ```
///
pub fn read(driver: Subject(Message(state))) -> state {
  process.call_forever(driver, Read)
}

/// Forces a catch-up pull and returns the converged state — the
/// pull-side truth, regardless of how many hints were lost.
///
/// ## Examples
///
/// ```gleam
/// // projection.sync(driver)
/// ```
///
pub fn sync(driver: Subject(Message(state))) -> Result(state, StorageError) {
  process.call_forever(driver, Synchronize)
}
