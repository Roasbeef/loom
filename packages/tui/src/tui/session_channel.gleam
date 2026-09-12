//// Terminal-owned progress for one credited conversation connection.
////
//// There is no additional process: the terminal drains its own inbox and
//// applies this state. A single request owns the wire at a time. One local
//// command may wait behind reconciliation; timeouts close the socket and
//// preserve uncertainty instead of resending a mutation on another connection.
////
//// A single request still owns the wire, because a pushed frame is not a
//// request. Well-formed frames the daemon volunteers arrive in every open
//// phase, consume no credit, allocate no identity and cannot fail the lane;
//// a frame that does not decode closes the socket as any bad frame does.
//// What a commit
//// notice does is move a catch-up earlier: the lane issues it now, or at the
//// moment the outstanding request finishes, rather than at the 250 ms idle
//// refresh. That makes a notice idempotent and order-free — a sequence
//// already held says nothing new, a lost notice is repaired by the refresh,
//// and a daemon that pushes nothing leaves the refresh as the only path,
//// which is the terminal's behaviour before live delivery existed.
////
//// Because a notice may legitimately do nothing, the lane reports every one
//// it receives as `Noticed` before deciding what to do with it. That is the
//// only account of live delivery which does not depend on winning a race
//// against the refresh, and it is what the shipped fixture counts.

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
  Captured(
    /// The completed, validated cut.
    cut: snapshot.Captured,
    /// The presentation derived from it.
    view: snapshot_view.View,
    /// What made the lane ask for this cut.
    trigger: Capture,
  )

  /// An independently validated older page; never advances the live cursor.
  HistoryPage(window: snapshot.Window, before_seq: Int, after_seq: Int)

  /// Exact decisions only; never a replacement conversation cut.
  LookedUp(records: List(approval.Review), missing: List(String))

  /// Models/schedules or a typed server refusal.
  Auxiliary(event: protocol.Event)

  /// A refusal belongs only to the exact correlated command which was issued.
  RequestRefused(
    /// Command which owned the outstanding reply slot.
    command: String,
    /// Actual wire identity already checked by the channel.
    request_id: Int,
    /// Server refusal class.
    code: String,
    /// Server explanation, sanitized by presentation.
    message: String,
  )

  /// One pushed provider fragment, ordered within its operation by the
  /// socket that delivered it. Unlike the snapshot's sampled preview these
  /// are continuous, so a renderer appends them until the operation changes.
  Streamed(
    /// The strand receiving the fragment.
    strand: String,
    /// The operation the fragment belongs to.
    operation: String,
    /// One request within the operation, including its retry attempt.
    generation: String,
    /// The open-set stream kind, such as `thinking` or `text`.
    kind: String,
    /// The bounded, sanitized-later fragment bytes.
    text: String,
  )

  /// One pushed tail of a running tool call's output. A snapshot of the
  /// window rather than a fragment, so the renderer replaces what it holds
  /// for `{operation, step, source_index, stream}` instead of appending.
  ToolStreamed(
    /// The strand whose call is printing.
    strand: String,
    /// The operation the call belongs to.
    operation: String,
    /// The step within the operation.
    step: String,
    /// The call's index within its step.
    source_index: Int,
    /// Provider call identity echoed by its durable result.
    call_id: String,
    /// `stdout` or `stderr`.
    stream: String,
    /// The whole retained window, sanitized later.
    text: String,
    /// How many bytes the stream has carried in all.
    total_bytes: Int,
  )

  /// One commit notice this lane received, whatever it went on to do with
  /// it. A notice for a sequence already held issues nothing, and a notice
  /// whose catch-up the idle refresh had already started paints under
  /// `Refreshed`; in both cases the frame still arrived. Which capture
  /// painted an answer is therefore not an observable a fixture can pin,
  /// but whether pushes reach this terminal at all is, and this is it.
  Noticed(seq: Int)

  /// The server acknowledged one mutation without implying a later snapshot.
  Acknowledged(command: String, status: String)

  /// A sent mutation lost its reply; the client must not retry automatically.
  UnknownOutcome(command: String, request_id: Int)

  /// The socket cannot continue, while the last completed projection survives.
  Failed(reason: String)
}

