//// Local session discovery, selection, and replacement attachment.
////
//// The selector reads only bootstrap records under the private launcher state
//// root. Resolution and websocket startup run outside the terminal process,
//// as one weft task under a deadline; the terminal pulls its outcome once per
//// tick and adopts a successful socket before discarding its current one.
////
//// Ownership is split deliberately. The task process owns the replacement
//// socket while it resolves and connects, so the deadline that kills the task
//// closes the socket with it, but every mailbox the terminal will later read
//// is created by the terminal itself: a `Subject` delivers to the process that
//// created it, and `gleam/erlang/process.receive` refuses a subject owned by
//// another process. A task-created frame inbox would therefore route the new
//// session's snapshot to the task and panic the terminal on its next tick.
////
//// The spawn, the monitor, the monotonic deadline and the kill-and-join this
//// once hand-rolled are weft's: `weft.start_detached` runs the task under a
//// scope linked to the terminal, so a terminal that dies mid-switch takes the
//// attempt down with it, and `weft.pull` with a zero wait is the non-blocking
//// poll the tick makes. After handshake, the socket's guardian monitors both
//// this attempt and the terminal-owned inbox. Normal task completion leaves
//// the socket with the terminal; cancellation or terminal death closes it.
//// `connection.adopt` checks liveness without linking a fallible network
//// actor directly to the terminal. Task exit initiates socket cleanup; it is
//// not itself a witness that the socket has already exited.

import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/keys
import etui/span
import etui/widgets/block
import etui/widgets/paragraph
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import tui/bootstrap.{type Options, type SessionChoice, SessionChoice}
import tui/connection
import tui/protocol
import tui/text_hygiene
import tui/theme
import weft

// The deadline must outlast the phases resolve can run in sequence: a 30 s
// launch lock, a 30 s daemon start, and two 10 s probes. A shorter bound
// would kill a task mid-launch on a contended cold start and leave nothing
// worse than an abandoned starting record, but it would also fail a switch
// that was about to succeed.
const switch_timeout_ms = 90_000

const discard_limit = 4096

// How long `cancel` waits for the scope to account for a killed task before
// giving up on closing a socket the task may have returned. The kill is
// immediate; the wait covers the scope's delivery, not the work.
const cancel_drain_ms = 1000

/// The session selector's local interaction state.
pub type State {
  State(
    /// Validated launcher records available under the active state root.
    choices: List(SessionChoice),
    /// The zero-based cursor within the visible rows.
    selected: Int,
    /// The canonical session file currently attached to the terminal.
    current: String,
  )
}

/// The result of one selector keystroke.
pub type Action {
  /// Keep the overlay open with replacement local state.
  Continue(state: State)

  /// Resolve and attach to the selected local session.
  Choose(choice: SessionChoice)

  /// Close the overlay without changing the active connection.
  Close
}

/// The lifecycle of one asynchronous replacement attachment.
pub type SwitchStatus {
  /// No replacement attachment is in flight.
  Idle

  /// A task is resolving or connecting to the named session.
  Resolving(
    /// The session name shown while the replacement is opening.
    session: String,
    /// The detached run whose one task owns the replacement until it
    /// returns. Its deadline is the whole timeout story.
    run: weft.Detached(Opened, String),
    /// The terminal-owned frame inbox the replacement socket delivers to.
    frames: Subject(connection.Message),
  )
}

/// One result the terminal observes for a replacement attachment.
///
/// `receive` builds these from the run's outcome, so the frame inbox a
/// `Ready` carries is always the one the terminal created in `start`; the
/// task never gets to name it.
pub type Message {
  /// A replacement websocket is ready for terminal-process adoption.
  Ready(
    /// The discovered launcher record selected by the operator.
    choice: SessionChoice,
    /// The local launch inputs reconstructed from that record.
    options: Options,
    /// The authenticated target returned by local bootstrap.
    target: bootstrap.Target,
    /// The fresh mailbox that receives the replacement session's frames.
    inbox: Subject(connection.Message),
    /// The replacement websocket actor awaiting terminal adoption.
    socket: connection.Connection,
  )

  /// Resolution or connection failed while the old session remained active.
  Failed(session: String, reason: String)

  /// The replacement task crashed before returning a typed result.
  WorkerCrashed(session: String, reason: String)
}

