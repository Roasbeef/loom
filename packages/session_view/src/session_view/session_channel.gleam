//// Client-owned progress for one credited conversation connection.
////
//// There is no additional process: the host that owns the connection's
//// inbox drains it and applies this state. The terminal is one such host
//// (`tui/terminal_lane` names its socket and recorder types), and the lane
//// never learns which host it runs under. A single request owns the wire at
//// a time. One local
//// command may wait behind reconciliation; timeouts close the socket and
//// preserve uncertainty instead of resending a mutation on another connection.
////
//// A single request still owns the wire, because a pushed frame is not a
//// request. Well-formed frames the daemon volunteers arrive in every open
//// phase, consume no credit, allocate no identity and cannot fail the lane;
//// a frame that does not decode closes the socket as any bad frame does.
//// What a commit
//// notice does is move a catch-up earlier: the lane issues it now, or at the
//// moment the outstanding request finishes, rather than at the idle
//// refresh. That makes a notice idempotent and order-free — a sequence
//// already held says nothing new, a lost notice is repaired by the refresh,
//// and a daemon that pushes nothing leaves the refresh as the only path,
//// which is the terminal's behaviour before live delivery existed.
////
//// The refresh has two intervals, and the lane picks between them by what
//// it has seen rather than by what the daemon claims. A lane starts
//// `Polling`, refreshing an idle cut every `polling_refresh_ms` (250 ms),
//// because until a frame has been pushed to it the refresh is the only way
//// it learns that the session moved. The first pushed frame moves it to
//// `Pushing` for the rest of its life, and from then on an idle cut is
//// refreshed every `pushing_refresh_ms` (5 s). The hello is not used for
//// this: it carries no push capability, and a lane that reconnects may be
//// talking to an older daemon than the one that pushed before.
////
//// No gap detection is needed for the longer interval. A notice carries
//// only a sequence, and a notice at or above the cut's `next_seq` catches
//// up from `cut.next_seq`, so a lost notice followed by any later one loses
//// nothing: the later catch-up fetches both commits. What the longer refresh
//// covers is a lost *final* notice, the last commit before the session goes
//// quiet, which no later notice will repair. That case, and a daemon that
//// stops pushing after it started, cost at most one refresh interval of
//// staleness.
////
//// A host drives the refresh and the deadlines by calling `tick`, and asks
//// `next_due` when it next has to. Neither host polls on a fixed cadence:
//// each arms one wake-up for `next_due` and reduces arriving traffic as it
//// arrives.
////
//// Because a notice may legitimately do nothing, the lane reports every one
//// it receives as `Noticed` before deciding what to do with it. That is the
//// only account of live delivery which does not depend on winning a race
//// against the refresh, and it is what the shipped fixture counts.
////
//// The lane reads no clock. Every transition that sets or checks a deadline
//// or the refresh instant takes `now`, a monotonic reading in milliseconds
//// from its caller: the terminal passes the transport reading it stamped
//// on the model before the step, a replay passes its own time, which starts
//// at zero, and a property test passes whatever schedule it generated. The
//// same arguments therefore always produce the same transition.
////
//// ## Flow
////
//// `start` → `receive` → `apply_reply` → `credit` → `send_queued` → `tick`
////
//// 1. `start` (or `start_resumed`) queues the subscribe through `emit`, so
////    the lane begins in `AwaitingBegin` with request 1 outstanding.
//// 2. `receive` notes the message, then dispatches by phase. A pushed frame
////    goes to `apply_pushed` and never touches the phase or the credit.
//// 3. `apply_reply` reduces the one correlated reply the lane is owed: a
////    begin goes to `credit`, which asks for the next chunk, and an end
////    returns the lane to `Ready`.
//// 4. `send_queued` runs on every return to `Ready`. It spends the waiting
////    command through `flush_queued` first and a deferred notice second.
//// 5. `submit` reaches the same command path from the operator: `admit`
////    checks the role and the slot, and `send` puts the frame on the wire.
//// 6. `tick` fails an expired request, or issues the idle catch-up through
////    `capture_again`; `next_due` names when a tick can next act.
//// 7. `fail` ends the lane on any violation or loss and calls `close`, which
////    is the only way into `Closed`.
////
//// `receive` records one transport message before decoding it.
//// `apply_pushed` handles uncorrelated notices; `apply_reply` handles the
//// outstanding request. A completed reply enters `send_queued`.
//// `send_queued` gives `flush_queued` first use of the free slot, then calls
//// `read_changed_goal`, then spends transcript capture debt if still ready.
//// `send` allocates the identity; `emit` records issuance before transmission.
//// `take_outputs` hands those effects to the host in their decision order.
//// `submit` admits operator intent through `admit`; `tick` owns timeouts and
//// idle transcript catch-up. Goal invalidation creates no periodic goal timer.
////
//// ## Transitions
////
//// What each entry point does to a lane in each phase. A bad frame, a
//// transport loss and an expired deadline all go through `fail`, so each
//// ends in `Closed`; `retire` is `fail` without the `Failed` update.
////
//// <!-- transitions: session_channel.Phase -->
////
//// | state | receive | `GoalChanged` push | tick | submit | close | retire |
//// | --- | --- | --- | --- | --- | --- | --- |
//// | `AwaitingBegin` | `Receiving` on a valid begin; `Ready` on a resumed marker; a push is applied in place; anything else `Closed` | stays; the goal read is due, issued on the next return to `Ready` | `Closed` once the deadline passes | queued (`Waiting`); a mutation also needs a held cut and a mutating role, else refused | `Closed` | `Closed` |
//// | `Receiving` | `Receiving` on a chunk; `Ready` on a valid end; a push is applied in place; anything else `Closed` | stays; the goal read is due, issued on the next return to `Ready` | `Closed` once the deadline passes | queued (`Waiting`); a mutation also needs a held cut and a mutating role, else refused | `Closed` | `Closed` |
//// | `AwaitingReply` | `Ready` on the matching reply or a server refusal; `Receiving` on a lookup or history begin; a push is applied in place; anything else `Closed` | stays; the goal read is due, and the read in flight does not spend it | `Closed` once the deadline passes | queued (`Waiting`) if the slot is free; a mutation is refused while another is in flight or the role forbids | `Closed`, with no outcome reported | `Closed` |
//// | `Ready` | stays on other pushes; `AwaitingBegin` on a notice at or past the cut or a metadata push; any reply is `Closed` | `AwaitingReply` once `send_queued` issues `goal_get`, after any waiting command | `AwaitingBegin` once the refresh instant passes | `AwaitingReply` (`Sent`), or refused if the role or slot forbids | `Closed` | `Closed` |
//// | `Closed` | ignored | ignored | nothing | refused | unchanged | unchanged |

