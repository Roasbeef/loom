//// One original Launch owns a duplex bridge outside finite endpoint credits.
////
//// `start_owner` creates the owner-local host projection and fresh binding.
//// `serve` installs an executor-local host once and returns before Unix accept.
//// `install` confirms the original executor door; a paused local connection
//// produces Ready and exposes the owner projection only after that confirmation. Callbacks and opaque references remain in their own VM.
////
//// `send_chunk` advances transfer; `complete_chunk` finishes admission.
//// `sent_step` retires failed sends; `return_original_credit` preserves consumption.
//// Each actor holds one directional frame and one acknowledged chunk cursor.
//// Chunk receipt never releases a frame; host consumption and original socket
//// WriteConsumed are separate closed observations. Retirement preserves charges.
//// Closing runs independently of data admission and joins the original actor;
//// node and resource observations come only from the actual executor close.
////
//// ## Flow
////
//// `start_owner` and `serve` validate local assembly before `start`.
//// `offer` and `acceptance` expose bounded doors; `install` authenticates its peer.
//// `install_failure` and `start_failure` preserve definite local installation refusal.
//// `step` dispatches local custody and `received` checks closed peer packets.
//// `begin_send` and `advance_send` retain frame/chunk reservations.
//// `receive_header` and `receive_chunk` reserve before assembly; `deliver` projects
//// exact local consumption. `begin_close` and `finish_close` gather actual joins.
//// `collect_closed` retains one original result until its bounded drain collection.

import codemode/enforcement
import codemode/run_channel as channel
import core/command
import executor/remote/distribution
import executor/remote/internal/beam_protocol as protocol
import executor/remote/internal/launch_stream_wire as wire
import executor/remote/launch_service
import executor/remote/service as native
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/result
import weft/actor
import weft/state_machine as sm

/// Closed failure; uncertainty never permits a replacement channel.
pub type Error {
  /// Provisioned binding, original key or peer-owned door differs.
  Invalid

  /// Original transport or local custody is no longer observed.
  Uncertain
}

/// Original owner-local projection and its one asynchronous handoff.
pub opaque type Owner {
  /// Original local control and asynchronous handoff custody.
  Owner(
    /// Dedicated cancellation and close lane.
    commands: process.Subject(Control),
    /// Original unnamed wire receiver.
    door: Door,
    /// Canonical original key, administrative binding and nonce.
    binding: BitArray,
    /// One original paused connection, never a historical replay.
    ready: process.Subject(Result(channel.Connection, Error)),
    /// Provisioned authenticated executor.
    peer: distribution.Peer,
    /// Original local actor observed during close.
    pid: process.Pid,
  )
}

/// Original executor-local installation, bounded by its Launch entry.
pub opaque type Executor {
  /// Original local receiver paired with its closed binding.
  Executor(
    /// Executor-owned unnamed stream receiver.
    door: Door,
    /// Canonical original authority accepted exactly once.
    binding: BitArray,
  )
}

/// Unnamed stream message door; it carries no callback or effect permission.
pub opaque type Door {
  /// Original unnamed subject, whose owner must match the pinned peer.
  Door(
    /// Transient stream receiver without local callback authority.
    subject: process.Subject(Remote),
  )
}

/// Exact bounded offer for the original owner actor.
pub opaque type Offer {
  /// Finite original owner bind proposal.
  Offer(
    /// Canonical original authority and fresh nonce.
    binding: BitArray,
    /// Authenticated owner receiver.
    door: Door,
  )
}

/// Exact bounded acceptance for the original executor actor.
pub opaque type Acceptance {
  /// Finite original executor bind acceptance.
  Acceptance(
    /// Exact canonical bytes from the accepted owner offer.
    binding: BitArray,
    /// Authenticated executor receiver.
    door: Door,
  )
}

type Remote {
  Bytes(sender: process.Pid, bytes: BitArray)
}

type Phase {
  Waiting
  Paused
  Active
  Closing
  Closed
}

type Role {
  OwnerRole(
    host: channel.HostEndpoint,
    ready: process.Subject(Result(channel.Connection, Error)),
  )
  ExecutorRole(service: launch_service.Service)
}

type Control {
  Install(Acceptance, process.Subject(Result(Nil, Error)))
  Incoming(Remote)
  Local(channel.Event)
  Handoff(channel.Connection)
  Activate(process.Subject(Result(Nil, channel.ChannelFailure)))
  OfferWrite(
    channel.Reservation,
    channel.Payload,
    process.Subject(Result(Nil, channel.ChannelFailure)),
  )
  HostConsumed(channel.FrameRef, channel.Consumption)
  LocalOfferAnswered(Result(Nil, channel.ChannelFailure))
  Close(Option(process.Subject(channel.CloseResult)))
  CloseReport(channel.CloseResult)
  ControlDown(process.Down)
  WriterDown(process.Down)
  Lost
  Deadline
  CleanupDeadline
}

type WriterMessage {
  Write(channel.Reservation, channel.Payload)
  Stop
}

type CloseWait {
  Observed(channel.CloseResult)
  Joined(process.Down)
}

type LocalControl {
  Consume(channel.Delivery, channel.Consumption)
  CloseOriginal
}

type LocalControlState {
  LocalControlState(
    connection: channel.Connection,
    events: process.Subject(Control),
  )
}

type WriterState {
  WriterState(connection: channel.Connection, events: process.Subject(Control))
}

type Sending {
  Sending(
    reservation: channel.Reservation,
    payload: channel.Payload,
    remaining: BitArray,
    offset: Int,
    awaiting: Int,
    source: Option(channel.Delivery),
  )
}

type Receiving {
  Receiving(
    reservation: channel.Reservation,
    total: Int,
    offset: Int,
    chunks: List(BitArray),
  )
}