/// What a replacement-attachment task returns when it succeeds.
///
/// It is exposed so tests can stand in for a task; the terminal only ever
/// sees the `Message` that `receive` derives from it.
@internal
pub type Opened {
  /// The task resolved the session and holds an open socket for adoption.
  Opened(
    choice: SessionChoice,
    options: Options,
    target: bootstrap.Target,
    socket: connection.Connection,
  )
}

/// Opens a selector over discovered launcher records.
///
/// ## Examples
///
/// ```gleam
/// sessions.new(choices, "/home/me/.loom/sessions/project.db")
/// ```
pub fn new(choices: List(SessionChoice), current: String) -> State {
  State(choices:, selected: selected_session(choices, current, 0), current:)
}

/// Handles one key while the selector owns input focus.
///
/// ## Examples
///
/// ```gleam
/// sessions.update(keys.Down, state)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape -> Close
    keys.Enter ->
      case item_at(state.choices, state.selected) {
        Ok(choice) -> Choose(choice)
        Error(Nil) -> Continue(state)
      }
    keys.Up ->
      Continue(State(..state, selected: wrap_up(state.selected, state.choices)))
    keys.Down ->
      Continue(
        State(..state, selected: wrap_down(state.selected, state.choices)),
      )
    keys.PageUp ->
      Continue(State(..state, selected: int.max(0, state.selected - 8)))
    keys.PageDown ->
      Continue(
        State(
          ..state,
          selected: int.min(last_index(state.choices), state.selected + 8),
        ),
      )
    keys.Backspace
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.Home
    | keys.End
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Char(_)
    | keys.Unknown(_) -> Continue(state)
  }
}

/// Starts one replacement attachment without blocking terminal input.
///
/// ## Examples
///
/// ```gleam
/// let status = sessions.start(choice, options)
/// ```
pub fn start(choice: SessionChoice, base: Options) -> SwitchStatus {
  let options = bootstrap.session_options(base, choice)
  start_with(
    choice.session,
    fn(frames) { resolve_and_connect(choice, options, frames) },
    within: switch_timeout_ms,
  )
}

/// Starts a replacement attachment whose work is `attempt`, bounded by
/// `within` milliseconds.
///
/// `start` is this with the real resolve-and-connect; tests hand in an
/// attempt that fails, sleeps, or crashes to drive each outcome without a
/// server. The attempt runs on the task's own process, so a socket it opens
/// is linked there and dies with the task when the deadline kills it.
///
/// ## Examples
///
/// ```gleam
/// sessions.start_with("demo", fn(_frames) { Error("refused") }, within: 100)
/// ```
@internal
pub fn start_with(
  session: String,
  attempt: fn(Subject(connection.Message)) -> Result(Opened, String),
  within within: Int,
) -> SwitchStatus {
  // The frame inbox is created here so it delivers to the terminal. Frames
  // the replacement socket emits before adoption queue in the terminal's
  // mailbox under this attempt's tag and are drained only once it adopts.
  let frames = connection.new_inbox()
  let run =
    weft.new([fn() { attempt(frames) }])
    |> weft.deadline(within)
    |> weft.start_detached
  Resolving(session:, run:, frames:)
}

/// Receives one completed replacement attachment, when ready.
///
/// ## Examples
///
/// ```gleam
/// sessions.receive(status)
/// ```
pub fn receive(status: SwitchStatus) -> Result(Message, Nil) {
  case status {
    Idle -> Error(Nil)
    Resolving(session:, run:, frames:) ->
      case settle(session, frames, weft.pull(run, within: 0)) {
        Error(Nil) -> Error(Nil)
        Ok(Ready(..) as message) -> Ok(message)

        // Every terminal answer but adoption leaves the frames the socket
        // already delivered with nobody to read them; a failed attempt
        // must leave no unread frames behind for the mailbox scan of every
        // later selective receive.
        Ok(message) -> {
          discard(frames)
          Ok(message)
        }
      }
  }
}

