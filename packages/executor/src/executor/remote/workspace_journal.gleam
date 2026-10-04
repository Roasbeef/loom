//// Whole semantic workspace custody before executor-local filesystem effects.
////
//// Admission retains canonical invocation bytes and reserves their length plus
//// the full codec completion ceiling. A first claim commits Started before
//// returning execution permission. No recovery or duplicate creates a claim;
//// uncertainty therefore survives a crash without replaying a mutation.
////
//// A weft actor owns each connection. BEGIN IMMEDIATE serializes independent
//// opens, including separate VMs. Every transaction validates bounded scalar
//// headers before reading selected bodies. Recovery validates bodies one row at
//// a time. SQLite failures poison the endpoint, because a failed reply or commit
//// may conceal a durable transition. There are no retries of effects here.
////
//// Exact completion bytes commit before a reply. An exact digest acknowledgement
//// means the caller already durably retained those bytes; only then do payloads
//// leave this store. UUID, request digest and result digest remain forever.
//// Cancelled and unknown work have no timeout collection path. Logical reserved
//// bytes bound admitted semantic content, not physical database/WAL growth or
//// a proof of power-loss behavior on an arbitrary filesystem.
////
//// ## Flow
////
//// `fresh` and `recover` enter `start` and `initialise`. `admit`, `inspect`,
//// `claim` and `cancel` validate before `exchange`; `finish` validates against
//// its opaque claim. `handle` commits `transact` before replying. `inventory`
//// validates metadata and headers; `retained` then validates bounded bodies.
//// `execute` changes one exact row and never launches filesystem work itself.

import core/ids
import core/workspace as cw
import executor/sql
import executor/workspace_schema
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import sqlight
import tools/workspace
import tools/workspace_codec as codec
import weft/actor

/// Explicit finite ceilings, bound immutably to the database metadata.
pub opaque type Limits {
  /// Both ceilings count permanent identities and unacknowledged reservations.
  Limits(
    /// Lifetime UUID slots, never reusable after acknowledgement.
    rows: Int,
    /// Input bytes plus complete result capacity until owner acknowledgement.
    bytes: Int,
  )
}

/// An actor endpoint bound to the exact registered workspace/session epochs.
pub opaque type Journal {
  /// Construction is restricted to validated fresh creation or recovery.
  Journal(
    /// The private actor endpoint; its SQLite connection never escapes.
    subject: process.Subject(Message),
    /// The full immutable registered scope, including both epochs.
    scope: cw.Scope,
  )
}

/// Live permission returned once, after Started commits, never from recovery.
pub opaque type Claim {
  /// Construction occurs only after the first committed Started transition.
  Claim(
    /// The original connection-owning endpoint, never replaced on recovery.
    journal: Journal,
    /// The actual invocation, including UUID, provenance and physical step.
    invocation: Validated,
  )
}

/// Durable closed dispositions, without filesystem or native-retirement claims.
pub type Status {
  /// Exact input and its complete result capacity are durably reserved.
  Accepted

  /// Execution was claimed; no exact completed result is durably known.
  Unknown

  /// Exact immutable bytes, suitable for replay without executing the request.
  Finished(
    /// The canonical completion including post-write diagnostics.
    bytes: BitArray,
  )

  /// Owner receipt released payloads; the replay fence is permanent.
  Acknowledged(
    /// The exact completion digest which authorized collection.
    result_digest: BitArray,
  )

  /// Cancellation committed before any claim; execution is permanently fenced.
  Cancelled
}

/// Only the first committed claim grants permission to execute.
pub type Claimed {
  /// The caller may execute this original invocation at most once.
  Claimed(
    /// An opaque permission tied to this endpoint and retained input.
    claim: Claim,
  )

  /// Existing evidence never grants execution permission.
  Existing(
    /// The committed disposition under this original identity.
    status: Status,
  )
}

