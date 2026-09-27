//// The web view's host for one session: a Lustre server component that
//// drives `session_view`'s lane and draws the session's transcript lines
//// as HTML.
////
//// The component is the lane's host in the sense ADR-014 gives the word. It
//// reads what the engine may not read (a clock, a mailbox) and delivers it as
//// messages, and it performs the lane's outputs. It holds no session logic of
//// its own: which frames to send, what a reply means, when to catch up,
//// which lines a capture becomes and what an operator's input becomes on the
//// wire are all `session_view`'s, exactly as they are for the terminal. What
//// is web-specific here is the delivery (a Lustre selector instead of an
//// etui tick) and the view (HTML elements instead of terminal cells).
////
//// Delivery keeps ADR-013's option C. A frame from the transport arrives as
//// `Arrived` and is only filed, into the engine's `session_view/inbox`. A
//// 250 ms timer delivers `Ticked` with the clock reading taken when the
//// timer message was received, and only then is every filed frame handed to
//// the lane, oldest first, through `operator.drain`, the loop the terminal
//// runs too, followed by the lane's own `tick`. A frame therefore never
//// changes what the page shows until a tick reduces it, which is the
//// terminal's discipline too.
////
//// The transport is supplied by the host that starts the component, because
//// what a socket is belongs to that host. In the daemon it is a relay into
//// the session's gateway (`client/daemon/ui_relay`); in a test it is
//// whatever the test hands in. Opening it may take as long as the gateway's
//// attach, which is longer than Lustre's one-second start budget, so the
//// transport opens asynchronously: `connect` returns at once and answers on
//// a subject the component selects. The interpreter for the lane's outputs
//// has the terminal's shape: `Transmit` writes a frame through the
//// transport and `Shut` closes it, in the order the lane decided them, in
//// one effect. The component has no recorder, so its recorder type is `Nil`
//// and it never queues a note.
////
//// This module is the observer's application, and its message type carries
//// no command: a browser has nothing it can send it, since its view attaches
//// no event handler. An operator's page is `web_view/operator_page`, which
//// wraps these messages with the two commands an operator may send and
//// reaches the lane through `submit` and `decide` here, which call the
//// engine's command arms.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/server_component
import session_view/approval
import session_view/connection_event
import session_view/inbox.{type Inbox}
import session_view/operator
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript
import session_view/transcript_line.{type Line}

/// How often the component reduces what arrived, in milliseconds.
///
/// The lane's own idle refresh and deadlines are measured against the
/// readings these ticks carry, so this is also the cadence at which the lane
/// can notice that a catch-up is due. It matches the terminal's poll.
pub const tick_ms = 250

/// The strand the page shows and addresses.
pub const strand = "main"

/// The most bytes of prompt text the page submits. The page socket's frame
/// limit bounds a whole message; this bounds the field inside it, so a
/// draft over it is refused with a notice before it becomes a command.
pub const prompt_limit = 262_144

/// What the host that starts the component supplies: the session it is
/// for, and the transport the lane's frames travel over.
pub type Start(socket) {
  Start(
    /// The canonical session identity, shown in the page's heading.
    session_id: String,
    /// The attachment the lane must see on every captured cut. A cut for
    /// another session, epoch or incarnation fails the lane rather than
    /// being drawn.
    expected: snapshot.Expected,
    /// The host's transport.
    transport: Transport(socket),
  )
}

/// The host's transport and clock.
///
/// Every function runs in the component's own process, which owns the
/// subjects `connect` is handed, so a reply is always read by the process
/// that created the subject it arrives on.
pub type Transport(socket) {
  Transport(
    /// Starts opening the connection and returns at once. Frames go to
    /// `inbox` as `connection_event.Message`s, and the outcome of the open
    /// is sent to `opened`, once: the handle the lane writes to, or why the
    /// connection was refused. It must not block, because it runs inside
    /// the component's start, which Lustre bounds at one second.
    connect: fn(
      Subject(connection_event.Message),
      Subject(Result(socket, String)),
    ) -> Nil,
    /// Writes one frame. It must not block on the peer.
    transmit: fn(socket, String) -> Nil,
    /// Closes the connection.
    shut: fn(socket) -> Nil,
    /// A monotonic reading in milliseconds, for the lane's deadlines.
    now: fn() -> Int,
  )
}

