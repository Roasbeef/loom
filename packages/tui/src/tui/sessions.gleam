//// Local session discovery, selection, and replacement attachment.
////
//// The selector reads only bootstrap records under the private launcher state
//// root. Resolution and websocket startup run outside the terminal process;
//// the caller adopts a successful socket before discarding its current one.
////
//// Ownership is split deliberately. The worker owns the replacement socket
//// until adoption, but every mailbox the terminal will later read is created
//// by the terminal itself: a `Subject` delivers to the process that created
//// it, and `gleam/erlang/process.receive` refuses a subject owned by another
//// process. A worker-created frame inbox would therefore route the new
//// session's snapshot to the worker and panic the terminal on its next tick.

import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/keys
import etui/span
import etui/widgets/block
import etui/widgets/paragraph
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/string
import tui/bootstrap.{type Options, type SessionChoice, SessionChoice}
import tui/connection
import tui/internal/ffi_bootstrap
import tui/protocol
import tui/text_hygiene
import tui/theme

const switch_timeout_ms = 70_000

const discard_limit = 4096

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

  /// A worker is resolving or connecting to the named session.
  Resolving(
    /// The session name shown while the replacement is opening.
    session: String,
    /// The process that owns the replacement until terminal adoption.
    worker: Pid,
    /// The monitor that turns an untyped worker exit into a typed result.
    monitor: Monitor,
    /// The mailbox used only by this replacement attempt.
    inbox: Subject(Outcome),
    /// The terminal-owned frame inbox the replacement socket delivers to.
    frames: Subject(connection.Message),
    /// The absolute monotonic deadline for this replacement attempt.
    deadline_ms: Int,
  )
}

/// One result the terminal observes for a replacement attachment.
///
/// `receive` builds these from the worker's `Outcome` and from its monitor,
/// so the frame inbox a `Ready` carries is always the one the terminal
/// created in `start`; the worker never gets to name it.
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
    /// The acknowledgement that releases the worker after adoption.
    adopted: Subject(Nil),
  )

  /// Resolution or connection failed while the old session remained active.
  Failed(session: String, reason: String)

  /// The replacement worker crashed before returning a typed result.
  WorkerCrashed(session: String, reason: String)
}