/// Fixed errors never contain peer input, SQL text or unbounded diagnostics.
pub type Error {
  /// Ceilings exceed the supported finite lifetime limits.
  InvalidLimits

  /// Filesystem custody needs an absolute bounded path without NUL.
  InvalidPath

  /// Fresh creation found an existing path and did not replace it.
  AlreadyExists

  /// Recovery or inspection found no existing evidence.
  Missing

  /// Original full workspace scope differs from this journal.
  ScopeMismatch

  /// Invocation or completion is not canonical codec-valid content.
  InvalidInput

  /// One UUID names changed request or result evidence.
  Conflict

  /// Lifetime rows or reserved bytes are exhausted before admission.
  Capacity

  /// The durable metadata differs from the exact configured scope or ceilings.
  BindingMismatch

  /// Bounded stored headers or content failed complete validation.
  Corrupt

  /// A transaction or reply may have committed; recover without executing again.
  Uncertain

  /// This actor is closed or poisoned.
  Closed

  /// The connection-owning actor could not start.
  StartFailed
}

type Validated {
  Validated(
    call: workspace.Invocation,
    bytes: BitArray,
    id: BitArray,
    digest: BitArray,
  )
}

type Mode {
  Fresh
  Recover
}

type Config {
  Config(path: String, scope: cw.Scope, limits: Limits)
}

type State {
  Waiting(config: Config)
  Ready(config: Config, connection: sqlight.Connection)
}

type Command {
  Admit(Validated)
  Inspect(Validated)
  TakeClaim(Validated)
  Complete(Validated, BitArray)
  Cancel(Validated)
  Acknowledge(Validated, BitArray)
}

type Permission {
  Granted
  Withheld
}

type Answer {
  Answer(status: Status, permission: Permission)
}

type Message {
  Initialise(Mode, process.Subject(Result(Nil, Error)))
  Run(Command, process.Subject(Result(Answer, Error)))
  Release(process.Subject(Result(Nil, Error)))
}

/// Validates lifetime ceilings; acknowledgement frees bytes but never row slots.
///
/// ## Examples
///
/// `limits(4096, 268_435_456)` permits at most 256 MiB of logical reservation.
pub fn limits(rows: Int, bytes: Int) -> Result(Limits, Error) {
  case rows > 0 && rows <= 4096 && bytes > 0 && bytes <= 268_435_456 {
    True -> Ok(Limits(rows, bytes))
    False -> Error(InvalidLimits)
  }
}

/// Creates a fresh database without replacing any existing replay fence.
///
/// ## Examples
///
/// `fresh(path, scope, limits)` returns only after schema and metadata commit.
pub fn fresh(
  path: String,
  scope: cw.Scope,
  limits: Limits,
) -> Result(Journal, Error) {
  start(Config(path, scope, limits), Fresh)
}

/// Recovers validated exact evidence; Started never becomes fresh permission.
///
/// ## Examples
///
/// `recover(path, scope, limits)` refuses changed epochs and changed ceilings.
pub fn recover(
  path: String,
  scope: cw.Scope,
  limits: Limits,
) -> Result(Journal, Error) {
  start(Config(path, scope, limits), Recover)
}

/// Retains canonical input and reserves the complete result ceiling before effects.
///
/// ## Examples
///
/// `admit(journal, bytes)` returns Accepted or the exact existing disposition.
pub fn admit(journal: Journal, bytes: BitArray) -> Result(Status, Error) {
  request(journal, bytes, Admit)
}

/// Reads original evidence without creating admission or execution permission.
///
/// ## Examples
///
/// `inspect(journal, bytes)` returns Missing for an unadmitted UUID.
pub fn inspect(journal: Journal, bytes: BitArray) -> Result(Status, Error) {
  request(journal, bytes, Inspect)
}

