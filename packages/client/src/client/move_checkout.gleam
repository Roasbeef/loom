//// The checkout step of a session move (protocol-change/107, slice 4c).
////
//// `sessions.move` hands a conversation to another orchestrator and leaves the
//// workspace where it is, on an executor both orchestrators reach. A session
//// whose workspace is a directory on the source has no such executor. This
//// module is the step that gives it one: it captures the directory, sends the
//// state to the executor the source's configuration names for the destination,
//// puts it in a scope's tree there, and closes the scope, so that the six steps
//// of `client/session_mover` find what they find for any session on an
//// executor: a file whose scope cell reads a clean close.
////
//// ## Why the state is applied by the source
////
//// `StateApply` is fenced by a scope's incarnation and token, so it needs an
//// open scope, and only an orchestrator that attached can send it. The
//// destination does not exist yet as far as the session is concerned: it takes
//// the session at the activation, after which its first turn may run at once. So
//// the source attaches a scope for the length of one apply (`landing`), asks for
//// it, and closes it cleanly. Nothing can run on the destination before the
//// apply has been answered, because the destination is not told of the session
//// until the checkout is recorded as done. The close removes the tree and keeps
//// the branch `loom/<session>`, and the destination's first attach, at the next
//// incarnation, recreates the tree from that branch at the applied tip.
////
//// ## What stays durable, and where
////
//// The step is entered again after a crash, after a step that could not finish
//// and after a daemon restart, and it takes only what remains. Its memory is one
//// reserved cell in the session file (`client/move/checkout`), written while no
//// writer holds the file: the move's operation, the state that was captured and
//// whether it was placed. A dirty workspace is captured as a snapshot commit
//// with a timestamp, so capturing again would give another hash and send the
//// bundle from the start; the cell lets a rerun send the state it already has,
//// from the offset the executor holds. A cell for another operation is ignored
//// and replaced, so a move that was abandoned and asked for again captures the
//// workspace as it is now.
////
//// Applying again is harmless. An apply of a tip the tree already has answers
//// the tip and changes nothing, and the scope the source left open is rebound by
//// the next attach, so a crash between the attach and the close costs one more
//// incarnation and nothing else.
////
//// ## What it refuses and what it only waits for
////
//// A failure names the stage it happened in. It is a `Refused` when the answer
//// will not change by asking again: the workspace cannot be captured (a
//// submodule, a shallow clone, LFS), the executor will not take the state (a
//// `shared` workspace, a tree with changes), or the store declines the bundle.
//// The move is then abandoned and the session stays on the source, with its
//// directory untouched. It is `Unfinished` when the executor or the link did not
//// answer, and the mover stalls and tries again.
////
//// ## What the move leaves behind
////
//// The source's directory is not changed, on success or failure, and Loom does
//// not write to it again for this session. The executor keeps the branch it was
//// given and, for seven days, the bundle in its state store. The session's
//// memory domain, when it is a workspace's, stays on the source, as for any
//// session that moves.
////
//// ## Flow
////
//// `carry` → `remembered` → `captured` → `delivered` → `sent` → `placed`, and
//// `landing` for the attach, apply and close the last of them asks for.
////
//// 1. `carry` reads the cell and takes the step from where it stopped.
//// 2. `captured` captures the directory into this node's store and records it.
//// 3. `sent` pushes the bundle to the executor's store, resuming at its offset.
//// 4. `placed` asks the ports to land the state in a tree, and `delivered`
////    records that the checkout was done.
//// 5. `landing` builds the function that does the landing, over an executor's
////    placement.

import client/orchestrators.{type CheckoutTarget}
import client/owner_services
import client/remote/owner_port
import client/remote/protocol
import client/remote/scope
import client/remote/workspace
import client/session_move
import client/state_object.{type State}
import client/state_store.{type Store}
import client/state_transfer.{type Link}
import core/clock.{type Clock}
import core/json
import core/register
import core/tx
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import session/session
import storage/catalogue
import storage/sqlite
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}

