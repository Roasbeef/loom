//// Durable first preparation claims for exact Compile and Launch inputs.
////
//// The journal reserves permanent identities and full Ready capacity before a
//// service may touch disk. A first Reserved->Preparing commit returns one live
//// Claim. Duplicate and recovered Preparing rows are Unknown, never permission
//// to run again. Gleam values are duplicable: the trusted adapter must perform
//// that returned claim at most once after its own re-vetting/artifact admission.
//// This journal checks canonical syntax and identity, not those authorization
//// facts, successful compilation, live resource custody or native retirement.
////
//// Original logical child addresses match owner custody. They exclude physical
//// step, content and UUID so changed evidence reaches the same conflict fence;
//// full key/header and exact input bytes retain all those immutable facts.
//// Historical Ready bytes remain even after uncertainty or witnessed cleanup.
//// They cannot reconstruct a listener, token or preparation claim on recovery.
////
//// Each private weft actor owns a SQLite connection. BEGIN IMMEDIATE, WAL and
//// FULL synchronization serialize independent opens. Checked scalar inventory
//// bounds precede reading one body; recovery validates bodies one at a time.
//// COMMIT precedes replies. SQL failure poisons this endpoint as uncertain.
//// Logical reservation ceilings do not bound SQLite pages/WAL or resident memory.
//// No timer, row collection, native process owner or effect retry lives here.
//// This store reserves input and Ready metadata only. The trusted physical
//// service must separately reserve exact outer outcome capacity before asking
//// for preparation; Ready never substitutes for terminal service custody.
////
//// ## Flow
////
//// `fresh` and `recover` enter `start` and `initialise`. `reserve`, `inspect`
//// and `claim_preparation` validate exact input before `exchange`. `commit_ready`
//// verifies its original key/producer before `run`. `handle` commits `transact`
//// before replying. `inventory` bounds headers; `retained` and `checked_row` validate one body.
//// `execute` compares both address and UUID fences, then `transition` applies
//// monotone state changes. `seal` enters `metadata_transaction` under the same
//// writer lock. `decode_header` uses core's full key decoder; `ready_for` checks
//// historical location association. `reservation` keeps lifetime byte accounting.

import broker/enrollment
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/json
import core/remote_tool
import executor/resource_schema
import executor/sql
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import parrot/dev
import simplifile
import sqlight
import weft/actor

/// Immutable lifetime ceilings; no transition returns row or byte capacity.
pub opaque type Limits {
  Limits(
    /// Permanent original UUID slots.
    rows: Int,
    /// Logical input/header/address and complete Ready reservations.
    bytes: Int,
  )
}

/// One connection-owning endpoint pinned to exact trusted enrollment and limits.
pub opaque type Journal {
  Journal(
    /// Private actor subject, never a native resource owner.
    subject: process.Subject(Message),
    /// Original full administrative snapshot.
    enrolled: enrollment.SessionEnrollment,
  )
}

/// Original service key and exact canonical body, revalidated at every entry.
pub type Input {
  Input(
    /// Full original identity, including physical coordinates and provenance.
    key: command.ServiceKey,
    /// Canonical whole Compile or Launch body, without a duplicate header.
    body: BitArray,
  )
}

/// One live post-COMMIT preparation permission, unavailable from historical rows.
pub opaque type Claim {
  Claim(
    /// Original endpoint; a recovered endpoint cannot reuse this value.
    journal: Journal,
    /// Exact immutable original invocation validated before reservation.
    original: Validated,
  )
}

/// Historical dispositions, never claims of current resource custody.
pub type Status {
  /// Exact input and full location-receipt capacity are durably reserved.
  Reserved

  /// Preparation may have occurred; original Ready evidence remains if issued.
  Unknown(ready: Option(resources.Ready))

  /// Canonical location evidence committed, without successful Compile or lease.
  Prepared(ready: resources.Ready)

  /// Trusted resource owner witnessed cleanup; historical location evidence stays.
  Released(ready: Option(resources.Ready))
}

