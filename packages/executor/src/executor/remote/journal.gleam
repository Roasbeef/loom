//// SQLite custody for one exact executor scope, before any native action.
////
//// A weft actor owns each connection. Every operation takes SQLite's immediate
//// writer lock, reads the current version, reduces against that committed book,
//// and commits changed evidence before replying. Independent opens therefore
//// share SQLite's serialization point, even across VMs. A stale actor replays
//// the bounded journal through admission, discarding every historical effect.
////
//// Fresh creation never replaces tables. Recovery never initializes them. The
//// metadata binds exact scope, capacity, row count and encoded-byte count; gaps,
//// extra rows, unknown commands and invalid transitions refuse recovery. Exact
//// duplicates write nothing. Each retained key has at most six changed records,
//// plus one closure record, so storage grows only with reserved lifetime slots.
////
//// A database error poisons and closes the connection. `Uncertain` can include
//// a committed transition; callers must recover and inspect the original key.
//// Timeout also means uncertainty, never definite refusal. Recovery returns no
//// launch decisions. The live caller must apply a returned Launch at most once;
//// this module neither launches processes nor proves native restart recovery.
////
//// Named queries and their row decoders come from Parrot/sqlc. The SQL source
//// owns storage shape; this module owns transactions and admission ordering.
////
//// ## Flow
////
//// `fresh` and `recover` enter `setup` then `load`. Calls enter `exchange` and
//// `handle`: `transact` reads `current`, applies the pure reducer and commits
//// before replying. `payload_write` performs the same locked admission preflight
//// before storing exact bytes. `read_payload` checks blob-free aggregate bounds
//// then decodes generated SQL rows; it never recreates a launch decision.

import executor/custody_schema
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal_codec as codec
import executor/remote/payload
import executor/sql
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import sqlight
import weft/actor

/// A serialized custody endpoint; the database connection never leaves its actor.
pub opaque type Journal {
  /// Only module functions construct requests and receive bounded responses.
  Journal(
    /// The private actor address, never a database handle or native capability.
    subject: process.Subject(Message),
  )
}

/// A bounded failure whose meaning never depends on caller-controlled SQL text.
pub type Error {
  /// Durability requires an absolute filesystem path, not a SQLite memory URI.
  InvalidPath

  /// Fresh creation found an existing filesystem path.
  AlreadyExists

  /// Recovery found no existing file; it creates no ledger.
  Missing

  /// Stored scope or capacity differs, including an unknown metadata version.
  BindingMismatch

  /// Rows, counts, bytes or reducer history fail complete validation.
  Corrupt

  /// The pure reducer refused the request without changing durable evidence.
  Rejected(
    /// The reducer's fixed, payload-free refusal.
    reason: admission.AdmissionError,
  )

  /// Database or reply failure; a write may have committed. Recover exact evidence.
  Uncertain

  /// The endpoint was released or poisoned; reopen through recovery.
  Closed

  /// The weft actor could not start; no launch decision was returned.
  StartFailed
}

/// A committed live decision, without exposing a duplicable replacement book.
pub type Decision {
  /// Evidence and launch permission are exposed only after the commit succeeds.
  Decision(
    /// The exact current reducer evidence.
    evidence: admission.Evidence,
    /// A live first-launch decision; historical effects never cross recovery.
    effect: admission.Effect,
  )
}

type Mode {
  Fresh
  Recover
}

type Config {
  Config(path: String, scope: identity.Scope, capacity: admission.Capacity)
}

type Snapshot {
  Snapshot(book: admission.Book, version: Int, bytes: Int)
}

type State {
  Waiting(config: Config)
  Ready(config: Config, connection: sqlight.Connection, snapshot: Snapshot)
}