import core/ids
import core/json
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/approval
import session_view/attempt
import session_view/connection_event
import session_view/protocol
import session_view/session_wire
import session_view/snapshot
import session_view/snapshot_view

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

  /// An independently validated page of one strand's ancestry, as the records
  /// on the path from `from` down its parent links; never advances the live
  /// cursor, and never carries metadata the lane adopts.
  LineagePage(window: snapshot.Window, from: String)

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

  /// The idle refresh, which is the recovery path and the only path on a
  /// daemon that pushes nothing.
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

// The reply contract and uncertainty rule travel with the issued command.
type Intent {
  /// A presentation board can be refused without retrying the command.
  Read

  /// A lost reply preserves unknown outcome instead of permitting resend.
  Mutation

  /// Only the selected decision identities may answer this read.
  Lookup(ids: List(String))

  /// Only the decided-approvals transfer may answer this read.
  Listing

  /// The independently validated page is the ancestry of this entry, whose
  /// record is the newest it may hold.
  Lineage(from: String)

  /// The independently validated page stays inside these sequence bounds.
  History(after_seq: Int, before_seq: Int)
}

// An admitted frame keeps its encoded body while the lane assigns its ID.
type Outbound {
  Outbound(name: String, suffix: String, intent: Intent)
}

/// Whether an invalidated observation is still owed a read.
///
/// A notice that arrives while a request is in flight cannot be acted on
/// then: the lane has one outstanding request and will not open a second.
/// One owed read is enough because an invalidation carries no state of its
/// own. Repeated invalidations coalesce until the read is issued.
type Refresh {
  /// Read at the next ready transition.
  Due

  /// No invalidation is owed.
  Idle
}

/// How long a `Polling` lane waits with an idle cut before it captures
/// again, in milliseconds.
///
/// A lane that has seen no pushed frame cannot tell a quiet session from a
/// daemon that never pushes, so it refreshes at the cadence the terminal
/// used before live delivery existed.
pub const polling_refresh_ms = 250

/// How long a `Pushing` lane waits with an idle cut before it captures
/// again, in milliseconds.
///
/// Once the daemon has pushed, every commit it makes is announced, so the
/// refresh repairs a lost final notice and catches what the daemon does not
/// announce.
///
/// Five seconds is affordable because the refresh no longer carries any
/// change a peer's screen depends on. The hub pushes `presence` when a
/// peer subscribes as well as when one departs
/// (`protocol-change/054-roster-push-on-subscribe.md`), so a newcomer
/// reaches the peers already attached as a pushed frame and not at their
/// next refresh. Before 054 a join produced no frame, and this constant
/// was 1000 so that a join reached the other peers within a second.
pub const pushing_refresh_ms = 5000

/// Whether this lane has evidence that its daemon pushes.
///
/// The evidence is a pushed frame the lane itself received, and nothing
/// else: the hello names no capability, and a lane replacing another may
/// face an older daemon. The value only ever moves from `Polling` to
/// `Pushing`, since a daemon that stops pushing is still covered by the
/// longer refresh.
type Delivery {
  /// No pushed frame has arrived; the idle refresh is the lane's only way
  /// to learn that the session moved, so it runs every
  /// `polling_refresh_ms`.
  Polling

  /// A pushed frame has arrived; the idle refresh runs every
  /// `pushing_refresh_ms` and only repairs a lost final notice.
  Pushing
}

type Projection {
  Conversation
  Decisions(List(String))
  Decided
  OlderPage(after_seq: Int, before_seq: Int)
  Lineaged(from: String)
}

// The outstanding request, not a transport connection's lifecycle. A pushed
// notice preserves its phase until that notice can use a free request slot.
// The module doc's transition table gives every phase against every entry
// point, checked against these constructors by lint R14. A malformed or
// mismatched reply closes every open phase, every mutation also needs
// can_mutate, and a second queued command is refused. Ready is the
// intermediate state before send_queued may issue another request.
type Phase {
  /// Initial subscribe or catch-up awaits its begin marker.
  AwaitingBegin

  /// Each valid chunk earns one next credit until a validated end.
  Receiving(snapshot.Transfer, Projection)

  /// The single issued command owns every correlated reply until settlement.
  AwaitingReply(name: String, intent: Intent)

  /// No correlated request is outstanding; debt or queued intent may issue.
  Ready

  /// No further output may be transmitted; closure is not a drain witness.
  Closed
}

/// What a channel transition asks the transport and the recorder to do.
///
/// The socket and the recorder are type parameters, because what they are
/// belongs to the host: the terminal's socket is a `host/websocket`
/// connection and its recorder a file, and a replay has neither. The lane
/// only carries each handle to the output it queues, and the host that
/// performs the output is the one that knows what to do with it.
///
/// The channel decides what to write, when to close and what to record; it
/// never writes, closes or records itself. A transition appends its outputs
/// to the channel's outbox, the host's reducer that called it moves them
/// out before it stores the channel, and the host performs them after its
/// step, so every function below is a pure transition over its arguments.
/// In the terminal the move is `tui_model.hold_channel` and the perform is
/// `tui/terminal_lane.perform`. Each output names what it acts on: an
/// attachment replaced later in the same step must not redirect a write
/// that was meant for the connection it replaced, and a note decided under
/// one recorder goes to that recorder.
///
/// A lane's notes and writes share one queue because the recording orders
/// them by cause (ADR-009): a request's `Issued` note is queued before its
/// frame, and a frame's `Received` note before anything the frame made the
/// lane send.
pub type Out(socket, recorder) {
  /// One protocol frame to write.
  Transmit(socket: socket, frame: String)

  /// A close of the lane's socket.
  Shut(socket: socket)

  /// One attempt event for the lane's recording.
  Note(recorder: recorder, event: attempt.Event)
}

