//// The receiving end of a session move (protocol-change/078, phase 5).
////
//// Another orchestrator hands this one a session by sending a copy of its
//// closed conversation file and then asking this daemon to make the copy into
//// the session. This module answers those three requests: it writes the pieces
//// of the copy into a directory of its own, says how far a move has got, and
//// activates the session. It is the whole of what a receiver does, and it does
//// it through the registry, so the one place that decides what this daemon
//// serves is the place that records the arrival.
////
//// ## Taking the copy
////
//// The pieces arrive in order, each acknowledged before the next. They are
//// written to a `.part` file, which becomes the complete copy only when the last
//// piece lands, so a name that exists in `incoming/` is whole. A piece that does
//// not start where the file stands is refused with the offset it expected, and
//// the sender starts again from zero; there is no resume inside a file. The
//// declared size is bounded, and a piece that would run past it is refused.
////
//// ## Activating the session
////
//// An activation is a compare-and-set on this daemon's catalogue, so everything
//// that can be checked is checked before it, and nothing is changed until it
//// passes. The order matters, because each check protects the next.
////
//// 1. The catalogue is asked first. A session this daemon already took in under
////    the same move is answered again without looking at the copy and without
////    looking at who is asking, because the first activation checked both
////    before it committed. Once that commit exists, every activation of the
////    same move is accepted: the sender abandons the move on a refusal, so a
////    refusal after the commit would leave the session owned by both daemons.
////    A reply the sender never saw must be answerable any number of times, and
////    whatever has changed since, such as a session opened here, an
////    `[orchestrators.<name>]` row renamed, or the copy gone, must not change
////    the answer. A session held under any other state is refused.
//// 2. Otherwise the sender's node is one of this daemon's
////    `[orchestrators.<name>]`. Without that there is no name to record as the
////    session's origin, and no standing to tell this daemon about sessions.
//// 3. The copy's SHA-256 is the digest the sender took when it cut the file.
////    A different digest means the copy is not what was cut, and the sender
////    sends the whole file again.
//// 4. The copy's scope cell reads a clean close at the incarnation the sender
////    claims. This is what makes the session safe to open on a different
////    machine: the executor holds nothing the old orchestrator can still use,
////    and the next attach is for the next incarnation. The cell is read from a
////    scratch copy, so opening the file, which rewrites a header and a lease,
////    never changes the bytes whose digest was just checked.
//// 5. This daemon has an `[executors.<name>]` for the executor the cell names.
////    Without one the session could be registered and never opened.
//// 6. The registry commits the registration, its mapping and the `imported` row
////    together and moves the copy into place in the same turn.
////
//// Every refusal is final for the sender, and it says why. A fault that is not
//// a finding about the copy, such as a registry that did not answer, is a
//// failure and the sender asks again.

import client/daemon/manager
import client/executors.{type Executor}
import client/orchestrators.{type Orchestrator}
import client/remote/orchestrator_port
import client/remote/protocol
import client/remote/scope
import client/session_move.{
  type Activation, type Chunk, type Stage, type Verdict, Accepted, Failed,
  Refused,
}
import core/clock.{type Clock}
import core/ids
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/catalogue
import telemetry/field
import telemetry/log.{type Logger}

/// What a receiver needs to take in a session.
pub type Context(instance) {
  Context(
    /// The registry, which decides what this daemon serves.
    registry: manager.Manager(instance),
    /// The daemon's private root, below which copies wait in `incoming/`.
    state_root: String,
    /// The directory new conversation files are placed in.
    sessions_directory: String,
    /// The daemon-wide domain configuration a new session's mapping carries.
    domain_configuration: String,
    /// The clock the short reads of a copy's cell use.
    clock: Clock,
    /// The orchestrators this daemon lists, by which a sender is recognised.
    orchestrators: List(Orchestrator),
    /// The executors this daemon lists, one of which must hold the session.
    executors: List(Executor),
    /// Where the receiver writes down what it did.
    logger: Logger,
  )
}

/// The importer a daemon hands the orchestrator port.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.start_importing(orchestrator_port.default(), held, session_importer.new(context))
/// ```
pub fn new(context: Context(instance)) -> orchestrator_port.Importer {
  orchestrator_port.Importer(
    chunk: fn(piece) { take(context, piece) },
    stage: fn(session, op) { stage(context, session, op) },
    activate: fn(activation) { activate(context, activation) },
  )
}

// --- the pieces -------------------------------------------------------------