type Message {
  Initialise(mode: Mode, reply: process.Subject(Result(Nil, Error)))
  Change(
    command: codec.Command,
    reply: process.Subject(Result(Option(Decision), Error)),
  )
  Inspect(
    key: identity.RequestKey,
    digest: identity.Digest,
    reply: process.Subject(Result(admission.Evidence, Error)),
  )
  PutPayload(
    key: identity.RequestKey,
    digest: identity.Digest,
    item: payload.Item,
    reply: process.Subject(Result(Nil, Error)),
  )
  ReadPayload(
    key: identity.RequestKey,
    digest: identity.Digest,
    reply: process.Subject(Result(List(payload.Item), Error)),
  )
  Release(reply: process.Subject(Result(Nil, Error)))
}

const timeout_ms = 30_000

/// Creates custody for an unused database path. Existing evidence is never reset.
/// Metadata and schema commit together before this endpoint is returned.
/// Paths must be absolute filesystem names of at most 4096 bytes without NUL.
///
/// ## Examples
///
/// ```gleam
/// journal.fresh(path, scope, capacity) // -> Ok(journal) for an unused path.
/// ```
pub fn fresh(
  path: String,
  scope: identity.Scope,
  capacity: admission.Capacity,
) -> Result(Journal, Error) {
  start(Config(path, scope, capacity), Fresh)
}

/// Opens existing custody and replays changed commands without returning effects.
/// Scope and capacity must match the original creation exactly.
///
/// ## Examples
///
/// ```gleam
/// journal.recover(path, scope, capacity) // -> retained evidence, never Launch.
/// ```
pub fn recover(
  path: String,
  scope: identity.Scope,
  capacity: admission.Capacity,
) -> Result(Journal, Error) {
  start(Config(path, scope, capacity), Recover)
}

/// Durably reserves bounded evidence before acknowledging the admission.
/// An exact duplicate returns existing evidence and does not append a record.
///
/// ## Examples
///
/// ```gleam
/// journal.admit(journal, key, digest) // -> Ok(Decision(_, NoLaunch)).
/// ```
pub fn admit(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Decision, Error) {
  change(journal, codec.Admit(key, digest)) |> require_decision
}

/// Commits changed custody before exposing its acknowledgement or first Launch.
/// The trusted native adapter supplies retirement and durable receipt evidence.
///
/// ## Examples
///
/// ```gleam
/// journal.apply(journal, key, digest, admission.AuthorizeLaunch)
/// // -> Launch only for the first successfully committed live authorization.
/// ```
pub fn apply(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  event: admission.Event,
) -> Result(Decision, Error) {
  change(journal, codec.Apply(key, digest, event)) |> require_decision
}

/// Permanently closes this scope's admission epoch without releasing evidence.
/// Repeated closure writes nothing; settlement and exact inspection remain valid.
///
/// ## Examples
///
/// ```gleam
/// journal.close_epoch(journal) // -> Ok(Nil) after the closure commits.
/// ```
pub fn close_epoch(journal: Journal) -> Result(Nil, Error) {
  change(journal, codec.CloseEpoch) |> result.map(fn(_) { Nil })
}