// The translation from weft's account of the one task to the terminal's
// vocabulary. All seven outcomes are named: a plain task never produces the
// two drain variants, and the arms exist so a run that grows an owner fails
// exhaustiveness here rather than taking a catch-all.
fn settle(
  session: String,
  frames: Subject(connection.Message),
  pulled: weft.Pulled(Opened, String),
) -> Result(Message, Nil) {
  case pulled {
    weft.NotYet -> Error(Nil)
    weft.PulledOutcome(weft.Completed(
      value: Opened(choice:, options:, target:, socket:),
      ..,
    )) -> Ok(Ready(choice:, options:, target:, inbox: frames, socket:))
    weft.PulledOutcome(weft.Failed(error:, ..)) -> Ok(Failed(session, error))
    weft.PulledOutcome(weft.Crashed(reason:, ..)) ->
      Ok(WorkerCrashed(session, string.inspect(reason)))

    // The deadline killed the task, or the run ended before it got a slot,
    // which a zero deadline can do. Either way the socket it may have
    // opened died with the task's process, and the frames it already
    // delivered are dropped with it below, which keeps a late attempt from
    // ever being adopted by a later switch.
    weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..)) ->
      Ok(Failed(session, "session startup timed out"))
    weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
      Ok(WorkerCrashed(session, string.inspect(reason)))
    weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      Ok(Failed(session, "session startup was cancelled"))

    // The run is over with nothing delivered, which a one-task run only
    // reaches once its outcome has already been pulled and acted on.
    weft.AllDelivered -> Ok(Failed(session, "session startup ended early"))
    weft.RunLost(reason:) -> Ok(WorkerCrashed(session, string.inspect(reason)))
  }
}

/// Drops every frame a replacement socket queued for the terminal.
///
/// The terminal calls this when a ready socket cannot be adopted. It is also
/// how a failed attempt leaves no unread frames behind for the mailbox scan
/// of every later selective receive. A socket that is still closing may add a
/// final notice after this returns; that residue is bounded by one frame.
///
/// ## Examples
///
/// ```gleam
/// sessions.discard(frames)
/// ```
pub fn discard(inbox: Subject(a)) -> Nil {
  discard_up_to(inbox, discard_limit)
}

fn discard_up_to(inbox: Subject(a), remaining: Int) -> Nil {
  case remaining <= 0, process.receive(inbox, 0) {
    True, _ | _, Error(Nil) -> Nil
    False, Ok(_) -> discard_up_to(inbox, remaining - 1)
  }
}

/// Stops an unfinished replacement attachment before terminal exit.
///
/// Cancelling kills a task still running, and the socket linked to it dies
/// too. A task that had already returned its socket is the one case the
/// link cannot cover, so the account is drained here and any socket it
/// carries is closed by hand: nothing an unadopted attempt opened outlives
/// this call.
///
/// ## Examples
///
/// ```gleam
/// sessions.cancel(status)
/// ```
pub fn cancel(status: SwitchStatus) -> Nil {
  case status {
    Idle -> Nil
    Resolving(run:, frames:, ..) -> {
      weft.cancel_detached(run)
      close_unadopted(run)
      discard(frames)
    }
  }
}