/// What a replacement-attachment worker sends back over its attempt mailbox.
///
/// It is exposed so tests can stand in for a worker; the terminal only ever
/// sees the `Message` that `receive` derives from it.
@internal
pub type Outcome {
  /// The worker resolved the session and holds an open socket for adoption.
  Opened(
    choice: SessionChoice,
    options: Options,
    target: bootstrap.Target,
    socket: connection.Connection,
    adopted: Subject(Nil),
  )

  /// Resolution or connection failed while the old session remained active.
  Refused(reason: String)
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
  let owner = process.self()
  let receiver = process.new_subject()

  // Both subjects are created here so they deliver to the terminal. Frames
  // the replacement socket emits before adoption queue in the terminal's
  // mailbox under this attempt's tag and are drained only once it adopts.
  let frames = connection.new_inbox()
  let worker =
    process.spawn_unlinked(fn() {
      let outcome = resolve_and_connect(choice, options, frames, owner)
      process.send(receiver, outcome)
      await_adoption(outcome)
    })
  Resolving(
    session: choice.session,
    worker:,
    monitor: process.monitor(worker),
    inbox: receiver,
    frames:,
    deadline_ms: ffi_bootstrap.monotonic_time_ms() + switch_timeout_ms,
  )
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
    Resolving(session:, worker:, monitor:, inbox:, frames:, deadline_ms:) ->
      case receive_monitored(inbox, session, monitor, frames) {
        Ok(Ready(..) as message) -> Ok(message)
        Ok(message) -> {
          discard(frames)
          Ok(message)
        }
        Error(Nil) ->
          case ffi_bootstrap.monotonic_time_ms() >= deadline_ms {
            True -> {
              process.kill(worker)
              process.demonitor_process(monitor)

              // The worker owned any socket it opened through a link, so the
              // kill closes it. A `Ready` that raced the deadline is dropped
              // with the frames it already delivered, which keeps a late
              // attempt from ever being adopted by a later switch.
              discard(inbox)
              discard(frames)
              Ok(Failed(session, "session startup timed out"))
            }
            False -> Error(Nil)
          }
      }
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
/// ## Examples
///
/// ```gleam
/// sessions.cancel(status)
/// ```
pub fn cancel(status: SwitchStatus) -> Nil {
  case status {
    Idle -> Nil
    Resolving(worker:, monitor:, ..) -> {
      process.kill(worker)
      process.demonitor_process(monitor)
    }
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

fn receive_monitored(
  inbox: Subject(Outcome),
  session: String,
  monitor: Monitor,
  frames: Subject(connection.Message),
) -> Result(Message, Nil) {
  let selector =
    process.new_selector()
    |> process.select_map(inbox, fn(outcome) {
      case outcome {
        Opened(choice:, options:, target:, socket:, adopted:) ->
          Ready(choice:, options:, target:, inbox: frames, socket:, adopted:)
        Refused(reason) -> Failed(session, reason)
      }
    })
    |> process.select_specific_monitor(monitor, fn(down) {
      WorkerCrashed(session, string.inspect(down))
    })
  case process.selector_receive(from: selector, within: 0) {
    Error(Nil) -> Error(Nil)
    Ok(message) -> {
      process.demonitor_process(monitor)
      Ok(message)
    }
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

fn resolve_and_connect(
  choice: SessionChoice,
  options: Options,
  frames: Subject(connection.Message),
  owner: Pid,
) -> Outcome {
  case bootstrap.resolve(options) {
    Error(reason) -> Refused(reason)
    Ok(target) ->
      case process.is_alive(owner) {
        False -> Refused("the terminal closed during startup")
        True -> connect_target(choice, options, target, frames, owner)
      }
  }
}

fn await_adoption(outcome: Outcome) -> Nil {
  case outcome {
    Opened(socket:, adopted:, ..) ->
      case process.receive(adopted, switch_timeout_ms) {
        Ok(Nil) -> Nil
        Error(Nil) -> connection.close(socket)
      }
    Refused(..) -> Nil
  }
}

// The socket actor links to this worker inside `connection.connect`, so a
// killed or crashed worker takes an unadopted socket down with it. The
// terminal re-links on adoption, and the worker's later normal exit does not
// disturb an actor that traps nothing.
fn connect_target(
  choice: SessionChoice,
  options: Options,
  target: bootstrap.Target,
  inbox: Subject(connection.Message),
  owner: Pid,
) -> Outcome {
  case connection.connect(target.address, target.token, inbox) {
    Error(reason) -> Refused("connect: " <> reason)
    Ok(socket) -> {
      let adopted = process.new_subject()
      connection.send(socket, protocol.subscribe(1, target.session))
      connection.send(socket, protocol.models(2))
      connection.send(socket, protocol.config(3, "main"))
      case process.is_alive(owner) {
        True -> Opened(choice:, options:, target:, socket:, adopted:)
        False -> {
          connection.close(socket)
          Refused("the terminal closed during startup")
        }
      }
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
        fit_tail(text_hygiene.single_line(session), width - 2),
        row_style,
      ),
      span.span_styled(current_badge, theme.overlay_current()),
    ]),
    span.line_new([
      span.span_styled(detail_indent, theme.overlay_plain()),
      span.span_styled(
        fit_tail(text_hygiene.single_line(workspace), path_width),
        theme.overlay_quiet(),
      ),
      span.span_styled(separator, theme.overlay_quiet()),
      span.span_styled(
        fit_tail(text_hygiene.single_line(session_file), path_width),
        theme.overlay_quiet(),
      ),
    ]),
  ]
}

/// Keeps the last `width` graphemes of a path, marking any cut with `…`.
///
/// ## Examples
///
/// ```gleam
/// sessions.fit_tail("/home/me/work/project", 10)
/// // -> "…k/project"
/// ```
@internal
pub fn fit_tail(text: String, width: Int) -> String {
  let length = string.length(text)
  case width <= 0, length <= width {
    True, _ -> ""
    False, True -> text
    False, False ->
      "…"
      <> string.slice(text, at_index: length - { width - 1 }, length: width - 1)
  }
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