/// What the page says about the connection.
pub type Status {
  /// The transport is opening, or the first cut has not arrived.
  Connecting

  /// At least one validated cut has been drawn.
  Following

  /// The connection ended, and the last drawn cut stays on the page.
  Ended(reason: String)
}

/// What the page last told an operator about their own input. Its text is
/// the component's own or the engine's, never the session's.
pub type Notice {
  /// Nothing to say.
  Quiet

  /// An outcome worth stating, such as a prompt that was sent.
  Said(text: String)

  /// A refusal or a loss the operator should read.
  Warned(text: String)
}

/// Whether the page's strand is running an operation.
pub type Activity {
  /// Nothing is running: a draft is sent as a prompt.
  Idle

  /// An operation is running: a draft is queued behind it or steers it.
  Busy
}

/// An operator's answer that the page offers. Remembering a grant for the
/// session is not offered from a page (protocol-change/051, the operator
/// addendum), so it is not a value this type can hold.
pub type Answer {
  /// Grant the displayed authority for this one request.
  AllowOnce

  /// Refuse the request.
  Deny
}

/// The component's state: the lane, the frames filed since the last tick,
/// the last completed capture and what was derived from it.
pub opaque type Model(socket) {
  Model(
    session_id: String,
    expected: snapshot.Expected,
    transport: Transport(socket),
    /// `None` until the transport has opened.
    lane: Option(session_channel.Channel(socket, Nil)),
    /// Frames filed since the last tick, oldest first. The component has
    /// one source, so its source is `Nil`.
    filed: Inbox(Nil, connection_event.Message),
    /// The last `Captured` update.
    shown: Option(#(snapshot.Captured, snapshot_view.View)),
    /// The transcript rows of `shown`, projected once when it arrived so
    /// that a message which changed nothing costs the view no projection.
    rows: List(transcript.Row),
    /// The escalations of `shown`, and the settled ones kept beside them.
    approvals: List(approval.Review),
    status: Status,
    /// The latest clock reading a message carried, which a command takes
    /// its deadline from.
    clock: Int,
    /// The timer's subject, once the tick selector is armed.
    timer: Option(Subject(Nil)),
    /// What the page last told the operator.
    notice: Notice,
    /// The command counter an operator's commands are encoded with.
    next_id: Int,
    /// How many drafts have been sent. The composer's editor is keyed by
    /// it, so a sent draft is replaced by an empty editor while a refused
    /// one stays as the operator left it.
    drafts: Int,
  )
}

/// Everything the component can be told.
pub type Msg(socket) {
  /// The transport opened, at this monotonic reading.
  Opened(socket: socket, at: Int)

  /// The transport refused to open.
  Refused(reason: String)

  /// The tick selector is armed on this subject.
  TimerArmed(timer: Subject(Nil))

  /// One frame from the transport, filed and not yet reduced.
  Arrived(message: connection_event.Message)

  /// The timer fired, at this monotonic reading. Reduction happens here.
  Ticked(at: Int)
}

/// The Lustre application for one session's observer page.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(component.app(), start)
/// ```
pub fn app() -> lustre.App(Start(socket), Model(socket), Msg(socket)) {
  lustre.application(init, update, view)
}

/// A component for `start`, before the transport opens: `init` without its
/// effects, for a test that drives the component through `simulate`.
///
/// ## Examples
///
/// ```gleam
/// // simulate.application(fn(s) { #(component.new(s), effect.none()) }, ..)
/// ```
pub fn new(start: Start(socket)) -> Model(socket) {
  Model(
    session_id: start.session_id,
    expected: start.expected,
    transport: start.transport,
    lane: None,
    filed: inbox.new(Nil),
    shown: None,
    rows: [],
    approvals: [],
    status: Connecting,
    clock: 0,
    timer: None,
    notice: Quiet,
    next_id: 1,
    drafts: 0,
  )
}

/// The component's first state and the two subscriptions it runs for its
/// life: the connection, and the tick.
///
/// ## Examples
///
/// ```gleam
/// // lustre.application(component.init, component.update, component.view)
/// ```
pub fn init(start: Start(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  let model = new(start)
  #(model, effect.batch([open(start.transport), arm(start.transport)]))
}

// Opens the transport inside the component's process, once. The inbox and
// the subject the outcome arrives on are both created here, in the
// component's process, so every frame and the open's answer are read by
// the process that owns them. `connect` returns at once; the answer is a
// message, so a slow gateway attach cannot hold the component's start.
// The clock is read when the answer is received, in the mapping, which is
// host code.
fn open(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use _dispatch, opened <- server_component.select
  let inbox = process.new_subject()
  transport.connect(inbox, opened)
  process.new_selector()
  |> process.select_map(opened, fn(outcome) {
    case outcome {
      Ok(socket) -> Opened(socket, transport.now())
      Error(reason) -> Refused(reason)
    }
  })
  |> process.select_map(inbox, Arrived)
}

// Arms the tick. The clock is read when the timer message is received, which
// is host code, so the reading `Ticked` carries is the instant of the tick.
fn arm(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use dispatch, timer <- server_component.select
  dispatch(TimerArmed(timer))
  process.send_after(timer, tick_ms, Nil)
  process.new_selector()
  |> process.select_map(timer, fn(_) { Ticked(transport.now()) })
}

/// Applies one message.
///
/// ## Examples
///
/// ```gleam
/// // let #(model, effect) = component.update(model, component.Ticked(250))
/// ```
pub fn update(
  model: Model(socket),
  message: Msg(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case message {
    Opened(socket:, at:) -> {
      let lane = session_channel.start(socket, model.expected, now: at)
      let #(lane, outputs) = session_channel.take_outputs(lane)
      #(
        Model(..model, lane: Some(lane), clock: at),
        perform(model.transport, outputs),
      )
    }

    Refused(reason:) -> #(Model(..model, status: Ended(reason)), effect.none())

    TimerArmed(timer:) -> #(Model(..model, timer: Some(timer)), effect.none())

    // Option C: an arrival is filed and nothing else happens. The page
    // cannot change until the next tick reduces it.
    Arrived(message:) -> #(
      Model(..model, filed: inbox.push(model.filed, message)),
      effect.none(),
    )

    Ticked(at:) -> tick(Model(..model, clock: at), at)
  }
}

// Every filed frame goes to the lane in arrival order, then the lane's own
// tick runs, which is where its idle refresh and deadlines are checked. A
// tick before the transport opens keeps what was filed for the next one.
fn tick(
  model: Model(socket),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.lane {
    None -> #(model, rearm(model.timer))
    Some(_) -> {
      let model = drained(model)
      case model.lane {
        None -> #(model, rearm(model.timer))
        Some(lane) -> {
          let #(lane, ticked) = session_channel.tick(lane, now: at)
          let #(lane, outputs) = session_channel.take_outputs(lane)
          let model = apply(Model(..model, lane: Some(lane)), ticked)
          #(
            model,
            effect.batch([perform(model.transport, outputs), rearm(model.timer)]),
          )
        }
      }
    }
  }
}

