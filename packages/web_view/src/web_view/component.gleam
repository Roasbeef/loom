//// The web view's host for one session: a Lustre server component that
//// drives `session_view`'s lane and draws its transcript lines as HTML.
////
//// The component is the lane's host in the sense ADR-014 gives the word. It
//// reads what the engine may not read (a clock, a mailbox) and delivers it as
//// messages, and it performs the lane's outputs. It holds no session logic of
//// its own: which frames to send, what a reply means, when to catch up and
//// which lines a capture becomes are all `session_view`'s, exactly as they
//// are for the terminal. What is web-specific here is the delivery (a Lustre
//// selector instead of an etui tick) and the view (HTML elements instead of
//// terminal cells).
////
//// Delivery keeps ADR-013's option C. A frame from the transport arrives as
//// `Arrived` and is only filed. A 250 ms timer delivers `Ticked` with the
//// clock reading taken when the timer message was received, and only then
//// is every filed frame handed to the lane, in arrival order, followed by the
//// lane's own `tick`. A frame therefore never changes what the page shows
//// until a tick reduces it, which is the terminal's discipline too.
////
//// The transport is supplied by the host that starts the component, because
//// what a socket is belongs to that host. In the daemon it is a relay into
//// the session's gateway (`client/daemon/ui_relay`); in a test it is
//// whatever the test hands in. The interpreter for the lane's outputs has
//// the terminal's shape: `Transmit` writes a frame through the transport and
//// `Shut` closes it. The component has no recorder, so its recorder type is
//// `Nil` and it never queues a note.
////
//// The component is read-only by construction. Its messages are the
//// transport's, the timer's and nothing else, and its view attaches no event
//// handler, so a browser has nothing it can send.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import session_view/connection_event
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