/// The reserved cell the step remembers itself in. The `client/` prefix keeps it
/// out of reach of a model's `put_fact`.
pub const key = "client/move/checkout"

/// The stage a failure happened in, in the words a refusal names it by.
pub type Stage {
  /// The session file could not be read or written.
  Recording

  /// The directory was being captured into this node's store.
  Capturing

  /// The state was being sent to the executor.
  Sending

  /// The state was being put in a scope's tree on the executor.
  Placing
}

/// The words for a stage, which follow "the checkout failed while".
///
/// ## Examples
///
/// ```gleam
/// assert move_checkout.describe_stage(move_checkout.Sending)
///   == "sending the state to the executor"
/// ```
pub fn describe_stage(stage: Stage) -> String {
  case stage {
    Recording -> "recording its progress in the session file"
    Capturing -> "capturing the workspace"
    Sending -> "sending the state to the executor"
    Placing -> "putting the checkout in the executor's tree"
  }
}

/// Why the step did not finish.
pub type Failure {
  /// The answer is final: asking again is answered the same way, so the move
  /// may be abandoned.
  Refused(stage: Stage, reason: String)

  /// The answer may change: something did not answer in time, or the reason can
  /// pass. The move stalls and the step runs again.
  Unfinished(stage: Stage, reason: String)
}

/// The failure in one sentence, for a stall or an abort reason.
///
/// ## Examples
///
/// ```gleam
/// assert move_checkout.describe(move_checkout.Refused(move_checkout.Capturing, "a submodule"))
///   == "the checkout failed while capturing the workspace: a submodule"
/// ```
pub fn describe(failure: Failure) -> String {
  let #(stage, reason) = failure_parts(failure)
  "the checkout failed while " <> describe_stage(stage) <> ": " <> reason
}

/// The stage and the reason of a failure, whichever kind it is.
fn failure_parts(failure: Failure) -> #(Stage, String) {
  // Both kinds say the same two things; they differ in what the mover does.
  case failure {
    Refused(stage:, reason:) -> #(stage, reason)
    Unfinished(stage:, reason:) -> #(stage, reason)
  }
}

/// How far the step has got, told to `Ports.after` as each part becomes durable.
/// A test uses it to lose the mover at a chosen moment; a daemon passes a function
/// that does nothing.
pub type Progress {
  /// The captured state is recorded in the session file.
  Captured

  /// The executor's store holds the whole bundle.
  Sent

  /// The executor's tree holds the checkout and the scope is closed.
  Placed
}

/// What the step is asked to do.
pub type Request {
  Request(
    /// The session's canonical identity, which is also the branch's name on the
    /// executor (`loom/<session>`).
    session: String,
    /// The move's identity. The cell is only believed for this operation.
    op: String,
    /// The session file, which no writer holds.
    path: String,
    /// The workspace on this machine to capture.
    directory: String,
    /// The executor and workspace the checkout lands in.
    target: CheckoutTarget,
    /// The clock the file accesses read.
    clock: Clock,
    /// Where each stage that finishes says so, by the session, the operation,
    /// the state's short hash and size, and how long the stage took.
    logger: Logger,
  )
}

/// What the step asks of an executor's attach, apply and close: the session, the
/// move, the file, where to land and what to land.
pub type Arrival {
  Arrival(
    session: String,
    op: String,
    path: String,
    target: CheckoutTarget,
    state: State,
    clock: Clock,
  )
}

/// Why an arrival did not land.
pub type LandFailure {
  /// The executor answered, and what it said will not change by asking again.
  LandRefused(reason: String)

  /// The executor or the link did not answer, or answered something that may
  /// pass.
  LandUnfinished(reason: String)
}

