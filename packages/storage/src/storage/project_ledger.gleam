//// A project's ledger file: the engine's event history, the scanner's read
//// positions, and the outside actions waiting for the host (protocol-change/106,
//// "Durable state").
////
//// A project is one workspace with a router session and many worker sessions
//// (`docs/design-notes/project-mode.md`). Its history cannot live in a session's
//// conversation store, because a project outlives every session and a session
//// store cannot commit together with anything else. So each project has one
//// SQLite file of its own. One actor, the project's, owns the connection; this
//// module is the storage layer under that actor and has no process of its own.
//// The file is never replicated and the catalogue records only its path.
////
//// ## What the file holds
////
//// - `ledger_event` is append-only. The engine encodes each accepted event as
////   JSON, and this module stores that text beside the system time the caller
////   read and returns it unchanged. Storage does not depend on the engine, so
////   it neither parses nor validates an event beyond checking that the text is
////   one JSON document. The engine's codec is the only reader that gives the
////   text meaning.
//// - `scanner_cursor` holds, for each worker session, the id of the last entry
////   whose report or human turn the engine has taken in.
//// - `effect_row` holds the actions the engine decided on and the host has not
////   yet settled, keyed by `(kind, key)`.
//// - `ledger_snapshot` is the retention hook: at most one row, the engine's
////   state as of every event below `before_seq`.
////
//// ## Why the effect rows share a transaction with the event
////
//// An effect is a consequence of an event, and a crash between writing the two
//// would leave one without the other. `append_with_effects` writes the event
//// and its effect rows in one immediate transaction, so a restart finds either
//// both or neither. Effects carry keys derived from the event that caused them,
//// so writing the same intent again replaces its row instead of adding a second
//// one, and the host may safely perform an effect at least once.
////
//// ## Retention
////
//// `compact_before` deletes the events below a sequence number and writes the
//// snapshot that stands for them in the same transaction. When to compact and
//// what the snapshot holds are the engine's decisions; this module only keeps
//// the two writes together and refuses a replay that would start inside the
//// deleted range, so a caller cannot read a history with a hole in it.
////
//// ## Time
////
//// Every time is Unix milliseconds that the caller read from the system clock
//// and passed in. This module reads no clock, and a time from the monotonic
//// clock must never be passed, because it is meaningless after a restart.

import core/json
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/project_ledger_schema
import storage/sql
import storage/sqlite_policy

/// An open ledger file, owned by one project actor.
pub opaque type Ledger {
  Ledger(connection: sqlight.Connection)
}

/// One stored event, as it was appended.
pub type StoredEvent {
  StoredEvent(
    /// The position in the history. It starts at 1 and rises by one for each
    /// event, and a number is never given to a second event.
    seq: Int,
    /// The system time the caller gave when it appended the event.
    at_ms: Int,
    /// The engine's own encoding of the event, one JSON document.
    event_json: String,
  )
}

/// An outside action to be queued, before the ledger has counted any attempt at
/// it.
pub type EffectDraft {
  EffectDraft(
    /// The family of action, such as a reply or a pull request, one to
    /// `kind_limit` bytes of printable text.
    kind: String,
    /// Which action of that kind, one to `key_limit` bytes of printable text.
    /// The engine derives it from the event that caused the effect.
    key: String,
    /// What the host needs to perform the action, one JSON document.
    payload_json: String,
    /// The earliest system time the host may try the action.
    due_ms: Int,
  )
}

/// A queued outside action as the ledger holds it.
pub type Effect {
  Effect(
    /// The family of action.
    kind: String,
    /// Which action of that kind.
    key: String,
    /// What the host needs to perform the action, one JSON document.
    payload_json: String,
    /// How many times the row has been deferred since it was written.
    attempts: Int,
    /// The earliest system time the host may try the action.
    due_ms: Int,
  )
}

/// The state the engine saved when it compacted its history.
pub type Snapshot {
  Snapshot(
    /// The snapshot stands for every event below this sequence number. The
    /// events at and above it are still in the file.
    before_seq: Int,
    /// The system time the snapshot was written.
    at_ms: Int,
    /// The engine's own encoding of its state, one JSON document.
    snapshot_json: String,
  )
}