/// Inspects the latest committed exact key, including after closure or compaction.
/// Independent writers are observed under the same SQLite transaction discipline.
///
/// ## Examples
///
/// ```gleam
/// journal.inspect(journal, key, digest) // -> Ok(retained_evidence).
/// ```
pub fn inspect(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(admission.Evidence, Error) {
  exchange(journal, Inspect(key, digest, _))
}

/// Commits immutable bounded bytes before admission, output or terminal acknowledgement.
/// Request reservation consumes a lifetime slot even if admission later fails.
/// Duplicate items compare exact bytes and append nothing; conflicting bytes fail.
///
/// ## Examples
///
/// ```gleam
/// journal.put_payload(journal, key, digest, payload.Request(bytes))
/// ```
pub fn put_payload(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  item: payload.Item,
) -> Result(Nil, Error) {
  exchange(journal, PutPayload(key, digest, item, _))
}

/// Retrieves original bounded immutable evidence, including after compaction.
/// No receipt or broker release deletes the only copy of result bytes.
///
/// ## Examples
///
/// ```gleam
/// journal.payloads(journal, key, digest) // -> exact retained items.
/// ```
pub fn payloads(
  journal: Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(List(payload.Item), Error) {
  exchange(journal, ReadPayload(key, digest, _))
}

/// Releases this connection without closing the epoch or declaring native drain.
/// The endpoint remains closed; recovery is a separate, explicit operation.
///
/// ## Examples
///
/// ```gleam
/// journal.release(journal) // -> Ok(Nil); journal.recover restores the ledger.
/// ```
pub fn release(journal: Journal) -> Result(Nil, Error) {
  case exchange(journal, Release) {
    Error(Closed) -> Ok(Nil)
    outcome -> outcome
  }
}

fn start(config: Config, mode: Mode) -> Result(Journal, Error) {
  use Nil <- result.try(
    case
      string.starts_with(config.path, "/")
      && string.byte_size(config.path) <= 4096
      && !string.contains(config.path, "\u{0}")
    {
      True -> Ok(Nil)
      False -> Error(InvalidPath)
    },
  )
  use started <- result.try(
    actor.new(Waiting(config))
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.unlinked
    |> actor.start
    |> result.map_error(fn(_) { StartFailed }),
  )
  let journal = Journal(started.data)
  case exchange(journal, Initialise(mode, _)) {
    Ok(Nil) -> Ok(journal)
    Error(error) -> {
      // Startup uncertainty may leave initialization queued. Releasing behind
      // it ensures that an endpoint withheld from the caller cannot linger.
      process.send(journal.subject, Release(process.new_subject()))
      Error(error)
    }
  }
}

fn change(
  journal: Journal,
  command: codec.Command,
) -> Result(Option(Decision), Error) {
  exchange(journal, Change(command, _))
}

fn exchange(
  journal: Journal,
  make_request: fn(process.Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  use owner <- result.try(
    process.subject_owner(journal.subject) |> result.map_error(fn(_) { Closed }),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error(Closed)
  })
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  process.send(journal.subject, make_request(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) { Error(Uncertain) })
    |> process.selector_receive(timeout_ms)

  // Death after sending cannot prove that the transaction did not commit.
  // Demonitoring flushes its notification; timeout only abandons the wait.
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(Uncertain))
}

fn require_decision(
  value: Result(Option(Decision), Error),
) -> Result(Decision, Error) {
  use decision <- result.try(value)
  case decision {
    Some(value) -> Ok(value)
    None -> Error(Corrupt)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message, state {
    Initialise(mode, reply), Waiting(config) -> {
      case initialise(config, mode) {
        Ok(#(connection, snapshot)) -> {
          process.send(reply, Ok(Nil))
          actor.continue(Ready(config, connection, snapshot))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.stop()
        }
      }
    }
    Change(command, reply), Ready(config, connection, snapshot) -> {
      let outcome = transact(connection, config, snapshot, command)
      settle_change(outcome, config, connection, snapshot, reply)
    }
    Inspect(key, digest, reply), Ready(config, connection, snapshot) -> {
      let outcome = read_current(connection, config, snapshot)
      settle_inspect(outcome, config, connection, key, digest, reply)
    }
    PutPayload(key, digest, item, reply), Ready(config, connection, snapshot) -> {
      let outcome =
        payload_write(connection, config, snapshot, key, digest, item)
      process.send(reply, outcome)
      case outcome {
        Ok(_) | Error(Rejected(_)) -> actor.continue(state)
        Error(_) -> actor.stop()
      }
    }
    ReadPayload(key, digest, reply), Ready(config, connection, _) -> {
      let outcome = read_payload(connection, config, key, digest)
      process.send(reply, outcome)
      case outcome {
        Ok(_) | Error(Rejected(_)) -> actor.continue(state)
        Error(_) -> actor.stop()
      }
    }
    PutPayload(_, _, _, reply), Waiting(_) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    ReadPayload(_, _, reply), Waiting(_) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Release(reply), Ready(_, connection, _) -> {
      process.send(reply, sqlight.close(connection) |> sql_error)
      actor.stop()
    }
    Release(reply), Waiting(_) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Initialise(_, reply), Ready(_, _, _) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Change(_, reply), Waiting(_) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Inspect(_, _, reply), Waiting(_) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
  }
}

fn initialise(
  config: Config,
  mode: Mode,
) -> Result(#(sqlight.Connection, Snapshot), Error) {
  use exists <- result.try(
    simplifile.exists(config.path, False)
    |> result.map_error(fn(_) { Uncertain }),
  )
  use Nil <- result.try(case mode, exists {
    Fresh, True -> Error(AlreadyExists)
    Recover, False -> Error(Missing)
    Fresh, False | Recover, True -> Ok(Nil)
  })
  use connection <- result.try(sqlight.open(config.path) |> sql_error)
  let outcome = setup(connection, config, mode)
  case outcome {
    Ok(snapshot) -> Ok(#(connection, snapshot))
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

fn setup(
  connection: sqlight.Connection,
  config: Config,
  mode: Mode,
) -> Result(Snapshot, Error) {
  // Require a crash-safe journal mode rather than inheriting a database's
  // configuration. FULL synchronization then makes commit the custody boundary.
  use Nil <- result.try(
    sqlight.exec("PRAGMA busy_timeout=5000", connection) |> sql_error,
  )
  use modes <- result.try(
    sqlight.query(
      "PRAGMA journal_mode=WAL",
      connection,
      [],
      decode.field(0, decode.string, decode.success),
    )
    |> sql_error,
  )
  use Nil <- result.try(case modes {
    ["wal"] -> Ok(Nil)
    _ -> Error(Uncertain)
  })
  use Nil <- result.try(
    sqlight.exec(
      "PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE",
      connection,
    )
    |> sql_error,
  )
  use Nil <- result.try(case mode {
    Fresh -> create(connection, config)
    Recover -> Ok(Nil)
  })
  use snapshot <- result.try(load(connection, config))
  use Nil <- result.try(sqlight.exec("COMMIT", connection) |> sql_error)
  Ok(snapshot)
}

fn create(
  connection: sqlight.Connection,
  config: Config,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    sqlight.exec(custody_schema.schema, connection)
    |> sql_error,
  )
  statement(
    connection,
    sql.initialize_custody(
      codec.binding(config.scope),
      admission.capacity_value(config.capacity),
    ),
  )
}

fn metadata(
  connection: sqlight.Connection,
  config: Config,
) -> Result(#(Int, Int), Error) {
  // SQLite affinity permits blobs in integer columns. Project only bounded
  // scalars so corruption cannot allocate a blob before the decoder refuses it.
  use rows <- result.try(
    query(connection, sql.custody_metadata())
    |> result.map_error(fn(_) { Corrupt }),
  )
  case rows {
    [sql.CustodyMetadata(binding:, capacity:, version:, bytes:)] -> {
      use Nil <- result.try(
        case
          binding == codec.binding(config.scope)
          && capacity == admission.capacity_value(config.capacity)
        {
          True -> Ok(Nil)
          False -> Error(BindingMismatch)
        },
      )
      let max_records = capacity * 6 + 1
      case
        version >= 0
        && version <= max_records
        && bytes >= 0
        && bytes <= version * codec.record_bytes
      {
        True -> Ok(#(version, bytes))
        False -> Error(Corrupt)
      }
    }
    _ -> Error(Corrupt)
  }
}

fn load(
  connection: sqlight.Connection,
  config: Config,
) -> Result(Snapshot, Error) {
  use meta <- result.try(metadata(connection, config))
  load_rows(connection, config, meta)
}

fn load_rows(
  connection: sqlight.Connection,
  config: Config,
  meta: #(Int, Int),
) -> Result(Snapshot, Error) {
  let #(version, bytes) = meta
  use rows <- result.try(
    query(
      connection,
      sql.custody_events(admission.capacity_value(config.capacity) * 6 + 2),
    )
    |> result.map_error(fn(_) { Corrupt }),
  )
  use snapshot <- result.try(
    list.try_fold(
      rows,
      Snapshot(admission.new(config.scope, config.capacity), 0, 0),
      fn(snapshot, row) {
        replay(snapshot, #(row.seq, row.payload), config.scope)
      },
    ),
  )
  case snapshot.version == version && snapshot.bytes == bytes {
    True -> Ok(snapshot)
    False -> Error(Corrupt)
  }
}

fn replay(
  snapshot: Snapshot,
  row: #(Int, BitArray),
  scope: identity.Scope,
) -> Result(Snapshot, Error) {
  let #(sequence, payload) = row
  use Nil <- result.try(case sequence == snapshot.version + 1 {
    True -> Ok(Nil)
    False -> Error(Corrupt)
  })
  use command <- result.try(
    codec.decode(payload, scope) |> result.map_error(fn(_) { Corrupt }),
  )
  use changed <- result.try(
    reduce(snapshot.book, command) |> result.map_error(fn(_) { Corrupt }),
  )
  let #(book, _historical_decision) = changed

  // A durable record must represent a real change. Discarding the historical
  // decision prevents recovery from exposing the first authorization again.
  case book != snapshot.book {
    True ->
      Ok(Snapshot(book, sequence, snapshot.bytes + bit_array.byte_size(payload)))
    False -> Error(Corrupt)
  }
}

fn reduce(
  book: admission.Book,
  command: codec.Command,
) -> Result(#(admission.Book, Option(Decision)), Error) {
  case command {
    codec.CloseEpoch -> Ok(#(admission.close(book), None))
    codec.Admit(key, digest) -> {
      use transition <- result.try(
        admission.admit(book, key, digest) |> result.map_error(Rejected),
      )
      Ok(#(
        transition.next,
        Some(Decision(transition.evidence, transition.effect)),
      ))
    }
    codec.Apply(key, digest, event) -> {
      use transition <- result.try(
        admission.reduce(book, key, digest, event) |> result.map_error(Rejected),
      )
      Ok(#(
        transition.next,
        Some(Decision(transition.evidence, transition.effect)),
      ))
    }
  }
}

fn current(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
) -> Result(Snapshot, Error) {
  use meta <- result.try(metadata(connection, config))
  case meta == #(snapshot.version, snapshot.bytes) {
    True -> Ok(snapshot)
    False -> load_rows(connection, config, meta)
  }
}

fn transact(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
  command: codec.Command,
) -> Result(#(Snapshot, Option(Decision)), Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = persist(connection, config, snapshot, command)
  finish_transaction(connection, outcome)
}

fn persist(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
  command: codec.Command,
) -> Result(#(Snapshot, Option(Decision)), Error) {
  use latest <- result.try(current(connection, config, snapshot))
  use changed <- result.try(reduce(latest.book, command))
  let #(book, decision) = changed
  case book == latest.book {
    True -> Ok(#(latest, decision))
    False -> {
      use next <- result.try(append(
        connection,
        latest,
        book,
        codec.encode(command),
      ))
      Ok(#(next, decision))
    }
  }
}

fn append(
  connection: sqlight.Connection,
  old: Snapshot,
  book: admission.Book,
  payload: BitArray,
) -> Result(Snapshot, Error) {
  let version = old.version + 1
  let bytes = old.bytes + bit_array.byte_size(payload)
  use _ <- result.try(statement(
    connection,
    sql.append_custody_event(version, payload),
  ))

  // The writer lock makes this CAS uncontended in normal operation. Checking
  // its returned row also refuses a schema or trigger that lost the head update.
  use rows <- result.try(query(
    connection,
    sql.advance_custody_head(version, bytes, old.version, old.bytes),
  ))
  case rows {
    [sql.AdvanceCustodyHead(version: value)] if value == version ->
      Ok(Snapshot(book, version, bytes))
    _ -> Error(Uncertain)
  }
}

fn finish_transaction(
  connection: sqlight.Connection,
  outcome: Result(a, Error),
) -> Result(a, Error) {
  case outcome {
    Ok(value) -> {
      use Nil <- result.try(sqlight.exec("COMMIT", connection) |> sql_error)
      Ok(value)
    }
    Error(error) -> {
      case sqlight.exec("ROLLBACK", connection) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(Uncertain)
      }
    }
  }
}

fn read_current(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
) -> Result(Snapshot, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  finish_transaction(connection, current(connection, config, snapshot))
}

fn settle_change(
  outcome: Result(#(Snapshot, Option(Decision)), Error),
  config: Config,
  connection: sqlight.Connection,
  previous: Snapshot,
  reply: process.Subject(Result(Option(Decision), Error)),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(#(snapshot, decision)) -> {
      process.send(reply, Ok(decision))
      actor.continue(Ready(config, connection, snapshot))
    }
    Error(Rejected(reason)) -> {
      process.send(reply, Error(Rejected(reason)))

      // A reducer rejection rolled back safely. A cached older version stays
      // valid: the next transaction reloads if another connection advanced it.
      actor.continue(Ready(config, connection, previous))
    }
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      process.send(reply, Error(error))
      actor.stop()
    }
  }
}

fn settle_inspect(
  outcome: Result(Snapshot, Error),
  config: Config,
  connection: sqlight.Connection,
  key: identity.RequestKey,
  digest: identity.Digest,
  reply: process.Subject(Result(admission.Evidence, Error)),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(snapshot) -> {
      process.send(
        reply,
        admission.inspect(snapshot.book, key, digest)
          |> result.map_error(Rejected),
      )
      actor.continue(Ready(config, connection, snapshot))
    }
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      process.send(reply, Error(error))
      actor.stop()
    }
  }
}

// Generated statements run on the actor's existing transaction. The adapter
// preserves sqlc's parameter order and decoder instead of maintaining a second
// handwritten account of the query's columns.
fn statement(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, parameters) = generated
  query(connection, #(text, parameters, decode.success(Nil)))
  |> result.replace(Nil)
}

fn query(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, parameters, decoder) = generated
  use arguments <- result.try(list.try_map(parameters, parameter))
  sqlight.query(text, connection, arguments, decoder) |> sql_error
}

// The custody schema binds only integers and binary payloads. A generator or
// schema change introducing another kind must update this explicit boundary.
fn parameter(value: dev.Param) -> Result(sqlight.Value, Error) {
  case value {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
    dev.ParamString(_)
    | dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_)
    | dev.ParamNullable(_) -> Error(Uncertain)
  }
}