/// Writes one piece of a copy. The first piece, at offset zero, begins the file
/// afresh; every later one must start exactly where the file stands. The piece
/// that reaches the declared size makes the file complete.
///
/// ## Examples
///
/// ```gleam
/// // session_importer.take(context, session_move.Chunk(session:, op:, offset: 0, total: 3, bytes: <<1, 2, 3>>))
/// ```
pub fn take(context: Context(instance), piece: Chunk) -> Verdict {
  case taken(context, piece) {
    Ok(Nil) -> Accepted
    Error(verdict) -> verdict
  }
}

fn taken(context: Context(instance), piece: Chunk) -> Result(Nil, Verdict) {
  use Nil <- result.try(well_formed(piece.session, piece.op))
  let size = bit_array.byte_size(piece.bytes)
  use Nil <- result.try(
    case
      piece.total >= 1
      && piece.total <= session_move.size_limit
      && piece.offset >= 0
      && size >= 1
      && piece.offset + size <= piece.total
    {
      True -> Ok(Nil)
      False ->
        Error(Refused(session_move.BadSize(limit: session_move.size_limit)))
    },
  )
  let directory = session_move.incoming_directory(context.state_root)
  use Nil <- result.try(
    bootstrap.ensure_private_directory(directory)
    |> result.map_error(fn(reason) { Failed(reason) }),
  )
  let part = session_move.part_path(context.state_root, piece.session, piece.op)
  use Nil <- result.try(case piece.offset {
    0 ->
      simplifile.write_bits(part, piece.bytes)
      |> result.map_error(file_failure(part))
    offset -> {
      let held = size_of(part)
      case held == offset {
        True ->
          simplifile.append_bits(part, piece.bytes)
          |> result.map_error(file_failure(part))
        False -> Error(Refused(session_move.OutOfOrder(expected: held)))
      }
    }
  })
  case piece.offset + size == piece.total {
    False -> Ok(Nil)
    True -> {
      let whole =
        session_move.incoming_path(context.state_root, piece.session, piece.op)
      simplifile.rename(at: part, to: whole)
      |> result.map_error(file_failure(whole))
    }
  }
}

// The size of a file, or zero for one that is not there, which is where a
// stream that lost its first piece stands.
fn size_of(path: String) -> Int {
  case simplifile.file_info(path) {
    Ok(info) -> info.size
    Error(_) -> 0
  }
}

fn file_failure(path: String) -> fn(simplifile.FileError) -> Verdict {
  fn(error) {
    Failed(
      "the received file " <> path <> ": " <> simplifile.describe_error(error),
    )
  }
}

// --- the status -------------------------------------------------------------

/// How far the move `op` of the session has got here: nothing, a whole copy
/// waiting, or the session taken in with its file in place.
///
/// A session whose row says `imported` under this move but whose copy is still
/// waiting is `Received`, because an activation that crashed between its commit
/// and the rename is finished by the sender asking again.
///
/// A catalogue that cannot be read, or a copy's path that cannot be examined,
/// gives no answer at all, which the port sends as silence. `Absent` would tell
/// the sender that nothing is here, and it would send the whole file again to a
/// receiver that may already hold the session.
///
/// ## Examples
///
/// ```gleam
/// // session_importer.stage(context, session, op)
/// ```
pub fn stage(
  context: Context(instance),
  session: String,
  op: String,
) -> Result(Stage, Nil) {
  let whole = session_move.incoming_path(context.state_root, session, op)

  // A file that cannot be examined is not a copy that is absent. With the row
  // `imported` the answer would be `Activated` while an unplaced copy may still
  // wait, and the source would retire over a session whose file is not in place.
  use waiting <- result.try(
    simplifile.is_file(whole) |> result.replace_error(Nil),
  )
  case manager.custody(context.registry, session) {
    Ok(catalogue.Imported(op: held, ..)) if held == op ->
      case waiting {
        True -> Ok(session_move.Received)
        False -> Ok(session_move.Activated)
      }

    // A session the catalogue has no row for is the ordinary first arrival.
    Ok(_) | Error(manager.Catalogue(catalogue.Missing)) ->
      case waiting {
        True -> Ok(session_move.Received)
        False -> Ok(session_move.Absent)
      }
    Error(_) -> Error(Nil)
  }
}

// --- the activation ---------------------------------------------------------

/// Makes the copy the sender cut into the session, after checking everything
/// that can be checked first. A repeat of an activation that already succeeded
/// answers `Accepted` again.
///
/// ## Examples
///
/// ```gleam
/// // session_importer.activate(context, activation)
/// ```
pub fn activate(context: Context(instance), activation: Activation) -> Verdict {
  let outcome = activated(context, activation)
  let verdict = case outcome {
    Ok(Nil) -> Accepted
    Error(verdict) -> verdict
  }
  discard_refused(context, activation, verdict)
  record(context, activation, verdict)
  verdict
}