/// Everything that can stop a ledger call.
pub type Error {
  /// The file is not a project ledger, or is one this build does not know how
  /// to read. Nothing was changed.
  Unsupported

  /// The caller's input broke the rule the reason names, and nothing was
  /// written.
  Invalid(reason: String)

  /// A stored row broke its grammar. The call fails and does not skip the row,
  /// because a history read with a row missing would replay as a different
  /// history.
  MalformedRow(reason: String)

  /// No effect row has this kind and key.
  Missing

  /// A replay asked for events the ledger compacted. The history before `floor`
  /// is in the snapshot, and a replay can start at `floor - 1` or later.
  Compacted(floor: Int)

  /// SQLite could not complete the operation.
  Database(reason: String)
}

/// The most events one `replay` page returns.
pub const replay_page_limit = 500

/// The most effects one `effects_due` page returns.
pub const due_page_limit = 100

/// The most bytes a kind, a session id or an entry id holds.
pub const kind_limit = 64

/// The most bytes an effect key holds.
pub const key_limit = 256

/// The most bytes an event or an effect payload holds.
pub const event_limit = 1_048_576

/// The most bytes a snapshot holds.
pub const snapshot_limit = 67_108_864

// The four letters "PLDG" read as a number, so a catalogue, an executor ledger
// or another application's database opened in this one's place is refused.
const application_id = 1_347_175_495

const schema_version = 1

/// Opens the ledger at `path`, creating and initializing the file when it does
/// not exist.
///
/// A file that is not a project ledger, or has a newer version than this build
/// knows, is `Unsupported` and is left unchanged. The parent directory must
/// exist and be private to the daemon. The ledger is a custody record, so the
/// connection syncs on every commit: an event the actor acted on must survive
/// power loss, or a restart would repeat an outside action.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.open(project_dir <> "/ledger.db")
/// ```
pub fn open(path: String) -> Result(Ledger, Error) {
  use Nil <- result.try(
    sqlite_policy.refusing_unopenable_path(path)
    |> result.map_error(Database),
  )
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(sql_error),
  )

  // A file that cannot be initialized is closed before the failure is returned.
  case initialize(connection) {
    Ok(Nil) -> Ok(Ledger(connection))
    Error(error) -> {
      let _closed = sqlight.close(connection)
      Error(error)
    }
  }
}

/// Closes the connection. Everything written stays in the file.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.close(ledger)
/// ```
pub fn close(ledger: Ledger) -> Result(Nil, Error) {
  sqlight.close(ledger.connection) |> result.map_error(sql_error)
}

/// Appends one event and returns its sequence number.
///
/// `event_json` must be one JSON document of at most `event_limit` bytes, and
/// `at_ms` a system time. A refused call writes nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.append(ledger, "{\"type\":\"opened\"}", 1_700_000_000_000)
/// ```
pub fn append(
  ledger: Ledger,
  event_json: String,
  at_ms: Int,
) -> Result(Int, Error) {
  append_with_effects(ledger, event_json, at_ms, [])
}

/// Appends one event and queues its effects in one transaction, and returns the
/// event's sequence number.
///
/// Either the event and every effect are written, or none is: a draft that
/// breaks its grammar is refused before anything is written, and a failure
/// inside the transaction rolls the event back with the effects already queued.
/// An effect whose `(kind, key)` is already queued replaces that row, as
/// `enqueue` does.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.append_with_effects(ledger, event, now, [reply_draft])
/// ```
pub fn append_with_effects(
  ledger: Ledger,
  event_json: String,
  at_ms: Int,
  effects: List(EffectDraft),
) -> Result(Int, Error) {
  use Nil <- result.try(valid_document(event_json, event_limit, "event"))
  use Nil <- result.try(valid_time(at_ms))
  use Nil <- result.try(list.try_each(effects, valid_draft))
  transaction(ledger.connection, fn() {
    use rows <- result.try(rows(
      ledger.connection,
      sql.project_ledger_append(at_ms, event_json),
    ))

    // The insert returns the row it wrote, so any other count is a fault.
    use seq <- result.try(case rows {
      [row] -> Ok(row.seq)
      [] | [_, _, ..] -> Error(MalformedRow("an append returned no sequence"))
    })

    // The effects join the event's transaction, so a failure here takes the
    // event back out with them.
    use Nil <- result.map(
      list.try_each(effects, fn(draft) { put_effect(ledger.connection, draft) }),
    )
    seq
  })
}

