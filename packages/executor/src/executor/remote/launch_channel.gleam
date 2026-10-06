//// Original executor socket custody is independent of native observation.
////
//// `start` retains canonical paths before `prepare` performs exclusive effects.
//// `install` accepts the original host once, then hands off exactly one paused
//// connection after acceptance. One reader orders every frame and End; Final
//// consumption terminates that reader before teardown joins it. `stop` closes
//// the socket and listener independently before asking blocked children to stop.
//// Native settlement and transport joins remain separate historical witnesses.
//// Missing cleanup evidence leaves the original paths and active capacity held.
////
//// ## Flow
////
//// `start` initializes original custody; `prepare` creates its private listener.
//// `step` dispatches installation, activation and independent closure.
//// `start_children` starts paused reader/writer leaves in a weft scope.
//// `connection` exposes exact original callbacks; `offer` checks its own window.
//// `begin_close` closes I/O before `finish_close` joins; `record_children` retains loss.
//// `start_channel_reader` and `channel_read_step` own the inbound producer.
//// `read_reserved_frame` charges before reading; `read_exact_body` folds bounded chunks.
//// `start_channel_writer` and `channel_write_step` own writes; `write_exact_chunks` folds chunks.

import codemode/enforcement
import codemode/internal/ffi_unix.{type Listener, type Socket}
import codemode/run_channel
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import weft
import weft/state_machine as sm

/// Original private endpoint; copying it cannot recreate paths or activation.
/// Physical preparation distinguishes concrete refusal from lost observation.
pub type PreparationError {
  /// The original owner observed the failed effect before Ready.
  Definite(reason: String)

  /// The original owner may still be performing effects.
  Uncertain
}

pub opaque type Owner {
  Owner(commands: Subject(ChannelEvent))
}

type Phase {
  Unprepared
  Prepared
  Refused
  Installed
  Closing
  Closed(run_channel.CloseResult)
}

type NativeCustody {
  Unresolved
  AwaitingOriginalRetirement
  ExcludedBeforeDispatch
  NativeRetired
}

type PreparationCustody {
  AwaitingPreparation
  PreparationJoined
}

type CleanupAttempt {
  NotAttempted
  Attempted
}

type WriterCustody {
  AwaitingWriter
  WriterAdopted
}

type Directory {
  NoDirectory
  OriginalDirectory
}

type ChannelEvent {
  Prepare(BitArray, Subject(Result(Nil, String)))
  Install(run_channel.HostEndpoint, Subject(run_channel.Connection))
  Activate(Subject(Result(Nil, run_channel.ChannelFailure)))
  Offer(
    run_channel.Reservation,
    run_channel.Payload,
    Subject(Result(Nil, run_channel.ChannelFailure)),
  )
  SocketAccepted(Socket)
  WriterReady
  WriterConsumed(run_channel.FrameRef)
  NativeObserved(enforcement.Report)
  OriginalRetirementExpected
  OriginalNativeRetired
  Excluded(enforcement.Report)
  FencedBeforeNative
  PreparerJoined
  Consumed(run_channel.FrameRef, run_channel.Consumption)
  Stop(Option(Subject(run_channel.CloseResult)))
  OwnerDied
  Deadline
  CleanupDeadline
  ReleaseClosed
  Children(weft.Pulled(Nil, Nil))
}

type Owned {
  Owned(
    paths: #(String, String, String),
    directory: Directory,
    listener: Option(Listener),
    socket: Option(Socket),
    deadline: Int,
    now: fn() -> Int,
    cancel: fn() -> Nil,
    release: fn() -> Result(Nil, String),
    on_closed: fn(run_channel.CloseResult) -> Nil,
    commands: Subject(ChannelEvent),
    parent_monitor: process.Monitor,
    host: Option(run_channel.HostEndpoint),
    handoff: Option(Subject(run_channel.Connection)),
    incarnation: run_channel.Incarnation,
    outbound: run_channel.Window,
    reader: Option(Subject(ChannelRead)),
    writer: Option(Subject(ChannelWrite)),
    writer_custody: WriterCustody,
    joined: Option(run_channel.TransportDrain),
    native_custody: NativeCustody,
    preparation: PreparationCustody,
    cleanup: CleanupAttempt,
    node: enforcement.Report,
    close_reply: Option(Subject(run_channel.CloseResult)),
  )
}

type ChannelReadPhase {
  ReadAccepting
  ReadPrepared
  ReadHeader
  ReadHeld
}

type ChannelRead {
  ReadAccept
  ReadActivate
  ReadNext
  ReadConsumed(
    frame: run_channel.FrameRef,
    disposition: run_channel.Consumption,
  )
  ReadStop
}