// A copy this daemon refused for a reason that sending it again cannot cure is
// removed, because the move it belongs to is over and nothing else will. A
// digest that does not match and a copy that is missing are cured by a new send,
// which replaces the file, so those leave it where it is.
fn discard_refused(
  context: Context(instance),
  activation: Activation,
  verdict: Verdict,
) -> Nil {
  case verdict {
    Refused(refusal: session_move.DigestMismatch)
    | Refused(refusal: session_move.NothingReceived)
    | Accepted
    | Failed(..) -> Nil
    Refused(..) -> {
      let whole =
        session_move.incoming_path(
          context.state_root,
          activation.session,
          activation.op,
        )
      list.each([whole, whole <> ".part", whole <> ".check"], fn(leftover) {
        let _removed = simplifile.delete_file(leftover)
        Nil
      })
    }
  }
}

fn activated(
  context: Context(instance),
  activation: Activation,
) -> Result(Nil, Verdict) {
  use Nil <- result.try(well_formed(activation.session, activation.op))
  use found <- result.try(
    case manager.custody(context.registry, activation.session) {
      Ok(custody) -> Ok(Some(custody))

      // A session this catalogue has no registration for is not an error: it is
      // the ordinary first arrival.
      Error(manager.Catalogue(catalogue.Missing)) -> Ok(None)
      Error(other) -> Error(Failed(string.inspect(other)))
    },
  )
  case found {
    // The first activation of this move committed and the sender did not hear.
    // It checked the copy and the sender then; asking again finishes what it
    // left undone, and there may be no copy left to check. The origin is the
    // one the row recorded, so a sender that this daemon no longer lists is
    // still answered: refusing here would be a refusal after the commit.
    Some(catalogue.Imported(op:, from:)) if op == activation.op ->
      import_it(context, activation, from)
    Some(catalogue.Resident)
    | Some(catalogue.Moving(..))
    | Some(catalogue.Imported(..)) -> conflict(context, activation)
    Some(catalogue.Moved(op:, ..)) if op == activation.op ->
      conflict(context, activation)

    // A session that was never here, or that was here and went away under an
    // earlier move, can be taken in.
    Some(catalogue.Moved(..)) | None -> {
      use source <- result.try(listed(context, activation))
      verified(context, activation, source)
    }
  }
}

// The orchestrator this daemon lists for the activation's node.
fn listed(
  context: Context(instance),
  activation: Activation,
) -> Result(Orchestrator, Verdict) {
  orchestrators.by_node(context.orchestrators, activation.from_node)
  |> result.replace_error(
    Refused(session_move.UnknownSource(node: activation.from_node)),
  )
}

// The refusal for a session this daemon holds under another state or move. It
// is for a listed sender only, so a node this daemon does not know learns
// nothing about which sessions it holds.
fn conflict(
  context: Context(instance),
  activation: Activation,
) -> Result(Nil, Verdict) {
  use _source <- result.try(listed(context, activation))
  Error(Refused(session_move.Conflict))
}

// The checks on the copy, and then the arrival.
fn verified(
  context: Context(instance),
  activation: Activation,
  source: Orchestrator,
) -> Result(Nil, Verdict) {
  let whole =
    session_move.incoming_path(
      context.state_root,
      activation.session,
      activation.op,
    )
  use Nil <- result.try(case simplifile.is_file(whole) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) -> Error(Refused(session_move.NothingReceived))
  })
  use bytes <- result.try(
    simplifile.read_bits(whole) |> result.map_error(file_failure(whole)),
  )
  use Nil <- result.try(case digest_of(bytes) == activation.digest {
    True -> Ok(Nil)
    False -> Error(Refused(session_move.DigestMismatch))
  })
  use cell <- result.try(closed_cell(context, activation, whole))
  let named = case cell.executor {
    Some(name) -> name
    None -> activation.manifest.executor
  }
  use Nil <- result.try(
    case
      named == activation.manifest.executor,
      executors.find(context.executors, named)
    {
      False, _ ->
        Error(
          Refused(session_move.NotClosed(
            "the scope names the executor "
            <> named
            <> " but the manifest names "
            <> activation.manifest.executor,
          )),
        )
      True, Error(Nil) -> Error(Refused(session_move.NoExecutor(name: named)))
      True, Ok(_) -> Ok(Nil)
    },
  )
  import_it(context, activation, source.name)
}

