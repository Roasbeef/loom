//// Terminal-owned progress for one credited conversation connection.
////
//// There is no additional process: the terminal drains its own inbox and
//// applies this state. A single request owns the wire at a time. One local
//// command may wait behind reconciliation; timeouts close the socket and
//// preserve uncertainty instead of resending a mutation on another connection.

import core/json
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import tui/approval
import tui/attempt
import tui/connection
import tui/protocol
import tui/session_wire
import tui/snapshot
import tui/snapshot_view

/// A completed cut or bounded command result for atomic model application.
pub type Update {
  /// A previously unsent local intent was sent or definitively cancelled.
  Submission(disposition: Disposition)

  /// Only this event may replace visible metadata and the durable projection.
  Captured(cut: snapshot.Captured, view: snapshot_view.View)

  /// Exact decisions only; never a replacement conversation cut.
  LookedUp(records: List(approval.Review), missing: List(String))

  /// Models/schedules or a typed server refusal.
  Auxiliary(event: protocol.Event)

  /// The server acknowledged one mutation without implying a later snapshot.
  Acknowledged(command: String, status: String)

  /// A sent mutation lost its reply; the client must not retry automatically.
  UnknownOutcome(command: String, request_id: Int)

  /// The socket cannot continue, while the last completed projection survives.
  Failed(reason: String)
}

/// Local admission is distinct from a wire write and its uncertain outcome.
pub type Disposition {
  /// One immutable intent waits behind an already synchronized capture.
  Waiting(command: String)

  /// The wire ID was allocated and the request was issued exactly once.
  Sent(command: String, request_id: Int)

  /// No mutation was issued; the original composer remains editable.
  DefinitelyNotSent(reason: String)
}

type Intent {
  Read
  Mutation
  Lookup(ids: List(String))
}

type Outbound {
  Outbound(name: String, suffix: String, intent: Intent)
}

type Phase {
  AwaitingBegin
  Receiving(snapshot.Transfer, Option(List(String)))
  AwaitingReply(name: String, intent: Intent)
  Ready
  Closed
}

/// One bounded protocol lane, held by the terminal which owns its inbox.
pub opaque type Channel {
  Channel(
    socket: Option(connection.Connection),
    trace: Option(attempt.Trace),
    timestamp: fn() -> Int,
    issued: attempt.Request,
    expected: snapshot.Expected,
    phase: Phase,
    request_id: Int,
    next_id: Int,
    deadline: Int,
    attachment: Option(snapshot.Attachment),
    cut: Option(snapshot.Captured),
    queued: Option(Outbound),
    refresh_at: Int,
  )
}

/// Starts initial capture; adoption waits for a Captured update, not this call.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.start(socket, selected)
/// ```
pub fn start(
  socket: connection.Connection,
  expected: snapshot.Expected,
) -> Channel {
  start_recorded(socket, expected, None)
}

/// Starts a live channel with optional attempt-scoped recording.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.start_recorded(socket, selected, trace)
/// ```
pub fn start_recorded(
  socket,
  expected,
  trace: Option(attempt.Trace),
) -> Channel {
  let channel = initial(Some(socket), expected, trace, now)
  case trace {
    Some(trace) -> trace.note(attempt.Started(trace.id, expected))
    None -> Nil
  }
  emit(channel, protocol.subscribe(1, expected.session))
  channel
}

/// Creates effect-free replay state without a socket, process or wall clock.
///
/// ## Examples
///
/// ```gleam
/// let lane = session_channel.replay(snapshot.Expected("s", "e", "i"))
/// ```
pub fn replay(expected: snapshot.Expected) -> Channel {
  replay_with_clock(expected, fn() { 0 })
}

/// Supplies a pure replay clock for deterministic capture-deadline checks.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_with_clock(expected, clock)
/// ```
@internal
pub fn replay_with_clock(
  expected: snapshot.Expected,
  timestamp: fn() -> Int,
) -> Channel {
  initial(None, expected, None, timestamp)
}

fn initial(socket, expected, trace, timestamp) {
  Channel(
    socket: socket,
    trace: trace,
    timestamp: timestamp,
    issued: attempt.Request(1, "subscribe", attempt.NoSelection),
    expected: expected,
    phase: AwaitingBegin,
    request_id: 1,
    next_id: 2,
    deadline: timestamp() + 30_000,
    attachment: None,
    cut: None,
    queued: None,
    refresh_at: timestamp(),
  )
}

fn emit(channel: Channel, frame) {
  case channel.trace {
    Some(trace) -> trace.note(attempt.Issued(trace.id, channel.issued))
    None -> Nil
  }
  case channel.socket {
    Some(socket) -> connection.send(socket, frame)
    None -> Nil
  }
}