/// What the step needs from the daemon around it. Each is a function so that
/// the step reads as a sequence and a test can replace one.
pub type Ports {
  Ports(
    /// Captures a directory into this node's store, with the working tree and
    /// the operator's identity for the snapshot commit.
    capture: fn(String) -> Result(State, String),
    /// This node's store, which holds the bundle the capture made.
    store: Store,
    /// The link to an executor's host, by the executor's name, or why it cannot
    /// be reached.
    link: fn(String) -> Result(Link, String),
    /// Attaches a scope for the session on the executor, applies the state in its
    /// tree and closes the scope, and answers the tip that was checked out.
    land: fn(Arrival) -> Result(String, LandFailure),
    /// Told after each part is durable.
    after: fn(Progress) -> Nil,
  )
}

/// Whether a registration is a session whose workspace is a directory on this
/// machine, which is the only kind this step serves. A session on an executor
/// keeps its checkout where it is, and one in a pool that has not attached yet
/// has no workspace to capture.
///
/// ## Examples
///
/// ```gleam
/// // move_checkout.is_local(registration)
/// ```
pub fn is_local(registration: catalogue.Registration) -> Bool {
  registration.executor == "" && registration.pool == ""
}

/// The registration the receiver is told of: the same session, placed on the
/// executor and workspace the checkout landed in. The source's own row is not
/// changed, so a move that is abandoned leaves a local session that opens as it
/// did before.
///
/// ## Examples
///
/// ```gleam
/// // move_checkout.relocated(registration, CheckoutTarget("box", "repo")).executor == "box"
/// ```
pub fn relocated(
  registration: catalogue.Registration,
  target: CheckoutTarget,
) -> catalogue.Registration {
  catalogue.Registration(
    ..registration,
    executor: target.executor,
    workspace: target.workspace,
  )
}

// --- the step ----------------------------------------------------------------

/// Takes the step from where it stopped, and answers when the checkout is on the
/// executor and the session file says so. Safe to call again after any outcome.
///
/// ## Examples
///
/// ```gleam
/// // move_checkout.carry(ports, request)
/// ```
pub fn carry(ports: Ports, request: Request) -> Result(Nil, Failure) {
  use kept <- result.try(remembered(request))

  // What an earlier run of this move left in the file decides where this one
  // starts: after the end, at the send, or at the beginning.
  case kept {
    // The checkout was placed and recorded by an earlier run of this move.
    Some(Marker(phase: Done, ..)) -> Ok(Nil)

    // A state was captured. It is used again only while this node's store
    // still holds it, since the store forgets a state after a week.
    Some(Marker(phase: Taken, state:, ..)) ->
      case still_held(ports.store, state) {
        True -> delivered(ports, request, state)
        False -> fresh(ports, request)
      }
    None -> fresh(ports, request)
  }
}

/// Captures the workspace and carries on from the state it made.
fn fresh(ports: Ports, request: Request) -> Result(Nil, Failure) {
  use state <- result.try(captured(ports, request))
  delivered(ports, request, state)
}

/// Sends and places a state, then records that the checkout is done.
fn delivered(
  ports: Ports,
  request: Request,
  state: State,
) -> Result(Nil, Failure) {
  use Nil <- result.try(sent(ports, request, state))
  ports.after(Sent)

  use Nil <- result.try(placed(ports, request, state))
  use Nil <- result.try(record(request, Marker(request.op, Done, state)))
  ports.after(Placed)
  Ok(Nil)
}

/// Captures the directory into this node's store and writes down the state, so
/// that a rerun sends the bundle it has.
fn captured(ports: Ports, request: Request) -> Result(State, Failure) {
  let started = bootstrap.monotonic_time_ms()
  use state <- result.try(
    ports.capture(request.directory)
    |> result.map_error(fn(reason) { Refused(Capturing, reason) }),
  )
  use Nil <- result.try(record(request, Marker(request.op, Taken, state)))
  told(request.logger, "captured", request.session, request.op, state, started)
  ports.after(Captured)
  Ok(state)
}