fn sql_error(value: Result(a, sqlight.Error)) -> Result(a, Error) {
  result.map_error(value, fn(_) { Uncertain })
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Ready(_, connection, _) -> {
      let _ = sqlight.close(connection)
      Nil
    }
    Waiting(_) -> Nil
  }
}

fn read_payload(
  connection: sqlight.Connection,
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(List(payload.Item), Error) {
  use Nil <- result.try(case identity.key_scope(key) == config.scope {
    True -> Ok(Nil)
    False -> Error(Rejected(admission.ScopeMismatch))
  })

  // Aggregates contain no blobs. Corrupt counts and cumulative bytes are
  // refused before the driver can materialize any payload body.
  use Nil <- result.try(
    list.try_each(
      [
        #(0, 1, 131_072),
        #(1, 1, 1024),
        #(2, 64, 1_048_576),
        #(3, 1, 32_768),
        #(4, 1, 32_768),
      ],
      fn(bound) {
        let #(kind, count, bytes) = bound
        use inventory <- result.try(query(
          connection,
          sql.payload_inventory(payload_locator(key, digest), kind),
        ))
        case inventory {
          [sql.PayloadInventory(items, total)]
            if items >= 0 && items <= count && total >= 0 && total <= bytes
          -> Ok(Nil)
          _ -> Error(Corrupt)
        }
      },
    ),
  )
  use rows <- result.try(query(
    connection,
    sql.read_custody_payload(payload_locator(key, digest)),
  ))
  use items <- result.try(
    list.try_map(rows, fn(row) {
      use Nil <- result.try(case row.digest == identity.digest_bytes(digest) {
        True -> Ok(Nil)
        False -> Error(Rejected(admission.RequestConflict))
      })
      payload.from_fields(row.kind, row.ordinal, row.body)
      |> result.map_error(fn(_) { Corrupt })
    }),
  )
  payload.validate_inventory(items) |> result.map_error(fn(_) { Corrupt })
}

fn payload_write(
  connection: sqlight.Connection,
  config: Config,
  snapshot: Snapshot,
  key: identity.RequestKey,
  digest: identity.Digest,
  item: payload.Item,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    payload.validate(item) |> result.map_error(fn(_) { Corrupt }),
  )
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use snapshot <- result.try(current(connection, config, snapshot))

    // Admission preflight is pure: a closed epoch cannot acquire new payload
    // custody, while existing keys still reconcile output and terminal bytes.
    use _ <- result.try(
      admission.admit(snapshot.book, key, digest) |> result.map_error(Rejected),
    )
    persist_payload(connection, config, key, digest, item)
  }
  case outcome {
    Ok(Nil) -> sqlight.exec("COMMIT", connection) |> sql_error
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
  }
}