/// Returns the selected raw socket for liveness/adoption and shutdown only.
///
/// ## Examples
///
/// ```gleam
/// // connection.adopt(session_channel.socket(channel))
/// ```
pub fn socket(channel: Channel) -> Option(connection.Connection) {
  channel.socket
}

/// Returns whether a first completed, validated cut has been obtained.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.synchronized(channel)
/// ```
pub fn synchronized(channel: Channel) -> Bool {
  channel.cut != None
}

/// Tests whether replay may adopt a completed, nonfailed initial cut.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_adoptable(lane)
/// ```
pub fn replay_adoptable(channel: Channel) -> Bool {
  channel.socket == None && channel.phase == Ready && channel.cut != None
}

/// Admits one local command, or one waiting command behind an active capture.
///
/// The generated command's prefix is replaced without reparsing its potentially
/// large image body. Only the canonical encoder prefix is accepted here.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.submit(channel, protocol.prompt(1, "main", "hello"))
/// ```
pub fn submit(channel: Channel, frame: String) -> #(Channel, Disposition) {
  case admit(channel, frame) {
    Ok(#(channel, disposition)) -> #(channel, disposition)
    Error(reason) -> #(channel, DefinitelyNotSent(reason))
  }
}

fn admit(channel: Channel, frame: String) {
  use outbound <- result.try(outbound(frame))
  use <- bool.guard(
    channel.phase == Closed,
    Error("conversation is disconnected"),
  )
  use <- bool.guard(
    outbound.intent == Mutation && !can_mutate(channel),
    Error("this attachment is read-only or not yet authenticated"),
  )
  use <- bool.guard(
    outbound.intent == Mutation && !mutation_available(channel),
    Error("another command or initial synchronization prevents submission"),
  )
  case channel.phase, channel.queued {
    Ready, None -> {
      let next = send(channel, outbound)
      Ok(#(next, Sent(outbound.name, next.request_id)))
    }
    _, None ->
      Ok(#(Channel(..channel, queued: Some(outbound)), Waiting(outbound.name)))
    _, Some(_) -> Error("one command is already waiting for the current reply")
  }
}

/// Checks the authenticated local role, never another peer's displayed role.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.can_mutate(channel)
/// ```
pub fn can_mutate(channel: Channel) -> Bool {
  case channel.phase, channel.attachment {
    Closed, _ -> False
    _, Some(snapshot.Attachment(role: snapshot.Operator, ..)) -> True
    _, Some(snapshot.Attachment(role: snapshot.Owner, ..)) -> True
    _, Some(snapshot.Attachment(role: snapshot.Observer, ..)) | _, None -> False
  }
}

/// Reports whether transport progress needs the short terminal polling cadence.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.in_flight(channel)
/// ```
pub fn in_flight(channel: Channel) -> Bool {
  case channel.phase {
    AwaitingBegin | Receiving(..) | AwaitingReply(..) -> True
    Ready | Closed -> False
  }
}

/// Checks local mutation admission before the composer discards its draft.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.mutation_available(channel)
/// ```
pub fn mutation_available(channel: Channel) -> Bool {
  let available = case channel.phase {
    Ready -> True
    AwaitingBegin | Receiving(_, None) -> synchronized(channel)
    Receiving(_, Some(_)) | AwaitingReply(..) | Closed -> False
  }
  can_mutate(channel) && available && channel.queued == None
}

/// Reports the single local mutation which has not crossed the wire.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.has_unsent(channel)
/// ```
pub fn has_unsent(channel: Channel) -> Bool {
  case channel.queued {
    Some(Outbound(intent: Mutation, ..)) -> True
    Some(_) | None -> False
  }
}

/// Cancels only the unsent mutation, preserving an outstanding read's credit.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.cancel_unsent(channel, "cancelled by Escape")
/// ```
pub fn cancel_unsent(
  channel: Channel,
  reason: String,
) -> #(Channel, List(Update)) {
  case has_unsent(channel) {
    True -> #(Channel(..channel, queued: None), [
      Submission(DefinitelyNotSent(reason)),
    ])
    False -> #(channel, [])
  }
}

/// Processes one real socket message without reading another process's inbox.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.receive(channel, incoming)
/// ```
pub fn receive(
  channel: Channel,
  message: connection.Message,
) -> #(Channel, List(Update)) {
  case channel.trace {
    Some(trace) -> trace.note(attempt.Received(trace.id, message))
    None -> Nil
  }
  case message {
    connection.Connected -> #(channel, [])
    connection.Closed(reason) | connection.NetworkFault(reason) ->
      fail(channel, reason)
    connection.Incoming(text) ->
      case channel.phase {
        Closed -> #(channel, [])
        Ready -> fail(channel, "unsolicited conversation response")
        AwaitingBegin | Receiving(..) | AwaitingReply(..) ->
          case session_wire.decode(text, channel.request_id) {
            Error(reason) -> fail(channel, reason)
            Ok(reply) -> apply_reply(channel, reply)
          }
      }
  }
}