type ChannelReader {
  ChannelReader(
    listener: Listener,
    socket: Option(Socket),
    accept_ms: Int,
    authority_ms: Int,
    events: Subject(run_channel.Event),
    owner: Subject(ChannelEvent),
    commands: Subject(ChannelRead),
    window: run_channel.Window,
    incarnation: run_channel.Incarnation,
  )
}

type ChannelWrite {
  WriteAttach(socket: Socket)
  WriteFrame(reservation: run_channel.Reservation, payload: run_channel.Payload)
  WriteStop
}

type ChannelWriter {
  ChannelWriter(
    socket: Option(Socket),
    events: Subject(run_channel.Event),
    owner: Subject(ChannelEvent),
    incarnation: run_channel.Incarnation,
  )
}

/// Retains original paths before any filesystem effect.
///
/// ## Examples
///
/// `start(paths, deadline, now, owner, cancel)` does not create a listener.
pub fn start(
  paths: #(String, String, String),
  deadline: Int,
  now: fn() -> Int,
  parent: Subject(message),
  cancel: fn() -> Nil,
  release: fn() -> Result(Nil, String),
  on_closed: fn(run_channel.CloseResult) -> Nil,
) -> Result(Owner, String) {
  use parent <- result.try(
    process.subject_owner(parent)
    |> result.replace_error("original owner is unavailable"),
  )
  let incarnation = run_channel.new_incarnation()
  sm.new_with_initialiser(1000, fn(commands) {
    let monitor = process.monitor(parent)
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_specific_monitor(monitor, fn(_) { OwnerDied })
    sm.initialised(
      Unprepared,
      Owned(
        paths:,
        directory: NoDirectory,
        listener: None,
        socket: None,
        deadline:,
        now:,
        cancel:,
        release:,
        on_closed:,
        commands:,
        parent_monitor: monitor,
        host: None,
        handoff: None,
        incarnation:,
        outbound: run_channel.prepare_direction(incarnation, run_channel.ToNode),
        reader: None,
        writer: None,
        writer_custody: AwaitingWriter,
        joined: Some(run_channel.TransportJoined),
        native_custody: Unresolved,
        preparation: AwaitingPreparation,
        cleanup: NotAttempted,
        node: enforcement.Unreported("original native settlement not observed"),
        close_reply: None,
      ),
    )
    |> sm.selecting(selector)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(step)
  |> sm.on_enter(enter)
  |> sm.unlinked
  |> sm.start
  |> result.map(fn(started) { Owner(started.data) })
  |> result.replace_error("original socket owner did not initialize")
}

/// Places bytes only through this closed effect operation after Claim handoff.
///
/// ## Examples
///
/// `prepare(owner, token)` refuses an existing canonical directory.
pub fn prepare(owner: Owner, token: BitArray) -> Result(Nil, PreparationError) {
  let reply = process.new_subject()
  process.send(owner.commands, Prepare(token, reply))
  case process.receive(reply, 1000) {
    Ok(value) -> result.map_error(value, Definite)
    Error(Nil) -> Error(Uncertain)
  }
}

/// Installs one trusted host; handoff is asynchronous and never renewed.
///
/// ## Examples
///
/// `install(owner, host, handoff)` starts acceptance without reading a body.
pub fn install(
  owner: Owner,
  host: run_channel.HostEndpoint,
  handoff: Subject(run_channel.Connection),
) -> Nil {
  process.send(owner.commands, Install(host, handoff))
}

/// Retains actual node observation without creating cap End or cleanup proof.
///
/// ## Examples
///
/// `settled(owner, report)` leaves resource retirement independent.
pub fn settled(owner: Owner, report: enforcement.Report) -> Nil {
  process.send(owner.commands, NativeObserved(report))
}

/// Retains close custody after actual original native association COMMIT.
/// This expectation is not retirement proof and expires with existing cleanup.
///
/// ## Examples
///
/// `retirement_expected(original)` never authorizes directory removal.
@internal
pub fn retirement_expected(original: Owner) -> Nil {
  process.send(original.commands, OriginalRetirementExpected)
}

/// Accepts the original validated association's durable exact-helper witness.
/// Terminal and ordinary Query never construct this local custody event.
///
/// ## Examples
///
/// `native_retired(original)` can complete cleanup after the original I/O joins.
@internal
pub fn native_retired(original: Owner) -> Nil {
  process.send(original.commands, OriginalNativeRetired)
}

/// Independently closes original I/O without consuming a metadata credit.
///
/// ## Examples
///
/// `stop(owner)` wakes a blocked socket reader before child joins.
pub fn stop(owner: Owner) -> Nil {
  process.send(owner.commands, Stop(None))
}

fn enter(
  _previous: Phase,
  phase: Phase,
  owned: Owned,
) -> sm.Enter(Phase, Owned, ChannelEvent) {
  case phase {
    Unprepared | Prepared | Refused | Installed ->
      sm.keep(owned)
      |> sm.with_state_timeout(
        after: int.max(owned.deadline - owned.now(), 0),
        sending: Deadline,
      )
    Closing ->
      sm.keep(owned)
      |> sm.with_state_timeout(after: 2000, sending: CleanupDeadline)
    Closed(_) ->
      sm.keep(owned)
      |> sm.with_state_timeout(after: 6000, sending: ReleaseClosed)
  }
}

fn step(
  phase: Phase,
  owned: Owned,
  event: ChannelEvent,
) -> sm.Next(Phase, Owned, ChannelEvent) {
  case phase, event {
    Unprepared, Prepare(token, reply) -> prepare_paths(owned, token, reply)
    Prepared, Install(host, handoff) -> start_children(owned, host, handoff)
    Installed, SocketAccepted(socket) -> {
      option.map(owned.writer, fn(writer) {
        process.send(writer, WriteAttach(socket))
      })
      handoff_connection(Owned(..owned, socket: Some(socket)))
    }
    Installed, WriterReady ->
      handoff_connection(Owned(..owned, writer_custody: WriterAdopted))
    Unprepared, WriterReady
    | Prepared, WriterReady
    | Refused, WriterReady
    | Closing, WriterReady
    | Closed(_), WriterReady
    -> sm.keep(owned)
    Unprepared, SocketAccepted(socket)
    | Refused, SocketAccepted(socket)
    | Prepared, SocketAccepted(socket)
    | Closing, SocketAccepted(socket)
    | Closed(_), SocketAccepted(socket)
    -> {
      ffi_unix.close_now(socket)
      sm.keep(owned)
    }
    Installed, Activate(reply) -> {
      let activated = run_channel.activate_direction(owned.outbound)
      case activated, owned.socket {
        Ok(outbound), Some(_) -> {
          option.map(owned.reader, fn(reader) {
            process.send(reader, ReadActivate)
          })
          process.send(reply, Ok(Nil))
          sm.keep(Owned(..owned, outbound:))
        }
        _, _ -> {
          process.send(reply, Error(run_channel.ChannelRetired))
          sm.keep(owned)
        }
      }
    }
    Installed, Offer(reservation, payload, reply) ->
      offer(owned, reservation, payload, reply)
    Installed, WriterConsumed(frame) -> {
      let #(outbound, consumed) =
        run_channel.consume_frame(owned.outbound, frame, run_channel.Continue)
      case consumed, owned.host {
        run_channel.Consumed, Some(host) -> {
          let #(_, events) = run_channel.endpoint(host)
          process.send(events, run_channel.WriteConsumed(frame))
        }
        _, _ -> Nil
      }
      sm.keep(Owned(..owned, outbound:))
    }
    Closed(closed), Stop(Some(reply)) -> {
      process.send(reply, closed)
      sm.keep(owned)
    }

    // Service cancellation carries no waiter and cannot erase the original close.
    Closing, Stop(None) -> sm.keep(owned)
    Closing, Stop(Some(reply)) ->
      sm.keep(Owned(..owned, close_reply: Some(reply)))
    Closed(_), Stop(None) -> sm.keep(owned)
    Unprepared, Stop(reply)
    | Prepared, Stop(reply)
    | Refused, Stop(reply)
    | Installed, Stop(reply)
    -> begin_close(owned, reply)

    // Refused may retain directory and token custody without a listener.
    // The original parent and deadline still bound that partial allocation.
    Unprepared, OwnerDied
    | Prepared, OwnerDied
    | Refused, OwnerDied
    | Installed, OwnerDied
    | Unprepared, Deadline
    | Prepared, Deadline
    | Refused, Deadline
    | Installed, Deadline
    -> begin_close(owned, None)
    Closing, Children(event) -> finish_close(record_children(owned, event))
    Unprepared, Children(event)
    | Refused, Children(event)
    | Prepared, Children(event)
    | Installed, Children(event)
    -> sm.keep(record_children(owned, event))
    Closing, CleanupDeadline -> publish_close(owned)
    Installed, Consumed(frame, disposition)
    | Closing, Consumed(frame, disposition)
    -> {
      option.map(owned.reader, fn(reader) {
        process.send(reader, ReadConsumed(frame, disposition))
      })
      sm.keep(owned)
    }
    Unprepared, Consumed(..)
    | Prepared, Consumed(..)
    | Refused, Consumed(..)
    | Closed(_), Consumed(..)
    -> sm.keep(owned)
    Closed(_), Excluded(node) ->
      finish_close(
        Owned(..owned, node:, native_custody: ExcludedBeforeDispatch),
      )
    Closing, Excluded(node) ->
      finish_close(
        Owned(..owned, node:, native_custody: ExcludedBeforeDispatch),
      )
    Unprepared, Excluded(node)
    | Prepared, Excluded(node)
    | Refused, Excluded(node)
    | Installed, Excluded(node)
    ->
      begin_close(
        Owned(..owned, node:, native_custody: ExcludedBeforeDispatch),
        None,
      )
    Closing, FencedBeforeNative | Closed(_), FencedBeforeNative ->
      finish_close(Owned(..owned, native_custody: ExcludedBeforeDispatch))
    Unprepared, FencedBeforeNative
    | Prepared, FencedBeforeNative
    | Refused, FencedBeforeNative
    | Installed, FencedBeforeNative
    -> begin_close(Owned(..owned, native_custody: ExcludedBeforeDispatch), None)
    Closing, PreparerJoined | Closed(_), PreparerJoined ->
      finish_close(Owned(..owned, preparation: PreparationJoined))
    Unprepared, PreparerJoined
    | Prepared, PreparerJoined
    | Refused, PreparerJoined
    | Installed, PreparerJoined
    -> sm.keep(Owned(..owned, preparation: PreparationJoined))
    Closed(_), ReleaseClosed -> sm.stop()
    Unprepared, ReleaseClosed
    | Prepared, ReleaseClosed
    | Refused, ReleaseClosed
    | Installed, ReleaseClosed
    | Closing, ReleaseClosed
    -> sm.keep(owned)
    _, OriginalRetirementExpected -> {
      case owned.native_custody {
        Unresolved ->
          sm.keep(Owned(..owned, native_custody: AwaitingOriginalRetirement))
        AwaitingOriginalRetirement | ExcludedBeforeDispatch | NativeRetired ->
          sm.keep(owned)
      }
    }
    Closing, OriginalNativeRetired | Closed(_), OriginalNativeRetired ->
      finish_close(Owned(..owned, native_custody: NativeRetired))
    Unprepared, OriginalNativeRetired
    | Prepared, OriginalNativeRetired
    | Refused, OriginalNativeRetired
    | Installed, OriginalNativeRetired
    -> sm.keep(Owned(..owned, native_custody: NativeRetired))
    _, NativeObserved(node) -> sm.keep(Owned(..owned, node:))
    _, Prepare(_, reply) -> {
      process.send(reply, Error("original preparation was already consumed"))
      sm.keep(owned)
    }
    _, Activate(reply) -> {
      process.send(reply, Error(run_channel.ChannelRetired))
      sm.keep(owned)
    }
    _, Offer(_, _, reply) -> {
      process.send(reply, Error(run_channel.ChannelRetired))
      sm.keep(owned)
    }
    _, Install(..)
    | _, WriterConsumed(_)
    | _, OwnerDied
    | _, Deadline
    | _, CleanupDeadline
    | Closed(_), Children(_)
    -> sm.keep(owned)
  }
}

// Exclusive creation is the allocation witness. Once it succeeds, later refusal
// retains directory custody rather than deleting or selecting another identity.
fn prepare_paths(
  owned: Owned,
  token: BitArray,
  reply: Subject(Result(Nil, String)),
) -> sm.Next(Phase, Owned, ChannelEvent) {
  case simplifile.create_directory(owned.paths.0) {
    Error(_) -> {
      process.send(
        reply,
        Error("canonical launch allocation exists or cannot be created"),
      )
      sm.keep(owned)
    }
    Ok(Nil) ->
      place_token(Owned(..owned, directory: OriginalDirectory), token, reply)
  }
}

fn place_token(
  owned: Owned,
  token: BitArray,
  reply: Subject(Result(Nil, String)),
) -> sm.Next(Phase, Owned, ChannelEvent) {
  let prepared = {
    use Nil <- result.try(
      simplifile.set_permissions_octal(owned.paths.0, 0o700)
      |> result.replace_error("private directory permissions failed"),
    )
    use Nil <- result.try(
      simplifile.write_bits(owned.paths.2, token)
      |> result.replace_error("original token placement failed"),
    )
    use Nil <- result.try(
      simplifile.set_permissions_octal(owned.paths.2, 0o600)
      |> result.replace_error("private token permissions failed"),
    )
    ffi_unix.listen(owned.paths.1)
  }
  case prepared {
    Error(reason) -> {
      process.send(reply, Error(reason))
      sm.transition(to: Refused, data: owned)
    }
    Ok(listener) -> {
      process.send(reply, Ok(Nil))
      sm.transition(
        to: Prepared,
        data: Owned(..owned, listener: Some(listener)),
      )
    }
  }
}

fn start_children(
  owned: Owned,
  host: run_channel.HostEndpoint,
  handoff: Subject(run_channel.Connection),
) -> sm.Next(Phase, Owned, ChannelEvent) {
  let started = {
    use listener <- result.try(option.to_result(
      owned.listener,
      "original listener absent",
    ))
    use reader <- result.try(start_channel_reader(
      listener,
      int.max(owned.deadline - owned.now(), 0),
      int.max(owned.deadline - owned.now(), 0),
      host,
      owned.incarnation,
      owned.commands,
    ))
    use writer <- result.try(
      start_channel_writer(host, owned.incarnation, owned.commands)
      |> result.map_error(fn(reason) {
        process.send(reader.data, ReadStop)
        reason
      }),
    )
    Ok(#(reader, writer, listener))
  }
  case started {
    Error(_) -> begin_close(owned, None)
    Ok(#(reader, writer, listener)) -> {
      let reports = process.new_subject()
      let #(pid, _) = run_channel.endpoint(host)
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select(owned.commands)
        |> process.select_specific_monitor(owned.parent_monitor, fn(_) {
          OwnerDied
        })
        |> process.select_map(reports, Children)
        |> process.select_specific_monitor(monitor, fn(_) { OwnerDied })
      let tasks = [
        weft.prepared_leaf(
          owner: reader.pid,
          cancel: fn() {
            ffi_unix.close_listener(listener)
            process.send(reader.data, ReadStop)
          },
          begin: fn() {
            process.send(reader.data, ReadAccept)
            Ok(Nil)
          },
        ),
        weft.prepared_leaf(
          owner: writer.pid,
          cancel: fn() { process.send(writer.data, WriteStop) },
          begin: fn() {
            process.send(owned.commands, WriterReady)
            Ok(Nil)
          },
        ),
      ]
      let _ =
        weft.new_prepared(tasks)
        |> weft.deadline(int.max(owned.deadline - owned.now(), 0))
        |> weft.cancel_grace(1000)
        |> weft.start_relayed(to: reports)
      sm.transition(
        to: Installed,
        data: Owned(
          ..owned,
          reader: Some(reader.data),
          writer: Some(writer.data),
          host: Some(host),
          handoff: Some(handoff),
          joined: None,
        ),
      )
      |> sm.with_selector(selector)
    }
  }
}

// Handoff waits for both weft monitors to dominate activation. A child that
// exits before its adoption cannot retroactively establish a drain witness.
fn handoff_connection(owned: Owned) -> sm.Next(Phase, Owned, ChannelEvent) {
  case owned.socket, owned.writer_custody, owned.handoff {
    Some(_), WriterAdopted, Some(reply) -> {
      case connection(owned) {
        Ok(connection) -> {
          process.send(reply, connection)
          sm.keep(Owned(..owned, handoff: None))
        }
        Error(_) -> begin_close(owned, None)
      }
    }
    _, _, _ -> sm.keep(owned)
  }
}

fn connection(
  owned: Owned,
) -> Result(run_channel.Connection, run_channel.ChannelFailure) {
  let commands = owned.commands
  let grant =
    run_channel.activate_direction(owned.outbound)
    |> result.try(run_channel.write_grant)

  // Socket acceptance occurs only once in Prepared, where this grant is checked
  // by construction. A failed reducer is retained as a refused handoff upstream.
  use grant <- result.try(grant)
  Ok(
    run_channel.Connection(
      incarnation: owned.incarnation,
      initial_write_grant: grant,
      offer: fn(reservation, payload) {
        let reply = process.new_subject()
        process.send(commands, Offer(reservation, payload, reply))
        process.receive(reply, 1000)
        |> result.unwrap(
          Error(run_channel.TransportFailed("write admission answer lost")),
        )
      },
      activate: fn() {
        let reply = process.new_subject()
        process.send(commands, Activate(reply))
        process.receive(reply, 1000)
        |> result.unwrap(
          Error(run_channel.TransportFailed("activation answer lost")),
        )
      },
      close: fn() {
        let reply = process.new_subject()
        process.send(commands, Stop(Some(reply)))
        process.receive(reply, 3000)
        |> result.lazy_unwrap(fn() {
          unknown_close(
            enforcement.Unreported("original close answer lost"),
            run_channel.TransportUnresolved("original joins not observed"),
          )
        })
      },
    ),
  )
}

fn offer(
  owned: Owned,
  reservation: run_channel.Reservation,
  payload: run_channel.Payload,
  reply: Subject(Result(Nil, run_channel.ChannelFailure)),
) -> sm.Next(Phase, Owned, ChannelEvent) {
  let #(_, length) = run_channel.reservation(reservation)
  let checked = {
    use #(window, exact) <- result.try(run_channel.reserve_frame(
      owned.outbound,
      length,
    ))
    use Nil <- result.try(case exact == reservation {
      True -> Ok(Nil)
      False -> Error(run_channel.StaleReservation)
    })
    use _ <- result.try(run_channel.finish_payload(
      reservation,
      run_channel.payload(payload),
    ))
    run_channel.publish_frame(window, reservation)
  }
  case checked {
    Error(error) -> {
      process.send(reply, Error(error))
      sm.keep(owned)
    }
    Ok(outbound) -> {
      option.map(owned.writer, fn(writer) {
        process.send(writer, WriteFrame(reservation, payload))
      })
      process.send(reply, Ok(Nil))
      sm.keep(Owned(..owned, outbound:))
    }
  }
}

fn begin_close(
  owned: Owned,
  reply: Option(Subject(run_channel.CloseResult)),
) -> sm.Next(Phase, Owned, ChannelEvent) {
  option.map(owned.socket, ffi_unix.close_now)
  option.map(owned.listener, ffi_unix.close_listener)
  option.map(owned.reader, fn(reader) { process.send(reader, ReadStop) })
  option.map(owned.writer, fn(writer) { process.send(writer, WriteStop) })
  case owned.native_custody {
    Unresolved | AwaitingOriginalRetirement -> owned.cancel()
    ExcludedBeforeDispatch | NativeRetired -> Nil
  }
  finish_close(
    Owned(
      ..owned,
      outbound: run_channel.retire_direction(owned.outbound),
      close_reply: reply,
    ),
  )
}

fn record_children(owned: Owned, event: weft.Pulled(Nil, Nil)) -> Owned {
  case event {
    weft.AllDelivered ->
      case owned.joined {
        Some(run_channel.TransportUnresolved(_)) -> owned
        None | Some(run_channel.TransportJoined) ->
          Owned(..owned, joined: Some(run_channel.TransportJoined))
      }
    weft.PulledOutcome(weft.Completed(..)) | weft.NotYet -> owned
    weft.RunLost(_) | weft.PulledOutcome(_) ->
      Owned(
        ..owned,
        joined: Some(run_channel.TransportUnresolved(
          "original child drain unresolved",
        )),
      )
  }
}

fn finish_close(owned: Owned) -> sm.Next(Phase, Owned, ChannelEvent) {
  case owned.cleanup, owned.joined, owned.native_custody, owned.preparation {
    Attempted, _, _, _ -> sm.keep(owned)
    NotAttempted,
      Some(run_channel.TransportJoined),
      custody,
      AwaitingPreparation
      if custody == ExcludedBeforeDispatch || custody == NativeRetired
    -> sm.transition(to: Closing, data: owned)

    // Actual transport join cannot outrun the original retirement observer.
    NotAttempted,
      Some(run_channel.TransportJoined),
      AwaitingOriginalRetirement,
      _
    -> sm.transition(to: Closing, data: owned)
    NotAttempted, Some(_), _, _ -> publish_close(owned)
    NotAttempted, None, _, _ -> sm.transition(to: Closing, data: owned)
  }
}

fn unknown_close(
  node: enforcement.Report,
  transport: run_channel.TransportDrain,
) -> run_channel.CloseResult {
  run_channel.CloseResult(
    node:,
    transport:,
    resources: run_channel.ResourcesUnresolved(
      "original native resource retirement not observed",
    ),
  )
}

fn publish_close(owned: Owned) -> sm.Next(Phase, Owned, ChannelEvent) {
  let closed =
    unknown_close(
      owned.node,
      option.unwrap(
        owned.joined,
        run_channel.TransportUnresolved("original children not joined"),
      ),
    )
  let resources = case
    owned.native_custody,
    owned.joined,
    owned.preparation,
    owned.directory
  {
    custody,
      Some(run_channel.TransportJoined),
      PreparationJoined,
      OriginalDirectory
      if custody == ExcludedBeforeDispatch || custody == NativeRetired
    ->
      case simplifile.delete(owned.paths.0) {
        Ok(Nil) -> run_channel.ResourcesReleased
        Error(_) ->
          run_channel.ResourcesUnresolved("original directory removal failed")
      }
    custody, Some(run_channel.TransportJoined), PreparationJoined, NoDirectory
      if custody == ExcludedBeforeDispatch || custody == NativeRetired
    -> run_channel.ResourcesReleased
    _, _, _, _ -> closed.resources
  }
  let resources = case resources {
    run_channel.ResourcesReleased ->
      case owned.release() {
        Ok(Nil) -> run_channel.ResourcesReleased
        Error(reason) -> run_channel.ResourcesUnresolved(reason)
      }
    run_channel.ResourcesUnresolved(_) -> resources
  }
  let closed = run_channel.CloseResult(..closed, resources:)
  owned.on_closed(closed)
  option.map(owned.close_reply, fn(reply) { process.send(reply, closed) })
  let cleanup = case owned.native_custody, owned.joined, owned.preparation {
    custody, Some(run_channel.TransportJoined), PreparationJoined
      if custody == ExcludedBeforeDispatch || custody == NativeRetired
    -> Attempted
    _, _, _ -> NotAttempted
  }
  sm.transition(
    to: Closed(closed),
    data: Owned(..owned, close_reply: None, cleanup:),
  )
}

fn start_channel_reader(
  listener: Listener,
  accept_ms: Int,
  authority_ms: Int,
  host: run_channel.HostEndpoint,
  incarnation: run_channel.Incarnation,
  owner: Subject(ChannelEvent),
) -> Result(sm.Started(Subject(ChannelRead)), String) {
  let #(_host, events) = run_channel.endpoint(host)
  sm.new_with_initialiser(1000, fn(commands) {
    sm.initialised(
      ReadAccepting,
      ChannelReader(
        listener:,
        socket: None,
        accept_ms:,
        authority_ms:,
        events:,
        owner:,
        commands:,
        window: run_channel.prepare_direction(incarnation, run_channel.ToHost),
        incarnation:,
      ),
    )
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(channel_read_step)
  // Passive OTP recv waits for the original socket's EXIT on independent
  // close. Trapping that port signal wakes the blocked read instead of
  // silently ignoring a normal port exit until its authority timeout.
  |> sm.trapping_exits(True)
  |> sm.unlinked
  |> sm.start
  |> result.map_error(fn(_) { "original reader did not initialise" })
}

fn channel_read_step(
  phase: ChannelReadPhase,
  reader: ChannelReader,
  event: ChannelRead,
) -> sm.Next(ChannelReadPhase, ChannelReader, ChannelRead) {
  case phase, event {
    ReadAccepting, ReadAccept -> {
      let accepted =
        ffi_unix.accept(
          reader.listener,
          int.min(reader.accept_ms, reader.authority_ms),
        )
      case accepted {
        Ok(socket) -> {
          process.send(reader.owner, SocketAccepted(socket))
          sm.transition(
            to: ReadPrepared,
            data: ChannelReader(..reader, socket: Some(socket)),
          )
        }
        Error(error) ->
          reader_fault(reader, case error {
            ffi_unix.AcceptTimeout -> "the original satellite did not connect"
            ffi_unix.AcceptFailed(reason) -> reason
          })
      }
    }
    ReadPrepared, ReadActivate -> {
      case run_channel.activate_direction(reader.window) {
        Ok(window) ->
          sm.transition(to: ReadHeader, data: ChannelReader(..reader, window:))
          |> sm.then_handle(ReadNext)
        Error(_) -> reader_fault(reader, "original reader activation failed")
      }
    }
    ReadHeader, ReadNext -> read_reserved_frame(reader)
    ReadHeld, ReadConsumed(frame, disposition) -> {
      let #(window, consumed) =
        run_channel.consume_frame(reader.window, frame, disposition)
      case consumed, disposition {
        run_channel.Ignored, _ -> sm.keep(reader)
        run_channel.Consumed, run_channel.Final -> sm.stop()
        run_channel.Consumed, run_channel.Continue ->
          sm.transition(to: ReadHeader, data: ChannelReader(..reader, window:))
          |> sm.then_handle(ReadNext)
      }
    }
    _, ReadStop -> sm.stop()
    ReadAccepting, ReadActivate
    | ReadAccepting, ReadNext
    | ReadAccepting, ReadConsumed(..)
    | ReadPrepared, ReadAccept
    | ReadHeader, ReadAccept
    | ReadHeld, ReadAccept
    | ReadPrepared, ReadNext
    | ReadHeld, ReadNext
    | ReadHeader, ReadActivate
    | ReadHeld, ReadActivate
    | ReadPrepared, ReadConsumed(..)
    | ReadHeader, ReadConsumed(..)
    -> sm.keep(reader)
  }
}

// The fixed four-byte declaration charges the lifetime before any body read.
fn read_reserved_frame(
  reader: ChannelReader,
) -> sm.Next(ChannelReadPhase, ChannelReader, ChannelRead) {
  case reader.socket {
    None -> reader_fault(reader, "original reader has no accepted socket")
    Some(socket) -> {
      let read = {
        use prefix <- result.try(ffi_unix.recv_exact(
          socket,
          4,
          reader.authority_ms,
        ))
        use length <- result.try(case prefix {
          <<size:32>> ->
            run_channel.payload_length(size)
            |> result.map_error(fn(_) {
              "frame declaration exceeds original bound"
            })
          _ -> Error("invalid exact frame prefix")
        })
        use #(window, reservation) <- result.try(
          run_channel.reserve_frame(reader.window, length)
          |> result.map_error(fn(_) { "inbound lifetime allowance exhausted" }),
        )
        use bytes <- result.try(
          read_exact_body(
            socket,
            run_channel.length_bytes(length),
            reader.authority_ms,
            [],
          ),
        )
        use payload <- result.try(
          run_channel.finish_payload(reservation, bytes)
          |> result.map_error(fn(_) { "frame body length changed" }),
        )
        use window <- result.try(
          run_channel.publish_frame(window, reservation)
          |> result.map_error(fn(_) { "original frame reservation was lost" }),
        )
        Ok(#(window, reservation, payload))
      }
      case read {
        Error(reason) -> reader_fault(reader, reason)
        Ok(#(window, reservation, payload)) -> {
          let #(frame, _) = run_channel.reservation(reservation)
          let commands = reader.owner
          let delivery =
            run_channel.delivery(reservation, payload, fn(disposition) {
              process.send(commands, Consumed(frame, disposition))
            })
          case delivery {
            Error(_) -> reader_fault(reader, "original delivery failed")
            Ok(delivery) -> {
              process.send(reader.events, run_channel.Frame(delivery))
              sm.transition(
                to: ReadHeld,
                data: ChannelReader(..reader, window:),
              )
            }
          }
        }
      }
    }
  }
}

// This is a bounded data fold, at most 257 exact chunks, not a phase loop.
fn read_exact_body(
  socket: Socket,
  remaining: Int,
  timeout_ms: Int,
  chunks: List(BitArray),
) -> Result(BitArray, String) {
  case remaining {
    0 -> Ok(bit_array.concat(list.reverse(chunks)))
    _ -> {
      let count = int.min(remaining, run_channel.max_chunk_bytes)
      use bytes <- result.try(ffi_unix.recv_exact(socket, count, timeout_ms))
      read_exact_body(socket, remaining - count, timeout_ms, [bytes, ..chunks])
    }
  }
}

fn reader_fault(
  reader: ChannelReader,
  reason: String,
) -> sm.Next(ChannelReadPhase, ChannelReader, ChannelRead) {
  let incarnation = reader.incarnation
  process.send(reader.events, run_channel.End(incarnation, reason))
  option.map(reader.socket, ffi_unix.close_now)
  sm.stop()
}

// One writer process; the owner admits exact reservations before its mailbox.

fn start_channel_writer(
  host: run_channel.HostEndpoint,
  incarnation: run_channel.Incarnation,
  owner: Subject(ChannelEvent),
) -> Result(sm.Started(Subject(ChannelWrite)), String) {
  let #(_host, events) = run_channel.endpoint(host)
  sm.new_with_initialiser(1000, fn(commands) {
    sm.initialised(
      Nil,
      ChannelWriter(socket: None, events:, owner:, incarnation:),
    )
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(channel_write_step)
  |> sm.unlinked
  |> sm.start
  |> result.map_error(fn(_) { "original writer did not initialise" })
}

fn channel_write_step(
  _phase: Nil,
  writer: ChannelWriter,
  event: ChannelWrite,
) -> sm.Next(Nil, ChannelWriter, ChannelWrite) {
  case event {
    WriteAttach(socket) ->
      sm.keep(ChannelWriter(..writer, socket: Some(socket)))
    WriteStop -> sm.stop()
    WriteFrame(reservation, payload) -> {
      let wrote = case writer.socket {
        None -> Error("the original writer has no socket")
        Some(socket) ->
          write_exact_chunks(socket, run_channel.wire_bytes(payload))
      }
      case wrote {
        Error(reason) -> {
          process.send(
            writer.events,
            run_channel.Fault(writer.incarnation, reason),
          )
          sm.stop()
        }
        Ok(Nil) -> {
          let #(frame, _length) = run_channel.reservation(reservation)
          process.send(writer.owner, WriterConsumed(frame))
          sm.keep(writer)
        }
      }
    }
  }
}

fn write_exact_chunks(socket: Socket, bytes: BitArray) -> Result(Nil, String) {
  let chunk_bytes = run_channel.max_chunk_bytes
  case bytes {
    <<>> -> Ok(Nil)
    <<chunk:bytes-size(chunk_bytes), rest:bits>> -> {
      use Nil <- result.try(ffi_unix.send(socket, chunk))
      write_exact_chunks(socket, rest)
    }
    _ -> ffi_unix.send(socket, bytes)
  }
}

/// Retains a committed original refusal fence independently from node reporting.
/// Only the live journal refusal caller may use this trusted local witness.
///
/// ## Examples
///
/// `excluded(owner, report)` permits cleanup after actual transport joins.
pub fn excluded(owner: Owner, report: enforcement.Report) -> Nil {
  process.send(owner.commands, Excluded(report))
}

/// Supplies the original successful fence and subsequent exact Unassociated proof.
/// It permits cleanup only after original preparer and socket joins, and never
/// serializes a definite historical Launch refusal.
///
/// ## Examples
///
/// `fenced_before_native(owner)` preserves an unresolved cap/native outcome.
pub fn fenced_before_native(owner: Owner) -> Nil {
  process.send(owner.commands, FencedBeforeNative)
}

/// Retains actual original managed preparation drain before directory removal.
///
/// ## Examples
///
/// `preparation_joined(owner)` follows weft AllDelivered for the original task.
pub fn preparation_joined(owner: Owner) -> Nil {
  process.send(owner.commands, PreparerJoined)
}