/// What made a lane ask for the cut it just completed.
///
/// The three are not interchangeable to a reader. Live delivery is working
/// only when a peer's answer is painted by a `Notified` capture; the same
/// answer painted by `Refreshed` means the notice never arrived and the
/// terminal fell back to polling, which is correct but is not the property
/// under test. Carrying the reason on the update is what lets a fixture tell
/// those two apart instead of inferring it from timing.
pub type Capture {
  /// A pushed frame — a commit notice, presence or attachment — asked for it.
  Notified

  /// The 250 ms idle refresh, which is the recovery path and the only path
  /// on a daemon that pushes nothing.
  Refreshed

  /// The lane's own subscribe or a recorded command produced it.
  Requested
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
  History(after_seq: Int, before_seq: Int)
}

type Outbound {
  Outbound(name: String, suffix: String, intent: Intent)
}

/// Whether a pushed notice is still owed a capture.
///
/// A notice that arrives while a request is in flight cannot be acted on
/// then: the lane has one outstanding request and will not open a second.
/// Remembering that one is due is enough, because a notice carries no state
/// of its own — any number of them collapse into "capture when free".
type Refresh {
  /// A notice arrived mid-request; capture at the next ready transition.
  Due

  /// Nothing is owed; the 250 ms idle refresh is the only capture cadence.
  Idle
}

type Projection {
  Conversation
  Decisions(List(String))
  OlderPage(after_seq: Int, before_seq: Int)
}

type Phase {
  AwaitingBegin
  Receiving(snapshot.Transfer, Projection)
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
    refresh: Refresh,
    trigger: Capture,
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

/// Records what a socketless lane would have written, for tests that need to
/// see which request a transition issued rather than only its outcome.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_traced(expected, clock, trace)
/// ```
@internal
pub fn replay_traced(
  expected: snapshot.Expected,
  timestamp: fn() -> Int,
  trace: attempt.Trace,
) -> Channel {
  initial(None, expected, Some(trace), timestamp)
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
    refresh: Idle,
    trigger: Requested,
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
    AwaitingBegin
    | Receiving(..)
    | AwaitingReply(_, Read)
    | AwaitingReply(_, Lookup(_))
    | AwaitingReply(_, History(..)) -> synchronized(channel)
    AwaitingReply(_, Mutation) | Closed -> False
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

        // A ready lane has no outstanding request, so the only frame it can
        // read is one the daemon volunteered. A correlated reply here names a
        // request that is already finished, and an undecodable frame is not
        // one the lane may quietly ignore; both close the socket, exactly as
        // every incoming frame in this phase did before pushes existed.
        Ready ->
          case session_wire.decode(text, channel.request_id) {
            Ok(session_wire.Pushed(event)) -> apply_pushed(channel, event)
            Ok(session_wire.Begin(_))
            | Ok(session_wire.Chunk(_))
            | Ok(session_wire.End(_))
            | Ok(session_wire.Mutation(_))
            | Ok(session_wire.Presentation(_))
            | Error(_) -> fail(channel, "unsolicited conversation response")
          }
        AwaitingBegin | Receiving(..) | AwaitingReply(..) ->
          case session_wire.decode(text, channel.request_id) {
            Error(reason) -> fail(channel, reason)

            // A push interleaved with a transfer belongs to no request, so
            // it is applied without touching the phase, the credit or the
            // outstanding identity the next chunk will be checked against.
            Ok(session_wire.Pushed(event)) -> apply_pushed(channel, event)
            Ok(reply) -> apply_reply(channel, reply)
          }
      }
  }
}