fn apply_reply(channel: Channel, reply: session_wire.Reply) {
  case channel.phase, reply {
    AwaitingBegin, session_wire.Begin(body) -> {
      let expected_window = case channel.cut {
        None -> "recent"
        Some(_) -> "catch_up"
      }
      let #(window, from_seq) = case channel.cut {
        None -> #(snapshot.empty(), 0)
        Some(cut) -> #(cut.window, cut.next_seq)
      }
      case
        matching_window(body, expected_window)
        |> result.try(fn(_) {
          snapshot.begin(
            body,
            channel.expected,
            channel.attachment,
            window,
            from_seq,
          )
        })
      {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(credit(channel, transfer, None), [])
      }
    }
    AwaitingReply(_, Lookup(ids)), session_wire.Begin(body) -> {
      let from_seq = case channel.cut {
        Some(cut) -> cut.next_seq
        None -> 0
      }
      case
        snapshot.begin_lookup(
          body,
          channel.expected,
          channel.attachment,
          from_seq,
        )
      {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(credit(channel, transfer, Some(ids)), [])
      }
    }
    Receiving(transfer, lookup), session_wire.Chunk(body) ->
      case snapshot.chunk(transfer, body) {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(credit(channel, transfer, lookup), [])
      }
    Receiving(transfer, Some(ids)), session_wire.End(body) -> {
      let resolved = {
        use cut <- result.try(snapshot.finish(transfer, body))
        use #(cells, missing) <- result.try(snapshot_view.lookup(cut, ids))
        use records <- result.map(approval.records(cells))
        #(records, missing)
      }
      case resolved {
        Error(reason) -> fail(channel, reason)
        Ok(#(records, missing)) ->
          send_queued(
            Channel(..channel, phase: Ready, refresh_at: channel.timestamp()),
            [LookedUp(records, missing)],
          )
      }
    }
    Receiving(transfer, None), session_wire.End(body) ->
      case
        snapshot.finish(transfer, body)
        |> result.try(fn(cut) {
          use view <- result.try(snapshot_view.decode(cut))
          use _ <- result.map(approval.records(view.cells))
          #(cut, view)
        })
      {
        Error(reason) -> fail(channel, reason)
        Ok(#(cut, view)) -> {
          let channel =
            Channel(
              ..channel,
              phase: Ready,
              cut: Some(cut),
              attachment: Some(cut.attachment),
              refresh_at: channel.timestamp() + 250,
            )
          send_queued(channel, [Captured(cut, view)])
        }
      }
    AwaitingReply(name, Mutation), session_wire.Mutation(status) -> {
      let channel =
        Channel(..channel, phase: Ready, refresh_at: channel.timestamp())
      send_queued(channel, [Acknowledged(name, status)])
    }
    AwaitingReply(name, intent), session_wire.Presentation(event) ->
      case matching_presentation(name, intent, event) {
        True ->
          send_queued(Channel(..channel, phase: Ready), [
            Auxiliary(event),
          ])
        False -> fail(channel, "presentation does not match its command")
      }
    AwaitingBegin,
      session_wire.Presentation(protocol.ServerError(code, message))
    | Receiving(..),
      session_wire.Presentation(protocol.ServerError(code, message))
    -> fail(channel, code <> ": " <> message)
    _, _ ->
      fail(
        channel,
        "conversation response does not match its outstanding command",
      )
  }
}

fn matching_window(body, expected) {
  case body {
    json.Object(fields) ->
      case list.key_find(fields, "window") {
        Ok(json.String(found)) if found == expected -> Ok(Nil)
        Ok(_) | Error(Nil) ->
          Error("snapshot window does not match its command")
      }
    _ -> Error("invalid snapshot begin body")
  }
}

fn matching_presentation(name, intent, event) {
  case name, intent, event {
    _, _, protocol.ServerError(..) -> True
    "models", Read, protocol.ModelsSnapshot(_) -> True
    "schedules", Read, protocol.SchedulesSnapshot(_) -> True
    "schedule_cancel", Mutation, protocol.SchedulesSnapshot(_) -> True
    _, _, _ -> False
  }
}