/// Says that a stage of the checkout finished, in one line a reader can follow
/// across the source and the executor. The state is named by its short hash and
/// its size, and nothing of either machine's paths is written.
fn told(
  logger: Logger,
  stage: String,
  session: String,
  op: String,
  state: State,
  started: Int,
) -> Nil {
  log.info(logger, "daemon.move_checkout_" <> stage, [
    field.ident("session", session),
    field.ident("op", op),
    field.ident("state", state_object.short(state.hash)),
    field.count("bytes", state.size),
    field.count("elapsed_ms", bootstrap.monotonic_time_ms() - started),
  ])
}

/// Pushes the bundle to the executor's store. The link asks how far the executor
/// has got, so a transfer that was interrupted resumes at its offset and one that
/// finished sends nothing.
fn sent(ports: Ports, request: Request, state: State) -> Result(Nil, Failure) {
  let started = bootstrap.monotonic_time_ms()
  use link <- result.try(
    ports.link(request.target.executor)
    |> result.map_error(fn(reason) { Unfinished(Sending, reason) }),
  )

  // Only a refusal from the executor's store is final. Silence and a fault are
  // what a dropped link looks like, and the next run resumes where this stopped.
  case state_transfer.send(ports.store, state.hash, link) {
    state_transfer.Delivered -> {
      told(request.logger, "sent", request.session, request.op, state, started)
      Ok(Nil)
    }
    state_transfer.Declined(refusal:) ->
      Error(Refused(Sending, state_transfer.describe(refusal)))
    state_transfer.Silent ->
      Error(Unfinished(Sending, "the executor did not answer"))
    state_transfer.Faulted(reason:) -> Error(Unfinished(Sending, reason))
    state_transfer.Stalled ->
      Error(Unfinished(Sending, "the executor stopped making progress"))
  }
}

/// Has the executor check the state out in a scope of its own and close it.
fn placed(
  ports: Ports,
  request: Request,
  state: State,
) -> Result(Nil, Failure) {
  let arrival =
    Arrival(
      session: request.session,
      op: request.op,
      path: request.path,
      target: request.target,
      state:,
      clock: request.clock,
    )

  // The tip the executor answers is the state's own, so nothing here reads it.
  case ports.land(arrival) {
    Ok(_tip) -> Ok(Nil)
    Error(LandRefused(reason:)) -> Error(Refused(Placing, reason))
    Error(LandUnfinished(reason:)) -> Error(Unfinished(Placing, reason))
  }
}

/// Whether this node's store holds the state, whole, under this description.
fn still_held(store: Store, state: State) -> Bool {
  case state_store.get(store, state.hash) {
    Ok(Some(held)) -> held.state == state
    Ok(None) | Error(_) -> False
  }
}

// --- the cell ----------------------------------------------------------------

/// What the step wrote down: whose move, how far, and the state.
type Marker {
  Marker(op: String, phase: Phase, state: State)
}

/// How far the move that wrote the cell got.
type Phase {
  /// The state is captured and in this node's store.
  Taken

  /// The state is on the executor, in a tree, and the scope is closed.
  Done
}

/// The cell, when it belongs to this move.
fn remembered(request: Request) -> Result(Option(Marker), Failure) {
  scope_file(request, storage_read)
  |> result.map_error(fn(reason) { Unfinished(Recording, reason) })
  |> result.map(fn(found) {
    case found {
      Some(Marker(op:, ..) as marker) if op == request.op -> Some(marker)
      Some(_) | None -> None
    }
  })
}

/// Replaces the cell.
fn record(request: Request, marker: Marker) -> Result(Nil, Failure) {
  scope_file(request, fn(opened) { storage_write(opened, marker) })
  |> result.map_error(fn(reason) { Unfinished(Recording, reason) })
}

/// Runs a cell access on the session file under the reader's lease owner.
fn scope_file(
  request: Request,
  access: fn(session.Session) -> Result(a, String),
) -> Result(a, String) {
  scope.with_file(
    request.path,
    session_move.reader_owner(request.op),
    request.clock,
    access,
  )
}