/// Only the first committed Reserved->Preparing transition grants preparation.
pub type Claimed {
  /// Trusted service may perform this original preparation at most once.
  Claimed(claim: Claim)

  /// Retained evidence grants no new preparation permission.
  Existing(status: Status)
}

/// Cleanup is a trusted owner witness, separate from endpoint/native retirement.
pub type Cleanup {
  /// Caller witnessed its own resource owner's cleanup; no inferred timeout.
  ResourceOwnerCleaned
}

/// Durable admission mode, separate from connection endpoint lifetime.
pub type ScopeMode {
  /// New reservations and first preparation claims remain possible.
  Open

  /// Permanent fence against new reservations and first claims across all opens.
  SealedScope
}

/// Fixed diagnostics never echo SQL text, peer source or other large data.
pub type Error {
  /// Lifetime ceilings are outside the supported finite profile.
  InvalidLimits

  /// A database path must be bounded absolute text without NUL.
  InvalidPath

  /// Fresh creation cannot replace any existing database fence.
  AlreadyExists

  /// Existing evidence or recovery path is absent.
  Missing

  /// Canonical input does not bind the exact trusted snapshot.
  BindingMismatch

  /// Body digest, syntax, bounds or Ready identity is invalid.
  InvalidInput

  /// Logical address, UUID, full key or retained evidence differs.
  Conflict

  /// Permanent row or complete Ready reservation capacity is exhausted.
  Capacity

  /// Stored bounded headers or canonical evidence failed validation.
  Corrupt

  /// A failed transaction/reply may conceal a commit; recover original evidence.
  Uncertain

  /// Durable seal prevents a new reservation or first claim.
  Sealed

  /// Endpoint is closed or poisoned.
  Closed

  /// Connection-owning actor could not start.
  StartFailed
}

type Validated {
  Validated(
    original: Input,
    id: BitArray,
    address: BitArray,
    header: BitArray,
    role: Int,
    digest: BitArray,
    producer: Option(command.ServiceKey),
  )
}

type Mode {
  Fresh
  Recover
}

type MetadataCommand {
  ObserveMode
  SealScope
}

type Inventory {
  Inventory(mode: ScopeMode, rows: List(sql.ResourceHeaders))
}

type Config {
  Config(path: String, enrolled: enrollment.SessionEnrollment, limits: Limits)
}

type State {
  Waiting(config: Config)
  Ready(config: Config, connection: sqlight.Connection)
}

type Command {
  Reserve(Validated)
  Inspect(Validated)
  TakeClaim(Validated)
  CommitReady(Validated, BitArray)
  LoseResources(Validated)
  RetireResources(Validated)
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
  Metadata(MetadataCommand, process.Subject(Result(ScopeMode, Error)))
  CloseEndpoint(process.Subject(Result(Nil, Error)))
}

/// Validates finite lifetime row/byte ceilings, retained permanently.
///
/// ## Examples
///
/// `limits(4096, 268_435_456)` bounds logical reservations to 256 MiB.
pub fn limits(rows: Int, bytes: Int) -> Result(Limits, Error) {
  case rows > 0 && rows <= 4096 && bytes > 0 && bytes <= 268_435_456 {
    True -> Ok(Limits(rows, bytes))
    False -> Error(InvalidLimits)
  }
}

/// Creates only an unused database path and commits its exact snapshot binding.
///
/// ## Examples
///
/// `fresh(path, enrolled, limits)` refuses existing evidence.
pub fn fresh(
  path: String,
  enrolled: enrollment.SessionEnrollment,
  limits: Limits,
) -> Result(Journal, Error) {
  start(Config(path, enrolled, limits), Fresh)
}