fn credit(channel: Channel, transfer: snapshot.Transfer, lookup) {
  let #(id, index) = snapshot.credit(transfer)
  let next =
    Channel(
      ..channel,
      issued: attempt.Request(
        channel.next_id,
        "snapshot_next",
        attempt.Credit(id, index),
      ),
      phase: Receiving(transfer, lookup),
      request_id: channel.next_id,
      next_id: channel.next_id + 1,
    )
  emit(next, session_wire.next(channel.next_id, id, index))
  next
}

/// Drives idle catch-up at 250ms and fails an expired in-flight request closed.
///
/// Capture credit does not reset the original thirty-second transfer deadline.
/// The enclosing Weft switch task separately bounds initial candidate lifetime.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.tick(channel)
/// ```
pub fn tick(channel: Channel) -> #(Channel, List(Update)) {
  let timestamp = channel.timestamp()
  case channel.phase {
    Closed -> #(channel, [])
    AwaitingBegin | Receiving(..) | AwaitingReply(..) ->
      case timestamp >= channel.deadline {
        True -> fail(channel, "conversation request timed out")
        False -> #(channel, [])
      }
    Ready ->
      case channel.cut {
        Some(cut) if channel.refresh_at <= timestamp -> {
          let next = capture_again(channel, cut.next_seq)
          #(next, [])
        }
        Some(_) | None -> #(channel, [])
      }
  }
}

/// Closes one channel without treating a close cast as transitive retirement.
///
/// ## Examples
///
/// ```gleam
/// session_channel.close(channel)
/// ```
pub fn close(channel: Channel) -> Nil {
  case channel.trace {
    Some(trace) -> trace.note(attempt.Closed(trace.id))
    None -> Nil
  }
  close_socket(channel)
}

/// Retires a local attachment while preserving unsent or unconfirmed intent.
///
/// A local replacement is not itself a transport error. Only the command
/// outcome survives; this requests socket closure, never proves native drain.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.retire(channel, "attachment replaced")
/// ```
pub fn retire(channel: Channel, reason: String) -> #(Channel, List(Update)) {
  case channel.phase {
    Closed -> #(channel, [])
    _ -> {
      let #(closed, updates) = fail(channel, reason)
      #(
        closed,
        list.filter(updates, fn(update) {
          case update {
            Failed(_) -> False
            _ -> True
          }
        }),
      )
    }
  }
}

fn fail(channel: Channel, reason: String) {
  close(channel)
  let updates = case channel.phase {
    AwaitingReply(name, Mutation) -> [
      UnknownOutcome(name, channel.request_id),
      Failed(reason),
    ]
    AwaitingReply(_, Read)
    | AwaitingReply(_, Lookup(_))
    | AwaitingBegin
    | Receiving(..)
    | Ready
    | Closed -> [
      Failed(reason),
    ]
  }
  let unsent = case has_unsent(channel) {
    True -> [Submission(DefinitelyNotSent(reason))]
    False -> []
  }
  #(
    Channel(..channel, phase: Closed, queued: None),
    list.append(unsent, updates),
  )
}

fn close_socket(channel: Channel) {
  case channel.socket {
    Some(socket) -> connection.close(socket)
    None -> Nil
  }
}

/// Records adoption only after the terminal commits the validated replacement.
///
/// ## Examples
///
/// ```gleam
/// session_channel.adopted(channel)
/// ```
pub fn adopted(channel: Channel) -> Nil {
  case channel.trace {
    Some(trace) -> trace.note(attempt.Adopted(trace.id))
    None -> Nil
  }
}

fn capture_again(channel: Channel, cursor) {
  let next =
    Channel(
      ..channel,
      phase: AwaitingBegin,
      issued: attempt.Request(
        channel.next_id,
        "catch_up",
        attempt.Cursor(cursor),
      ),
      request_id: channel.next_id,
      next_id: channel.next_id + 1,
      deadline: channel.timestamp() + 30_000,
    )
  emit(next, session_wire.catch_up(channel.next_id, cursor))
  next
}