type Owned {
  Owned(
    role: Role,
    peer: distribution.Peer,
    binding: wire.Binding,
    commands: process.Subject(Control),
    door: Door,
    peer_door: Option(Door),
    incarnation: channel.Incarnation,
    inbound: channel.Window,
    outbound: channel.Window,
    sending: Option(Sending),
    receiving: Option(Receiving),
    delivered: Option(channel.Reservation),
    source: Option(channel.Connection),
    grant: Option(channel.WriteGrant),
    writer: Option(process.Subject(WriterMessage)),
    writer_join: Option(Nil),
    close_result: Option(channel.CloseResult),
    close_drained: Option(Nil),
    close_reply: Option(process.Subject(channel.CloseResult)),
    deadline: Int,
    now: fn() -> Int,
    ended: Option(Nil),
    last_inbound: Int,
    last_outbound: Int,
    selector: process.Selector(Control),
    local_control: Option(process.Subject(LocalControl)),
    drain_deadline: Option(Int),
    bound: Option(Nil),
  )
}

/// Starts the original owner projection with an immutable executor deadline.
///
/// ## Examples
/// `start_owner(peer, pin, key, host, deadline, now)` mints one 32-byte nonce.
pub fn start_owner(
  executor: distribution.Peer,
  pin: protocol.Binding,
  key: command.ServiceKey,
  host: channel.HostEndpoint,
  deadline: Int,
  now: fn() -> Int,
) -> Result(Owner, Error) {
  let #(pid, _) = channel.endpoint(host)
  use Nil <- result.try(local_pid(pid))
  use checked <- result.try(
    wire.binding(pin, key, crypto.strong_random_bytes(32)) |> invalid,
  )
  use Nil <- result.try(finite_deadline(deadline, now))
  let ready = process.new_subject()
  use started <- result.try(start(
    OwnerRole(host, ready),
    executor,
    checked,
    None,
    deadline,
    now,
  ))
  use pid <- result.try(
    process.subject_owner(started.0) |> result.replace_error(Uncertain),
  )
  Ok(Owner(started.0, started.1, wire.bytes(checked), ready, executor, pid))
}

/// Returns the original bounded door and bytes for finite bind transport.
///
/// ## Examples
/// `offer(owner)` never reconstructs an owner from historical metadata.
pub fn offer(owner: Owner) -> Offer {
  Offer(owner.binding, owner.door)
}

/// Exposes only closed bytes and the original transient message door.
///
/// ## Examples
/// `offer_fields(original)` serializes neither HostEndpoint nor closures.
pub fn offer_fields(offer: Offer) -> #(BitArray, Door) {
  #(offer.binding, offer.door)
}

/// Checks bounded incoming offer data against one authenticated owner peer.
///
/// ## Examples
/// `offer_from_wire(peer, bytes, door)` refuses foreign unnamed doors.
pub fn offer_from_wire(
  peer: distribution.Peer,
  bytes: BitArray,
  door: Door,
) -> Result(Offer, Error) {
  use Nil <- result.try(peer_door(peer, door))
  use Nil <- result.try(bounded_binding(bytes))
  Ok(Offer(bytes, door))
}