/// Recovers checked historical evidence without returning any preparation claim.
///
/// ## Examples
///
/// `recover(path, enrolled, limits)` refuses changed snapshot or quotas.
pub fn recover(
  path: String,
  enrolled: enrollment.SessionEnrollment,
  limits: Limits,
) -> Result(Journal, Error) {
  start(Config(path, enrolled, limits), Recover)
}

/// Reserves exact input, original identity and full Ready allowance before effects.
///
/// ## Examples
///
/// An exact `reserve(journal, original)` retry returns existing evidence even sealed.
pub fn reserve(journal: Journal, original: Input) -> Result(Status, Error) {
  request(journal, original, Reserve)
}

/// Inspects original evidence without implicit reservation or resource authority.
///
/// ## Examples
///
/// `inspect(journal, original)` returns Missing before reservation.
pub fn inspect(journal: Journal, original: Input) -> Result(Status, Error) {
  request(journal, original, Inspect)
}

/// Commits Preparing before returning the one live preparation claim.
/// The trusted service MUST re-vet Compile or admit retained successful Compile
/// evidence for Launch before calling. Syntax validation here is not that proof.
///
/// ## Examples
///
/// Repeated `claim_preparation(journal, original)` returns Existing(Unknown(None)).
pub fn claim_preparation(
  journal: Journal,
  original: Input,
) -> Result(Claimed, Error) {
  use validated <- result.try(validate(journal.enrolled, original))
  use answer <- result.try(exchange(journal, Run(TakeClaim(validated), _)))
  case answer.permission {
    Granted -> Ok(Claimed(Claim(journal, validated)))
    Withheld -> Ok(Existing(answer.status))
  }
}

/// Returns the exact original key/body for the trusted physical service.
///
/// ## Examples
///
/// `original(claim).body` never substitutes current enrollment defaults.
pub fn original(claim: Claim) -> Input {
  claim.original.original
}

/// Commits exact Ready bytes under the original key and Launch producer.
/// A late claim cannot commit after explicit uncertainty or resource cleanup.
/// An exact already-Prepared retry retains original bytes without new permission.
///
/// ## Examples
///
/// `commit_ready(claim, ready)` proves location association, never native admission.
pub fn commit_ready(
  claim: Claim,
  ready: resources.Ready,
) -> Result(Status, Error) {
  use bytes <- result.try(
    resources.encode(ready) |> result.replace_error(InvalidInput),
  )
  use _ <- result.try(ready_for(claim.journal.enrolled, claim.original, bytes))
  run(claim.journal, CommitReady(claim.original, bytes))
}

/// Permanently records uncertainty, retaining original Ready bytes when present.
///
/// ## Examples
///
/// `mark_unknown(journal, original)` cannot fabricate a receipt after owner death.
pub fn mark_unknown(
  journal: Journal,
  original: Input,
) -> Result(Status, Error) {
  request(journal, original, LoseResources)
}

/// Records witnessed resource-owner cleanup without discarding replay evidence.
/// This is independent of endpoint release, native retirement or Compile success.
///
/// ## Examples
///
/// `mark_released(journal, original, ResourceOwnerCleaned)` retains original Ready.
pub fn mark_released(
  journal: Journal,
  original: Input,
  _cleanup: Cleanup,
) -> Result(Status, Error) {
  request(journal, original, RetireResources)
}

/// Reads the exact trusted snapshot retained by this endpoint.
///
/// ## Examples
///
/// `enrolled(journal)` is the original snapshot, never a newer advertisement.
pub fn enrolled(journal: Journal) -> enrollment.SessionEnrollment {
  journal.enrolled
}

/// Reads the current committed mode under the same writer lock as claims.
///
/// ## Examples
///
/// `mode(journal)` returns SealedScope after another endpoint seals.
pub fn mode(journal: Journal) -> Result(ScopeMode, Error) {
  exchange(journal, Metadata(ObserveMode, _))
}