/// Reads the events after `after_seq` in order, at most `limit` of them (and
/// never more than `replay_page_limit`). A caller continues after the last
/// sequence number it received; an empty page means it has read everything.
///
/// A replay that would start inside the range `compact_before` deleted is
/// `Compacted(floor)`: the caller reads `snapshot` and replays from the events
/// that follow it. A stored row whose time is negative or whose text is not a
/// JSON document is `MalformedRow`.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.replay(ledger, 0, 100) == Ok([])
/// ```
pub fn replay(
  ledger: Ledger,
  after_seq: Int,
  limit: Int,
) -> Result(List(StoredEvent), Error) {
  // A negative position names nothing, and is refused before a read.
  use Nil <- result.try(case after_seq >= 0 {
    True -> Ok(Nil)
    False ->
      Error(Invalid("a replay starts at a sequence number of zero or more"))
  })

  // The earliest event the ledger still holds bounds where a replay may start.
  use floor <- result.try(retained_from(ledger))

  // The snapshot stands for the events below `floor`, so a replay may begin
  // only where its first event is `floor` or later.
  case after_seq + 1 < floor {
    True -> Error(Compacted(floor:))
    False -> {
      let bound = int.max(1, int.min(limit, replay_page_limit))
      use stored <- result.try(rows(
        ledger.connection,
        sql.project_ledger_events_after(after_seq, bound),
      ))
      list.try_map(stored, fn(row) {
        decode_event(row.seq, row.at_ms, row.event_json)
      })
    }
  }
}

/// The sequence number of the newest event, or 0 when the ledger holds none.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.last_seq(ledger) == Ok(0)
/// ```
pub fn last_seq(ledger: Ledger) -> Result(Int, Error) {
  use found <- result.try(rows(ledger.connection, sql.project_ledger_last_seq()))

  // An aggregate over a table always answers one row.
  case found {
    [row] -> Ok(row.last_seq)
    [] | [_, _, ..] -> Error(MalformedRow("expected one sequence row"))
  }
}

/// Queues an outside action, or replaces the queued action with the same
/// `(kind, key)`.
///
/// A replacement is a newer intent for the same action, so it takes the new
/// payload and time and starts counting attempts again. Replacing is therefore
/// how the engine restates an effect, and enqueueing the same draft twice
/// leaves one row.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.enqueue(ledger, EffectDraft("reply", "t1-3", "{}", 0))
/// ```
pub fn enqueue(ledger: Ledger, draft: EffectDraft) -> Result(Nil, Error) {
  use Nil <- result.try(valid_draft(draft))
  put_effect(ledger.connection, draft)
}

/// Lists the queued actions whose time has come, earliest first, at most
/// `limit` of them (and never more than `due_page_limit`). Ties on the time
/// break by kind and then key, so the order is the same on every read.
///
/// Reading changes nothing. The host performs an action, then calls `settle`,
/// or calls `defer` when the attempt failed.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.effects_due(ledger, 1_700_000_000_000, 10) == Ok([])
/// ```
pub fn effects_due(
  ledger: Ledger,
  now_ms: Int,
  limit: Int,
) -> Result(List(Effect), Error) {
  let bound = int.max(1, int.min(limit, due_page_limit))
  use found <- result.try(rows(
    ledger.connection,
    sql.project_ledger_effects_due(now_ms, bound),
  ))
  list.try_map(found, fn(row) {
    decode_effect(row.kind, row.key, row.payload_json, row.attempts, row.due_ms)
  })
}

/// Removes a queued action because the host performed it. Settling an action
/// that is not queued changes nothing, so a retry after a lost reply is safe.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.settle(ledger, "reply", "t1-3")
/// ```
pub fn settle(ledger: Ledger, kind: String, key: String) -> Result(Nil, Error) {
  use Nil <- result.try(valid_effect_name(kind, key))
  statement(ledger.connection, sql.project_ledger_delete_effect(kind, key))
}

/// Pushes a queued action's time to `due_ms` and counts the attempt, and returns
/// the number of attempts the row now records. An action that is not queued is
/// `Missing`: it was settled or replaced, and the caller's attempt is stale.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.defer(ledger, "reply", "t1-3", 1_700_000_060_000) == Ok(1)
/// ```
pub fn defer(
  ledger: Ledger,
  kind: String,
  key: String,
  due_ms: Int,
) -> Result(Int, Error) {
  use Nil <- result.try(valid_effect_name(kind, key))
  use Nil <- result.try(valid_time(due_ms))
  use found <- result.try(rows(
    ledger.connection,
    sql.project_ledger_defer_effect(due_ms, kind, key),
  ))

  // No row means the action was settled or replaced since the caller read it.
  case found {
    [] -> Error(Missing)
    [row] -> Ok(row.attempts)
    [_, _, ..] -> Error(MalformedRow("a key matched more than one effect"))
  }
}