/// Installs one bridge-local host for the exact active Launch entry.
///
/// Acceptance returns before original socket acceptance. A lost installation
/// answer leaves custody uncertain and never permits another installation.
///
/// ## Examples
/// `serve(service, owner_peer, pin, offered)` performs no network enrollment.
pub fn serve(
  service: launch_service.Service,
  owner: distribution.Peer,
  pin: protocol.Binding,
  offered: Offer,
) -> Result(Executor, Error) {
  use Nil <- result.try(peer_door(owner, offered.door))
  use checked <- result.try(
    wire.decode_binding(pin, offered.binding) |> invalid,
  )
  let config = native.configuration(launch_service.native_service(service))
  use Nil <- result.try(
    case
      config.owner == pin.owner
      && config.executor == pin.executor
      && config.scope == pin.scope
      && config.generation == pin.generation
    {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  let now = config.now

  // The live service independently retains its stricter original deadline. This
  // transport ceiling prevents a lost pre-handoff installation from living forever.
  let deadline = now() + 30_000
  use started <- result.try(start(
    ExecutorRole(service),
    owner,
    checked,
    Some(offered.door),
    deadline,
    now,
  ))
  Ok(Executor(started.1, wire.bytes(checked)))
}

/// Returns the exact executor bridge door for a finite control reply.
///
/// ## Examples
/// `acceptance(executor)` contains no paused Connection.
pub fn acceptance(executor: Executor) -> Acceptance {
  Acceptance(executor.binding, executor.door)
}

/// Exposes only bounded acceptance bytes and its transient door.
///
/// ## Examples
/// `acceptance_fields(answer)` has no local native-resource handle.
pub fn acceptance_fields(answer: Acceptance) -> #(BitArray, Door) {
  #(answer.binding, answer.door)
}

/// Checks an acceptance's original authenticated executor door.
///
/// ## Examples
/// `acceptance_from_wire(peer, bytes, door)` refuses oversized metadata.
pub fn acceptance_from_wire(
  peer: distribution.Peer,
  bytes: BitArray,
  door: Door,
) -> Result(Acceptance, Error) {
  use Nil <- result.try(peer_door(peer, door))
  use Nil <- result.try(bounded_binding(bytes))
  Ok(Acceptance(bytes, door))
}

/// Installs the exact original executor acceptance without waiting for Ready.
///
/// ## Examples
/// `install(owner, acceptance)` never spends an endpoint stream credit.
pub fn install(owner: Owner, answer: Acceptance) -> Result(Nil, Error) {
  use Nil <- result.try(peer_door(owner.peer, answer.door))
  use Nil <- result.try(case answer.binding == owner.binding {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  let reply = process.new_subject()
  process.send(owner.commands, Install(answer, reply))
  process.receive(reply, 1000) |> result.unwrap(Error(Uncertain))
}

/// Awaits the original live paused handoff outside the finite bind exchange.
///
/// ## Examples
/// `await_connection(owner, 1000)` cannot reconstruct a historical connection.
pub fn await_connection(
  owner: Owner,
  within_ms: Int,
) -> Result(channel.Connection, Error) {
  case within_ms > 0 && within_ms <= 86_400_000 {
    True ->
      process.receive(owner.ready, within_ms) |> result.unwrap(Error(Uncertain))
    False -> Error(Invalid)
  }
}

/// Cancels original bridge custody directly, without a metadata credit.
///
/// ## Examples
/// `cancel(owner)` retires both directions before independent shutdown.
pub fn cancel(owner: Owner) -> Nil {
  process.send(owner.commands, Close(None))
}

/// Collects original local and remote close witnesses before or after Ready.
/// Missing original remote evidence remains explicitly unresolved.
///
/// ## Examples
/// `close(owner)` never waits for a historical metadata request.
pub fn close(owner: Owner) -> channel.CloseResult {
  close_projection(owner.commands)
}

/// Returns the original local stream actor for trusted supervision.
///
/// ## Examples
/// `pid(owner)` names no remote process or reconstructed continuation.
pub fn pid(owner: Owner) -> process.Pid {
  owner.pid
}

fn start(
  role: Role,
  peer: distribution.Peer,
  binding: wire.Binding,
  remote: Option(Door),
  deadline: Int,
  now: fn() -> Int,
) -> Result(#(process.Subject(Control), Door), Error) {
  sm.new_with_initialiser(1000, fn(commands) {
    let subject = process.new_subject()
    let events = process.new_subject()
    let handoff = process.new_subject()
    let incarnation = channel.new_incarnation()
    let #(in_direction, out_direction) = directions(role)
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(subject, Incoming)
      |> process.select_map(events, Local)
      |> process.select_map(handoff, Handoff)
    let selector = case remote {
      Some(door) -> {
        case process.subject_owner(door.subject) {
          Ok(pid) ->
            process.select_specific_monitor(
              selector,
              process.monitor(pid),
              fn(_) { Lost },
            )
          Error(_) -> selector
        }
      }
      None -> selector
    }
    let owned =
      Owned(
        role: role,
        peer: peer,
        binding: binding,
        commands: commands,
        door: Door(subject),
        peer_door: remote,
        incarnation: incarnation,
        inbound: channel.prepare_direction(incarnation, in_direction),
        outbound: channel.prepare_direction(incarnation, out_direction),
        sending: None,
        receiving: None,
        delivered: None,
        source: None,
        grant: None,
        writer: None,
        writer_join: Some(Nil),
        close_result: None,
        close_drained: None,
        close_reply: None,
        deadline: deadline,
        now: now,
        ended: None,
        last_inbound: 0,
        last_outbound: 0,
        selector: selector,
        local_control: None,
        drain_deadline: None,
        bound: None,
      )
    use owned <- result.try(case role {
      OwnerRole(host, _) -> {
        let #(pid, _) = channel.endpoint(host)
        let monitor = process.monitor(pid)
        Ok(#(
          owned,
          process.select_specific_monitor(selector, monitor, fn(_) { Lost }),
        ))
      }
      ExecutorRole(service) -> {
        let monitor = process.monitor(launch_service.pid(service))
        use launch_service.Installed(original_deadline) <- result.try(
          launch_service.install_host(
            service,
            wire.key(binding),
            channel.host_endpoint(process.self(), events),
            handoff,
          )
          |> result.map_error(install_failure),
        )
        Ok(#(
          Owned(..owned, deadline: original_deadline),
          process.select_specific_monitor(selector, monitor, fn(_) { Lost }),
        ))
      }
    })
    Ok(
      sm.initialised(Waiting, Owned(..owned.0, selector: owned.1))
      |> sm.selecting(owned.1)
      |> sm.returning(#(commands, Door(subject))),
    )
  })
  |> sm.on_enter(enter)
  |> sm.on_event(step)
  |> sm.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(start_failure)
}

// Only the local service's definite refusal names this fixed private marker.
// Timeout, exit and every other diagnostic retain original uncertainty.
fn install_failure(error: launch_service.Error) -> String {
  case error {
    launch_service.Invalid -> "loom.launch.install.definite-refusal/1"
    launch_service.InvalidConfiguration
    | launch_service.Capacity
    | launch_service.Expired
    | launch_service.Closing
    | launch_service.Uncertain
    | launch_service.Preparation(_)
    | launch_service.Custody(_) -> "original host installation unknown"
  }
}

fn start_failure(error: otp_actor.StartError) -> Error {
  case error {
    otp_actor.InitFailed("loom.launch.install.definite-refusal/1") -> Invalid
    otp_actor.InitFailed(_) | otp_actor.InitTimeout | otp_actor.InitExited(_) ->
      Uncertain
  }
}

fn enter(
  _before: Phase,
  phase: Phase,
  owned: Owned,
) -> sm.Enter(Phase, Owned, Control) {
  case phase {
    Waiting | Paused | Active ->
      sm.keep(owned)
      |> sm.with_state_timeout(
        after: int.max(0, owned.deadline - owned.now()),
        sending: Deadline,
      )
    Closing | Closed ->
      sm.keep(owned)
      |> sm.with_state_timeout(
        after: int.max(
          0,
          option.unwrap(owned.drain_deadline, owned.now()) - owned.now(),
        ),
        sending: CleanupDeadline,
      )
  }
}

fn step(
  phase: Phase,
  owned: Owned,
  event: Control,
) -> sm.Next(Phase, Owned, Control) {
  case phase {
    Closed -> collect_closed(owned, event)
    Waiting | Paused | Active | Closing -> live_step(phase, owned, event)
  }
}

fn collect_closed(
  owned: Owned,
  event: Control,
) -> sm.Next(Phase, Owned, Control) {
  case event {
    Close(Some(reply)) -> {
      let report = option.unwrap(owned.close_result, unknown_close())
      process.send(reply, report)
      sm.stop()
    }
    CleanupDeadline -> sm.stop()
    Install(_, reply) -> {
      process.send(reply, Error(Invalid))
      sm.keep(owned)
    }
    Activate(reply) | OfferWrite(_, _, reply) -> {
      process.send(reply, Error(channel.ChannelRetired))
      sm.keep(owned)
    }
    _ -> sm.keep(owned)
  }
}

fn live_step(
  phase: Phase,
  owned: Owned,
  event: Control,
) -> sm.Next(Phase, Owned, Control) {
  case event {
    Install(answer, reply) -> install_peer(phase, owned, answer, reply)
    Incoming(Bytes(sender, bytes)) -> received(phase, owned, sender, bytes)
    Handoff(connection) -> handoff(phase, owned, connection)
    Activate(reply) -> activate(phase, owned, reply)
    OfferWrite(reservation, payload, reply) ->
      offer_write(phase, owned, reservation, payload, reply)
    Local(channel.Frame(delivery)) -> local_frame(phase, owned, delivery)
    Local(channel.WriteConsumed(frame)) -> writer_consumed(phase, owned, frame)
    Local(channel.End(incarnation, reason)) -> {
      case owned.source {
        Some(source) if source.incarnation == incarnation ->
          ordered_end(phase, owned, reason)
        _ -> sm.keep(owned)
      }
    }
    Local(channel.Fault(incarnation, _)) -> {
      case owned.source {
        Some(source) if source.incarnation == incarnation ->
          begin_close(phase, owned, None)
        _ -> sm.keep(owned)
      }
    }
    Lost | Deadline -> begin_close(phase, owned, None)
    HostConsumed(frame, disposition) ->
      host_consumed(phase, owned, frame, disposition)
    LocalOfferAnswered(Ok(Nil)) -> sm.keep(owned)
    LocalOfferAnswered(Error(_)) -> begin_close(phase, owned, None)
    Close(reply) -> begin_close(phase, owned, reply)
    CloseReport(report) -> sm.keep(Owned(..owned, close_result: Some(report)))
    WriterDown(down) -> worker_down(phase, owned, down)
    ControlDown(down) -> control_down(phase, owned, down)
    CleanupDeadline -> publish_close(owned, unknown_close())
  }
}

fn install_peer(
  phase: Phase,
  owned: Owned,
  answer: Acceptance,
  reply: process.Subject(Result(Nil, Error)),
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role, owned.peer_door {
    Waiting, OwnerRole(_, _), None -> {
      let checked = peer_door(owned.peer, answer.door)
      case checked, answer.binding == wire.bytes(owned.binding) {
        Ok(Nil), True -> {
          let monitor =
            process.subject_owner(answer.door.subject)
            |> result.map(process.monitor)
          let selector = case monitor {
            Ok(value) ->
              process.select_specific_monitor(owned.selector, value, fn(_) {
                Lost
              })
            Error(_) -> owned.selector
          }
          let next =
            Owned(..owned, peer_door: Some(answer.door), selector: selector)
          let sent = transmit(next, wire.Bound)
          process.send(reply, sent |> result.replace_error(Uncertain))
          case sent {
            Ok(Nil) -> sm.keep(next) |> sm.with_selector(selector)
            Error(_) ->
              begin_close(phase, next, None) |> sm.with_selector(selector)
          }
        }
        _, _ -> {
          process.send(reply, Error(Invalid))
          sm.keep(owned)
        }
      }
    }
    _, _, _ -> {
      process.send(reply, Error(Invalid))
      sm.keep(owned)
    }
  }
}

fn handoff(
  phase: Phase,
  owned: Owned,
  connection: channel.Connection,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role, owned.source {
    Waiting, ExecutorRole(_), None -> {
      let events = owned.commands
      let workers = {
        use writer <- result.try(
          actor.new(WriterState(connection, events))
          |> actor.on_message(write_step)
          |> actor.start,
        )
        use control <- result.try(
          actor.new(LocalControlState(connection, events))
          |> actor.on_message(local_control_step)
          |> actor.start,
        )
        Ok(#(writer, control))
      }
      case workers {
        Error(_) ->
          begin_close(phase, Owned(..owned, source: Some(connection)), None)
        Ok(#(writer, control)) -> {
          let writer_monitor = process.monitor(writer.pid)
          let control_monitor = process.monitor(control.pid)
          let selector =
            owned.selector
            |> process.select_specific_monitor(writer_monitor, WriterDown)
            |> process.select_specific_monitor(control_monitor, ControlDown)
          let next =
            Owned(
              ..owned,
              source: Some(connection),
              grant: Some(connection.initial_write_grant),
              writer: Some(writer.data),
              local_control: Some(control.data),
              writer_join: None,
              selector: selector,
            )
          announce_ready(next) |> sm.with_selector(selector)
        }
      }
    }
    _, _, _ -> begin_close(phase, owned, None)
  }
}

fn announce_ready(owned: Owned) -> sm.Next(Phase, Owned, Control) {
  case owned.bound, owned.source {
    Some(Nil), Some(_) -> {
      case transmit(owned, wire.Ready) {
        Ok(Nil) -> sm.transition(Paused, owned)
        Error(_) -> begin_close(Waiting, owned, None)
      }
    }
    _, _ -> sm.keep(owned)
  }
}

fn received(
  phase: Phase,
  owned: Owned,
  sender: process.Pid,
  bytes: BitArray,
) -> sm.Next(Phase, Owned, Control) {
  let checked = {
    use door <- result.try(option.to_result(owned.peer_door, Nil))
    use actual <- result.try(process.subject_owner(door.subject))
    use Nil <- result.try(
      case actual == sender && distribution.owns(owned.peer, sender) {
        True -> Ok(Nil)
        False -> Error(Nil)
      },
    )
    wire.decode(owned.binding, bytes)
  }
  case checked {
    Error(_) -> sm.keep(owned)
    Ok(wire.Bound) -> {
      case phase, owned.role, owned.bound {
        Waiting, ExecutorRole(_), None ->
          announce_ready(Owned(..owned, bound: Some(Nil)))
        _, _, _ -> sm.keep(owned)
      }
    }
    Ok(wire.Ready) -> owner_ready(phase, owned)
    Ok(wire.Activate) -> remote_activate(phase, owned)
    Ok(wire.Header(direction, sequence, size)) ->
      receive_header(phase, owned, direction, sequence, size)
    Ok(wire.Chunk(direction, sequence, offset, bytes)) ->
      receive_chunk(phase, owned, direction, sequence, offset, bytes)
    Ok(wire.ChunkAck(direction, sequence, offset)) ->
      advance_send(phase, owned, direction, sequence, offset)
    Ok(wire.Consumed(direction, sequence, disposition)) ->
      consumed(phase, owned, direction, sequence, disposition)
    Ok(wire.End(sequence, reason)) ->
      receive_end(phase, owned, sequence, reason)
    Ok(wire.Close) -> begin_close(phase, owned, None)

    // The original executor can finish independently before a local close ask.
    // Its authenticated result must survive that ordering for the collector.
    Ok(wire.Closed(report)) -> {
      case phase, owned.role {
        _, OwnerRole(_, _) -> publish_close(owned, report)
        _, _ -> sm.keep(owned)
      }
    }
  }
}

fn owner_ready(phase: Phase, owned: Owned) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role {
    Waiting, OwnerRole(_, ready) -> {
      let prepared = {
        use inbound <- result.try(channel.activate_direction(owned.inbound))
        use outbound <- result.try(channel.activate_direction(owned.outbound))
        use grant <- result.try(channel.write_grant(outbound))
        Ok(#(inbound, outbound, grant))
      }
      case prepared {
        Ok(#(inbound, outbound, grant)) -> {
          process.send(ready, Ok(project(owned, grant)))
          sm.transition(Paused, Owned(..owned, inbound:, outbound:))
        }
        Error(_) -> begin_close(phase, owned, None)
      }
    }
    _, _ -> sm.keep(owned)
  }
}

fn project(owned: Owned, grant: channel.WriteGrant) -> channel.Connection {
  let commands = owned.commands
  channel.Connection(
    owned.incarnation,
    grant,
    fn(reservation, payload) {
      let reply = process.new_subject()
      process.send(commands, OfferWrite(reservation, payload, reply))
      process.receive(reply, 1000)
      |> result.unwrap(Error(channel.ChannelRetired))
    },
    fn() {
      let reply = process.new_subject()
      process.send(commands, Activate(reply))
      process.receive(reply, 1000)
      |> result.unwrap(Error(channel.ChannelRetired))
    },
    fn() { close_projection(commands) },
  )
}

fn close_projection(commands: process.Subject(Control)) -> channel.CloseResult {
  let reply = process.new_subject()
  let owner = process.subject_owner(commands)
  case owner {
    Error(_) -> unknown_close()
    Ok(pid) -> {
      // The monitor precedes shutdown, so the local bridge's exit is witnessed.
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_map(reply, Observed)
        |> process.select_specific_monitor(monitor, Joined)
      process.send(commands, Close(Some(reply)))
      case process.selector_receive(selector, 8000) {
        Ok(Observed(report)) -> {
          case process.selector_receive(selector, 1000) {
            Ok(Joined(process.ProcessDown(_, _, process.Normal))) -> report
            _ ->
              channel.CloseResult(
                ..report,
                transport: channel.TransportUnresolved(
                  "Original bridge join absent",
                ),
              )
          }
        }
        _ -> unknown_close()
      }
    }
  }
}

fn activate(
  phase: Phase,
  owned: Owned,
  reply: process.Subject(Result(Nil, channel.ChannelFailure)),
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role {
    Paused, OwnerRole(_, _) -> {
      let sent = transmit(owned, wire.Activate)
      process.send(reply, sent |> result.replace_error(channel.ChannelRetired))
      case sent {
        Ok(Nil) -> sm.transition(Active, owned)
        Error(_) -> begin_close(phase, owned, None)
      }
    }
    _, _ -> {
      process.send(reply, Error(channel.ChannelRetired))
      sm.keep(owned)
    }
  }
}

fn remote_activate(
  phase: Phase,
  owned: Owned,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role, owned.source {
    Paused, ExecutorRole(_), Some(connection) -> {
      let activated = {
        use Nil <- result.try(connection.activate())
        use inbound <- result.try(channel.activate_direction(owned.inbound))
        use outbound <- result.try(channel.activate_direction(owned.outbound))
        Ok(#(inbound, outbound))
      }
      case activated {
        Ok(#(inbound, outbound)) ->
          sm.transition(Active, Owned(..owned, inbound:, outbound:))
        Error(_) -> begin_close(phase, owned, None)
      }
    }
    _, _, _ -> sm.keep(owned)
  }
}

fn offer_write(
  phase: Phase,
  owned: Owned,
  reservation: channel.Reservation,
  payload: channel.Payload,
  reply: process.Subject(Result(Nil, channel.ChannelFailure)),
) -> sm.Next(Phase, Owned, Control) {
  let admitted = {
    use Nil <- result.try(case phase, owned.role, owned.sending {
      Active, OwnerRole(_, _), None -> Ok(Nil)
      Active, OwnerRole(_, _), Some(_) -> Error(channel.WindowUnavailable)
      _, _, _ -> Error(channel.ChannelRetired)
    })
    let #(_, length) = channel.reservation(reservation)
    use #(window, exact) <- result.try(channel.reserve_frame(
      owned.outbound,
      length,
    ))
    use Nil <- result.try(case exact == reservation {
      True -> Ok(Nil)
      False -> Error(channel.StaleReservation)
    })
    use _ <- result.try(channel.delivery(reservation, payload, fn(_) { Nil }))
    use window <- result.try(channel.publish_frame(window, exact))
    Ok(#(window, exact))
  }
  case admitted {
    Ok(#(window, exact)) -> {
      let next = Owned(..owned, outbound: window)
      process.send(reply, Ok(Nil))
      begin_send(phase, next, exact, payload, None)
    }
    Error(channel.AllowanceExhausted) -> {
      process.send(reply, Error(channel.AllowanceExhausted))
      begin_close(phase, owned, None)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      sm.keep(owned)
    }
  }
}

fn local_frame(
  phase: Phase,
  owned: Owned,
  delivery: channel.Delivery,
) -> sm.Next(Phase, Owned, Control) {
  let admitted = {
    use Nil <- result.try(case phase, owned.role, owned.sending, owned.source {
      Active, ExecutorRole(_), None, Some(_) -> Ok(Nil)
      _, _, _, _ -> Error(channel.ChannelRetired)
    })
    let #(source, payload) = channel.delivered(delivery)
    let #(incarnation, direction, sequence) = channel.coordinates(source)
    use connection <- result.try(option.to_result(
      owned.source,
      channel.ChannelRetired,
    ))
    use Nil <- result.try(
      case
        incarnation == connection.incarnation && direction == channel.ToHost
      {
        True -> Ok(Nil)
        False -> Error(channel.StaleReservation)
      },
    )
    use length <- result.try(
      channel.payload_length(bit_array.byte_size(channel.payload(payload))),
    )
    use #(window, reservation) <- result.try(channel.reserve_frame(
      owned.outbound,
      length,
    ))
    let #(frame, _) = channel.reservation(reservation)
    use Nil <- result.try(case channel.coordinates(frame).2 == sequence {
      True -> Ok(Nil)
      False -> Error(channel.StaleReservation)
    })
    use window <- result.try(channel.publish_frame(window, reservation))
    Ok(#(window, reservation, payload))
  }
  case admitted {
    Ok(#(window, reservation, payload)) ->
      begin_send(
        phase,
        Owned(..owned, outbound: window),
        reservation,
        payload,
        Some(delivery),
      )
    Error(channel.StaleReservation)
    | Error(channel.WindowUnavailable)
    | Error(channel.ChannelRetired) -> sm.keep(owned)
    Error(_) -> begin_close(phase, owned, None)
  }
}

fn begin_send(
  phase: Phase,
  owned: Owned,
  reservation: channel.Reservation,
  payload: channel.Payload,
  source: Option(channel.Delivery),
) -> sm.Next(Phase, Owned, Control) {
  let #(frame, length) = channel.reservation(reservation)
  let #(_, direction, sequence) = channel.coordinates(frame)
  let sending =
    Sending(reservation, payload, channel.wire_bytes(payload), 0, 0, source)
  let next = Owned(..owned, sending: Some(sending))
  case
    transmit(
      next,
      wire.Header(direction, sequence, channel.wire_length(length)),
    )
  {
    Ok(Nil) -> sm.keep(next)
    Error(_) -> begin_close(phase, next, None)
  }
}

fn advance_send(
  phase: Phase,
  owned: Owned,
  direction: channel.Direction,
  sequence: Int,
  offset: Int,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.sending {
    Active, Some(sending) -> {
      let #(frame, _) = channel.reservation(sending.reservation)
      let #(_, expected, original) = channel.coordinates(frame)
      case
        expected == direction
        && sequence == original
        && offset == sending.awaiting
      {
        False -> sm.keep(owned)
        True -> send_chunk(phase, owned, sending, direction, sequence, offset)
      }
    }
    _, _ -> sm.keep(owned)
  }
}

// Each admitted ACK advances one bounded cursor without returning frame credit.
fn send_chunk(
  phase: Phase,
  owned: Owned,
  sending: Sending,
  direction: channel.Direction,
  sequence: Int,
  offset: Int,
) -> sm.Next(Phase, Owned, Control) {
  case sending.remaining {
    <<>> -> sm.keep(owned)
    bytes -> {
      let count = int.min(channel.max_chunk_bytes, bit_array.byte_size(bytes))
      case bytes {
        <<chunk:bytes-size(count), rest:bytes>> -> {
          let next =
            Owned(
              ..owned,
              sending: Some(
                Sending(
                  ..sending,
                  remaining: rest,
                  offset: offset + count,
                  awaiting: offset + count,
                ),
              ),
            )
          sent_step(phase, next, wire.Chunk(direction, sequence, offset, chunk))
        }
        _ -> begin_close(phase, owned, None)
      }
    }
  }
}

fn sent_step(
  phase: Phase,
  owned: Owned,
  packet: wire.Packet,
) -> sm.Next(Phase, Owned, Control) {
  case transmit(owned, packet) {
    Ok(Nil) -> sm.keep(owned)
    Error(_) -> begin_close(phase, owned, None)
  }
}

fn receive_header(
  phase: Phase,
  owned: Owned,
  direction: channel.Direction,
  sequence: Int,
  total: Int,
) -> sm.Next(Phase, Owned, Control) {
  let admitted = {
    use Nil <- result.try(case phase, owned.receiving, owned.delivered {
      Active, None, None -> Ok(Nil)
      _, _, _ -> Error(channel.WindowUnavailable)
    })
    use Nil <- result.try(case direction == directions(owned.role).0 {
      True -> Ok(Nil)
      False -> Error(channel.StaleReservation)
    })
    use length <- result.try(channel.payload_length(total - 4))
    use #(window, reservation) <- result.try(channel.reserve_frame(
      owned.inbound,
      length,
    ))
    let #(frame, _) = channel.reservation(reservation)
    use Nil <- result.try(case channel.coordinates(frame).2 == sequence {
      True -> Ok(Nil)
      False -> Error(channel.StaleReservation)
    })
    Ok(#(window, reservation))
  }
  case admitted {
    Ok(#(window, reservation)) -> {
      let next =
        Owned(
          ..owned,
          inbound: window,
          receiving: Some(Receiving(reservation, total, 0, [])),
        )
      case transmit(next, wire.ChunkAck(direction, sequence, 0)) {
        Ok(Nil) -> sm.keep(next)
        Error(_) -> begin_close(phase, next, None)
      }
    }
    Error(channel.AllowanceExhausted) -> begin_close(phase, owned, None)
    Error(_) -> sm.keep(owned)
  }
}

fn receive_chunk(
  phase: Phase,
  owned: Owned,
  direction: channel.Direction,
  sequence: Int,
  offset: Int,
  bytes: BitArray,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.receiving {
    Active, Some(receiving) -> {
      let #(frame, _) = channel.reservation(receiving.reservation)
      let #(_, expected, original) = channel.coordinates(frame)
      let count = bit_array.byte_size(bytes)
      case
        direction == expected
        && sequence == original
        && offset == receiving.offset
        && count == int.min(channel.max_chunk_bytes, receiving.total - offset)
      {
        False -> sm.keep(owned)
        True -> {
          let held =
            Receiving(..receiving, offset: offset + count, chunks: [
              bytes,
              ..receiving.chunks
            ])
          let next = Owned(..owned, receiving: Some(held))
          complete_chunk(phase, next, held, direction, sequence)
        }
      }
    }
    _, _ -> sm.keep(owned)
  }
}

fn complete_chunk(
  phase: Phase,
  owned: Owned,
  held: Receiving,
  direction: channel.Direction,
  sequence: Int,
) -> sm.Next(Phase, Owned, Control) {
  case transmit(owned, wire.ChunkAck(direction, sequence, held.offset)) {
    Error(_) -> begin_close(phase, owned, None)
    Ok(Nil) -> {
      case held.offset == held.total {
        False -> sm.keep(owned)
        True -> deliver(phase, owned, held)
      }
    }
  }
}

fn deliver(
  phase: Phase,
  owned: Owned,
  receiving: Receiving,
) -> sm.Next(Phase, Owned, Control) {
  let checked = {
    use payload <- result.try(channel.from_wire(
      receiving.chunks |> list.reverse |> bit_array.concat,
    ))
    use inbound <- result.try(channel.publish_frame(
      owned.inbound,
      receiving.reservation,
    ))
    let #(frame, _) = channel.reservation(receiving.reservation)
    let commands = owned.commands
    use delivery <- result.try(
      channel.delivery(receiving.reservation, payload, fn(disposition) {
        process.send(commands, HostConsumed(frame, disposition))
      }),
    )
    Ok(#(payload, inbound, delivery))
  }
  case checked {
    Error(_) -> begin_close(phase, owned, None)
    Ok(#(payload, inbound, delivery)) -> {
      let next =
        Owned(
          ..owned,
          inbound:,
          receiving: None,
          delivered: Some(receiving.reservation),
        )
      case owned.role {
        OwnerRole(host, _) -> {
          let #(_, events) = channel.endpoint(host)
          process.send(events, channel.Frame(delivery))
          sm.keep(next)
        }
        ExecutorRole(_) -> write_local(phase, next, payload)
      }
    }
  }
}

fn write_local(
  phase: Phase,
  owned: Owned,
  payload: channel.Payload,
) -> sm.Next(Phase, Owned, Control) {
  let checked = {
    use grant <- result.try(option.to_result(
      owned.grant,
      channel.ChannelRetired,
    ))
    use #(grant, reservation) <- result.try(channel.reserve_write(
      grant,
      payload,
    ))
    use writer <- result.try(option.to_result(
      owned.writer,
      channel.ChannelRetired,
    ))
    process.send(writer, Write(reservation, payload))
    Ok(grant)
  }
  case checked {
    Ok(grant) -> sm.keep(Owned(..owned, grant: Some(grant)))
    Error(_) -> begin_close(phase, owned, None)
  }
}

fn writer_consumed(
  phase: Phase,
  owned: Owned,
  frame: channel.FrameRef,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role, owned.grant, owned.delivered {
    Active, ExecutorRole(_), Some(grant), Some(reservation) -> {
      let #(grant, accepted) = channel.consume_write(grant, frame)
      let #(original, _) = channel.reservation(reservation)
      case
        accepted,
        channel.coordinates(frame).2 == channel.coordinates(original).2
      {
        channel.Consumed, True ->
          host_consumed(
            phase,
            Owned(..owned, grant: Some(grant)),
            original,
            channel.Continue,
          )
        _, _ -> sm.keep(owned)
      }
    }
    _, _, _, _ -> sm.keep(owned)
  }
}

fn host_consumed(
  phase: Phase,
  owned: Owned,
  frame: channel.FrameRef,
  disposition: channel.Consumption,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.delivered {
    Active, Some(reservation) -> {
      let #(original, _) = channel.reservation(reservation)
      case original == frame {
        False -> sm.keep(owned)
        True -> {
          let #(inbound, accepted) =
            channel.consume_frame(owned.inbound, frame, disposition)
          let #(_, direction, sequence) = channel.coordinates(frame)
          case accepted {
            channel.Ignored -> sm.keep(owned)
            channel.Consumed -> {
              let next =
                Owned(
                  ..owned,
                  inbound:,
                  delivered: None,
                  last_inbound: sequence,
                )
              sent_step(
                phase,
                next,
                wire.Consumed(direction, sequence, disposition),
              )
            }
          }
        }
      }
    }
    _, _ -> sm.keep(owned)
  }
}

fn consumed(
  phase: Phase,
  owned: Owned,
  direction: channel.Direction,
  sequence: Int,
  disposition: channel.Consumption,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.sending {
    Active, Some(sending) -> {
      let #(frame, _) = channel.reservation(sending.reservation)
      let #(_, expected, original) = channel.coordinates(frame)
      case
        direction == expected
        && sequence == original
        && sending.remaining == <<>>
        && sending.awaiting
        == channel.wire_length(channel.reservation(sending.reservation).1)
        && { direction == channel.ToHost || disposition == channel.Continue }
      {
        False -> sm.keep(owned)
        True -> {
          let #(outbound, accepted) =
            channel.consume_frame(owned.outbound, frame, disposition)
          case accepted {
            channel.Ignored -> sm.keep(owned)
            channel.Consumed -> {
              return_original_credit(owned, sending, frame, disposition)
              sm.keep(
                Owned(
                  ..owned,
                  outbound:,
                  sending: None,
                  last_outbound: sequence,
                ),
              )
            }
          }
        }
      }
    }
    _, _ -> sm.keep(owned)
  }
}

// Only the original recipient's consumption returns its local projection credit.
fn return_original_credit(
  owned: Owned,
  sending: Sending,
  frame: channel.FrameRef,
  disposition: channel.Consumption,
) -> Nil {
  case owned.role, sending.source {
    ExecutorRole(_), Some(delivery) -> {
      let _sent =
        option.map(owned.local_control, fn(control) {
          process.send(control, Consume(delivery, disposition))
        })
      Nil
    }
    OwnerRole(host, _), None -> {
      let #(_, events) = channel.endpoint(host)
      process.send(events, channel.WriteConsumed(frame))
    }
    _, _ -> Nil
  }
}

fn ordered_end(
  phase: Phase,
  owned: Owned,
  reason: String,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role, owned.sending {
    Active, ExecutorRole(_), None -> {
      let sequence = owned.last_outbound
      case transmit(owned, wire.End(sequence, reason)) {
        Ok(Nil) -> sm.keep(Owned(..owned, ended: Some(Nil)))
        Error(_) -> begin_close(phase, owned, None)
      }
    }
    _, _, _ -> begin_close(phase, owned, None)
  }
}

fn receive_end(
  phase: Phase,
  owned: Owned,
  sequence: Int,
  reason: String,
) -> sm.Next(Phase, Owned, Control) {
  case phase, owned.role, owned.receiving, owned.delivered {
    Active, OwnerRole(host, _), None, None -> {
      case sequence == owned.last_inbound && owned.ended == None {
        True -> {
          let #(_, events) = channel.endpoint(host)
          process.send(events, channel.End(owned.incarnation, reason))
          sm.keep(Owned(..owned, ended: Some(Nil)))
        }
        False -> sm.keep(owned)
      }
    }
    _, _, _, _ -> sm.keep(owned)
  }
}

fn begin_close(
  phase: Phase,
  owned: Owned,
  reply: Option(process.Subject(channel.CloseResult)),
) -> sm.Next(Phase, Owned, Control) {
  case phase {
    Closed -> collect_closed(owned, Close(reply))
    Closing -> {
      case owned.close_reply, reply {
        None, Some(subject) ->
          sm.keep(Owned(..owned, close_reply: Some(subject)))
        _, _ -> sm.keep(owned)
      }
    }
    Waiting | Paused | Active -> {
      let next =
        Owned(
          ..owned,
          inbound: channel.retire_direction(owned.inbound),
          outbound: channel.retire_direction(owned.outbound),
          close_reply: reply,
          drain_deadline: Some(owned.now() + 7000),
        )
      case owned.role, owned.source {
        OwnerRole(_, ready), _ -> {
          process.send(ready, Error(Uncertain))
          case transmit(next, wire.Close) {
            Ok(Nil) -> sm.transition(Closing, next)
            Error(_) -> publish_close(next, unknown_close())
          }
        }
        ExecutorRole(_), Some(_) -> {
          option.map(owned.local_control, fn(control) {
            process.send(control, CloseOriginal)
          })
          sm.transition(Closing, next)
        }
        ExecutorRole(_), None -> {
          // Stopping the installed host retires this original entry's channel.
          // Its watchdog retains resource custody; no service-wide close applies.
          publish_close(next, unknown_close())
        }
      }
    }
  }
}

fn local_control_step(
  state: LocalControlState,
  message: LocalControl,
) -> actor.Next(LocalControlState, LocalControl) {
  case message {
    Consume(delivery, disposition) -> {
      channel.consume(delivery, disposition)
      actor.continue(state)
    }
    CloseOriginal -> {
      let report = state.connection.close()
      process.send(state.events, CloseReport(report))
      actor.stop()
    }
  }
}

fn worker_down(
  phase: Phase,
  owned: Owned,
  down: process.Down,
) -> sm.Next(Phase, Owned, Control) {
  case phase, down {
    Closing, process.ProcessDown(_, _, process.Normal) ->
      finish_close(Owned(..owned, writer_join: Some(Nil)))
    _, _ -> begin_close(phase, owned, None)
  }
}

fn control_down(
  phase: Phase,
  owned: Owned,
  down: process.Down,
) -> sm.Next(Phase, Owned, Control) {
  case phase, down, owned.close_result {
    Closing, process.ProcessDown(_, _, process.Normal), Some(_) -> {
      option.map(owned.writer, fn(writer) { process.send(writer, Stop) })
      finish_close(Owned(..owned, close_drained: Some(Nil)))
    }
    _, _, _ -> publish_close(owned, unknown_close())
  }
}

fn finish_close(owned: Owned) -> sm.Next(Phase, Owned, Control) {
  case owned.close_result, owned.close_drained, owned.writer_join {
    Some(closed), Some(Nil), Some(Nil) -> {
      let _sent = transmit(owned, wire.Closed(closed))
      publish_close(owned, closed)
    }
    _, _, _ -> sm.keep(owned)
  }
}

fn publish_close(
  owned: Owned,
  report: channel.CloseResult,
) -> sm.Next(Phase, Owned, Control) {
  // An independently observed remote close retires capacity immediately. The
  // first close grace bounds retained evidence without renewing on later asks.
  let owned =
    Owned(
      ..owned,
      inbound: channel.retire_direction(owned.inbound),
      outbound: channel.retire_direction(owned.outbound),
      drain_deadline: Some(
        option.lazy_unwrap(owned.drain_deadline, fn() { owned.now() + 7000 }),
      ),
    )
  case owned.role, owned.close_reply {
    OwnerRole(_, _), None ->
      sm.transition(Closed, Owned(..owned, close_result: Some(report)))
    _, Some(reply) -> {
      process.send(reply, report)
      sm.stop()
    }
    ExecutorRole(_), None -> sm.stop()
  }
}

fn transmit(owned: Owned, packet: wire.Packet) -> Result(Nil, Nil) {
  use door <- result.try(option.to_result(owned.peer_door, Nil))
  use bytes <- result.try(wire.encode(owned.binding, packet))
  case distribution.send(door.subject, Bytes(process.self(), bytes)) {
    distribution.Sent -> Ok(Nil)
    distribution.WouldBlock
    | distribution.Disconnected
    | distribution.InvalidSubject -> Error(Nil)
  }
}

fn write_step(
  state: WriterState,
  message: WriterMessage,
) -> actor.Next(WriterState, WriterMessage) {
  case message {
    Stop -> actor.stop()
    Write(reservation, payload) -> {
      let answer = state.connection.offer(reservation, payload)
      process.send(state.events, LocalOfferAnswered(answer))
      actor.continue(state)
    }
  }
}

fn directions(role: Role) -> #(channel.Direction, channel.Direction) {
  case role {
    OwnerRole(_, _) -> #(channel.ToHost, channel.ToNode)
    ExecutorRole(_) -> #(channel.ToNode, channel.ToHost)
  }
}

fn finite_deadline(deadline: Int, now: fn() -> Int) -> Result(Nil, Error) {
  case deadline > now() && deadline - now() <= 86_400_000 {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn bounded_binding(bytes: BitArray) -> Result(Nil, Error) {
  case bit_array.byte_size(bytes) > 0 && bit_array.byte_size(bytes) <= 9260 {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn local_pid(pid: process.Pid) -> Result(Nil, Error) {
  case process.is_alive(pid) {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn peer_door(peer: distribution.Peer, door: Door) -> Result(Nil, Error) {
  use pid <- result.try(process.subject_owner(door.subject) |> invalid)
  case distribution.owns(peer, pid) {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn unknown_close() -> channel.CloseResult {
  channel.CloseResult(
    enforcement.Unreported("original remote close not observed"),
    channel.TransportUnresolved("original bridge drain not observed"),
    channel.ResourcesUnresolved("original resources not observed"),
  )
}

fn invalid(value: Result(a, b)) -> Result(a, Error) {
  result.replace_error(value, Invalid)
}