// Hands every filed frame to the lane, oldest first, through the engine's
// drain. The lane's outputs stay queued on it until the caller takes them,
// so a command submitted after the drain leaves behind them, in order.
fn drained(model: Model(socket)) -> Model(socket) {
  operator.drain(model, inbox.held(model.filed), take_filed, received)
}

fn take_filed(
  model: Model(socket),
) -> #(Model(socket), Result(connection_event.Message, Nil)) {
  let #(filed, next) = inbox.take(model.filed)
  #(Model(..model, filed:), next)
}

fn received(
  model: Model(socket),
  message: connection_event.Message,
) -> Model(socket) {
  case model.lane {
    None -> model
    Some(lane) -> {
      let #(lane, updates) =
        session_channel.receive(lane, message, now: model.clock)
      apply(Model(..model, lane: Some(lane)), updates)
    }
  }
}

/// Folds the lane's updates into the component: a capture is projected
/// once, here, into the rows the view draws and the escalations it offers;
/// a submission's outcome becomes the notice; a failure ends the page.
///
/// ## Examples
///
/// ```gleam
/// // component.apply(model, updates)
/// ```
@internal
pub fn apply(
  model: Model(socket),
  updates: List(session_channel.Update),
) -> Model(socket) {
  list.fold(updates, model, fn(model, update) {
    case update {
      session_channel.Captured(cut:, view:, ..) ->
        Model(
          ..model,
          shown: Some(#(cut, view)),
          rows: transcript.project_rows(cut, view, strand),
          approvals: case approval.records(view.cells) {
            Ok(current) -> approval.project(model.approvals, current)
            Error(_) -> []
          },
          status: Following,
        )
      session_channel.Failed(reason:) -> Model(..model, status: Ended(reason))
      session_channel.Submission(disposition:) -> settled(model, disposition)
      session_channel.UnknownOutcome(..) ->
        Model(
          ..model,
          notice: Warned(
            "The daemon's reply to your last command was lost. It was not resent.",
          ),
        )
      session_channel.HistoryPage(..)
      | session_channel.LookedUp(..)
      | session_channel.Auxiliary(..)
      | session_channel.RequestRefused(..)
      | session_channel.Streamed(..)
      | session_channel.ToolStreamed(..)
      | session_channel.Noticed(..)
      | session_channel.Acknowledged(..) -> model
    }
  })
}

// What the lane's answer to a submission means for the page. A sent draft
// leaves the composer, by a new key on its editor; a waiting one stays until
// the lane sends it after the next capture; a refused one stays where the
// operator can edit it.
fn settled(
  model: Model(socket),
  disposition: session_channel.Disposition,
) -> Model(socket) {
  case disposition {
    session_channel.Sent(command:, ..) ->
      Model(..model, drafts: model.drafts + 1, notice: Said(command <> " sent"))
    session_channel.Waiting(_) ->
      Model(
        ..model,
        notice: Said("Waiting for the session to synchronize before sending."),
      )
    session_channel.DefinitelyNotSent(reason:) ->
      Model(..model, notice: Warned("Not sent: " <> reason))
  }
}

/// Submits an operator's text to the page's strand through the engine's
/// command arm, after handing the lane what was already filed, as the
/// terminal drains before it acts on a key.
///
/// Empty text and text over `prompt_limit` are refused with a notice
/// before they become a command. What the lane decides is folded back as
/// its disposition.
///
/// ## Examples
///
/// ```gleam
/// // component.submit(model, "inspect the tree", operator.Prompt)
/// ```
pub fn submit(
  model: Model(socket),
  text: String,
  delivery: operator.Delivery,
) -> #(Model(socket), Effect(Msg(socket))) {
  case string.trim(text), string.byte_size(text) > prompt_limit {
    "", _ -> #(
      Model(..model, notice: Warned("Nothing to send.")),
      effect.none(),
    )
    _, True -> #(
      Model(
        ..model,
        notice: Warned(
          "The draft is longer than the page sends ("
          <> int.to_string(prompt_limit)
          <> " bytes).",
        ),
      ),
      effect.none(),
    )
    _, False ->
      commanded(model, fn(lane, id, now) {
        Ok(operator.submit(lane, id, strand, text, delivery, now))
      })
  }
}