/// Validates a recorded request against the effect-free channel's next credit.
///
/// Only a ready lane can begin another command. Credit generated by a previous
/// frame must exactly match its recorded marker before that response is read.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_issued(lane, request)
/// ```
pub fn replay_issued(
  channel: Channel,
  request: attempt.Request,
) -> Result(Channel, String) {
  use <- bool.guard(
    channel.socket != None,
    Error("cannot replay into a live channel"),
  )
  let next = case channel.phase, request.selection {
    Ready, attempt.Cursor(cursor) ->
      case channel.cut {
        Some(cut) if request.kind == "catch_up" && cursor == cut.next_seq ->
          Ok(capture_again(channel, cursor))
        Some(_) | None ->
          Error("recorded catch-up cursor does not match the adopted cut")
      }
    Ready, attempt.Decisions(ids) -> lookup(channel, ids)
    Ready, attempt.NoSelection ->
      admit(channel, session_wire.command(1, request.kind, []))
      |> result.map(fn(admitted) { admitted.0 })
    Ready, attempt.Credit(..) -> Error("unsolicited recorded snapshot credit")
    AwaitingBegin, _ | Receiving(..), _ | AwaitingReply(..), _ -> Ok(channel)
    Closed, _ -> Error("request on a closed recording attempt")
  }
  use next <- result.try(next)
  case next.issued == request {
    True -> Ok(next)
    False -> Error("recorded request does not match protocol progress")
  }
}

/// Requests at most eight displayed decisions without moving the main cursor.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.lookup(channel, ["approval-id"])
/// ```
pub fn lookup(channel: Channel, ids: List(String)) -> Result(Channel, String) {
  use <- bool.guard(
    ids == [] || list.drop(ids, 8) != [],
    Error("lookup requires one to eight identities"),
  )
  use <- bool.guard(
    list.unique(ids) != ids
      || list.any(ids, fn(id) { id == "" || string.byte_size(id) > 256 }),
    Error("lookup identities must be distinct and contain one to 256 bytes"),
  )
  use <- bool.guard(
    channel.phase == Closed || channel.cut == None,
    Error("conversation is not synchronized"),
  )
  let frame =
    session_wire.command(1, "escalations_get", [
      #("ids", json.Array(list.map(ids, json.String))),
    ])
  use outbound <- result.try(outbound(frame))
  let outbound = Outbound(..outbound, intent: Lookup(ids))
  case channel.phase, channel.queued {
    Ready, None -> Ok(send(channel, outbound))
    _, None -> Ok(Channel(..channel, queued: Some(outbound)))
    _, Some(_) -> Error("one read is already queued")
  }
}

fn send_queued(channel: Channel, updates: List(Update)) {
  case channel.queued {
    None -> #(channel, updates)
    Some(outbound) -> {
      let cleared = Channel(..channel, queued: None)

      // The completed cut is authoritative before allocation or emission. The
      // original action, approval seq and encoded body remain untouched.
      case outbound.intent == Mutation && !can_mutate(cleared) {
        True -> #(
          cleared,
          list.append(updates, [
            Submission(DefinitelyNotSent(
              "attachment no longer permits this mutation",
            )),
          ]),
        )
        False -> {
          let sent = send(cleared, outbound)
          #(
            sent,
            list.append(updates, [
              Submission(Sent(outbound.name, sent.request_id)),
            ]),
          )
        }
      }
    }
  }
}

fn send(channel: Channel, outbound: Outbound) {
  let frame =
    session_wire.command_prefix
    <> int.to_string(channel.next_id)
    <> session_wire.command_tag
    <> outbound.suffix
  let selection = case outbound.intent {
    Lookup(ids) -> attempt.Decisions(ids)
    Read | Mutation -> attempt.NoSelection
  }
  let next =
    Channel(
      ..channel,
      issued: attempt.Request(channel.next_id, outbound.name, selection),
      phase: AwaitingReply(outbound.name, outbound.intent),
      request_id: channel.next_id,
      next_id: channel.next_id + 1,
      deadline: channel.timestamp() + 10_000,
    )
  emit(next, frame)
  next
}

fn outbound(frame: String) {
  use <- bool.guard(
    string.byte_size(frame) > snapshot.record_limit,
    Error("conversation command exceeds the input bound"),
  )
  use #(prefix, suffix) <- result.try(
    string.split_once(frame, session_wire.command_tag)
    |> result.replace_error("invalid generated command prefix"),
  )
  use id <- result.try(
    case string.starts_with(prefix, session_wire.command_prefix) {
      True ->
        Ok(string.drop_start(prefix, string.length(session_wire.command_prefix)))
      False -> Error("invalid generated command version")
    },
  )
  use _ <- result.try(
    int.parse(id) |> result.replace_error("invalid generated command identity"),
  )
  use #(name, _body) <- result.try(
    string.split_once(suffix, session_wire.command_body)
    |> result.replace_error("invalid generated command body"),
  )
  use name <- result.try(
    json.parse(name) |> result.replace_error("invalid generated command name"),
  )
  case name {
    json.String(name) -> {
      let intent = case name {
        "models" | "schedules" -> Read
        _ -> Mutation
      }
      Ok(Outbound(name, suffix, intent))
    }
    _ -> Error("invalid generated command name")
  }
}

fn now() {
  bootstrap.monotonic_time_ms()
}