/// Permanently fences all new reservations and first claims across independent opens.
///
/// ## Examples
///
/// `seal(journal)` commits before returning; existing evidence remains inspectable.
pub fn seal(journal: Journal) -> Result(ScopeMode, Error) {
  exchange(journal, Metadata(SealScope, _))
}

/// Closes only this SQLite actor endpoint; no resources are retired or cancelled.
///
/// ## Examples
///
/// `release_endpoint(journal)` permits explicit recovery without changing phases.
pub fn release_endpoint(journal: Journal) -> Result(Nil, Error) {
  case exchange(journal, CloseEndpoint) {
    Error(Closed) -> Ok(Nil)
    outcome -> outcome
  }
}

/// Computes SHA-256 over the exact canonical body or receipt bytes.
///
/// ## Examples
///
/// `digest(original.body)` must equal the ServiceKey input digest in lowercase hex.
pub fn digest(bytes: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, bytes)
}

fn request(
  journal: Journal,
  original: Input,
  command: fn(Validated) -> Command,
) -> Result(Status, Error) {
  use validated <- result.try(validate(journal.enrolled, original))
  run(journal, command(validated))
}

fn validate(
  enrolled: enrollment.SessionEnrollment,
  original: Input,
) -> Result(Validated, Error) {
  use Nil <- result.try(
    case
      bit_array.bit_size(original.body) % 8 == 0
      && bit_array.byte_size(original.body) <= 9_437_184
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  use producer <- result.try(case command.service_role(original.key) {
    command.CompileService -> {
      use decoded <- result.try(
        input.decode_compile(original.body)
        |> result.replace_error(InvalidInput),
      )
      use Nil <- result.try(
        enrollment.matches(enrolled, input.compile_facts(decoded).enrolled)
        |> result.replace_error(BindingMismatch),
      )
      use _ <- result.try(
        input.compile_envelope(original.key, decoded)
        |> result.replace_error(InvalidInput),
      )
      Ok(None)
    }
    command.LaunchService -> {
      use decoded <- result.try(
        input.decode_launch(original.body) |> result.replace_error(InvalidInput),
      )
      let facts = input.launch_facts(decoded)
      use Nil <- result.try(
        enrollment.matches(enrolled, facts.enrolled)
        |> result.replace_error(BindingMismatch),
      )
      use _ <- result.try(
        input.launch_envelope(original.key, decoded)
        |> result.replace_error(InvalidInput),
      )
      Ok(Some(facts.compiled_by))
    }
  })
  use Nil <- result.try(
    case
      string.lowercase(bit_array.base16_encode(digest(original.body)))
      == command.digests(original.key).0
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  let header =
    bit_array.from_string(json.to_string(command.encode_service(original.key)))
  let address =
    bit_array.from_string(
      remote_tool.child_address(command.service_origin(original.key)),
    )
  use Nil <- result.try(
    case
      bit_array.byte_size(header) <= 8192
      && bit_array.byte_size(address) <= 8192
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  let role = case command.service_role(original.key) {
    command.CompileService -> 0
    command.LaunchService -> 1
  }
  Ok(Validated(
    original,
    bit_array.from_string(
      ids.entry_id_to_string(command.request_id(original.key)),
    ),
    address,
    header,
    role,
    digest(original.body),
    producer,
  ))
}

fn ready_for(
  enrolled: enrollment.SessionEnrollment,
  original: Validated,
  bytes: BitArray,
) -> Result(resources.Ready, Error) {
  use ready <- result.try(
    resources.decode(enrolled, bytes) |> result.replace_error(InvalidInput),
  )
  let agrees = case ready, original.producer {
    resources.CompileReady(locations), None ->
      resources.compile_fields(locations).0 == original.original.key
    resources.LaunchReady(locations), Some(producer) ->
      resources.launch_keys(locations) == #(original.original.key, producer)
    _, _ -> False
  }
  case agrees {
    True -> Ok(ready)
    False -> Error(InvalidInput)
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
  let journal = Journal(started.data, config.enrolled)
  case exchange(journal, Initialise(mode, _)) {
    Ok(Nil) -> Ok(journal)
    Error(error) -> {
      // Initialization may still be queued after timeout. Close behind it.
      process.send(journal.subject, CloseEndpoint(process.new_subject()))
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
    Ready(config, connection), Metadata(command, reply) -> {
      let outcome = metadata_transaction(connection, config, command)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Waiting(_), Metadata(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(_, connection), CloseEndpoint(reply) -> {
      process.send(reply, sqlight.close(connection) |> sql_error)
      actor.stop()
    }
    Waiting(_), CloseEndpoint(reply) -> {
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
          sqlight.exec(resource_schema.schema, connection) |> sql_error,
        )
        statement(
          connection,
          sql.initialize_resources(
            snapshot(config.enrolled),
            config.limits.rows,
            config.limits.bytes,
          ),
        )
      }
      Recover -> Ok(Nil)
    })
    use inventory <- result.try(inventory(connection, config))

    // Retain only bounded addresses while validating each large body separately.
    list.try_fold(inventory.rows, set.new(), fn(seen, row) {
      use checked <- result.try(checked_row(connection, config, row))
      case set.contains(seen, checked.1) {
        True -> Error(Corrupt)
        False -> Ok(set.insert(seen, checked.1))
      }
    })
    |> result.replace(Nil)
  }
  complete_transaction(connection, outcome)
}

fn snapshot(enrolled: enrollment.SessionEnrollment) -> BitArray {
  // Smart construction already bounded this exact canonical snapshot.
  result.lazy_unwrap(enrollment.encode(enrolled), fn() { <<>> })
}

fn inventory(
  connection: sqlight.Connection,
  config: Config,
) -> Result(Inventory, Error) {
  use metadata <- result.try(
    query(connection, sql.resource_metadata()) |> result.replace_error(Corrupt),
  )
  use mode <- result.try(case metadata {
    [sql.ResourceMetadata(actual, mode, rows, bytes)]
      if rows == config.limits.rows && bytes == config.limits.bytes
    -> {
      use Nil <- result.try(case actual == snapshot(config.enrolled) {
        True -> Ok(Nil)
        False -> Error(BindingMismatch)
      })
      case mode {
        0 -> Ok(Open)
        1 -> Ok(SealedScope)
        _ -> Error(Corrupt)
      }
    }
    [_] -> Error(BindingMismatch)
    _ -> Error(Corrupt)
  })
  use rows <- result.try(
    query(connection, sql.resource_headers(config.limits.rows + 1))
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
      Ok(total + reservation(row))
    }),
  )
  use Nil <- result.try(
    case
      list.drop(rows, config.limits.rows) == []
      && reserved <= config.limits.bytes
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )
  use _ <- result.try(
    list.try_fold(rows, set.new(), fn(seen, row) {
      case set.contains(seen, row.id) {
        True -> Error(Corrupt)
        False -> Ok(set.insert(seen, row.id))
      }
    }),
  )
  Ok(Inventory(mode, rows))
}

fn reservation(row: sql.ResourceHeaders) -> Int {
  // All original blobs plus UUID and both digest slots remain reserved forever.
  row.address_size + row.header_size + row.input_size + 262_144 + 100
}

fn retained(
  connection: sqlight.Connection,
  config: Config,
  row: sql.ResourceHeaders,
) -> Result(Status, Error) {
  checked_row(connection, config, row) |> result.map(fn(checked) { checked.0 })
}

fn checked_row(
  connection: sqlight.Connection,
  config: Config,
  row: sql.ResourceHeaders,
) -> Result(#(Status, BitArray), Error) {
  use bodies <- result.try(
    query(connection, sql.resource_bodies(row.id))
    |> result.replace_error(Corrupt),
  )
  use body <- result.try(case bodies {
    [body] -> Ok(body)
    _ -> Error(Corrupt)
  })
  use key <- result.try(decode_header(body.service_header))
  use validated <- result.try(
    validate(config.enrolled, Input(key, body.input))
    |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(
    case
      validated.id == row.id
      && validated.address == body.address
      && validated.header == body.service_header
      && validated.role == row.role
      && validated.digest == row.input_digest
      && bit_array.byte_size(body.input) == row.input_size
      && bit_array.byte_size(body.address) == row.address_size
      && bit_array.byte_size(body.service_header) == row.header_size
      && bit_array.byte_size(body.ready) == row.ready_size
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )
  use ready <- result.try(case body.ready {
    <<>> -> Ok(None)
    bytes -> {
      use Nil <- result.try(case digest(bytes) == row.ready_digest {
        True -> Ok(Nil)
        False -> Error(Corrupt)
      })
      ready_for(config.enrolled, validated, bytes)
      |> result.map(Some)
      |> result.replace_error(Corrupt)
    }
  })
  let status = case row.phase, ready {
    0, None -> Ok(Reserved)
    1, None | 3, _ -> Ok(Unknown(ready))
    2, Some(ready) -> Ok(Prepared(ready))
    4, _ -> Ok(Released(ready))
    _, _ -> Error(Corrupt)
  }
  result.map(status, fn(status) { #(status, validated.address) })
}

fn decode_header(bytes: BitArray) -> Result(command.ServiceKey, Error) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(Corrupt),
  )
  use value <- result.try(json.parse(text) |> result.replace_error(Corrupt))
  command.decode_service(value) |> result.replace_error(Corrupt)
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
    use inventory <- result.try(inventory(connection, config))
    execute(connection, config, inventory, command)
  }
  complete_transaction(connection, outcome)
}

fn metadata_transaction(
  connection: sqlight.Connection,
  config: Config,
  command: MetadataCommand,
) -> Result(ScopeMode, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(connection, config))
    case command, inventory.mode {
      ObserveMode, mode -> Ok(mode)
      SealScope, SealedScope -> Ok(SealedScope)
      SealScope, Open -> {
        use Nil <- result.try(phase_change(
          connection,
          sql.seal_resources(),
          fn(row) { row.mode },
          1,
        ))
        Ok(SealedScope)
      }
    }
  }
  complete_transaction(connection, outcome)
}