/// The strand the skeleton shows.
pub const strand = "main"

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
/// inbox `connect` is handed, so a reply is always read by the process that
/// created the subject it arrives on.
pub type Transport(socket) {
  Transport(
    /// Opens the connection, delivering every frame to `inbox` as a
    /// `connection_event.Message`. Returns the handle the lane writes to.
    connect: fn(Subject(connection_event.Message)) -> Result(socket, String),
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

/// The component's state: the lane, the frames filed since the last tick,
/// and the last completed capture.
pub opaque type Model(socket) {
  Model(
    session_id: String,
    expected: snapshot.Expected,
    transport: Transport(socket),
    /// `None` until the transport has opened.
    lane: Option(session_channel.Channel(socket, Nil)),
    /// Filed frames, newest first; reduced at the next tick.
    filed: List(connection_event.Message),
    /// The last `Captured` update, which is the only thing drawn.
    shown: Option(#(snapshot.Captured, snapshot_view.View)),
    status: Status,
    /// The timer's subject, once the tick selector is armed.
    timer: Option(Subject(Nil)),
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

/// The Lustre application for one session.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(component.app(), Start(id, expected, transport))
/// ```
pub fn app() -> lustre.App(Start(socket), Model(socket), Msg(socket)) {
  lustre.application(init, update, view)
}

/// A component that has not opened its transport, with no effects.
///
/// `init` is this plus the two effects that open the transport and arm the
/// timer; a test uses it to drive `update` without either.
///
/// ## Examples
///
/// ```gleam
/// // let model = component.new(start)
/// ```
pub fn new(start: Start(socket)) -> Model(socket) {
  Model(
    session_id: start.session_id,
    expected: start.expected,
    transport: start.transport,
    lane: None,
    filed: [],
    shown: None,
    status: Connecting,
    timer: None,
  )
}

fn init(start: Start(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  let model = new(start)
  #(model, effect.batch([open(start.transport), arm(start.transport)]))
}

// Opens the transport inside the component's process. The inbox is the
// subject Lustre's `select` created here, so the frames the transport sends
// are read by the process that owns it, and each becomes an `Arrived`.
fn open(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use dispatch, inbox <- effect.select
  case transport.connect(inbox) {
    Ok(socket) -> dispatch(Opened(socket, transport.now()))
    Error(reason) -> dispatch(Refused(reason))
  }
  process.new_selector() |> process.select_map(inbox, Arrived)
}

// Arms the tick. The clock is read when the timer message is received, which
// is host code, so the reading `Ticked` carries is the instant of the tick.
fn arm(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use dispatch, timer <- effect.select
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
/// // let #(model, _effect) = component.update(model, Arrived(frame))
/// ```
pub fn update(
  model: Model(socket),
  message: Msg(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case message {
    Opened(socket:, at:) -> {
      let lane = session_channel.start(socket, model.expected, now: at)
      let #(lane, outputs) = session_channel.take_outputs(lane)
      #(Model(..model, lane: Some(lane)), perform(model.transport, outputs))
    }

    Refused(reason:) -> #(Model(..model, status: Ended(reason)), effect.none())

    TimerArmed(timer:) -> #(Model(..model, timer: Some(timer)), effect.none())

    // Option C: an arrival is filed and nothing else happens. The page
    // cannot change until the next tick reduces it.
    Arrived(message:) -> #(
      Model(..model, filed: [message, ..model.filed]),
      effect.none(),
    )

    Ticked(at:) -> tick(model, at)
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
    Some(lane) -> {
      let #(lane, updates) =
        list.fold(list.reverse(model.filed), #(lane, []), fn(acc, message) {
          let #(lane, seen) = session_channel.receive(acc.0, message, now: at)
          #(lane, list.append(acc.1, seen))
        })
      let #(lane, ticked) = session_channel.tick(lane, now: at)
      let #(lane, outputs) = session_channel.take_outputs(lane)
      let model =
        Model(..model, lane: Some(lane), filed: [])
        |> apply(list.append(updates, ticked))
      #(
        model,
        effect.batch([perform(model.transport, outputs), rearm(model.timer)]),
      )
    }
  }
}

/// Applies the lane's updates to what the page shows.
///
/// Only `Captured` replaces the drawn transcript, as in the terminal, and
/// `Failed` ends the page's connection while leaving the last cut on it.
/// Everything else the lane reports concerns commands, streams or lookups
/// that the read-only skeleton neither sends nor draws.
///
/// ## Examples
///
/// ```gleam
/// // component.apply(model, [session_channel.Captured(cut, view, trigger)])
/// ```
@internal
pub fn apply(
  model: Model(socket),
  updates: List(session_channel.Update),
) -> Model(socket) {
  list.fold(updates, model, fn(model, update) {
    case update {
      session_channel.Captured(cut:, view:, ..) ->
        Model(..model, shown: Some(#(cut, view)), status: Following)
      session_channel.Failed(reason:) -> Model(..model, status: Ended(reason))
      session_channel.Submission(..)
      | session_channel.HistoryPage(..)
      | session_channel.LookedUp(..)
      | session_channel.Auxiliary(..)
      | session_channel.RequestRefused(..)
      | session_channel.Streamed(..)
      | session_channel.ToolStreamed(..)
      | session_channel.Noticed(..)
      | session_channel.Acknowledged(..)
      | session_channel.UnknownOutcome(..) -> model
    }
  })
}

// The lane's outputs, performed through the host's transport in the order
// the lane decided them. The shape is the terminal's `terminal_lane.perform`.
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

/// The transcript lines the page draws: `session_view`'s projection of the
/// last capture, for the `main` strand.
///
/// ## Examples
///
/// ```gleam
/// // component.lines(model) == transcript.project(cut, view, "main")
/// ```
pub fn lines(model: Model(socket)) -> List(Line) {
  case model.shown {
    None -> []
    Some(#(cut, view)) -> transcript.project(cut, view, strand)
  }
}

/// The page's connection status.
///
/// ## Examples
///
/// ```gleam
/// // component.status(component.new(start)) == component.Connecting
/// ```
pub fn status(model: Model(socket)) -> Status {
  model.status
}

/// The component's HTML: a heading, the connection status and one element
/// per transcript line, with no event handler anywhere.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(component.view(model))
/// ```
pub fn view(model: Model(socket)) -> Element(Msg(socket)) {
  html.main([attribute.class("loom-session")], [
    html.header([], [
      html.h1([], [html.text("Session " <> model.session_id)]),
      html.p([attribute.class("status")], [html.text(status_text(model.status))]),
    ]),
    html.div(
      [attribute.class("transcript")],
      list.map(lines(model), line_element),
    ),
  ])
}

fn status_text(status: Status) -> String {
  case status {
    Connecting -> "connecting"
    Following -> "following · read-only"
    Ended(reason:) -> "disconnected: " <> reason
  }
}

fn line_element(line: Line) -> Element(Msg(socket)) {
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