/// Reads the cell from an opened session file. An absent cell is `None`, and one
/// that is present and malformed is an error, so a damaged record is not taken
/// for a move that never started.
fn storage_read(opened: session.Session) -> Result(Option(Marker), String) {
  case storage.get_register(opened.store, register.FactCustom, key) {
    Error(error) ->
      Error("the checkout record is unreadable: " <> string.inspect(error))
    Ok(None) -> Ok(None)
    Ok(Some(cell)) -> decode(cell.value.payload) |> result.map(Some)
  }
}

/// Replaces the cell in an opened session file. The write goes straight to the
/// file's store, which is legal because no writer holds a file that is moving.
fn storage_write(
  opened: session.Session,
  marker: Marker,
) -> Result(Nil, String) {
  storage.commit(
    opened.store,
    tx.Tx(
      writes: [
        tx.SetRegister(register.FactCustom, key, register.value(encode(marker))),
      ],
      expected: [],
    ),
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    "the checkout record was not written: " <> string.inspect(error)
  })
}

/// The cell's payload: the move, how far it got, and the state as text.
fn encode(marker: Marker) -> json.JsonValue {
  json.Object([
    #("op", json.String(marker.op)),
    #("phase", json.String(phase_word(marker.phase))),
    #("state", json.String(state_object.encode(marker.state))),
  ])
}

fn phase_word(phase: Phase) -> String {
  case phase {
    Taken -> "taken"
    Done -> "done"
  }
}

/// The phase a word names.
fn phase_of(word: String) -> Result(Phase, String) {
  // Any other word was written by something else.
  case word {
    "taken" -> Ok(Taken)
    "done" -> Ok(Done)
    _ -> Error("the phase is not one the step writes")
  }
}

/// Reads the cell's payload, refusing one this module did not write.
fn decode(payload: json.JsonValue) -> Result(Marker, String) {
  // Only an object with the three members this module writes is a record.
  case payload {
    json.Object(fields) -> {
      use op <- result.try(text(fields, "op"))
      use word <- result.try(text(fields, "phase"))
      use phase <- result.try(phase_of(word))
      use encoded <- result.try(text(fields, "state"))
      use state <- result.map(state_object.decode(encoded))
      Marker(op:, phase:, state:)
    }
    _ -> Error("the record is not an object")
  }
  |> result.map_error(fn(reason) {
    "the checkout record is malformed: " <> reason
  })
}

/// One string member of the cell's payload.
fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  // A member of another type is as good as an absent one.
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error(name <> " is not a string")
  }
}

// --- landing -----------------------------------------------------------------

/// Builds the `land` function of the ports. `placing` gives the placement of a
/// session registered on one named executor (`workspace.fixed` over the daemon's
/// executor roster), so a name this daemon does not list never gets as far as an
/// attach.
///
/// The function opens the session file under the move's lease owner, attaches a
/// scope for the session on the executor the arrival names, asks it to apply the
/// state, and closes the scope whether or not the apply was accepted, so a
/// refusal leaves the executor with no scope open. The close writes the cell the
/// mover's next step reads. A refusal that is about the state or the tree is
/// final; the fence, the connection and a scope the executor is still preparing
/// are not.
///
/// ## Examples
///
/// ```gleam
/// // move_checkout.landing(fn(name) { workspace.fixed(membership, configured, name, fn(_) { Nil }) }, logger)
/// ```
pub fn landing(
  placing: fn(String) -> workspace.Placement,
  logger: Logger,
) -> fn(Arrival) -> Result(String, LandFailure) {
  fn(arrival: Arrival) {
    let owner = session_move.lease_owner(arrival.op)

    // A run that died here left its lease behind; this move's own is reclaimed.
    let _released = sqlite.release_export(path: arrival.path, owner:)
    scope.with_file(arrival.path, owner, arrival.clock, fn(opened) {
      attach_apply_close(
        placing(arrival.target.executor),
        logger,
        opened,
        arrival,
      )
    })
    |> result.map_error(LandUnfinished)
    |> result.flatten
  }
}