fn require_open(mode: ScopeMode) -> Result(Nil, Error) {
  case mode {
    Open -> Ok(Nil)
    SealedScope -> Error(Sealed)
  }
}

fn command_input(command: Command) -> Validated {
  case command {
    Reserve(original)
    | Inspect(original)
    | TakeClaim(original)
    | CommitReady(original, _)
    | LoseResources(original)
    | RetireResources(original) -> original
  }
}

fn execute(
  connection: sqlight.Connection,
  config: Config,
  inventory: Inventory,
  command: Command,
) -> Result(Answer, Error) {
  let original = command_input(command)
  case list.find(inventory.rows, fn(row) { row.id == original.id }) {
    Error(_) -> {
      use addresses <- result.try(
        query(connection, sql.resource_address(original.address))
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case addresses {
        [] -> Ok(Nil)
        _ -> Error(Conflict)
      })
      case command {
        Reserve(_) -> {
          use Nil <- result.try(require_open(inventory.mode))
          insert(connection, config, inventory.rows, original)
        }
        Inspect(_)
        | TakeClaim(_)
        | CommitReady(_, _)
        | LoseResources(_)
        | RetireResources(_) -> Error(Missing)
      }
    }
    Ok(row) -> {
      use status <- result.try(retained(connection, config, row))
      use bodies <- result.try(
        query(connection, sql.resource_bodies(row.id))
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case bodies {
        [body]
          if body.input == original.original.body
          && body.service_header == original.header
          && body.address == original.address
        -> Ok(Nil)
        _ -> Error(Conflict)
      })
      transition(
        connection,
        config.enrolled,
        inventory.mode,
        row,
        status,
        command,
      )
    }
  }
}

