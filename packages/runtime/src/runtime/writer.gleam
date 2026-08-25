//// The StorageWriter: the one process that commits to a session.
////
//// All commits flow through this actor as calls, so ordering is its
//// mailbox — "transactions on one session are serialized" is structural
//// (design §3.5). Reads also route through it in the runtime, keeping a
//// single storage path and one instrumentation point. After each
//// successful commit the writer publishes a `Committed` event to its
//// subscribers (a simple typed pub/sub over process subjects — the
//// `pg`-based EventBus proper is WP-K) and then invokes the injected
//// `after_commit` observer.
////
//// `after_commit` is the interleave harness's crash scheduler seam: it
//// runs in the writer process after the commit is durable and published
//// but *before* the committer's reply is sent, so an observer that kills
//// the writer produces exactly the state "commit N durable, committer
//// never saw it succeed" — a crash between adjacent commits, scriptable
//// for every boundary. Production wiring passes a no-op.
////
//// For SQLite sessions the writer renews the writer lease on an idle
//// timer (`Session.lease_interval_ms`, a third of the TTL); a lost lease
//// stops the writer abnormally so the supervisor reboots the tree, whose
//// reopen path re-acquires or fails loudly.

import core/entry.{type Entry, type UsageRow}
import core/ids.{type EntryId, type Seq}
import core/register.{type RegisterNs}
import core/tx.{type CommitError, type CommitResult, type Tx}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import session/session.{type Session}
import storage/storage.{type StorageError}

/// A committed-transaction event published to subscribers post-commit.
/// Events are hints; pulls are truth (design §3.6) — a subscriber that
/// misses events catches up from the store by seq.
pub type Event {
  /// One transaction committed. `ordinal` counts this writer process's
  /// successful commits from 1 (it restarts with the process); `seqs`
  /// are the storage-assigned write seqs.
  Committed(ordinal: Int, seqs: List(Seq), ts: Int)
}

/// Writer configuration.
///
/// Constructor invariants: `session` is an open session this writer
/// becomes the sole committer for; `after_commit` is called with the
/// commit ordinal after durability and publication, before the reply —
/// it must be fast and may deliberately kill the writer (the crash
/// scheduler); `subscribers` receive every `Committed` event from the
/// writer's start.
pub type Options {
  Options(
    session: Session,
    after_commit: fn(Int) -> Nil,
    subscribers: List(Subject(Event)),
  )
}

/// Messages understood by the writer. Opaque: callers use the wrapper
/// functions below.
pub opaque type Message {
  Commit(tx: Tx, reply: Subject(Result(CommitResult, CommitError)))
  GetEntries(
    ids: List(EntryId),
    reply: Subject(Result(Dict(EntryId, Entry), StorageError)),
  )
  GetRegister(
    ns: RegisterNs,
    key: String,
    reply: Subject(Result(Option(storage.Register), StorageError)),
  )
  ListRegisters(
    ns: RegisterNs,
    key_prefix: Option(String),
    reply: Subject(Result(List(#(String, storage.Register)), StorageError)),
  )
  ScanBranch(
    q: storage.BranchScan,
    reply: Subject(Result(List(Entry), StorageError)),
  )
  ScanUsage(
    q: storage.UsageScan,
    reply: Subject(Result(List(UsageRow), StorageError)),
  )
  Stats(reply: Subject(Result(storage.SessionStats, StorageError)))
  Subscribe(subscriber: Subject(Event))
  RenewTick
}

type State {
  State(
    session: Session,
    ordinal: Int,
    subscribers: List(Subject(Event)),
    after_commit: fn(Int) -> Nil,
    self: Subject(Message),
  )
}

/// Starts a writer registered under `name` (so a supervisor restart keeps
/// the address stable for the strands that call it).
///
/// ## Examples
///
/// ```gleam
/// // writer.start(options, name)
/// ```
///
pub fn start(
  options: Options,
  name: Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    schedule_renew(options.session, subject)
    actor.initialised(State(
      session: options.session,
      ordinal: 0,
      subscribers: options.subscribers,
      after_commit: options.after_commit,
      self: subject,
    ))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// The writer as a supervision child.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(builder, writer.supervised(options, name))
/// ```
///
pub fn supervised(
  options: Options,
  name: Name(Message),
) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(options, name) })
}

// Publishes one event to one subscriber, skipping a subscriber that is
// not there to hear it. Events are hints and pulls are truth (design
// §3.6), so a hint with nowhere to go is a non-event — but a subscriber
// held as a *named* subject is an unregistered name while its owner
// restarts, and sending into an unregistered name crashes the sender.
// Without this guard the writer would be the process that dies for a
// hint, taking the whole rest-for-one tree below it; with it, a
// subscriber may be supervised and restartable (`client/gateway`'s
// commit forwarder is) without putting the commit path at risk.
fn publish(subscriber: Subject(Event), event: Event) -> Nil {
  case process.subject_owner(subscriber) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> process.send(subscriber, event)
        False -> Nil
      }
    Error(Nil) -> Nil
  }
}