/// Commits Started and grants the original invocation once across all opens.
/// Admission must already exist; claim never implicitly reserves a new request.
///
/// ## Examples
///
/// A repeated `claim(journal, bytes)` returns Existing(Unknown).
pub fn claim(journal: Journal, bytes: BitArray) -> Result(Claimed, Error) {
  use invocation <- result.try(validate(journal.scope, bytes))
  use answer <- result.try(exchange(journal, Run(TakeClaim(invocation), _)))
  case answer.permission {
    Granted -> Ok(Claimed(Claim(journal, invocation)))
    Withheld -> Ok(Existing(answer.status))
  }
}

/// Exposes only the original codec-validated invocation for executor-local work.
///
/// ## Examples
///
/// The host executes `invocation(claim)` once after receiving Claimed.
pub fn invocation(claim: Claim) -> workspace.Invocation {
  claim.invocation.call
}

/// Commits canonical completion bytes matched against the retained request.
/// An exact repeated finish with the same live claim writes nothing.
///
/// ## Examples
///
/// `finish(claim, completion)` persists bytes before returning Finished.
pub fn finish(claim: Claim, bytes: BitArray) -> Result(Status, Error) {
  use _ <- result.try(
    codec.decode_completion(workspace.request(claim.invocation.call), bytes)
    |> result.replace_error(InvalidInput),
  )
  run(claim.journal, Complete(claim.invocation, bytes))
}

/// Fences an admitted unclaimed invocation; Started remains Unknown.
/// Cancellation does not declare already-started synchronous effects stopped.
///
/// ## Examples
///
/// `cancel(journal, bytes)` leaves a permanent Cancelled execution fence.
pub fn cancel(journal: Journal, bytes: BitArray) -> Result(Status, Error) {
  request(journal, bytes, Cancel)
}

/// Releases payloads only after matching the exact committed completion digest.
/// The caller MUST durably retain the result before sending this acknowledgement.
///
/// ## Examples
///
/// `acknowledge(journal, input, digest(result))` keeps identity fences forever.
pub fn acknowledge(
  journal: Journal,
  bytes: BitArray,
  digest: BitArray,
) -> Result(Status, Error) {
  use Nil <- result.try(case bit_array.bit_size(digest) == 256 {
    True -> Ok(Nil)
    False -> Error(InvalidInput)
  })
  use invocation <- result.try(validate(journal.scope, bytes))
  run(journal, Acknowledge(invocation, digest))
}

/// Computes immutable content evidence over whole canonical semantic bytes.
///
/// ## Examples
///
/// `digest(completion)` is the acknowledgement value after owner persistence.
pub fn digest(bytes: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, bytes)
}

/// Closes this endpoint without changing durable evidence or granting permission.
///
/// ## Examples
///
/// `release(journal)` permits a later explicit recover against the same binding.
pub fn release(journal: Journal) -> Result(Nil, Error) {
  case exchange(journal, Release) {
    Error(Closed) -> Ok(Nil)
    outcome -> outcome
  }
}

fn request(
  journal: Journal,
  bytes: BitArray,
  command: fn(Validated) -> Command,
) -> Result(Status, Error) {
  use invocation <- result.try(validate(journal.scope, bytes))
  run(journal, command(invocation))
}

fn validate(scope: cw.Scope, bytes: BitArray) -> Result(Validated, Error) {
  use call <- result.try(
    codec.decode_invocation(bytes) |> result.replace_error(InvalidInput),
  )
  let #(actual, _, _, _, id) = workspace.invocation_identity(call)
  case actual == scope {
    True ->
      Ok(Validated(
        call,
        bytes,
        bit_array.from_string(ids.entry_id_to_string(id)),
        digest(bytes),
      ))
    False -> Error(ScopeMismatch)
  }
}

fn run(journal: Journal, command: Command) -> Result(Status, Error) {
  exchange(journal, Run(command, _)) |> result.map(fn(answer) { answer.status })
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
    |> result.replace_error(StartFailed),
  )
  let journal = Journal(started.data, config.scope)
  case exchange(journal, Initialise(mode, _)) {
    Ok(Nil) -> Ok(journal)
    Error(error) -> {
      // Initialization may still be queued after timeout. Close behind it.
      process.send(journal.subject, Release(process.new_subject()))
      Error(error)
    }
  }
}