fn insert(
  connection: sqlight.Connection,
  config: Config,
  rows: List(sql.ResourceHeaders),
  original: Validated,
) -> Result(Answer, Error) {
  let reserved = list.fold(rows, 0, fn(total, row) { total + reservation(row) })
  let required =
    bit_array.byte_size(original.address)
    + bit_array.byte_size(original.header)
    + bit_array.byte_size(original.original.body)
    + 262_144
    + 100
  use Nil <- result.try(
    case
      list.drop(rows, config.limits.rows - 1) == []
      && reserved + required <= config.limits.bytes
    {
      True -> Ok(Nil)
      False -> Error(Capacity)
    },
  )
  use inserted <- result.try(query(
    connection,
    sql.insert_resource(
      original.id,
      original.address,
      original.header,
      original.role,
      original.digest,
      bit_array.byte_size(original.original.body),
      original.original.body,
    ),
  ))
  use Nil <- result.try(case inserted {
    [sql.InsertResource(id)] if id == original.id -> Ok(Nil)
    _ -> Error(Uncertain)
  })
  Ok(Answer(Reserved, Withheld))
}

fn transition(
  connection: sqlight.Connection,
  enrolled: enrollment.SessionEnrollment,
  mode: ScopeMode,
  row: sql.ResourceHeaders,
  status: Status,
  command: Command,
) -> Result(Answer, Error) {
  case command, status {
    TakeClaim(_), Reserved -> {
      use Nil <- result.try(require_open(mode))
      use Nil <- result.try(phase_change(
        connection,
        sql.claim_resource(row.id),
        fn(row) { row.phase },
        1,
      ))
      Ok(Answer(Unknown(None), Granted))
    }
    CommitReady(original, bytes), Unknown(None) if row.phase == 1 -> {
      use ready <- result.try(ready_for(enrolled, original, bytes))
      use Nil <- result.try(phase_change(
        connection,
        sql.commit_resource_ready(
          digest(bytes),
          bit_array.byte_size(bytes),
          bytes,
          row.id,
        ),
        fn(row) { row.phase },
        2,
      ))
      Ok(Answer(Prepared(ready), Withheld))
    }
    CommitReady(_, bytes), Prepared(ready) -> {
      use original <- result.try(
        resources.encode(ready) |> result.replace_error(Corrupt),
      )
      case bytes == original {
        True -> Ok(Answer(status, Withheld))
        False -> Error(Conflict)
      }
    }
    CommitReady(_, _), _ -> Error(Conflict)
    LoseResources(_), Unknown(_) if row.phase == 3 ->
      Ok(Answer(status, Withheld))
    LoseResources(_), Unknown(_) | LoseResources(_), Prepared(_) -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.mark_resource_unknown(row.id),
        fn(row) { row.phase },
        3,
      ))
      Ok(Answer(Unknown(historical(status)), Withheld))
    }
    LoseResources(_), Released(_) -> Ok(Answer(status, Withheld))
    LoseResources(_), Reserved -> Error(Conflict)
    RetireResources(_), Released(_) -> Ok(Answer(status, Withheld))
    RetireResources(_), Reserved -> Error(Conflict)
    RetireResources(_), _ -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.release_resource(row.id),
        fn(row) { row.phase },
        4,
      ))
      Ok(Answer(Released(historical(status)), Withheld))
    }
    Reserve(_), _ | Inspect(_), _ | TakeClaim(_), _ ->
      Ok(Answer(status, Withheld))
  }
}

fn historical(status: Status) -> Option(resources.Ready) {
  case status {
    Reserved -> None
    Unknown(ready) | Released(ready) -> ready
    Prepared(ready) -> Some(ready)
  }
}

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