/// One bounded protocol lane, held by the host which owns its inbox.
///
/// `socket` and `recorder` are the host's handle types, carried unchanged to
/// the outputs that name them; see `Out`.
pub opaque type Channel(socket, recorder) {
  Channel(
    socket: Option(socket),
    /// Pending outputs, newest first, until `take_outputs` hands them over.
    outbox: List(Out(socket, recorder)),
    trace: Option(attempt.Trace(recorder)),
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
    /// One auxiliary read owed after a goal write notification.
    goal_refresh: Refresh,
    trigger: Capture,
    /// Whether a pushed frame has reached this lane, which picks the idle
    /// refresh interval.
    delivery: Delivery,
  )
}

/// Starts initial capture; adoption waits for a Captured update, not this call.
///
/// `now` is the caller's monotonic reading in milliseconds. The lane holds
/// no clock of its own: its first deadline and refresh instant are measured
/// from this reading, and every later transition that compares against them
/// is handed the time it happens at.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.start(socket, selected, now: stamp.transport_ms)
/// ```
pub fn start(
  socket: socket,
  expected: snapshot.Expected,
  now now: Int,
) -> Channel(socket, recorder) {
  start_recorded(socket, expected, None, now:)
}

/// Starts a live channel with optional attempt-scoped recording.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.start_recorded(socket, selected, trace, now:)
/// ```
pub fn start_recorded(
  socket,
  expected,
  trace: Option(attempt.Trace(recorder)),
  now now: Int,
) -> Channel(socket, recorder) {
  initial(Some(socket), expected, trace, now)
  |> note(attempt.Started(_, expected))
  |> emit(protocol.subscribe(1, expected.session))
}

/// Starts a reattachment that resumes from a cut this terminal already holds.
///
/// A reconnect has a transcript to keep, so the subscription names the cursor
/// that transcript ends at instead of asking the server to start again. The
/// lane therefore begins with the retained cut and its authenticated
/// attachment in hand: the attachment is what admits the operator's next
/// mutation, and the cut is what the idle catch-up then reconciles from — so
/// the entries committed while this terminal was away arrive as a bounded
/// capture rather than as a rebuilt transcript.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.start_resumed(socket, expected, retained, trace, now:)
/// ```
pub fn start_resumed(
  socket: socket,
  expected: snapshot.Expected,
  retained: snapshot.Captured,
  trace: Option(attempt.Trace(recorder)),
  now now: Int,
) -> Channel(socket, recorder) {
  Channel(
    socket: Some(socket),
    outbox: [],
    trace: trace,
    issued: attempt.Request(1, "subscribe", attempt.Cursor(retained.next_seq)),
    expected: expected,
    phase: AwaitingBegin,
    request_id: 1,
    next_id: 2,
    deadline: now + 30_000,
    attachment: Some(retained.attachment),
    cut: Some(retained),
    queued: None,
    refresh_at: now,
    refresh: Idle,
    goal_refresh: Idle,
    trigger: Requested,
    delivery: Polling,
  )
  |> note(attempt.Started(_, expected))
  |> emit(protocol.subscribe_from(1, expected.session, retained.next_seq))
}

/// Creates effect-free replay state without a socket, process or wall clock.
///
/// A replay lane's time starts at zero and moves only when its caller
/// passes a later reading, so a replay reaches the same deadlines on every
/// run whatever the host clock says.
///
/// ## Examples
///
/// ```gleam
/// let lane = session_channel.replay(snapshot.Expected("s", "e", "i"))
/// ```
pub fn replay(expected: snapshot.Expected) -> Channel(socket, recorder) {
  initial(None, expected, None, 0)
}

/// Records what a socketless lane would have written, for tests that need to
/// see which request a transition issued rather than only its outcome. The
/// lane queues its notes and nothing else, since it has no socket. Its time
/// starts at zero, as `replay`'s does.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_traced(expected, trace)
/// ```
@internal
pub fn replay_traced(
  expected: snapshot.Expected,
  trace: attempt.Trace(recorder),
) -> Channel(socket, recorder) {
  initial(None, expected, Some(trace), 0)
}

fn initial(socket, expected, trace, now: Int) {
  Channel(
    socket: socket,
    outbox: [],
    trace: trace,
    issued: attempt.Request(1, "subscribe", attempt.NoSelection),
    expected: expected,
    phase: AwaitingBegin,
    request_id: 1,
    next_id: 2,
    deadline: now + 30_000,
    attachment: None,
    cut: None,
    queued: None,
    refresh_at: now,
    refresh: Idle,
    goal_refresh: Idle,
    trigger: Requested,
    delivery: Polling,
  )
}

// The issue is noted before the frame is queued, so a recording never holds
// a frame on the wire that it has no request for. A socketless lane has
// nowhere to write, so it notes the issue and queues no frame, which is
// what lets replay run the same transitions.
fn emit(
  channel: Channel(socket, recorder),
  frame: String,
) -> Channel(socket, recorder) {
  let channel = note(channel, attempt.Issued(_, channel.issued))
  case channel.socket {
    Some(socket) ->
      Channel(..channel, outbox: [Transmit(socket, frame), ..channel.outbox])
    None -> channel
  }
}