fn persist_payload(
  connection: sqlight.Connection,
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
  item: payload.Item,
) -> Result(Nil, Error) {
  use previous <- result.try(read_payload(connection, config, key, digest))
  let #(kind, ordinal, body) = payload.fields(item)
  case
    list.find(previous, fn(old) {
      let #(old_kind, old_ordinal, _) = payload.fields(old)
      old_kind == kind && old_ordinal == ordinal
    })
  {
    Ok(old) if old == item -> Ok(Nil)
    Ok(_) -> Error(Rejected(admission.ResultConflict))
    Error(_) ->
      insert_payload(connection, config, key, digest, previous, item, body)
  }
}

fn insert_payload(
  connection: sqlight.Connection,
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
  previous: List(payload.Item),
  item: payload.Item,
  body: BitArray,
) -> Result(Nil, Error) {
  use _ <- result.try(
    payload.validate_inventory([item, ..previous])
    |> result.map_error(fn(_) { Rejected(admission.Saturated) }),
  )
  let #(kind, ordinal, _) = payload.fields(item)
  use Nil <- result.try(case item, previous {
    payload.Request(_), [] | payload.Cancellation(_), [] -> {
      use counts <- result.try(query(connection, sql.payload_reservations()))
      let maximum = admission.capacity_value(config.capacity)
      case counts {
        [sql.PayloadReservations(items)] if items >= 0 && items < maximum ->
          Ok(Nil)
        _ -> Error(Rejected(admission.Saturated))
      }
    }
    payload.Request(_), _ -> Error(Rejected(admission.RequestConflict))
    _, [] -> Error(Rejected(admission.UnknownRequest))
    _, _ -> Ok(Nil)
  })
  statement(
    connection,
    sql.insert_custody_payload(
      payload_locator(key, digest),
      identity.digest_bytes(digest),
      kind,
      ordinal,
      body,
    ),
  )
}

fn payload_locator(
  key: identity.RequestKey,
  digest: identity.Digest,
) -> BitArray {
  // Admit encoding ends in fixed 32-byte content evidence. The locator keeps
  // only logical identity so conflicting digests cannot reserve a second slot.
  let bytes = codec.encode(codec.Admit(key, digest))
  bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 32)
  |> result.lazy_unwrap(fn() { <<>> })
}