// Pull until the scope says the run is over, closing any socket a task
// returned before the cancel landed. The wait is bounded per pull, and a
// cancelled one-task run delivers at most one outcome, so this is a short
// drain rather than a loop that can hang teardown.
fn close_unadopted(run: weft.Detached(Opened, String)) -> Nil {
  case weft.pull(run, within: cancel_drain_ms) {
    weft.PulledOutcome(weft.Completed(value: Opened(socket:, ..), ..)) -> {
      connection.close(socket)
      close_unadopted(run)
    }
    weft.PulledOutcome(weft.Failed(..))
    | weft.PulledOutcome(weft.Crashed(..))
    | weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.DrainProofLost(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      close_unadopted(run)
    weft.NotYet | weft.AllDelivered | weft.RunLost(..) -> Nil
  }
}

/// Reports whether a replacement attachment is already in flight.
///
/// ## Examples
///
/// ```gleam
/// sessions.busy(sessions.Idle)
/// // -> False
/// ```
pub fn busy(status: SwitchStatus) -> Bool {
  case status {
    Idle -> False
    Resolving(..) -> True
  }
}

/// Renders the local session selector above the main interface.
///
/// ## Examples
///
/// ```gleam
/// sessions.render(buffer, screen, state)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let width = int.max(1, int.min(96, screen.size.width - 6))
  let height =
    int.max(8, int.min(22, list.length(state.choices) * 2 + 5))
    |> int.min(int.max(1, screen.size.height - 4))
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [
        span.span_styled(" SESSIONS ", theme.overlay_signal()),
        span.span_styled("local launcher state ", theme.overlay_quiet()),
      ],
      block.Top,
    )
    |> block.with_padding(1, 0, 2, 2)
  let inside = block.inner(area, frame)
  case geometry.split_v(inside, [Length(1), Fill, Length(1)]) {
    [summary_area, list_area, help_area] ->
      buf
      |> buffer.clear(area)
      |> block.render(area, frame)
      |> render_summary(summary_area, state.choices)
      |> render_choices(list_area, state)
      |> render_help(help_area)
    _ -> buf |> buffer.clear(area) |> block.render(area, frame)
  }
}

/// The real attempt `start` runs: resolve the session locally, then open
/// and subscribe a websocket that delivers to `frames`.
///
/// Exposed so a test can wrap it — to learn the socket's pid before the
/// outcome is pulled, say — and still exercise the shipped path.
///
/// ## Examples
///
/// ```gleam
/// sessions.start_with(choice.session, fn(frames) {
///   sessions.resolve_and_connect(choice, options, frames)
/// }, within: 90_000)
/// ```
@internal
pub fn resolve_and_connect(
  choice: SessionChoice,
  options: Options,
  frames: Subject(connection.Message),
) -> Result(Opened, String) {
  case bootstrap.resolve(options) {
    Error(reason) -> Error(reason)
    Ok(target) -> connect_target(choice, options, target, frames)
  }
}

// Connection startup retains the socket's ordinary link until its guardian
// has adopted it. The guardian monitors this task and the terminal-owned
// inbox, preserving cancellation while allowing a successful task to return
// normally. Adoption no longer links a fallible socket to the terminal.
fn connect_target(
  choice: SessionChoice,
  options: Options,
  target: bootstrap.Target,
  inbox: Subject(connection.Message),
) -> Result(Opened, String) {
  case connection.connect(target.address, target.token, inbox) {
    Error(reason) -> Error("connect: " <> reason)
    Ok(socket) -> {
      connection.send(socket, protocol.subscribe(1, target.session))
      connection.send(socket, protocol.models(2))
      connection.send(socket, protocol.config(3, "main"))
      Ok(Opened(choice:, options:, target:, socket:))
    }
  }
}

fn render_summary(
  buf: buffer.Buffer,
  area: Rect,
  choices: List(SessionChoice),
) -> buffer.Buffer {
  paragraph.render_text(
    buf,
    area,
    span.text_new([
      span.line_new([
        span.span_styled(
          int.to_string(list.length(choices)),
          theme.overlay_current(),
        ),
        span.span_styled(" managed sessions", theme.overlay_quiet()),
      ]),
    ]),
  )
}