/// Answers the escalation the page drew as `id` at `seq`, through the
/// engine's command arm.
///
/// The answer is sent only for the record with exactly that identity and
/// sequence, still pending (`operator.drawn`); a record that moved after
/// the card was drawn is not decided, and the page says so.
///
/// ## Examples
///
/// ```gleam
/// // component.decide(model, "esc-1", 12, component.Deny)
/// ```
pub fn decide(
  model: Model(socket),
  id: String,
  seq: Int,
  answer: Answer,
) -> #(Model(socket), Effect(Msg(socket))) {
  let model = drained(model)
  case operator.drawn(model.approvals, id, seq) {
    Error(Nil) ->
      Model(
        ..model,
        notice: Warned(
          "That approval changed after it was drawn, so nothing was decided.",
        ),
      )
      |> flushed
    Ok(record) -> {
      let choice = case answer {
        AllowOnce -> operator.AllowOnce
        Deny -> operator.Deny
      }
      commanded(model, fn(lane, id, now) {
        operator.decide(lane, id, record, choice, now)
      })
    }
  }
}

// One command through the lane: drain what was filed, run the arm, fold its
// disposition, and perform everything the lane queued in the order it
// queued it.
fn commanded(
  model: Model(socket),
  arm: fn(session_channel.Channel(socket, Nil), Int, Int) ->
    Result(
      #(session_channel.Channel(socket, Nil), session_channel.Disposition),
      String,
    ),
) -> #(Model(socket), Effect(Msg(socket))) {
  let model = drained(model)
  case model.lane {
    None -> #(
      Model(..model, notice: Warned("The page is not connected yet.")),
      effect.none(),
    )
    Some(lane) ->
      case arm(lane, model.next_id, model.clock) {
        Error(reason) -> flushed(Model(..model, notice: Warned(reason)))
        Ok(#(lane, disposition)) ->
          Model(..model, lane: Some(lane), next_id: model.next_id + 1)
          |> settled(disposition)
          |> flushed
      }
  }
}