// A lane with no trace records nothing, and one with a trace queues the
// event under its own attempt identity, behind whatever it queued before.
fn note(
  channel: Channel(socket, recorder),
  event: fn(attempt.Id) -> attempt.Event,
) -> Channel(socket, recorder) {
  case channel.trace {
    Some(attempt.Trace(recorder:, id:)) ->
      Channel(..channel, outbox: [Note(recorder, event(id)), ..channel.outbox])
    None -> channel
  }
}

/// Hands over the outputs queued since the last call, oldest first.
///
/// A host's reducer calls this after every transition of the lane it holds,
/// so the outputs join the host's queue in the order they were decided. In
/// the terminal that reducer is `tui_model.hold_channel` for the adopted
/// lane, and the attachment calls it for its candidate's lane. A caller
/// that drives a channel outside a host's loop, such as a test holding a live socket, takes the outputs itself and
/// performs each as its host does; the terminal's is
/// `tui/terminal_lane.perform`.
///
/// ## Examples
///
/// ```gleam
/// let #(lane, outputs) = session_channel.take_outputs(lane)
/// list.each(outputs, terminal_lane.perform)
/// ```
pub fn take_outputs(
  channel: Channel(socket, recorder),
) -> #(Channel(socket, recorder), List(Out(socket, recorder))) {
  #(Channel(..channel, outbox: []), list.reverse(channel.outbox))
}

/// The lane's state with its host handles forgotten: no socket, no recorder
/// and nothing queued for either.
///
/// Two hosts that drove one lane through the same messages at the same
/// readings hold equal values here, whatever their sockets are, which is
/// what ADR-014's one-engine-two-views claim means for the engine; the
/// parity test between the terminal and the web view compares exactly this.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.state(web_lane) == session_channel.state(terminal_lane)
/// ```
@internal
pub fn state(channel: Channel(socket, recorder)) -> Channel(Nil, Nil) {
  Channel(
    socket: None,
    outbox: [],
    trace: None,
    issued: channel.issued,
    expected: channel.expected,
    phase: channel.phase,
    request_id: channel.request_id,
    next_id: channel.next_id,
    deadline: channel.deadline,
    attachment: channel.attachment,
    cut: channel.cut,
    queued: channel.queued,
    refresh_at: channel.refresh_at,
    refresh: channel.refresh,
    goal_refresh: channel.goal_refresh,
    trigger: channel.trigger,
    delivery: channel.delivery,
  )
}

/// Returns the selected raw socket for liveness/adoption and shutdown only.
///
/// ## Examples
///
/// ```gleam
/// // connection.adopt(session_channel.socket(channel))
/// ```
pub fn socket(channel: Channel(socket, recorder)) -> Option(socket) {
  channel.socket
}

/// Returns whether a first completed, validated cut has been obtained.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.synchronized(channel)
/// ```
pub fn synchronized(channel: Channel(socket, recorder)) -> Bool {
  channel.cut != None
}