// Every choice owns exactly two rows, so the visible window is computed from
// rows rather than from wrapped text. A canonical path is routinely wider
// than the overlay, and a wrapped detail line would steal the next choice's
// rows; each path is instead cut to its tail, which is the distinctive end.
fn render_choices(
  buf: buffer.Buffer,
  area: Rect,
  state: State,
) -> buffer.Buffer {
  let visible_count = int.max(1, area.size.height / 2)
  let start =
    int.max(0, state.selected - visible_count + 1)
    |> int.min(int.max(0, list.length(state.choices) - visible_count))
  let rows =
    state.choices
    |> list.drop(start)
    |> list.take(visible_count)
    |> list.index_map(fn(choice, offset) {
      choice_lines(
        choice,
        start + offset,
        state.selected,
        state.current,
        area.size.width,
      )
    })
    |> list.flatten
  paragraph.render_styled(buf, area, rows)
}

fn choice_lines(
  choice: SessionChoice,
  index: Int,
  selected: Int,
  current: String,
  width: Int,
) -> List(span.Line) {
  let SessionChoice(session:, workspace:, session_file:) = choice
  let #(marker, row_style) = case index == selected {
    True -> #("▸ ", theme.overlay_signal())
    False -> #("  ", theme.overlay_plain())
  }
  let current_badge = case session_file == current {
    True -> "  ● current"
    False -> ""
  }

  // The detail row shares its width between the two paths after the indent
  // and the separator, so both tails stay visible on a narrow terminal.
  let detail_indent = "    "
  let separator = "  ·  "
  let path_width =
    int.max(
      1,
      { width - string.length(detail_indent) - string.length(separator) } / 2,
    )
  [
    span.line_new([
      span.span_styled(marker, row_style),
      span.span_styled(
        text_hygiene.fit_tail(text_hygiene.single_line(session), width - 2),
        row_style,
      ),
      span.span_styled(current_badge, theme.overlay_current()),
    ]),
    span.line_new([
      span.span_styled(detail_indent, theme.overlay_plain()),
      span.span_styled(
        text_hygiene.fit_tail(text_hygiene.single_line(workspace), path_width),
        theme.overlay_quiet(),
      ),
      span.span_styled(separator, theme.overlay_quiet()),
      span.span_styled(
        text_hygiene.fit_tail(
          text_hygiene.single_line(session_file),
          path_width,
        ),
        theme.overlay_quiet(),
      ),
    ]),
  ]
}

fn render_help(buf: buffer.Buffer, area: Rect) -> buffer.Buffer {
  paragraph.render_text(
    buf,
    area,
    span.text_new([
      span.line_new([
        span.span_styled("↑↓", theme.overlay_signal()),
        span.span_styled(" navigate   ", theme.overlay_quiet()),
        span.span_styled("enter", theme.overlay_signal()),
        span.span_styled(" open   ", theme.overlay_quiet()),
        span.span_styled("esc", theme.overlay_signal()),
        span.span_styled(" close", theme.overlay_quiet()),
      ]),
    ]),
  )
}

fn selected_session(
  choices: List(SessionChoice),
  current: String,
  fallback: Int,
) -> Int {
  let found =
    choices
    |> list.index_fold(-1, fn(found, choice, index) {
      case found < 0 && choice.session_file == current {
        True -> index
        False -> found
      }
    })
  case found >= 0 {
    True -> found
    False -> int.min(int.max(0, fallback), last_index(choices))
  }
}

fn wrap_up(selected: Int, choices: List(SessionChoice)) -> Int {
  case selected <= 0 {
    True -> last_index(choices)
    False -> selected - 1
  }
}

fn wrap_down(selected: Int, choices: List(SessionChoice)) -> Int {
  case selected >= last_index(choices) {
    True -> 0
    False -> selected + 1
  }
}

fn last_index(choices: List(a)) -> Int {
  int.max(0, list.length(choices) - 1)
}

fn item_at(items: List(a), index: Int) -> Result(a, Nil) {
  items |> list.drop(index) |> list.first
}