/// Reads the scanner's position in a session's commit stream: the id of the last
/// entry the engine has taken in, or `None` for a session not scanned yet.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.cursor(ledger, session_id) == Ok(None)
/// ```
pub fn cursor(
  ledger: Ledger,
  session_id: String,
) -> Result(Option(String), Error) {
  use Nil <- result.try(valid_name(session_id, kind_limit, "session id"))
  use found <- result.try(rows(
    ledger.connection,
    sql.project_ledger_cursor(session_id),
  ))

  // The session id is the primary key, so one row is the most there can be.
  case found {
    [] -> Ok(None)
    [row] ->
      case valid_name(row.entry_id, kind_limit, "entry id") {
        Ok(Nil) -> Ok(Some(row.entry_id))
        Error(_) -> Error(MalformedRow("a cursor holds an invalid entry id"))
      }
    [_, _, ..] -> Error(MalformedRow("a session matched more than one cursor"))
  }
}

/// Records the scanner's position in a session's commit stream, replacing the
/// earlier position.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.set_cursor(ledger, session_id, entry_id)
/// ```
pub fn set_cursor(
  ledger: Ledger,
  session_id: String,
  entry_id: String,
) -> Result(Nil, Error) {
  use Nil <- result.try(valid_name(session_id, kind_limit, "session id"))
  use Nil <- result.try(valid_name(entry_id, kind_limit, "entry id"))
  statement(
    ledger.connection,
    sql.project_ledger_put_cursor(session_id, entry_id),
  )
}

/// Reads the snapshot the last compaction wrote, or `None` for a ledger that has
/// never been compacted.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.snapshot(ledger) == Ok(None)
/// ```
pub fn snapshot(ledger: Ledger) -> Result(Option(Snapshot), Error) {
  use found <- result.try(rows(ledger.connection, sql.project_ledger_snapshot()))

  // The slot column holds the table to one row.
  case found {
    [] -> Ok(None)
    [row] ->
      decode_snapshot(row.before_seq, row.at_ms, row.snapshot_json)
      |> result.map(Some)
    [_, _, ..] -> Error(MalformedRow("the ledger holds more than one snapshot"))
  }
}

/// Deletes the events below `before_seq` and stores `snapshot_json` as the state
/// they stand for, in one transaction.
///
/// The sequence number must lie above the earlier snapshot's and at or below the
/// newest event's. The newest event stays so that the next append continues the
/// numbering instead of reusing a deleted number. A refused call changes
/// nothing, and a snapshot written here replaces the earlier one.
///
/// ## Examples
///
/// ```gleam
/// // project_ledger.compact_before(ledger, 101, state_json, now)
/// ```
pub fn compact_before(
  ledger: Ledger,
  before_seq: Int,
  snapshot_json: String,
  at_ms: Int,
) -> Result(Nil, Error) {
  use Nil <- result.try(valid_document(
    snapshot_json,
    snapshot_limit,
    "snapshot",
  ))
  use Nil <- result.try(valid_time(at_ms))
  transaction(ledger.connection, fn() {
    use floor <- result.try(retained_from(ledger))
    use newest <- result.try(last_seq(ledger))

    // Compacting to the floor deletes nothing, and compacting past the newest
    // event would delete the row that anchors the numbering.
    use Nil <- result.try(case before_seq > floor && before_seq <= newest {
      True -> Ok(Nil)
      False ->
        Error(Invalid(
          "a compaction point lies above the earlier snapshot and at or below the newest event",
        ))
    })

    // The snapshot and the deletion commit together or not at all.
    use Nil <- result.try(statement(
      ledger.connection,
      sql.project_ledger_put_snapshot(before_seq, at_ms, snapshot_json),
    ))
    statement(ledger.connection, sql.project_ledger_delete_before(before_seq))
  })
}