fn apply_pushed(channel: Channel, event: protocol.Event) {
  case event {
    protocol.Committed(strand: _, seq:) -> notified(channel, seq)

    // Presence and attachment carry nothing renderable; what they say is
    // that the next capture differs, which is what a notice says too.
    protocol.MetadataChanged -> capture_or_defer(channel)
    protocol.StreamDelta(strand:, operation:, generation:, kind:, text:) -> #(
      channel,
      [
        Streamed(strand:, operation:, generation:, kind:, text:),
      ],
    )

    // A running call's tail is the same kind of thing as a delta — live
    // display state the daemon pushed and no cut will ever carry — so it
    // takes the same route to the renderer and touches nothing else.
    protocol.ToolOutput(
      strand:,
      operation:,
      step:,
      source_index:,
      call_id:,
      stream:,
      text:,
      total_bytes:,
    ) -> #(channel, [
      ToolStreamed(
        strand:,
        operation:,
        step:,
        source_index:,
        call_id:,
        stream:,
        text:,
        total_bytes:,
      ),
    ])

    // A pushed error reports a failure the daemon had on this terminal's
    // behalf — a held prompt that could not be admitted when its turn came.
    // The connection is fine, so this is the same auxiliary refusal a
    // correlated error is, and the socket stays open.
    protocol.ServerError(..)
    | protocol.WorktreeSnapshot(_)
    | protocol.ContextSnapshot(_) -> #(channel, [
      Auxiliary(event),
    ])

    // Everything else in the event vocabulary is either unknown to this
    // client or reachable only as a correlated reply. Dropping it is what
    // keeps a daemon running ahead of this terminal harmless.
    protocol.FullSnapshot(..)
    | protocol.StrandsSnapshot(..)
    | protocol.ModelsSnapshot(..)
    | protocol.SkillsSnapshot(..)
    | protocol.NotesSnapshot(..)
    | protocol.QueuedInputSnapshot(..)
    | protocol.LiveJobsSnapshot(..)
    | protocol.SchedulesSnapshot(..)
    | protocol.ConfigSnapshot(..)
    | protocol.EntryAdded(..)
    | protocol.OperationChanged(..)
    | protocol.UsageChanged(..)
    | protocol.EscalationPending(..)
    | protocol.Ignored(_) -> #(channel, [])
  }
}

// A notice for a sequence the lane already holds, or one that arrives before
// any cut exists to compare it against, tells the lane nothing it has not
// already fetched or is not already fetching.
//
// The arrival is reported ahead of that decision, and independently of it.
// Dropping a notice is a statement about what this lane already knows, never
// about whether the daemon pushed, so the count a reader can trust has to be
// taken before the drop.
fn notified(channel: Channel, seq: Int) {
  let #(channel, updates) = case channel.cut {
    Some(cut) if seq < cut.next_seq -> #(channel, [])
    Some(_) | None -> capture_or_defer(channel)
  }
  #(channel, [Noticed(seq), ..updates])
}

// A push that arrives before any cut exists says nothing the initial
// transfer will not deliver, so it is dropped here for every kind of trigger
// rather than deferred into a redundant second catch-up.
fn capture_or_defer(channel: Channel) {
  case channel.phase, channel.cut {
    Ready, Some(cut) -> #(
      capture_again(Channel(..channel, refresh: Idle), cut.next_seq, Notified),
      [],
    )

    // The lane holds one request at a time, so a notice arriving mid-transfer
    // is remembered rather than acted on. `send_queued` spends it at the next
    // ready transition, which is sooner than the idle refresh would.
    AwaitingBegin, Some(_)
    | Receiving(..), Some(_)
    | AwaitingReply(..), Some(_)
    -> #(Channel(..channel, refresh: Due), [])
    Ready, None
    | AwaitingBegin, None
    | Receiving(..), None
    | AwaitingReply(..), None
    | Closed, _
    -> #(channel, [])
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
        Ok(transfer) -> #(credit(channel, transfer, Conversation), [])
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
        Ok(transfer) -> #(credit(channel, transfer, Decisions(ids)), [])
      }
    }
    AwaitingReply(_, History(after, before)), session_wire.Begin(body) -> {
      let started = {
        use _ <- result.try(matching_window(body, "history"))
        snapshot.begin(
          body,
          channel.expected,
          channel.attachment,
          snapshot.empty(),
          after + 1,
        )
      }
      case started {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(
          credit(channel, transfer, OlderPage(after, before)),
          [],
        )
      }
    }
    Receiving(transfer, OlderPage(after, before)), session_wire.End(body) -> {
      let completed = {
        use cut <- result.try(snapshot.finish(transfer, body))
        use <- bool.guard(
          list.any(cut.window.items, fn(item) {
            snapshot.sequence(item) <= after
            || snapshot.sequence(item) >= before
          }),
          Error("history page exceeds requested range"),
        )
        Ok(cut.window)
      }
      case completed {
        Error(reason) -> fail(channel, reason)
        Ok(window) ->
          send_queued(
            Channel(..channel, phase: Ready, refresh_at: channel.timestamp()),
            [HistoryPage(window, before, after)],
          )
      }
    }
    Receiving(transfer, lookup), session_wire.Chunk(body) ->
      case snapshot.chunk(transfer, body) {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(credit(channel, transfer, lookup), [])
      }
    Receiving(transfer, Decisions(ids)), session_wire.End(body) -> {
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
    Receiving(transfer, Conversation), session_wire.End(body) ->
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
          send_queued(channel, [Captured(cut, view, channel.trigger)])
        }
      }
    AwaitingReply(name, Mutation), session_wire.Mutation(status) -> {
      let channel =
        Channel(..channel, phase: Ready, refresh_at: channel.timestamp())
      send_queued(channel, [Acknowledged(name, status)])
    }
    AwaitingReply(name, _),
      session_wire.Presentation(protocol.ServerError(code, message))
    ->
      send_queued(Channel(..channel, phase: Ready), [
        RequestRefused(name, channel.request_id, code, message),
      ])
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
    "skills", Read, protocol.SkillsSnapshot(_) -> True
    "notes", Read, protocol.NotesSnapshot(_) -> True
    "queued_input", Read, protocol.QueuedInputSnapshot(_) -> True
    "worktree_diff", Read, protocol.WorktreeSnapshot(_) -> True
    "context", Read, protocol.ContextSnapshot(_) -> True
    "live_jobs", Read, protocol.LiveJobsSnapshot(_) -> True
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
          let next = capture_again(channel, cut.next_seq, Refreshed)
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
    | AwaitingReply(_, History(..))
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