fn exchange(
  journal: Journal,
  make: fn(process.Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  use owner <- result.try(
    process.subject_owner(journal.subject) |> result.replace_error(Closed),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error(Closed)
  })
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  process.send(journal.subject, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) { Error(Uncertain) })
    |> process.selector_receive(30_000)

  // A lost reply cannot establish whether Started or completion committed.
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(Uncertain))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case state, message {
    Waiting(config), Initialise(mode, reply) -> {
      case initialise(config, mode) {
        Ok(connection) -> {
          process.send(reply, Ok(Nil))
          actor.continue(Ready(config, connection))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.stop()
        }
      }
    }
    Ready(config, connection), Run(command, reply) -> {
      let outcome = transact(connection, config, command)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Ready(_, connection), Release(reply) -> {
      process.send(reply, sqlight.close(connection) |> sql_error)
      actor.stop()
    }
    Waiting(_), Release(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Waiting(_), Run(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(_, _), Initialise(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
  }
}

fn initialise(config: Config, mode: Mode) -> Result(sqlight.Connection, Error) {
  use exists <- result.try(
    simplifile.exists(config.path, False) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(case mode, exists {
    Fresh, True -> Error(AlreadyExists)
    Recover, False -> Error(Missing)
    Fresh, False | Recover, True -> Ok(Nil)
  })
  use connection <- result.try(sqlight.open(config.path) |> sql_error)
  let outcome = setup(connection, config, mode)
  case outcome {
    Ok(Nil) -> Ok(connection)
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
) -> Result(Nil, Error) {
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
      "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE",
      connection,
    )
    |> sql_error,
  )
  let outcome = {
    use Nil <- result.try(case mode {
      Fresh -> {
        use Nil <- result.try(
          sqlight.exec(workspace_schema.schema, connection) |> sql_error,
        )
        statement(
          connection,
          sql.initialize_workspace(
            binding(config.scope),
            config.limits.rows,
            config.limits.bytes,
          ),
        )
      }
      Recover -> Ok(Nil)
    })
    use rows <- result.try(inventory(connection, config))
    list.try_each(rows, fn(row) {
      retained(connection, config, row) |> result.replace(Nil)
    })
  }
  complete_transaction(connection, outcome)
}

fn binding(scope: cw.Scope) -> BitArray {
  let #(session, bound) = cw.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) = cw.binding_fields(bound)
  let #(executor, workspace_id) = cw.selector_fields(selector)
  let session = ids.session_id_to_string(session)
  <<
    session:utf8,
    0,
    executor:utf8,
    0,
    workspace_id:utf8,
    0,
    workspace_epoch:32,
    session_epoch:32,
  >>
}

fn inventory(
  connection: sqlight.Connection,
  config: Config,
) -> Result(List(sql.WorkspaceHeaders), Error) {
  use metadata <- result.try(
    query(connection, sql.workspace_metadata()) |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(case metadata {
    [sql.WorkspaceMetadata(actual, rows, bytes)]
      if rows == config.limits.rows && bytes == config.limits.bytes
    -> {
      case actual == binding(config.scope) {
        True -> Ok(Nil)
        False -> Error(BindingMismatch)
      }
    }
    [_] -> Error(BindingMismatch)
    _ -> Error(Corrupt)
  })
  use rows <- result.try(
    query(connection, sql.workspace_headers(config.limits.rows + 1))
    |> result.replace_error(Corrupt),
  )
  use reserved <- result.try(
    list.try_fold(rows, 0, fn(total, row) {
      use id <- result.try(
        bit_array.to_string(row.id) |> result.replace_error(Corrupt),
      )
      use parsed <- result.try(
        ids.parse_entry_id(id) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(
        case row.valid == 1 && ids.entry_id_to_string(parsed) == id {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      let size = case row.phase {
        3 -> 0
        _ -> row.request_size + codec.max_completion_bytes
      }
      Ok(total + size)
    }),
  )
  case
    list.drop(rows, config.limits.rows) == [] && reserved <= config.limits.bytes
  {
    True -> Ok(rows)
    False -> Error(Corrupt)
  }
}

fn retained(
  connection: sqlight.Connection,
  config: Config,
  row: sql.WorkspaceHeaders,
) -> Result(Status, Error) {
  case row.phase {
    3 -> Ok(Acknowledged(row.result_digest))
    _ -> {
      use bodies <- result.try(
        query(connection, sql.workspace_bodies(row.id))
        |> result.replace_error(Corrupt),
      )
      use body <- result.try(case bodies {
        [body] -> Ok(body)
        _ -> Error(Corrupt)
      })
      use invocation <- result.try(
        validate(config.scope, body.request) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(
        case
          invocation.id == row.id
          && invocation.digest == row.request_digest
          && bit_array.byte_size(body.request) == row.request_size
        {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      disposition(row, invocation, body.result)
    }
  }
}

fn disposition(
  row: sql.WorkspaceHeaders,
  invocation: Validated,
  bytes: BitArray,
) -> Result(Status, Error) {
  case row.phase {
    0 -> Ok(Accepted)
    1 -> Ok(Unknown)
    2 -> {
      use Nil <- result.try(
        case
          digest(bytes) == row.result_digest
          && bit_array.byte_size(bytes) == row.result_size
        {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      use _ <- result.try(
        codec.decode_completion(workspace.request(invocation.call), bytes)
        |> result.replace_error(Corrupt),
      )
      Ok(Finished(bytes))
    }
    4 -> Ok(Cancelled)
    _ -> Error(Corrupt)
  }
}

fn transact(
  connection: sqlight.Connection,
  config: Config,
  command: Command,
) -> Result(Answer, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use rows <- result.try(inventory(connection, config))
    execute(connection, config, rows, command)
  }
  complete_transaction(connection, outcome)
}

fn command_input(command: Command) -> Validated {
  case command {
    Admit(input)
    | Inspect(input)
    | TakeClaim(input)
    | Complete(input, _)
    | Cancel(input)
    | Acknowledge(input, _) -> input
  }
}

fn execute(
  connection: sqlight.Connection,
  config: Config,
  rows: List(sql.WorkspaceHeaders),
  command: Command,
) -> Result(Answer, Error) {
  let input = command_input(command)
  case list.find(rows, fn(row) { row.id == input.id }) {
    Error(_) -> {
      case command {
        Admit(_) -> insert(connection, config, rows, input)
        Inspect(_)
        | TakeClaim(_)
        | Complete(_, _)
        | Cancel(_)
        | Acknowledge(_, _) -> Error(Missing)
      }
    }
    Ok(row) -> {
      use Nil <- result.try(
        case
          row.request_digest == input.digest
          && row.request_size == bit_array.byte_size(input.bytes)
        {
          True -> Ok(Nil)
          False -> Error(Conflict)
        },
      )
      use status <- result.try(retained(connection, config, row))

      // Until receipt collection, compare exact input as well as its digest.
      use Nil <- result.try(case row.phase {
        3 -> Ok(Nil)
        _ -> {
          use bodies <- result.try(
            query(connection, sql.workspace_bodies(row.id))
            |> result.replace_error(Corrupt),
          )
          case bodies {
            [sql.WorkspaceBodies(request, _)] if request == input.bytes ->
              Ok(Nil)
            _ -> Error(Conflict)
          }
        }
      })
      transition(connection, row, status, command)
    }
  }
}

fn insert(
  connection: sqlight.Connection,
  config: Config,
  rows: List(sql.WorkspaceHeaders),
  input: Validated,
) -> Result(Answer, Error) {
  let reserved =
    list.fold(rows, 0, fn(total, row) {
      case row.phase {
        3 -> total
        _ -> total + row.request_size + codec.max_completion_bytes
      }
    })
  use Nil <- result.try(
    case
      list.drop(rows, config.limits.rows - 1) == []
      && reserved
      + bit_array.byte_size(input.bytes)
      + codec.max_completion_bytes
      <= config.limits.bytes
    {
      True -> Ok(Nil)
      False -> Error(Capacity)
    },
  )
  use Nil <- result.try(statement(
    connection,
    sql.insert_workspace(
      input.id,
      input.digest,
      bit_array.byte_size(input.bytes),
      input.bytes,
    ),
  ))
  Ok(Answer(Accepted, Withheld))
}

fn transition(
  connection: sqlight.Connection,
  row: sql.WorkspaceHeaders,
  status: Status,
  command: Command,
) -> Result(Answer, Error) {
  case command, status {
    TakeClaim(_), Accepted -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.claim_workspace(row.id),
        fn(row) { row.phase },
        1,
      ))
      Ok(Answer(Unknown, Granted))
    }
    Cancel(_), Accepted -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.cancel_workspace(row.id),
        fn(row) { row.phase },
        4,
      ))
      Ok(Answer(Cancelled, Withheld))
    }
    Complete(_, bytes), Unknown -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.finish_workspace(
          digest(bytes),
          bit_array.byte_size(bytes),
          bytes,
          row.id,
        ),
        fn(row) { row.phase },
        2,
      ))
      Ok(Answer(Finished(bytes), Withheld))
    }
    Complete(_, bytes), Finished(original) -> {
      case bytes == original {
        True -> Ok(Answer(status, Withheld))
        False -> Error(Conflict)
      }
    }
    Complete(_, bytes), Acknowledged(expected) -> {
      case
        digest(bytes) == expected
        && bit_array.byte_size(bytes) == row.result_size
      {
        True -> Ok(Answer(status, Withheld))
        False -> Error(Conflict)
      }
    }
    Complete(_, _), _ -> Error(Conflict)
    Acknowledge(_, supplied), Finished(_) -> {
      use Nil <- result.try(case supplied == row.result_digest {
        True -> Ok(Nil)
        False -> Error(Conflict)
      })
      use Nil <- result.try(phase_change(
        connection,
        sql.acknowledge_workspace(row.id),
        fn(row) { row.phase },
        3,
      ))
      Ok(Answer(Acknowledged(supplied), Withheld))
    }
    Acknowledge(_, supplied), Acknowledged(expected) -> {
      case supplied == expected {
        True -> Ok(Answer(status, Withheld))
        False -> Error(Conflict)
      }
    }
    Acknowledge(_, _), _ -> Error(Conflict)
    Admit(_), _ | Inspect(_), _ | TakeClaim(_), _ | Cancel(_), _ ->
      Ok(Answer(status, Withheld))
  }
}

// Each permission or evidence transition must return its committed phase.
// A missing update cannot accidentally grant execution or acknowledge custody.
fn phase_change(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
  phase: fn(a) -> Int,
  expected: Int,
) -> Result(Nil, Error) {
  use rows <- result.try(query(connection, generated))
  case rows {
    [row] -> {
      case phase(row) == expected {
        True -> Ok(Nil)
        False -> Error(Uncertain)
      }
    }
    _ -> Error(Uncertain)
  }
}

fn complete_transaction(
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
  use arguments <- result.try(
    list.try_map(parameters, fn(value) {
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
    }),
  )
  sqlight.query(text, connection, arguments, decoder) |> sql_error
}

fn sql_error(value: Result(a, sqlight.Error)) -> Result(a, Error) {
  result.replace_error(value, Uncertain)
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Ready(_, connection) -> {
      let _ = sqlight.close(connection)
      Nil
    }
    Waiting(_) -> Nil
  }
}