// The first sequence number a replay may start at. A ledger that was never
// compacted keeps every event from the first, and one that was compacted keeps
// those from its snapshot's `before_seq`.
/// The lowest sequence number the ledger still holds, or 1 before any
/// compaction.
fn retained_from(ledger: Ledger) -> Result(Int, Error) {
  use held <- result.map(snapshot(ledger))

  // Without a snapshot nothing has been deleted, so the history starts at 1.
  case held {
    None -> 1
    Some(Snapshot(before_seq:, ..)) -> before_seq
  }
}

/// Decodes one stored event, refusing a sequence, time or text outside its
/// grammar.
fn decode_event(
  seq: Int,
  at_ms: Int,
  event_json: String,
) -> Result(StoredEvent, Error) {
  case seq >= 1 && at_ms >= 0 && is_document(event_json, event_limit) {
    True -> Ok(StoredEvent(seq:, at_ms:, event_json:))
    False -> Error(MalformedRow("an event row breaks its grammar"))
  }
}

/// Decodes one stored effect, refusing a name, count, time or payload outside
/// its grammar.
fn decode_effect(
  kind: String,
  key: String,
  payload_json: String,
  attempts: Int,
  due_ms: Int,
) -> Result(Effect, Error) {
  case
    valid_effect_name(kind, key)
    |> result.is_ok
    && attempts >= 0
    && due_ms >= 0
    && is_document(payload_json, event_limit)
  {
    True -> Ok(Effect(kind:, key:, payload_json:, attempts:, due_ms:))
    False -> Error(MalformedRow("an effect row breaks its grammar"))
  }
}

/// Decodes the stored snapshot, refusing a sequence, time or text outside its
/// grammar.
fn decode_snapshot(
  before_seq: Int,
  at_ms: Int,
  snapshot_json: String,
) -> Result(Snapshot, Error) {
  case
    before_seq >= 1 && at_ms >= 0 && is_document(snapshot_json, snapshot_limit)
  {
    True -> Ok(Snapshot(before_seq:, at_ms:, snapshot_json:))
    False -> Error(MalformedRow("the snapshot row breaks its grammar"))
  }
}

/// Writes one effect row, replacing the row with the same kind and key.
fn put_effect(
  connection: sqlight.Connection,
  draft: EffectDraft,
) -> Result(Nil, Error) {
  statement(
    connection,
    sql.project_ledger_put_effect(
      draft.kind,
      draft.key,
      draft.payload_json,
      draft.due_ms,
    ),
  )
}

/// Checks an effect draft's fields before anything is written.
fn valid_draft(draft: EffectDraft) -> Result(Nil, Error) {
  use Nil <- result.try(valid_effect_name(draft.kind, draft.key))
  use Nil <- result.try(valid_document(
    draft.payload_json,
    event_limit,
    "effect",
  ))
  valid_time(draft.due_ms)
}

/// Checks the two names that identify an effect.
fn valid_effect_name(kind: String, key: String) -> Result(Nil, Error) {
  use Nil <- result.try(valid_name(kind, kind_limit, "effect kind"))
  valid_name(key, key_limit, "effect key")
}

/// Checks that a name is one to `limit` bytes of printable text.
fn valid_name(text: String, limit: Int, what: String) -> Result(Nil, Error) {
  let size = string.byte_size(text)
  let plain =
    list.all(string.to_utf_codepoints(text), fn(codepoint) {
      let code = string.utf_codepoint_to_int(codepoint)
      code >= 0x20 && code != 0x7f
    })

  // The table's CHECK holds the same length bounds.
  case size >= 1 && size <= limit && plain {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        what
        <> " must be one to "
        <> int.to_string(limit)
        <> " bytes of printable text",
      ))
  }
}

/// Checks that a text is one JSON document within a size.
fn valid_document(
  text: String,
  limit: Int,
  what: String,
) -> Result(Nil, Error) {
  case is_document(text, limit) {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        what
        <> " must be one JSON document of at most "
        <> int.to_string(limit)
        <> " bytes",
      ))
  }
}

/// Whether a text is one JSON document within a size. The size is judged first,
/// so an oversized text is never parsed.
fn is_document(text: String, limit: Int) -> Bool {
  string.byte_size(text) <= limit && result.is_ok(json.parse(text))
}

/// Checks a caller-supplied system time.
fn valid_time(ms: Int) -> Result(Nil, Error) {
  case ms >= 0 {
    True -> Ok(Nil)
    False -> Error(Invalid("a time is Unix milliseconds of zero or more"))
  }
}

