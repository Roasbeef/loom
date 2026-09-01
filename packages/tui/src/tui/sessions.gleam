//// Local session discovery, selection, and replacement attachment.
////
//// The selector reads only bootstrap records under the private launcher state
//// root. Resolution and websocket startup run outside the terminal process;
//// the caller adopts a successful socket before discarding its current one.

import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/keys
import etui/span
import etui/widgets/block
import etui/widgets/paragraph
import filepath
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
    inbox: Subject(Message),
    /// The absolute monotonic deadline for this replacement attempt.
    deadline_ms: Int,
  )
}

/// One result returned by a replacement-attachment worker.
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
  let worker =
    process.spawn_unlinked(fn() {
      let answer = resolve_and_connect(choice, options, owner)
      process.send(receiver, answer)
      await_adoption(answer)
    })
  Resolving(
    session: choice.session,
    worker:,
    monitor: process.monitor(worker),
    inbox: receiver,
    deadline_ms: ffi_bootstrap.system_time_ms() + switch_timeout_ms,
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
    Resolving(session:, worker:, monitor:, inbox:, deadline_ms:) ->
      case receive_monitored(inbox, session, monitor) {
        Ok(message) -> Ok(message)
        Error(Nil) ->
          case ffi_bootstrap.system_time_ms() >= deadline_ms {
            True -> {
              process.kill(worker)
              process.demonitor_process(monitor)
              Ok(Failed(session, "session startup timed out"))
            }
            False -> Error(Nil)
          }
      }
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
  inbox: Subject(Message),
  session: String,
  monitor: Monitor,
) -> Result(Message, Nil) {
  let selector =
    process.new_selector()
    |> process.select(inbox)
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
  owner: Pid,
) -> Message {
  case bootstrap.resolve(options) {
    Error(reason) -> Failed(choice.session, reason)
    Ok(target) ->
      case process.is_alive(owner) {
        False -> Failed(choice.session, "the terminal closed during startup")
        True -> connect_target(choice, options, target, owner)
      }
  }
}

fn await_adoption(message: Message) -> Nil {
  case message {
    Ready(socket:, adopted:, ..) ->
      case process.receive(adopted, switch_timeout_ms) {
        Ok(Nil) -> Nil
        Error(Nil) -> connection.close(socket)
      }
    Failed(..) | WorkerCrashed(..) -> Nil
  }
}

fn connect_target(
  choice: SessionChoice,
  options: Options,
  target: bootstrap.Target,
  owner: Pid,
) -> Message {
  let inbox = connection.new_inbox()
  case connection.connect(target.address, target.token, inbox) {
    Error(reason) -> Failed(choice.session, "connect: " <> reason)
    Ok(socket) -> {
      let adopted = process.new_subject()
      connection.send(socket, protocol.subscribe(1, target.session))
      connection.send(socket, protocol.models(2))
      connection.send(socket, protocol.config(3, "main"))
      case process.is_alive(owner) {
        True -> Ready(choice, options, target, inbox, socket, adopted)
        False -> {
          connection.close(socket)
          Failed(choice.session, "the terminal closed during startup")
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
      choice_lines(choice, start + offset, state.selected, state.current)
    })
    |> list.flatten
  paragraph.render_text(buf, area, span.text_new(rows))
}

fn choice_lines(
  choice: SessionChoice,
  index: Int,
  selected: Int,
  current: String,
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
  [
    span.line_new([
      span.span_styled(marker, row_style),
      span.span_styled(text_hygiene.single_line(session), row_style),
      span.span_styled(current_badge, theme.overlay_current()),
    ]),
    span.line_new([
      span.span_styled("    ", theme.overlay_plain()),
      span.span_styled(
        text_hygiene.single_line(workspace),
        theme.overlay_quiet(),
      ),
      span.span_styled("  ·  ", theme.overlay_quiet()),
      span.span_styled(
        text_hygiene.single_line(filepath.base_name(session_file)),
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