/// Tests whether replay may adopt a completed, nonfailed initial cut.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_adoptable(lane)
/// ```
pub fn replay_adoptable(channel: Channel(socket, recorder)) -> Bool {
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
/// // session_channel.submit(channel, protocol.prompt(1, "main", "hi"), now:)
/// ```
pub fn submit(
  channel: Channel(socket, recorder),
  frame: String,
  now now: Int,
) -> #(Channel(socket, recorder), Disposition) {
  case admit(channel, frame, now) {
    Ok(#(channel, disposition)) -> #(channel, disposition)
    Error(reason) -> #(channel, DefinitelyNotSent(reason))
  }
}

fn admit(channel: Channel(socket, recorder), frame: String, now: Int) {
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
      let next = send(channel, outbound, now)
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
pub fn can_mutate(channel: Channel(socket, recorder)) -> Bool {
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
pub fn in_flight(channel: Channel(socket, recorder)) -> Bool {
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
pub fn mutation_available(channel: Channel(socket, recorder)) -> Bool {
  let available = case channel.phase {
    Ready -> True
    AwaitingBegin
    | Receiving(..)
    | AwaitingReply(_, Read)
    | AwaitingReply(_, Lookup(_))
    | AwaitingReply(_, Listing)
    | AwaitingReply(_, Lineage(..))
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
pub fn has_unsent(channel: Channel(socket, recorder)) -> Bool {
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
  channel: Channel(socket, recorder),
  reason: String,
) -> #(Channel(socket, recorder), List(Update)) {
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
/// // session_channel.receive(channel, incoming, now:)
/// ```
pub fn receive(
  channel: Channel(socket, recorder),
  message: connection_event.Message,
  now now: Int,
) -> #(Channel(socket, recorder), List(Update)) {
  // Every message is noted before it is reduced, so its note precedes
  // anything the message makes the lane send, including a close.
  let channel = note(channel, attempt.Received(_, message))

  case message {
    connection_event.Connected -> #(channel, [])

    // A socket reports its end more than once: a network fault is usually
    // followed by the transport's own close. The first report fails the
    // lane; a later one finds it `Closed` and has nothing left to end, so it
    // neither queues a second close nor tells the operator twice.
    connection_event.Closed(reason) | connection_event.NetworkFault(reason) ->
      case channel.phase {
        Closed -> #(channel, [])
        AwaitingBegin | Receiving(..) | AwaitingReply(..) | Ready ->
          fail(channel, reason)
      }
    connection_event.Incoming(text) ->
      case channel.phase {
        Closed -> #(channel, [])

        // A ready lane has no outstanding request, so the only frame it can
        // read is one the daemon volunteered. A correlated reply here names a
        // request that is already finished, and an undecodable frame is not
        // one the lane may quietly ignore; both close the socket, exactly as
        // every incoming frame in this phase did before pushes existed.
        Ready ->
          case session_wire.decode(text, channel.request_id) {
            Ok(session_wire.Pushed(event)) -> apply_pushed(channel, event, now)
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
            Ok(session_wire.Pushed(event)) -> apply_pushed(channel, event, now)
            Ok(reply) -> apply_reply(channel, reply, now)
          }
      }
  }
}

// Every pushed frame, of whatever kind, is the evidence `Delivery` waits
// for, so the switch to `Pushing` happens before the frame is dispatched,
// including for a kind this client drops. The switch moves no deadline and
// no refresh instant already set: the next capture is the first to be
// followed by the longer refresh.
fn apply_pushed(
  channel: Channel(socket, recorder),
  event: protocol.Event,
  now: Int,
) {
  let channel = Channel(..channel, delivery: Pushing)
  case event {
    protocol.Committed(strand: _, seq:) -> notified(channel, seq, now)

    // The write notification cannot be spent by an older in-flight read.
    // Only the read issued after this notification consumes the debt.
    protocol.GoalChanged -> {
      let invalidated = Channel(..channel, goal_refresh: Due)
      case channel.phase {
        Ready -> send_queued(invalidated, [], now)
        AwaitingBegin | Receiving(..) | AwaitingReply(..) | Closed -> #(
          invalidated,
          [],
        )
      }
    }

    // Presence and attachment carry nothing renderable; what they say is
    // that the next capture differs, which is what a notice says too. A
    // peer's configuration change arrives as the configuration board the
    // daemon pushes to every other subscriber, and says the same thing:
    // the cut's configuration moved. Before the refresh slowed to five
    // seconds on a pushing lane, dropping it cost at most 250 ms; now it
    // is the only prompt a peer's lane gets.
    protocol.MetadataChanged | protocol.ConfigSnapshot(..) ->
      capture_or_defer(channel, now)
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
    // correlated error is, and the socket stays open. A custody return rides
    // the same lane: it is pushed, it answers nothing, and the terminal is
    // the only place the returned draft can be restored. A usage row is the
    // same kind of fact — pushed live state that no cut is required to
    // carry — so the terminal folds it into its own watch and settlement
    // figures now rather than at the next capture.
    //
    // A summarizer label is live display state of the same kind: the settled
    // one's cell is in no cut, and the live one is stored nowhere.
    protocol.ServerError(..)
    | protocol.HeldInputReturned(..)
    | protocol.WorktreeSnapshot(_)
    | protocol.ContextSnapshot(_)
    | protocol.UsageChanged(..)
    | protocol.BlockSummarized(..) -> #(channel, [
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
    | protocol.AdvisorPendingSnapshot(..)
    | protocol.BlockSummariesSnapshot(..)
    | protocol.GoalSnapshot(..)
    | protocol.SchedulesSnapshot(..)
    | protocol.PermissionsSnapshot(..)
    | protocol.ProfileSnapshot(..)
    | protocol.EntryAdded(..)
    | protocol.OperationChanged(..)
    | protocol.EscalationPending(..)
    | protocol.Resumed(_)
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
fn notified(channel: Channel(socket, recorder), seq: Int, now: Int) {
  let #(channel, updates) = case channel.cut {
    Some(cut) if seq < cut.next_seq -> #(channel, [])
    Some(_) | None -> capture_or_defer(channel, now)
  }
  #(channel, [Noticed(seq), ..updates])
}

// A push that arrives before any cut exists says nothing the initial
// transfer will not deliver, so it is dropped here for every kind of trigger
// rather than deferred into a redundant second catch-up.
fn capture_or_defer(channel: Channel(socket, recorder), now: Int) {
  case channel.phase, channel.cut {
    Ready, Some(cut) -> #(
      capture_again(
        Channel(..channel, refresh: Idle),
        cut.next_seq,
        Notified,
        now,
      ),
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

fn apply_reply(
  channel: Channel(socket, recorder),
  reply: session_wire.Reply,
  now: Int,
) {
  case channel.phase, reply {
    // A resumed marker is the subscribe slot's own answer: the server accepted
    // the cursor this lane named and is continuing from it. Everything the
    // transcript shows before that cursor came from the cut the lane already
    // holds, so nothing is captured here and the phase moves straight to
    // `Ready`. The cursor deliberately stays where that cut ended rather than
    // moving up to the marker's `next_seq`: the replayed events which follow
    // arrive as pushes, and the lane's own catch-up turns them into a bounded
    // captured cut. A marker answering a request that named no cursor is a
    // lane this client never built, and it fails closed.
    AwaitingBegin, session_wire.Presentation(protocol.Resumed(_)) ->
      case channel.issued.selection {
        attempt.Cursor(_) -> #(
          Channel(..channel, phase: Ready, refresh: Due),
          [],
        )
        attempt.NoSelection
        | attempt.Decisions(_)
        | attempt.DecidedList
        | attempt.HistoryRange(..)
        | attempt.LineageFrom(..)
        | attempt.Credit(..) ->
          fail(channel, "resumed marker answers a request that asked for none")
      }

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
    AwaitingReply(_, Listing), session_wire.Begin(body) -> {
      let from_seq = case channel.cut {
        Some(cut) -> cut.next_seq
        None -> 0
      }
      case
        snapshot.begin_decided(
          body,
          channel.expected,
          channel.attachment,
          from_seq,
        )
      {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(credit(channel, transfer, Decided), [])
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
    AwaitingReply(_, Lineage(from)), session_wire.Begin(body) -> {
      let started = {
        use _ <- result.try(matching_window(body, "lineage"))
        snapshot.begin_lineage(body, channel.expected, channel.attachment, 1)
      }
      case started {
        Error(reason) -> fail(channel, reason)
        Ok(transfer) -> #(credit(channel, transfer, Lineaged(from)), [])
      }
    }
    Receiving(transfer, Lineaged(from)), session_wire.End(body) -> {
      let completed = {
        use cut <- result.try(snapshot.finish(transfer, body))

        // The newest record of the page is the entry that was asked about, or
        // there is no record: the store holds nothing at that entry below the
        // cut. Anything else is a page of another read.
        case cut.window.items {
          [] -> Ok(cut.window)
          [newest, ..] ->
            case snapshot.identity(newest) == from {
              True -> Ok(cut.window)
              False -> Error("lineage page does not begin at its entry")
            }
        }
      }
      case completed {
        Error(reason) -> fail(channel, reason)
        Ok(window) ->
          send_queued(
            Channel(..channel, phase: Ready, refresh_at: now),
            [LineagePage(window, from)],
            now,
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
            Channel(..channel, phase: Ready, refresh_at: now),
            [HistoryPage(window, before, after)],
            now,
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
            Channel(..channel, phase: Ready, refresh_at: now),
            [LookedUp(records, missing)],
            now,
          )
      }
    }
    Receiving(transfer, Decided), session_wire.End(body) -> {
      let resolved = {
        use cut <- result.try(snapshot.finish(transfer, body))
        use cells <- result.try(snapshot_view.decided(cut))
        approval.records(cells)
      }
      case resolved {
        Error(reason) -> fail(channel, reason)
        Ok(records) ->
          send_queued(
            Channel(..channel, phase: Ready, refresh_at: now),
            [LookedUp(records, [])],
            now,
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
              refresh_at: now + refresh_interval(channel.delivery),
            )
          send_queued(channel, [Captured(cut, view, channel.trigger)], now)
        }
      }

    // A correlated reply answers the one request this channel issued, so a
    // host may read Acknowledged and RequestRefused as its own command's
    // outcome; the web view's notice relies on that.
    AwaitingReply(name, Mutation), session_wire.Mutation(status) -> {
      let channel = Channel(..channel, phase: Ready, refresh_at: now)
      send_queued(channel, [Acknowledged(name, status)], now)
    }
    AwaitingReply(name, _),
      session_wire.Presentation(protocol.ServerError(code, message))
    ->
      send_queued(
        Channel(..channel, phase: Ready),
        [RequestRefused(name, channel.request_id, code, message)],
        now,
      )
    AwaitingReply(name, intent), session_wire.Presentation(event) ->
      case matching_presentation(name, intent, event) {
        True ->
          send_queued(Channel(..channel, phase: Ready), [Auxiliary(event)], now)
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
    "advisor_pending", Read, protocol.AdvisorPendingSnapshot(_) -> True
    "block_summaries", Read, protocol.BlockSummariesSnapshot(_) -> True
    "goal_get", Read, protocol.GoalSnapshot(_) -> True

    // A goal mutation answers with the fresh board rather than a bare
    // `committed`, the way `schedule_cancel` answers with the schedule
    // listing: the panel's new state is what the operator asked for, and a
    // second read would show it a round trip later.
    "goal_set", Mutation, protocol.GoalSnapshot(_) -> True
    "goal_check", Mutation, protocol.GoalSnapshot(_) -> True
    "goal_clear", Mutation, protocol.GoalSnapshot(_) -> True
    "goal_pause", Mutation, protocol.GoalSnapshot(_) -> True
    "goal_resume", Mutation, protocol.GoalSnapshot(_) -> True

    "schedules", Read, protocol.SchedulesSnapshot(_) -> True

    // A profile switch answers with the profile it saved, as a goal mutation
    // answers with its board: the operator is told what was saved and how many
    // strands moved, and the session closes the connection when it restarts.
    "profile_get", Read, protocol.ProfileSnapshot(..) -> True
    "profile_set", Mutation, protocol.ProfileSnapshot(..) -> True
    "schedule_cancel", Mutation, protocol.SchedulesSnapshot(_) -> True

    // A forget answers with the permissions that remain, as a goal mutation
    // answers with its board, so the page redraws from the one reply.
    "permissions", Read, protocol.PermissionsSnapshot(_) -> True
    "permission_forget", Mutation, protocol.PermissionsSnapshot(_) -> True
    _, _, _ -> False
  }
}

fn credit(
  channel: Channel(socket, recorder),
  transfer: snapshot.Transfer,
  lookup,
) {
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
}

/// Drives the idle catch-up and fails an expired in-flight request closed.
///
/// An idle lane with a cut captures again once its refresh instant has
/// passed, which is `polling_refresh_ms` or `pushing_refresh_ms` after its
/// last capture completed, by the lane's `Delivery`. An in-flight request
/// fails the lane at its deadline. Capture credit does not reset the
/// original thirty-second transfer deadline. The enclosing Weft switch task
/// separately bounds initial candidate lifetime.
///
/// A tick at any other time does nothing, so a host may tick as often as it
/// likes; `next_due` says when a tick is next able to act.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.tick(channel, now:)
/// ```
pub fn tick(
  channel: Channel(socket, recorder),
  now now: Int,
) -> #(Channel(socket, recorder), List(Update)) {
  case channel.phase {
    Closed -> #(channel, [])
    AwaitingBegin | Receiving(..) | AwaitingReply(..) ->
      case now >= channel.deadline {
        True -> fail(channel, "conversation request timed out")
        False -> #(channel, [])
      }
    Ready ->
      case channel.cut {
        Some(cut) if channel.refresh_at <= now -> {
          let next = capture_again(channel, cut.next_seq, Refreshed, now)
          #(next, [])
        }
        Some(_) | None -> #(channel, [])
      }
  }
}

/// The earliest reading at which `tick` would act on this lane, or `None`
/// when no tick can act until something else happens to it.
///
/// While a request is in flight this is its deadline, at which `tick` fails
/// the lane. While the lane is ready with a cut it is the refresh instant,
/// at which `tick` issues the catch-up. A lane with no cut, or a closed one,
/// has nothing a tick could do: the first waits for its initial reply,
/// which arrives as a frame, and the second is finished.
///
/// A host arms one wake-up for this reading instead of ticking on a fixed
/// cadence. The contract is exact in both directions: `tick` at any reading
/// before the one returned changes nothing, and `tick` at the reading
/// returned acts. A host that wakes late acts late, and never misses the
/// deadline or the refresh, because `tick` compares with `>=`. The answer
/// changes with every transition, so a host asks again after each one.
///
/// ## Examples
///
/// ```gleam
/// let lane = session_channel.start(socket, expected, now: 1000)
/// assert session_channel.next_due(lane) == Some(31_000)
/// ```
pub fn next_due(channel: Channel(socket, recorder)) -> Option(Int) {
  case channel.phase, channel.cut {
    AwaitingBegin, _ | Receiving(..), _ | AwaitingReply(..), _ ->
      Some(channel.deadline)
    Ready, Some(_) -> Some(channel.refresh_at)
    Ready, None | Closed, _ -> None
  }
}

// The idle refresh interval a lane uses after a capture, by what it has
// seen of its daemon.
fn refresh_interval(delivery: Delivery) -> Int {
  case delivery {
    Polling -> polling_refresh_ms
    Pushing -> pushing_refresh_ms
  }
}

/// Closes one channel without treating a close cast as transitive retirement.
///
/// ## Examples
///
/// The close is queued, like every other output: the returned channel
/// carries it until `take_outputs`. The lane is `Closed` from here on, so no
/// later transition in the same step can queue a write behind its close.
///
/// ```gleam
/// let lane = session_channel.close(lane)
/// ```
pub fn close(channel: Channel(socket, recorder)) -> Channel(socket, recorder) {
  case channel.phase {
    // A lane is closed once. A quit after a transport failure reaches a lane
    // that `fail` already closed, and a second `Shut` or a second recorded
    // close would describe an event that did not happen.
    Closed -> channel
    AwaitingBegin | Receiving(..) | AwaitingReply(..) | Ready ->
      Channel(..channel, phase: Closed, queued: None)
      |> note(attempt.Closed)
      |> close_socket
  }
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
pub fn retire(
  channel: Channel(socket, recorder),
  reason: String,
) -> #(Channel(socket, recorder), List(Update)) {
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

// The outcome is read from the lane as it stood, because closing it is what
// ends the request that was in flight.
fn fail(channel: Channel(socket, recorder), reason: String) {
  let updates = case channel.phase {
    AwaitingReply(name, Mutation) -> [
      UnknownOutcome(name, channel.request_id),
      Failed(reason),
    ]
    AwaitingReply(_, Read)
    | AwaitingReply(_, Lookup(_))
    | AwaitingReply(_, Listing)
    | AwaitingReply(_, Lineage(..))
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
  #(close(channel), list.append(unsent, updates))
}

fn close_socket(
  channel: Channel(socket, recorder),
) -> Channel(socket, recorder) {
  case channel.socket {
    Some(socket) -> Channel(..channel, outbox: [Shut(socket), ..channel.outbox])
    None -> channel
  }
}

/// Records adoption only after the terminal commits the validated replacement.
///
/// The note is queued on the lane like its other outputs; the caller moves
/// it into the step's queue when it stores the lane.
///
/// ## Examples
///
/// ```gleam
/// let lane = session_channel.adopted(lane)
/// ```
pub fn adopted(
  channel: Channel(socket, recorder),
) -> Channel(socket, recorder) {
  note(channel, attempt.Adopted)
}

fn capture_again(
  channel: Channel(socket, recorder),
  cursor,
  trigger: Capture,
  now: Int,
) {
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
      deadline: now + 30_000,
    )
  emit(next, session_wire.catch_up(channel.next_id, cursor))
}

/// Validates a recorded request against the effect-free channel's next credit.
///
/// Only a ready lane can begin another command. Credit generated by a previous
/// frame must exactly match its recorded marker before that response is read.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.replay_issued(lane, request, now: 0)
/// ```
pub fn replay_issued(
  channel: Channel(socket, recorder),
  request: attempt.Request,
  now now: Int,
) -> Result(Channel(socket, recorder), String) {
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
          Ok(capture_again(channel, cursor, Refreshed, now))
        Some(_) | None ->
          Error("recorded catch-up cursor does not match the adopted cut")
      }
    Ready, attempt.Decisions(ids) -> lookup(channel, ids, now)
    Ready, attempt.DecidedList -> decided(channel, now)
    Ready, attempt.HistoryRange(after, before) ->
      history(channel, after, before, now)
    Ready, attempt.LineageFrom(entry) -> lineage(channel, entry, now)
    Ready, attempt.NoSelection ->
      admit(channel, session_wire.command(1, request.kind, []), now)
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
/// // session_channel.lookup(channel, ["approval-id"], now:)
/// ```
pub fn lookup(
  channel: Channel(socket, recorder),
  ids: List(String),
  now now: Int,
) -> Result(Channel(socket, recorder), String) {
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
    Ready, None -> Ok(send(channel, outbound, now))
    _, None -> Ok(Channel(..channel, queued: Some(outbound)))
    _, Some(_) -> Error("one read is already queued")
  }
}

/// Requests the session's newest decided approvals without moving the main
/// cursor, so a page that opened after a decision can draw its row.
///
/// The read is sent only to a synchronized lane with nothing out and nothing
/// queued, and is never queued itself: a queued read would hold the lane's
/// one queue slot, and an operator's first command would be refused behind
/// a read the operator never asked for. A busy lane returns the reason, and
/// the caller asks again at its next opportunity.
/// The answer arrives as `LookedUp(records, [])`, the update an exact lookup
/// produces, and is folded the same way, so a decision the page also saw
/// live is one record in the ledger, keyed by the escalation's identity.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.decided(channel, now:)
/// ```
pub fn decided(
  channel: Channel(socket, recorder),
  now now: Int,
) -> Result(Channel(socket, recorder), String) {
  use <- bool.guard(
    !ready_for_read(channel),
    Error("conversation read lane is busy"),
  )
  use outbound <- result.try(
    outbound(session_wire.command(1, "escalations_decided", [])),
  )
  Ok(send(channel, Outbound(..outbound, intent: Listing), now))
}

/// Reads at most one hundred older sequence positions on the existing lane.
///
/// The bounds are exclusive. The result cannot replace live metadata or the
/// catch-up cursor, and a busy lane leaves the request with its caller.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.history(channel, 100, 201, now:)
/// ```
@internal
pub fn history(
  channel: Channel(socket, recorder),
  after: Int,
  before: Int,
  now now: Int,
) -> Result(Channel(socket, recorder), String) {
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
  Ok(send(channel, Outbound(..outbound, intent: History(after, before)), now))
}

/// Reads at most one hundred records of one strand's ancestry on the existing
/// lane: the entry `from` and the records below it down their parent links,
/// and nothing another strand wrote between them.
///
/// A strand is named by its newest record, and a page below one already held
/// by the parent of its oldest record, so the read carries no cursor of its own
/// (protocol-change/072). Like `history` it cannot replace live metadata or the
/// catch-up cursor, and a busy lane leaves the request with its caller.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.lineage(channel, "0198...", now:)
/// ```
@internal
pub fn lineage(
  channel: Channel(socket, recorder),
  from: String,
  now now: Int,
) -> Result(Channel(socket, recorder), String) {
  use <- bool.guard(
    result.is_error(ids.parse_entry_id(from)),
    Error("lineage requires an entry identity"),
  )
  use <- bool.guard(
    !ready_for_read(channel),
    Error("conversation read lane is busy"),
  )
  use outbound <- result.try(
    outbound(
      session_wire.command(1, "history_lineage", [#("from", json.String(from))]),
    ),
  )
  Ok(send(channel, Outbound(..outbound, intent: Lineage(from)), now))
}

// Every transition back to `Ready` passes through here, so this is the one
// place a deferred notice can be spent. A waiting local command still goes
// first: it keeps the lane busy, and the notice survives to the transition
// after that one.
// Reply updates settle the old owner before any newly issued request installs
// another. Queued operator intent wins the slot; goal debt and transcript debt
// remain due if that intent uses it. List order here is reducer order in both hosts.
fn send_queued(
  channel: Channel(socket, recorder),
  updates: List(Update),
  now: Int,
) {
  let #(channel, updates) = flush_queued(channel, updates, now)
  let #(channel, updates) = read_changed_goal(channel, updates, now)
  case channel.phase, channel.refresh, channel.cut {
    Ready, Due, Some(cut) -> #(
      capture_again(
        Channel(..channel, refresh: Idle),
        cut.next_seq,
        Notified,
        now,
      ),
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

// A held command keeps its original body, but uses the latest attachment
// authority after reconciliation. Clearing queued before send gives this
// issuance one owner and prevents later read servicing from issuing it again.
fn flush_queued(
  channel: Channel(socket, recorder),
  updates: List(Update),
  now: Int,
) {
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
          let sent = send(cleared, outbound, now)
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

// An invalidation is spent only when its read is issued. A notification
// arriving during that read survives its reply and requests a newer board.
// The host must know this read's ID to accept its refusal. Its sent update
// follows the older reply's updates so that reply cannot clear the new owner.
fn read_changed_goal(
  channel: Channel(socket, recorder),
  updates: List(Update),
  now: Int,
) {
  case channel.phase, channel.goal_refresh {
    Ready, Due -> {
      // Due becomes Idle at issuance, not at a successful board. A later
      // notice can therefore restore Due while this read is outstanding.
      let sent =
        send(
          Channel(..channel, goal_refresh: Idle),
          Outbound(
            "goal_get",
            "\"goal_get\"" <> session_wire.command_body <> "{}}",
            Read,
          ),
          now,
        )

      // Keep the older board or refusal first: applying it after this Sent
      // would erase the new goal_request in the shared surface reducer.
      #(
        sent,
        list.append(updates, [Submission(Sent("goal_get", sent.request_id))]),
      )
    }
    _, _ -> #(channel, updates)
  }
}

fn send(channel: Channel(socket, recorder), outbound: Outbound, now: Int) {
  let frame =
    session_wire.command_prefix
    <> int.to_string(channel.next_id)
    <> session_wire.command_tag
    <> outbound.suffix
  let selection = case outbound.intent {
    Lookup(ids) -> attempt.Decisions(ids)
    Listing -> attempt.DecidedList
    History(after, before) -> attempt.HistoryRange(after, before)
    Lineage(from) -> attempt.LineageFrom(from)
    Read | Mutation -> attempt.NoSelection
  }
  let next =
    Channel(
      ..channel,
      issued: attempt.Request(channel.next_id, outbound.name, selection),
      phase: AwaitingReply(outbound.name, outbound.intent),
      request_id: channel.next_id,
      next_id: channel.next_id + 1,
      deadline: now + 10_000,
    )
  emit(next, frame)
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
      let intent = case is_read(name) {
        True -> Read
        False -> Mutation
      }
      Ok(Outbound(name, suffix, intent))
    }
    _ -> Error("invalid generated command name")
  }
}

/// Whether a command name is one of the auxiliary reads, which a host
/// issues on its own account and which answer with a snapshot, rather than
/// a command an operator asked for.
///
/// The history read is not among them: it has its own request and its own
/// window.
///
/// ## Examples
///
/// ```gleam
/// assert session_channel.is_read("notes")
/// assert !session_channel.is_read("prompt")
/// ```
pub fn is_read(command: String) -> Bool {
  case command {
    "models"
    | "skills"
    | "schedules"
    | "profile_get"
    | "permissions"
    | "notes"
    | "queued_input"
    | "context"
    | "worktree_diff"
    | "live_jobs"
    | "advisor_pending"
    | "block_summaries"
    | "goal_get" -> True
    _ -> False
  }
}

/// Admits auxiliary reads only after retained mutations and captures finish.
///
/// ## Examples
///
/// ```gleam
/// // session_channel.ready_for_read(channel)
/// ```
pub fn ready_for_read(channel: Channel(socket, recorder)) -> Bool {
  channel.phase == Ready && channel.queued == None && synchronized(channel)
}