// The copy's scope cell, which must read a clean close at the claimed
// incarnation. It is read from a scratch copy: opening a session file switches
// its journal mode and writes and releases a lease, and the file whose digest
// was just checked must stay exactly what the sender cut.
fn closed_cell(
  context: Context(instance),
  activation: Activation,
  whole: String,
) -> Result(scope.Scope, Verdict) {
  let check =
    session_move.check_path(
      context.state_root,
      activation.session,
      activation.op,
    )
  use Nil <- result.try(
    simplifile.copy_file(at: whole, to: check)
    |> result.map_error(file_failure(check)),
  )
  let read =
    scope.read_at(
      check,
      session_move.reader_owner(activation.op),
      context.clock,
    )
  list.each(
    [check, check <> "-wal", check <> "-shm", check <> "-journal"],
    fn(leftover) {
      let _removed = simplifile.delete_file(leftover)
      Nil
    },
  )
  case read {
    Error(reason) -> Error(Refused(session_move.NotClosed(reason)))
    Ok(None) ->
      Error(
        Refused(session_move.NotClosed(
          "the copy records no scope on an executor",
        )),
      )
    Ok(Some(cell)) ->
      case cell.closed, cell.incarnation == activation.incarnation {
        Some(protocol.AllRetired), True -> Ok(cell)
        Some(protocol.AllRetired), False ->
          Error(
            Refused(session_move.NotClosed(
              "the copy closed incarnation "
              <> int.to_string(cell.incarnation)
              <> ", not the "
              <> int.to_string(activation.incarnation)
              <> " claimed",
            )),
          )
        Some(protocol.UnknownCleanup(..)), _ ->
          Error(
            Refused(session_move.NotClosed(
              "the executor could not prove the scope's cleanup",
            )),
          )
        None, _ ->
          Error(
            Refused(session_move.NotClosed(
              "the copy's last close was never recorded",
            )),
          )
      }
  }
}

// Hands the registry what it needs to register the session and record the
// arrival. The copy waits where the pieces left it, or is already gone from
// there in a repeat, in which case the registry checks that the file is in
// place.
fn import_it(
  context: Context(instance),
  activation: Activation,
  from: String,
) -> Result(Nil, Verdict) {
  let manifest = activation.manifest
  let received =
    session_move.incoming_path(
      context.state_root,
      activation.session,
      activation.op,
    )
  let registration =
    catalogue.Registration(
      id: activation.session,
      path: context.sessions_directory <> "/" <> activation.session <> ".db",
      workspace: manifest.workspace,
      name: manifest.name,
      configuration: "",
      profile: manifest.profile,
      model: None,
      executor: manifest.executor,
      pool: manifest.pool,
      created_at: manifest.created_at,
      request_key: "import-" <> activation.op,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let mapping =
    manager.session_only_domain(
      registration,
      context.domain_configuration,
      context.state_root,
    )
  case
    manager.import_session(
      context.registry,
      manager.Import(
        registration:,
        mapping:,
        op: activation.op,
        from:,
        received:,
        subtitle: manifest.subtitle,
      ),
    )
  {
    Ok(_) -> Ok(Nil)
    Error(manager.AdminMetadata(catalogue.Conflict))
    | Error(manager.AdminBusy) -> Error(Refused(session_move.Conflict))
    Error(manager.AdminMetadata(catalogue.Invalid(reason))) ->
      Error(Refused(session_move.Malformed(reason)))
    Error(other) -> Error(Failed(string.inspect(other)))
  }
}

// --- shared -----------------------------------------------------------------

// A session identity and an operation in their grammars. They name files, so a
// separator or a dot-dot in either must be refused before it reaches a path.
fn well_formed(session: String, op: String) -> Result(Nil, Verdict) {
  case ids.parse_session_id(session), catalogue.is_move_op(op) {
    Ok(_), True -> Ok(Nil)
    Error(_), _ ->
      Error(Refused(session_move.Malformed("the session identity is invalid")))
    _, False ->
      Error(Refused(session_move.Malformed("the operation is invalid")))
  }
}

fn digest_of(bytes: BitArray) -> String {
  bootstrap.sha256(bytes) |> bit_array.base16_encode |> string.lowercase
}

fn record(
  context: Context(instance),
  activation: Activation,
  verdict: Verdict,
) -> Nil {
  let fields = [
    field.ident("session", activation.session),
    field.ident("op", activation.op),
  ]
  case verdict {
    Accepted -> log.info(context.logger, "daemon.move_activated", fields)
    Refused(refusal:) ->
      log.warn(context.logger, "daemon.move_refused", [
        field.text("reason", session_move.describe(refusal)),
        ..fields
      ])
    Failed(reason:) ->
      log.warn(context.logger, "daemon.move_failed", [
        field.text("reason", reason),
        ..fields
      ])
  }
}