// The schema is checked inside the transaction that may create it, so two opens
// of a fresh file cannot both decide it is empty. Journal configuration follows
// validation, so an unrelated file is refused before any persistent tuning can
// change its header.
/// Applies the connection policy and verifies or creates the schema.
fn initialize(connection: sqlight.Connection) -> Result(Nil, Error) {
  let options = sqlite_policy.defaults()
  use Nil <- result.try(
    sqlite_policy.configure_connection(connection, options)
    |> result.map_error(sql_error),
  )

  // The ledger is a custody record: an event the actor acted on must survive
  // power loss, or a restart would repeat an outside action.
  use Nil <- result.try(execute(connection, "PRAGMA synchronous = FULL"))
  use Nil <- result.try(initialize_schema(connection))
  sqlite_policy.configure_database(connection, options)
  |> result.map_error(sql_error)
}

/// Creates the tables of an empty file, accepts a current ledger, and refuses
/// anything else.
fn initialize_schema(connection: sqlight.Connection) -> Result(Nil, Error) {
  transaction(connection, fn() {
    use found <- result.try(number(connection, "PRAGMA application_id"))
    use version <- result.try(number(connection, "PRAGMA user_version"))

    // Dispatch on a current ledger, an empty file, or a file that is neither.
    case found, version {
      id, 1 if id == application_id -> Ok(Nil)
      0, 0 -> {
        use tables <- result.try(number(connection, "PRAGMA schema_version"))

        // A blank file has schema version zero, and a file with tables is some
        // other database.
        case tables {
          0 -> create_schema(connection)
          _ -> Error(Unsupported)
        }
      }
      _, _ -> Error(Unsupported)
    }
  })
}

/// Creates the ledger's tables and stamps the file with its identity.
fn create_schema(connection: sqlight.Connection) -> Result(Nil, Error) {
  use Nil <- result.try(execute(connection, project_ledger_schema.schema))
  execute(
    connection,
    "PRAGMA application_id = "
      <> int.to_string(application_id)
      <> "; PRAGMA user_version = "
      <> int.to_string(schema_version),
  )
}

// Generated queries return a statement, its parameters and a row decoder. These
// bind only strings and integers; any other parameter would mean the generator
// changed, so it is refused and not guessed at.
/// Encodes a query parameter value into its sqlight representation.
fn parameter(param: dev.Param) -> Result(sqlight.Value, Error) {
  case param {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamNullable(Some(inner)) -> parameter(inner)
    dev.ParamNullable(None)
    | dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamBitArray(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_) ->
      Error(Invalid("unsupported generated ledger parameter"))
  }
}

/// Executes a generated query and decodes its rows.
fn rows(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, params, decoder) = generated
  use arguments <- result.try(list.try_map(params, parameter))
  sqlight.query(text, on: connection, with: arguments, expecting: decoder)
  |> result.map_error(sql_error)
}

/// Executes a generated statement and discards any rows.
fn statement(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, params) = generated
  rows(connection, #(text, params, decode.success(Nil)))
  |> result.replace(Nil)
}

/// Reads one integer from a pragma query.
fn number(connection: sqlight.Connection, text: String) -> Result(Int, Error) {
  use values <- result.try(
    sqlight.query(
      text,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(sql_error),
  )

  // Exactly one value is expected from a pragma.
  case values {
    [value] -> Ok(value)
    [] | [_, _, ..] -> Error(MalformedRow("expected one metadata row"))
  }
}

// Every write runs in `BEGIN IMMEDIATE`, which takes the database's write lock
// before the first read. The checks that guard a write therefore see the state
// the write will land on, and a failure rolls back so a refused call leaves no
// row behind.
/// Runs an action in an immediate transaction, committing on success and rolling
/// back on failure.
fn transaction(
  connection: sqlight.Connection,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use Nil <- result.try(execute(connection, "BEGIN IMMEDIATE"))
  let outcome =
    run()
    |> result.try(fn(value) {
      execute(connection, "COMMIT") |> result.replace(value)
    })

  // Commit on success or roll back on failure.
  case outcome {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let _rolled_back = execute(connection, "ROLLBACK")
      Error(error)
    }
  }
}

/// Executes a statement with no parameters.
fn execute(connection: sqlight.Connection, text: String) -> Result(Nil, Error) {
  sqlight.exec(text, on: connection) |> result.map_error(sql_error)
}

/// Wraps a SQLite failure.
fn sql_error(error: sqlight.Error) -> Error {
  Database(string.inspect(error))
}