fn schedule_renew(session: Session, subject: Subject(Message)) -> Nil {
  case session.lease_interval_ms {
    Some(interval) -> {
      let _timer = process.send_after(subject, interval, RenewTick)
      Nil
    }
    None -> Nil
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Commit(tx:, reply:) ->
      case storage.commit(state.session.store, tx) {
        Ok(result) -> {
          let ordinal = state.ordinal + 1
          let event = Committed(ordinal:, seqs: result.seqs, ts: result.ts)
          list.each(state.subscribers, publish(_, event))
          // The crash-scheduler seam: may not return (see module doc).
          state.after_commit(ordinal)
          process.send(reply, Ok(result))
          actor.continue(State(..state, ordinal:))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    GetEntries(ids:, reply:) -> {
      process.send(reply, storage.get_entries(state.session.store, ids))
      actor.continue(state)
    }
    GetRegister(ns:, key:, reply:) -> {
      process.send(reply, storage.get_register(state.session.store, ns, key))
      actor.continue(state)
    }
    ListRegisters(ns:, key_prefix:, reply:) -> {
      process.send(
        reply,
        storage.list_registers(state.session.store, ns, key_prefix),
      )
      actor.continue(state)
    }
    ScanBranch(q:, reply:) -> {
      process.send(reply, storage.scan_branch(state.session.store, q))
      actor.continue(state)
    }
    ScanUsage(q:, reply:) -> {
      process.send(reply, storage.scan_usage(state.session.store, q))
      actor.continue(state)
    }
    Stats(reply:) -> {
      process.send(reply, storage.stats(state.session.store))
      actor.continue(state)
    }
    Subscribe(subscriber:) ->
      actor.continue(
        State(..state, subscribers: [subscriber, ..state.subscribers]),
      )
    RenewTick ->
      case state.session.renew_lease() {
        Ok(Nil) -> {
          schedule_renew(state.session, state.self)
          actor.continue(state)
        }
        // A lost lease means another writer owns the file: this tree
        // must not keep committing. Stop abnormally; the supervisor's
        // restart re-runs the open path, which re-acquires or refuses.
        Error(error) ->
          actor.stop_abnormal(
            "writer lease renewal failed: " <> describe_storage_error(error),
          )
      }
  }
}

fn describe_storage_error(error: StorageError) -> String {
  case error {
    storage.CorruptRow(report:) -> "corrupt row: " <> report.boundary
    storage.UnknownEntry(id: _) -> "unknown entry"
    storage.BackendFault(reason:) -> reason
    storage.HandleClosed -> "handle closed"
  }
}

// --- calling wrappers -----------------------------------------------------

/// Commits one transaction through the writer. Panics if the writer is
/// dead — under supervision a crashed caller beats one holding an
/// unobserved commit.
///
/// ## Examples
///
/// ```gleam
/// // writer.commit(subject, tx)
/// ```
///
pub fn commit(
  writer: Subject(Message),
  tx: Tx,
) -> Result(CommitResult, CommitError) {
  process.call_forever(writer, Commit(tx, _))
}

/// Batch entry fetch through the writer.
///
/// ## Examples
///
/// ```gleam
/// // writer.get_entries(subject, [id])
/// ```
///
pub fn get_entries(
  writer: Subject(Message),
  ids: List(EntryId),
) -> Result(Dict(EntryId, Entry), StorageError) {
  process.call_forever(writer, GetEntries(ids, _))
}

/// One register point-lookup through the writer.
///
/// ## Examples
///
/// ```gleam
/// // writer.get_register(subject, register.OpState, key)
/// ```
///
pub fn get_register(
  writer: Subject(Message),
  ns: RegisterNs,
  key: String,
) -> Result(Option(storage.Register), StorageError) {
  process.call_forever(writer, GetRegister(ns, key, _))
}

/// A namespace listing through the writer.
///
/// ## Examples
///
/// ```gleam
/// // writer.list_registers(subject, register.PendingEntry, None)
/// ```
///
pub fn list_registers(
  writer: Subject(Message),
  ns: RegisterNs,
  key_prefix: Option(String),
) -> Result(List(#(String, storage.Register)), StorageError) {
  process.call_forever(writer, ListRegisters(ns, key_prefix, _))
}

/// A branch scan through the writer.
///
/// ## Examples
///
/// ```gleam
/// // writer.scan_branch(subject, storage.branch_scan(from: leaf))
/// ```
///
pub fn scan_branch(
  writer: Subject(Message),
  q: storage.BranchScan,
) -> Result(List(Entry), StorageError) {
  process.call_forever(writer, ScanBranch(q, _))
}

/// A usage-ledger read through the writer.
///
/// ## Examples
///
/// ```gleam
/// // writer.scan_usage(subject, storage.usage_scan())
/// ```
///
pub fn scan_usage(
  writer: Subject(Message),
  q: storage.UsageScan,
) -> Result(List(UsageRow), StorageError) {
  process.call_forever(writer, ScanUsage(q, _))
}

/// The stats projection through the writer.
///
/// ## Examples
///
/// ```gleam
/// // writer.stats(subject)
/// ```
///
pub fn stats(
  writer: Subject(Message),
) -> Result(storage.SessionStats, StorageError) {
  process.call_forever(writer, Stats)
}

/// Subscribes a subject to committed events (fire-and-forget).
///
/// ## Examples
///
/// ```gleam
/// // writer.subscribe(subject, events_subject)
/// ```
///
pub fn subscribe(writer: Subject(Message), subscriber: Subject(Event)) -> Nil {
  process.send(writer, Subscribe(subscriber))
}