// Takes everything the lane queued and performs it, keeping the emptied
// lane, so no output is performed twice.
fn flushed(model: Model(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  case model.lane {
    None -> #(model, effect.none())
    Some(lane) -> {
      let #(lane, outputs) = session_channel.take_outputs(lane)
      #(Model(..model, lane: Some(lane)), perform(model.transport, outputs))
    }
  }
}

// The lane's outputs, performed through the host's transport in the order
// the lane decided them, in one effect: Lustre does not order a batch.
// The shape is the terminal's `terminal_lane.perform`.
fn perform(
  transport: Transport(socket),
  outputs: List(session_channel.Out(socket, Nil)),
) -> Effect(Msg(socket)) {
  case outputs {
    [] -> effect.none()
    [_, ..] -> {
      use _dispatch <- effect.from
      list.each(outputs, fn(output) {
        case output {
          session_channel.Transmit(socket:, frame:) ->
            transport.transmit(socket, frame)
          session_channel.Shut(socket:) -> transport.shut(socket)

          // The lane holds no trace, so it never queues a note.
          session_channel.Note(..) -> Nil
        }
      })
    }
  }
}

fn rearm(timer: Option(Subject(Nil))) -> Effect(Msg(socket)) {
  case timer {
    None -> effect.none()
    Some(timer) -> {
      use _dispatch <- effect.from
      process.send_after(timer, tick_ms, Nil)
      Nil
    }
  }
}

/// The transcript lines the page draws, oldest first.
///
/// ## Examples
///
/// ```gleam
/// // component.lines(model)
/// ```
pub fn lines(model: Model(socket)) -> List(Line) {
  list.map(model.rows, fn(row) { row.line })
}

/// The connection's status.
///
/// ## Examples
///
/// ```gleam
/// // component.status(model) == component.Following
/// ```
pub fn status(model: Model(socket)) -> Status {
  model.status
}

/// The escalations still waiting for a decision, in the order the capture
/// held them.
///
/// ## Examples
///
/// ```gleam
/// // component.pending(model)
/// ```
pub fn pending(model: Model(socket)) -> List(approval.Review) {
  list.filter(model.approvals, fn(record) { record.status == approval.Pending })
}

/// What the page last told the operator.
///
/// ## Examples
///
/// ```gleam
/// // component.notice(model) == component.Quiet
/// ```
pub fn notice(model: Model(socket)) -> Notice {
  model.notice
}

/// How many drafts have been sent, which keys the composer's editor.
///
/// ## Examples
///
/// ```gleam
/// // component.drafts(model)
/// ```
pub fn drafts(model: Model(socket)) -> Int {
  model.drafts
}

/// The attachment the last capture was taken for: who the page acts as.
///
/// ## Examples
///
/// ```gleam
/// // component.attachment(model)
/// ```
pub fn attachment(model: Model(socket)) -> Option(snapshot.Attachment) {
  option.map(model.shown, fn(shown) { { shown.0 }.attachment })
}

/// Whether the page's strand has an operation running, as the last
/// capture says, which decides whether the composer offers one Send or a
/// Queue and a Steer.
///
/// ## Examples
///
/// ```gleam
/// // component.activity(model) == component.Idle
/// ```
pub fn activity(model: Model(socket)) -> Activity {
  let running = case model.shown {
    None -> False
    Some(#(_, view)) ->
      list.any(view.strands, fn(listed) {
        listed.id == strand && listed.live_phase != None
      })
  }
  case running {
    True -> Busy
    False -> Idle
  }
}

/// The transcript rows the page draws, keyed, oldest first.
///
/// ## Examples
///
/// ```gleam
/// // component.transcript_view(component.rows(model))
/// ```
pub fn rows(model: Model(socket)) -> List(transcript.Row) {
  model.rows
}

/// The page's lane, for the parity test that compares it with the
/// terminal's through `session_channel.state`.
///
/// ## Examples
///
/// ```gleam
/// // option.map(component.lane(model), session_channel.state)
/// ```
@internal
pub fn lane(
  model: Model(socket),
) -> Option(session_channel.Channel(socket, Nil)) {
  model.lane
}

/// The session identity the page was opened for.
///
/// ## Examples
///
/// ```gleam
/// // component.session_id(model)
/// ```
pub fn session_id(model: Model(socket)) -> String {
  model.session_id
}

/// The observer's page: the heading, the transcript, and a fixed line
/// saying the page is read-only. It attaches no event handler.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(component.view(model))
/// ```
pub fn view(model: Model(socket)) -> Element(Msg(socket)) {
  html.main([attribute.class("loom-session")], [
    heading(model),
    transcript_view(model.rows),
    html.p([attribute.class("observer-bar")], [
      html.text(
        "Observer · read-only · you can follow this session; ask the owner for operator access",
      ),
    ]),
  ])
}

/// The page's heading: the session and the connection's status.
///
/// ## Examples
///
/// ```gleam
/// // component.heading(model)
/// ```
pub fn heading(model: Model(socket)) -> Element(message) {
  html.header([], [
    html.h1([], [html.text("Session " <> model.session_id)]),
    html.p([attribute.class("status"), attribute.role("status")], [
      html.text(status_text(model.status)),
    ]),
  ])
}

/// The transcript, keyed by the engine's row identity and memoized on the
/// rows, so a message that did not bring a capture costs no diff here and a
/// window that drops its oldest rows removes them rather than rewriting
/// every row after them.
///
/// ## Examples
///
/// ```gleam
/// // component.transcript_view(rows)
/// ```
pub fn transcript_view(rows: List(transcript.Row)) -> Element(message) {
  use <- element.memo([element.ref(rows)])
  keyed.div(
    [attribute.class("transcript"), attribute.role("log")],
    list.map(rows, fn(row) { #(row.key, line_element(row.line)) }),
  )
}

fn status_text(status: Status) -> String {
  case status {
    Connecting -> "connecting"
    Following -> "following"
    Ended(reason:) -> "disconnected: " <> reason
  }
}

fn line_element(line: Line) -> Element(message) {
  html.pre([attribute.class("line " <> speaker_class(line.speaker))], [
    html.text(line.text),
  ])
}

// A class per speaker, which is the whole of a line's styling here as in the
// terminal. The stylesheet decides what each looks like.
fn speaker_class(speaker: transcript_line.Speaker) -> String {
  case speaker {
    transcript_line.System -> "system"
    transcript_line.User -> "user"
    transcript_line.Assistant -> "assistant"
    transcript_line.Reasoning -> "reasoning"
    transcript_line.ReasoningDigest -> "reasoning-digest"
    transcript_line.SummarizedReasoning -> "summarized-reasoning"
    transcript_line.SummarizedAdvice -> "summarized-advice"
    transcript_line.ToolCall -> "tool-call"
    transcript_line.ToolResult -> "tool-result"
    transcript_line.ToolDetail -> "tool-detail"
    transcript_line.ToolPatch -> "tool-patch"
    transcript_line.ToolFailure -> "tool-failure"
    transcript_line.Failure -> "failure"
    transcript_line.Spacer -> "spacer"
  }
}