/// Attaches, applies and closes on an opened session file.
fn attach_apply_close(
  placement: workspace.Placement,
  logger: Logger,
  opened: session.Session,
  arrival: Arrival,
) -> Result(Result(String, LandFailure), String) {
  use recorded <- result.try(scope.read(opened))

  // The attach goes to the executor the file's scope record names, whatever the
  // placement says, so a record left by an earlier move that was abandoned would
  // put the checkout on one executor and tell the receiver another.
  case scope.executor_of(recorded) {
    Some(named) if named != arrival.target.executor ->
      Ok(
        Error(LandRefused(
          "the session's scope record names the executor `"
          <> named
          <> "` from an earlier move, so it can move only to a destination whose "
          <> "checkout_executor is that one",
        )),
      )
    Some(_) | None -> attach_and_apply(placement, logger, opened, arrival)
  }
}

/// Attaches a scope, applies the state in its tree and closes it.
fn attach_and_apply(
  placement: workspace.Placement,
  logger: Logger,
  opened: session.Session,
  arrival: Arrival,
) -> Result(Result(String, LandFailure), String) {
  let attached =
    workspace.attach(workspace.Registered(
      placement:,
      session: arrival.session,
      workspace: arrival.target.workspace,
      opened:,
      owner: owner_services.declining(),
      clock: arrival.clock,
      reconcile_every_ms: owner_port.default_reconcile_every_ms,
      executions: owner_port.no_executions(),
      mcp: protocol.empty_mcp_plan(),
      git_identity: None,
      logger:,
    ))

  // An attach that failed left nothing to close here: the open removed what it
  // had made. One that succeeded owns a scope that is closed on every path.
  case attached {
    Error(reason) -> Ok(Error(LandUnfinished(reason)))
    Ok(hands) -> {
      let applying = bootstrap.monotonic_time_ms()
      let applied = hands.apply_state(arrival.state)
      told_landed(logger, "applied", arrival, applying, applied)

      // The scope is closed on every path, so that the executor's slot is
      // returned and the file's cell records the close.
      let closing = bootstrap.monotonic_time_ms()
      hands.plane.close()
      told_landed(logger, "closed", arrival, closing, applied)
      Ok(landed(applied))
    }
  }
}

/// Says that the apply was accepted, or that the scope was closed after one that
/// was. A refused apply is told by the abort or the stall that carries its
/// reason, so it adds no line here.
fn told_landed(
  logger: Logger,
  stage: String,
  arrival: Arrival,
  started: Int,
  applied: Result(String, workspace.ApplyFailure),
) -> Nil {
  case applied {
    Ok(_tip) ->
      told(logger, stage, arrival.session, arrival.op, arrival.state, started)
    Error(_) -> Nil
  }
}

/// The executor's answer to an apply, as a landing's.
fn landed(
  applied: Result(String, workspace.ApplyFailure),
) -> Result(String, LandFailure) {
  case applied {
    Ok(tip) -> Ok(tip)
    Error(workspace.ApplyUnanswered) ->
      Error(LandUnfinished("the executor did not answer the apply"))
    Error(workspace.ApplyRefused(refusal:)) -> Error(classified(refusal))
  }
}

/// A refusal of an apply as final or passing. What the workspace decided about
/// the state (it is shared, the tree has changes, the store lacks the state) is
/// final. The fence and the executor's own condition are not.
fn classified(refusal: protocol.Refusal) -> LandFailure {
  case refusal {
    protocol.ExecutorFault(reason:)
    | protocol.NoStates(reason:)
    | protocol.Invalid(reason:) -> LandRefused(reason)
    protocol.WorkspaceMismatch(..) -> LandRefused(protocol.describe(refusal))
    other -> LandUnfinished(protocol.describe(other))
  }
}