fn capture_again(channel: Channel, cursor, trigger: Capture) {
  let next =
    Channel(
      ..channel,
      phase: AwaitingBegin,
      trigger: trigger,
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
        // A recording preserves the request, not the reason for it. Every
        // catch-up in a recording made before pushed frames existed was the
        // idle refresh, so that is what replay reports.
        Some(cut) if request.kind == "catch_up" && cursor == cut.next_seq ->
          Ok(capture_again(channel, cursor, Refreshed))
        Some(_) | None ->
          Error("recorded catch-up cursor does not match the adopted cut")
      }
    Ready, attempt.Decisions(ids) -> lookup(channel, ids)
    Ready, attempt.HistoryRange(after, before) ->
      history(channel, after, before)
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

/// Reads at most one hundred older sequence positions on the existing lane.
///
/// The bounds are exclusive. The result cannot replace live metadata or the
/// catch-up cursor, and a busy lane leaves the request with its caller.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.history(channel, 100, 201)
/// ```
@internal
pub fn history(
  channel: Channel,
  after: Int,
  before: Int,
) -> Result(Channel, String) {
  use <- bool.guard(
    after < 0 || before <= after || before - after > 101,
    Error("history requires a range of at most one hundred sequences"),
  )
  use <- bool.guard(
    !ready_for_read(channel),
    Error("conversation read lane is busy"),
  )
  use outbound <- result.try(
    outbound(
      session_wire.command(1, "history", [
        #("after_seq", json.Int(after)),
        #("before_seq", json.Int(before)),
      ]),
    ),
  )
  Ok(send(channel, Outbound(..outbound, intent: History(after, before))))
}

// Every transition back to `Ready` passes through here, so this is the one
// place a deferred notice can be spent. A waiting local command still goes
// first: it keeps the lane busy, and the notice survives to the transition
// after that one.
fn send_queued(channel: Channel, updates: List(Update)) {
  let #(channel, updates) = flush_queued(channel, updates)
  case channel.phase, channel.refresh, channel.cut {
    Ready, Due, Some(cut) -> #(
      capture_again(Channel(..channel, refresh: Idle), cut.next_seq, Notified),
      updates,
    )
    Ready, Due, None
    | Ready, Idle, _
    | AwaitingBegin, _, _
    | Receiving(..), _, _
    | AwaitingReply(..), _, _
    | Closed, _, _
    -> #(channel, updates)
  }
}

fn flush_queued(channel: Channel, updates: List(Update)) {
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
    History(after, before) -> attempt.HistoryRange(after, before)
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
        "models"
        | "skills"
        | "schedules"
        | "notes"
        | "queued_input"
        | "context"
        | "worktree_diff"
        | "live_jobs" -> Read
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

/// Admits auxiliary reads only after retained mutations and captures finish.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.ready_for_read(channel)
/// ```
pub fn ready_for_read(channel: Channel) -> Bool {
  channel.phase == Ready && channel.queued == None && synchronized(channel)
}
