//// A pure-Gleam Loom terminal client built on etui.
////
//// The terminal process owns one immutable `Model`. Keyboard, mouse, paste,
//// websocket, and periodic inbox events each reduce that model before `view`
//// renders the next frame; no widget owns hidden conversation state. The
//// websocket actor owns transport I/O, while this process alone decides which
//// frozen ClientGateway command an operator action means. Durable entries
//// replace matching transient streams, keeping replay and live output from
//// appearing twice at the settlement boundary.

import argv
import core/entry
import core/json
import core/message
import etui/app
import etui/backend
import etui/backend/default
import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/keys
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import etui/widgets/statusbar
import etui/widgets/textarea as text_area
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tui_gleam/agents
import tui_gleam/command
import tui_gleam/composer
import tui_gleam/connection
import tui_gleam/markdown
import tui_gleam/model_selector
import tui_gleam/protocol.{ModelInfo, Strand}
import tui_gleam/text_hygiene
import tui_gleam/theme

type Speaker {
  System
  User
  Assistant
  Reasoning
  ToolCall
  ToolResult
  ToolDetail
  ToolFailure
  Failure
}

type Line {
  Line(speaker: Speaker, text: String)
}

// A stream stays separate from durable entries because the server may replay
// the settled entry after its fragments. Keeping both in one list would render
// the same assistant answer twice at the exact moment it becomes durable.
type Stream {
  Stream(strand: String, kind: String, fragments: List(String))
}

type Overlay {
  NoOverlay
  ModelSelector(model_selector.State)
  AgentInspector(selected: Int)
}

type Launch {
  Demo
  Remote(address: String, session: String, token: String)
  Invalid(reason: String)
}

type SubmissionMode {
  SteerNow
  QueueAfter
}

// Interrupt state belongs to the client because the server's abort contract
// deliberately drains queued steer entries. Holding one instruction here until
// the durable operation settles preserves the operator's intent without racing
// a steer admission against cancellation.
type Interrupt {
  Interrupt(strand: String, pending: Option(String))
}

// Twenty frames per second keeps streamed text and keyboard response below a
// perceptible terminal delay while avoiding sixty full buffer diffs per second
// when the websocket inbox is idle.
const terminal_poll_ms = 50

type Model {
  Model(
    quit: Bool,
    width: Int,
    height: Int,
    input: text_area.TextAreaState,
    attachments: List(composer.Attachment),
    history: List(String),
    history_index: Int,
    history_draft: String,
    command_selected: Int,
    submission_mode: SubmissionMode,
    interrupt: Option(Interrupt),
    submitting: Option(String),
    transcript: List(Line),
    records: List(protocol.EntryRecord),
    notice: String,
    help_open: Bool,
    notes_open: Bool,
    overlay: Overlay,
    models: List(protocol.ModelInfo),
    current_model: String,
    strands: List(protocol.Strand),
    active_strand: String,
    session: String,
    inbox: Subject(connection.Message),
    socket: Option(connection.Connection),
    next_id: Int,
    usage: message.Usage,
    agent_rail_visible: Bool,
    details_expanded: Bool,
    repaint_phase: Bool,
    activity_frame: Int,
    streams: List(Stream),
    scroll_offset: Int,
    render_revision: Int,
    rendered_revision: Int,
    rendered_row_count: Int,
    rendered_rows: List(span.Line),
    record_rows: List(span.Line),
    pending_records: List(protocol.EntryRecord),
    record_cache_valid: Bool,
    record_cache_width: Int,
    record_cache_strand: String,
    record_cache_details: Bool,
  )
}

/// Runs the interactive terminal client.
///
/// ## Examples
///
/// ```sh
/// gleam run -- --addr ws://127.0.0.1:8080/v1/ws --session demo
/// ```
pub fn main() {
  let inbox = connection.new_inbox()
  let base =
    Model(
      quit: False,
      width: 80,
      height: 24,
      input: text_area.state_new(),
      attachments: [],
      history: [],
      history_index: 0,
      history_draft: "",
      command_selected: 0,
      submission_mode: SteerNow,
      interrupt: None,
      submitting: None,
      transcript: [
        Line(System, "etui input and gateway paths ready"),
        Line(
          Reasoning,
          "Mapped the frozen ClientGateway events onto one immutable view model.",
        ),
        Line(ToolResult, "read · packages/client/CLAUDE.md"),
        Line(
          Assistant,
          "## Native client\n\nThe pure-Gleam path is live. Use `/model` to switch models or `/help` for the command map.",
        ),
      ],
      records: [],
      notice: "interactive design preview",
      help_open: False,
      notes_open: False,
      overlay: NoOverlay,
      models: demo_models(),
      current_model: "baseten-kimi-k3",
      strands: demo_strands(),
      active_strand: "main",
      session: "demo",
      inbox:,
      socket: None,
      next_id: 1,
      usage: zero_usage(),
      agent_rail_visible: False,
      details_expanded: False,
      repaint_phase: False,
      activity_frame: 0,
      streams: [],
      scroll_offset: 0,
      render_revision: 0,
      rendered_revision: -1,
      rendered_row_count: 0,
      rendered_rows: [],
      record_rows: [],
      pending_records: [],
      record_cache_valid: False,
      record_cache_width: 0,
      record_cache_strand: "",
      record_cache_details: False,
    )
  let initial = case parse_launch(argv.load().arguments) {
    Demo -> base
    Invalid(reason) ->
      append_error(Model(..base, notice: "invalid launch"), reason)
    Remote(address, session, token) ->
      case connection.connect(address, token, inbox) {
        Error(reason) ->
          append_error(
            Model(..base, session:, strands: []),
            "connect: " <> reason,
          )
        Ok(socket) -> {
          connection.send(socket, protocol.subscribe(1, session))
          connection.send(socket, protocol.models(2))
          connection.send(socket, protocol.config(3, base.active_strand))
          Model(
            ..base,
            session:,
            socket: Some(socket),
            next_id: 4,
            models: [],
            strands: [],
            transcript: [Line(System, "connecting to session " <> session)],
            notice: "connecting",
          )
        }
      }
  }
  let _ =
    app.run_buffered_cursor(
      default.new_with_options(backend.Options(mouse: True, paste: True)),
      initial,
      view,
      update,
      fn(model) { model.quit },
      terminal_poll_ms,
    )
  Nil
}

fn parse_launch(arguments: List(String)) -> Launch {
  case arguments {
    [] | ["--demo"] -> Demo
    _ ->
      case flag_value(arguments, "--addr"), flag_value(arguments, "--session") {
        Ok(address), Ok(session) ->
          case launch_token(arguments) {
            Ok(token) -> Remote(address:, session:, token:)
            Error(reason) -> Invalid(reason)
          }
        Error(_), _ -> Invalid(launch_usage())
        _, Error(_) -> Invalid(launch_usage())
      }
  }
}

fn launch_token(arguments: List(String)) -> Result(String, String) {
  case flag_value(arguments, "--token-file") {
    Ok(path) ->
      simplifile.read(path)
      |> result.map(string.trim)
      |> result.map_error(fn(error) {
        "cannot read --token-file " <> path <> ": " <> string.inspect(error)
      })
    Error(Nil) -> Ok(flag_value(arguments, "--token") |> result.unwrap(""))
  }
}

fn launch_usage() -> String {
  "usage: tui_gleam --addr <websocket-url> --session <id> "
  <> "[--token-file <path> | --token <bearer>]"
}

fn flag_value(arguments: List(String), flag: String) -> Result(String, Nil) {
  case arguments {
    [] | [_] -> Error(Nil)
    [name, value, ..rest] ->
      case name == flag {
        True -> Ok(value)
        False -> flag_value([value, ..rest], flag)
      }
  }
}

fn view(
  model: Model,
  screen: Rect,
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  let #(header_area, body_area, input_area, footer_area) = layout(screen, model)
  let #(transcript_panel, agent_panel) =
    body_layout(body_area, model.width, model.agent_rail_visible)
  let transcript_block =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.quiet, style.Default)
    |> block.with_title(transcript_title(model), block.Top)
  let input_block =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, style.Default)
    |> block.with_title(input_title(model), block.Top)
  let transcript_area = block.inner(transcript_panel, transcript_block)
  let #(paste_area, editor_area) =
    input_layout(block.inner(input_area, input_block), model.attachments)
  let input_view = input_view_state(model.input, editor_area.size.width)
  let editor =
    text_area.textarea_new()
    |> text_area.with_max_lines(0)
    |> text_area.with_colors(theme.paper, style.Default)
    |> text_area.with_cursor_style(style.new(
      theme.graphite,
      theme.signal,
      style.bold(),
    ))
  let base =
    repaint_canvas(screen, model.repaint_phase)
    |> render_header(header_area, model)
    |> block.render(transcript_panel, transcript_block)
    |> render_transcript(transcript_area, model)
    |> render_agent_rail(agent_panel, model)
    |> block.render(input_area, input_block)
    |> render_paste_chip(paste_area, model.attachments)
    |> text_area.render(editor_area, editor, input_view)
    |> render_footer(footer_area, model)
    |> render_command_palette(body_area, model)
  let rendered = case model.overlay {
    NoOverlay -> base
    ModelSelector(selector) -> model_selector.render(base, screen, selector)
    AgentInspector(selected) ->
      agents.render_overlay(
        base,
        screen,
        model.strands,
        model.active_strand,
        selected,
      )
  }
  let cursor = case model.overlay {
    NoOverlay -> text_area.cursor_screen_pos(input_view, editor_area)
    ModelSelector(_) | AgentInspector(_) -> Error(Nil)
  }
  #(rendered, cursor)
}

fn layout(screen: Rect, model: Model) -> #(Rect, Rect, Rect, Rect) {
  case
    geometry.split_v(screen, [
      Length(1),
      Fill,
      Length(input_height(model)),
      Length(1),
    ])
  {
    [header, body, input, footer] -> #(header, body, input, footer)
    _ -> #(screen, screen, screen, screen)
  }
}

fn body_layout(body: Rect, width: Int, visible: Bool) -> #(Rect, Rect) {
  case visible && width >= 100, geometry.split_h(body, [Fill, Length(34)]) {
    True, [transcript, agents] -> #(transcript, agents)
    _, _ -> #(body, geometry.rect_zero())
  }
}

fn render_agent_rail(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case area.size.width > 0 {
    True -> agents.render_rail(buf, area, model.strands, model.active_strand)
    False -> buf
  }
}

fn render_header(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([
      span.line_new([span.span_styled(" ◆ ", theme.signal_bold())]),
    ])
    |> statusbar.with_center([
      span.line_new([
        span.span_styled("session ", theme.quiet_text()),
        span.span_plain(text_hygiene.single_line(model.session)),
      ]),
    ])
    |> statusbar.with_right([
      span.line_new([
        span.span_styled(
          " "
            <> text_hygiene.single_line(model.current_model)
            <> " · "
            <> int.to_string(model.width)
            <> "×"
            <> int.to_string(model.height)
            <> " ",
          theme.quiet_text(),
        ),
      ]),
    ])
  statusbar.render(buf, area, bar)
}

fn render_transcript(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let visible =
    model.rendered_rows
    |> list.drop(model.scroll_offset)
    |> list.take(area.size.height)
    |> list.reverse
  paragraph.render_styled(buf, area, visible)
}

fn transcript_title(model: Model) -> String {
  let surface = case model.help_open, model.notes_open {
    True, _ -> "help"
    False, True -> "agent notes"
    False, False -> "transcript"
  }
  " "
  <> surface
  <> " / "
  <> text_hygiene.single_line(model.active_strand)
  <> " "
}

fn transcript_content(lines: List(Line)) -> span.Text {
  lines
  |> list.flat_map(render_line)
  |> span.text_new
}

fn render_line(line: Line) -> List(span.Line) {
  let #(mark, mark_style) = case line.speaker {
    System -> #("◇ ", theme.quiet_text())
    User -> #("› ", theme.signal_bold())
    Assistant -> #("◆ ", theme.current_bold())
    Reasoning -> #("∴ reason ", theme.quiet_text())
    ToolCall -> #("● ", theme.success_text())
    ToolResult -> #("└ ", theme.quiet_text())
    ToolDetail -> #("  ", theme.quiet_text())
    ToolFailure -> #("└ × ", theme.danger_text())
    Failure -> #("! error  ", theme.danger_text())
  }
  case line.speaker {
    Assistant | ToolDetail ->
      markdown.render(line.text)
      |> prefix_rendered_lines(mark, mark_style)
    System | User | Reasoning | ToolCall | ToolResult | ToolFailure | Failure ->
      line.text
      |> text_hygiene.multiline
      |> string.split("\n")
      |> list.index_map(fn(text, index) {
        let prefix = case index == 0 {
          True -> mark
          False -> string.repeat(" ", string.length(mark))
        }
        span.line_new([
          span.span_styled(prefix, mark_style),
          span.span_plain(text),
        ])
      })
      |> list.append([span.line_plain("")])
  }
}

fn prefix_rendered_lines(
  lines: List(span.Line),
  mark: String,
  mark_style: style.Style,
) -> List(span.Line) {
  lines
  |> list.index_map(fn(line, index) {
    let span.Line(spans:, alignment:) = line
    let prefix = case index == 0 {
      True -> mark
      False -> string.repeat(" ", string.length(mark))
    }
    span.Line(
      spans: [span.span_styled(prefix, mark_style), ..spans],
      alignment:,
    )
  })
}

fn help_content() -> span.Text {
  let command_lines =
    command.help_text()
    |> string.split("\n")
    |> list.map(fn(line) {
      case string.split_once(line, " ") {
        Ok(#(name, rest)) ->
          span.line_new([
            span.span_styled(name, theme.signal_bold()),
            span.span_plain(" " <> rest),
          ])
        Error(Nil) -> span.line_plain(line)
      }
    })
  span.text_new([
    span.line_new([
      span.span_styled("SLASH COMMANDS", theme.current_bold()),
      span.span_styled(" · press esc to close", theme.quiet_text()),
    ]),
    span.line_plain(""),
    ..command_lines
  ])
}

fn notes_content(
  records: List(protocol.EntryRecord),
  active_strand: String,
) -> span.Text {
  let latest =
    records
    |> list.find_map(fn(record) {
      let protocol.EntryRecord(strand:, entry:) = record
      case strand == active_strand, entry {
        True, entry.MessageEntry(message: value, ..) ->
          agent_notes_payload(value) |> option.to_result(Nil)
        _, _ -> Error(Nil)
      }
    })
    |> result.map(Some)
    |> result.unwrap(None)
  case latest {
    Some(payload) ->
      transcript_content([
        Line(System, "durable blackboard digest · newest values first"),
        Line(Assistant, "```agent-notes\n" <> payload <> "\n```"),
      ])
    None ->
      transcript_content([
        Line(System, "no agent notes are available for " <> active_strand),
      ])
  }
}

fn render_footer(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let shortcuts = case active_strand_live(model) {
    True ->
      case active_interrupt(model), model.submission_mode {
        Some(_), _ -> [
          span.span_styled(" esc ", theme.signal_bold()),
          span.span_styled("stop · ", theme.quiet_text()),
          span.span_styled("enter ", theme.signal_bold()),
          span.span_styled("steer after", theme.quiet_text()),
        ]
        None, SteerNow -> [
          span.span_styled(" enter ", theme.signal_bold()),
          span.span_styled("steer · ", theme.quiet_text()),
          span.span_styled("tab ", theme.signal_bold()),
          span.span_styled("queue", theme.quiet_text()),
        ]
        None, QueueAfter -> [
          span.span_styled(" enter ", theme.signal_bold()),
          span.span_styled("queue · ", theme.quiet_text()),
          span.span_styled("tab ", theme.signal_bold()),
          span.span_styled("steer", theme.quiet_text()),
        ]
      }
    False -> [
      span.span_styled(" /help ", theme.signal_bold()),
      span.span_styled("commands · ", theme.quiet_text()),
      span.span_styled("/agents ", theme.signal_bold()),
      span.span_styled("agents", theme.quiet_text()),
    ]
  }
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([
      span.line_new(
        list.append(shortcuts, [
          span.span_styled(" · ⇧tab ", theme.signal_bold()),
          span.span_styled("rail · ", theme.quiet_text()),
          span.span_styled("^g ", theme.signal_bold()),
          span.span_styled("detail", theme.quiet_text()),
        ]),
      ),
    ])
    |> statusbar.with_center([
      span.line_new([
        span.span_styled(
          " " <> usage_summary(model.usage) <> " ",
          theme.quiet_text(),
        ),
      ]),
    ])
    |> statusbar.with_right([
      span.line_new([
        span.span_styled(
          " "
            <> compact(
            agents.summary(model.strands) <> " · " <> model.notice,
            36,
          )
            <> " ",
          theme.quiet_text(),
        ),
      ]),
    ])
  statusbar.render(buf, area, bar)
}

// Etui's incremental diff can retain cells when one action replaces most of
// the viewport. Detail mode is exactly that action: bounded tool summaries
// become full stack traces in one frame. Alternating an invisible modifier on
// otherwise blank canvas cells makes those vacated positions explicit diff
// writes without forcing every steady streaming frame to repaint.
fn repaint_canvas(screen: Rect, phase: Bool) -> buffer.Buffer {
  let modifier = case phase {
    True -> style.dim()
    False -> style.none()
  }
  buffer.buffer_new_filled(
    screen,
    " ",
    style.new(style.Default, style.Default, modifier),
  )
}

fn input_layout(
  area: Rect,
  attachments: List(composer.Attachment),
) -> #(Rect, Rect) {
  case composer.summary(attachments) {
    None -> #(geometry.rect_zero(), area)
    Some(summary) -> {
      let width =
        int.min(int.max(0, area.size.width - 2), string.length(summary) + 3)
      case geometry.split_h(area, [Length(width), Fill]) {
        [paste_area, editor_area] -> #(paste_area, editor_area)
        _ -> #(area, geometry.rect_zero())
      }
    }
  }
}

// The editor owns the unwrapped source text, while its view is wrapped to the
// current terminal width. Keeping this transformation render-only preserves
// the exact prompt bytes used by editing, history, and submission.
@internal
pub fn input_view_state(
  state: text_area.TextAreaState,
  available_width: Int,
) -> text_area.TextAreaState {
  let width = int.max(2, available_width)
  let text_area.TextAreaState(lines:, cursor_x:, cursor_y:) = state
  let current_line =
    lines |> list.drop(cursor_y) |> list.first |> result.unwrap("")
  let cursor_prefix = text.truncate(current_line, cursor_x, "")
  let #(cursor_row, wrapped_cursor_x) = wrapped_cursor(cursor_prefix, width, 0)
  let rows_before =
    lines
    |> list.take(cursor_y)
    |> list.flat_map(hard_wrap_line(_, width))
    |> list.length
  let wrapped_lines =
    lines
    |> list.index_map(fn(line, index) {
      let wrapped = hard_wrap_line(line, width)
      case index == cursor_y, list.drop(wrapped, cursor_row) {
        True, [] -> list.append(wrapped, [""])
        _, _ -> wrapped
      }
    })
    |> list.flatten
  text_area.TextAreaState(
    lines: wrapped_lines,
    cursor_x: wrapped_cursor_x,
    cursor_y: rows_before + cursor_row,
  )
}

fn hard_wrap_line(line: String, width: Int) -> List(String) {
  case line {
    "" -> [""]
    _ -> hard_wrap_nonempty(line, width, [])
  }
}

fn hard_wrap_nonempty(
  line: String,
  width: Int,
  rows: List(String),
) -> List(String) {
  case line {
    "" -> list.reverse(rows)
    _ -> {
      let chunk = text.truncate(line, width, "")
      let rest = string.drop_start(line, string.length(chunk))
      hard_wrap_nonempty(rest, width, [chunk, ..rows])
    }
  }
}

fn wrapped_cursor(prefix: String, width: Int, rows: Int) -> #(Int, Int) {
  let prefix_width = text.cell_width(prefix)
  case prefix_width < width {
    True -> #(rows, prefix_width)
    False -> {
      let chunk = text.truncate(prefix, width, "")
      let rest = string.drop_start(prefix, string.length(chunk))
      wrapped_cursor(rest, width, rows + 1)
    }
  }
}

fn input_height(model: Model) -> Int {
  let content_rows =
    model.input
    |> input_view_state(editor_content_width(model))
    |> text_area.line_count
    |> int.max(1)
    |> int.min(4)
  content_rows + 2
}

fn editor_content_width(model: Model) -> Int {
  let inner_width = int.max(2, model.width - 2)
  let attachment_width = case composer.summary(model.attachments) {
    None -> 0
    Some(summary) ->
      int.min(int.max(0, inner_width - 2), string.length(summary) + 3)
  }
  int.max(2, inner_width - attachment_width)
}

fn input_title(model: Model) -> String {
  case
    active_interrupt(model),
    active_status_label(model),
    model.submission_mode
  {
    Some(_), _, _ -> " interrupting · enter steers after stop "
    None, None, _ -> " prompt · / commands "
    None, Some(_), QueueAfter ->
      " queue after turn · enter queues · tab steers "
    None, Some(status), SteerNow ->
      " "
      <> activity_glyph(model.activity_frame)
      <> " "
      <> status
      <> " · enter steers · tab queues "
  }
}

/// Returns the low-motion activity indicator used by the prompt border.
@internal
pub fn activity_glyph(frame: Int) -> String {
  case int.modulo(frame / 3, 4) |> result.unwrap(0) {
    0 -> "◐"
    1 -> "◓"
    2 -> "◑"
    _ -> "◒"
  }
}

// The operation phase is authoritative for liveness, while the latest stream
// kind supplies the finer distinction the protocol phase cannot express. In
// particular, `assistant` begins before the first reasoning delta, so treating
// it as a completed response would make a steerable turn look stuck.
fn active_status_label(model: Model) -> Option(String) {
  case active_strand_phase(model) {
    None -> None
    Some("assistant") ->
      Some(case active_stream_kind(model) {
        Some("text") -> "responding"
        Some("tool_call") -> "calling tool"
        _ -> "thinking"
      })
    Some("tools") -> Some("running tools")
    Some("starting") -> Some("starting")
    Some("checkpoint") -> Some("checkpointing")
    Some("compacting") -> Some("compacting")
    Some("awaiting_deferred") -> Some("waiting")
    Some("failure_drain") -> Some("finishing failure")
    Some("cancel_requested") -> Some("stopping")
    Some(phase) -> Some(text_hygiene.single_line(phase))
  }
}

fn active_stream_kind(model: Model) -> Option(String) {
  model.streams
  |> list.reverse
  |> list.find(fn(stream) {
    let Stream(strand:, ..) = stream
    strand == model.active_strand
  })
  |> result.map(fn(stream) {
    let Stream(kind:, ..) = stream
    kind
  })
  |> result.map(Some)
  |> result.unwrap(None)
}

fn render_paste_chip(
  buf: buffer.Buffer,
  area: Rect,
  attachments: List(composer.Attachment),
) -> buffer.Buffer {
  case composer.summary(attachments), area.size.width > 0 {
    Some(summary), True ->
      paragraph.render_styled(buf, area, [
        span.line_new([
          span.span_styled("[" <> summary <> "]", theme.signal_bold()),
          span.span_plain(" "),
        ]),
      ])
    _, _ -> buf
  }
}

fn render_command_palette(
  buf: buffer.Buffer,
  body: Rect,
  model: Model,
) -> buffer.Buffer {
  let suggestions = command.suggestions(text_area.value(model.input))
  case suggestions, model.overlay {
    [], _ | _, ModelSelector(_) | _, AgentInspector(_) -> buf
    _, NoOverlay -> {
      let width = int.max(1, int.min(72, body.size.width - 4))
      let height = int.max(1, int.min(10, list.length(suggestions) + 2))
      let selected =
        int.min(model.command_selected, list.length(suggestions) - 1)
      let offset = int.max(0, selected - { height - 3 })
      let area =
        geometry.rect_new(
          body.position.x + 2,
          geometry.bottom(body) - height,
          width,
          height,
        )
      let frame =
        block.block_new()
        |> block.with_border(block.Rounded)
        |> block.with_colors(theme.signal, theme.graphite)
        |> block.with_bg_fill
        |> block.with_title_styled(
          [
            span.span_styled(" commands ", theme.overlay_signal()),
          ],
          block.Top,
        )
      let lines =
        suggestions
        |> list.drop(offset)
        |> list.take(height - 2)
        |> list.index_map(fn(suggestion, relative) {
          let command.Suggestion(command: name, description:, ..) = suggestion
          let is_selected = offset + relative == selected
          let signal = theme.overlay_signal()
          let current = theme.overlay_current()
          let quiet = theme.overlay_quiet()
          span.line_new([
            span.span_styled(
              case is_selected {
                True -> "▸ "
                False -> "  "
              },
              case is_selected {
                True -> signal
                False -> quiet
              },
            ),
            span.span_styled(name, case is_selected {
              True -> signal
              False -> current
            }),
            span.span_styled("  " <> description, quiet),
          ])
        })
      buf
      |> buffer.clear(area)
      |> block.render(area, frame)
      |> paragraph.render_styled(block.inner(area, frame), lines)
    }
  }
}

fn update(event: backend.InputEvent, model: Model) -> Model {
  let updated = case event {
    backend.Resize(width, height) -> Model(..model, width:, height:)
    backend.Tick ->
      drain_connection(
        Model(..model, activity_frame: model.activity_frame + 1),
        64,
      )
    backend.KeyPress(key) -> update_key(keys.match(key), model)
    backend.Paste(text) -> handle_paste(model, text)
    backend.MouseScroll(_, _, up) -> scroll_transcript(model, up, 3)
    backend.MousePress(..)
    | backend.MouseRelease(..)
    | backend.MouseDrag(..)
    | backend.MouseMove(..) -> model
  }
  refresh_render_cache(model, updated)
}

// Terminal polling still produces idle ticks so the websocket inbox can be
// drained, but those ticks must not compare or wrap the durable transcript.
// Event handlers increment a scalar revision at the mutation boundary, which
// keeps an idle cache check constant-time regardless of session length.
fn refresh_render_cache(before: Model, after: Model) -> Model {
  let changed =
    after.render_revision != after.rendered_revision
    || before.width != after.width
    || before.agent_rail_visible != after.agent_rail_visible
    || before.details_expanded != after.details_expanded
    || before.help_open != after.help_open
    || before.notes_open != after.notes_open
    || before.active_strand != after.active_strand
    || viewport_height_changed(
      transcript_viewport_height(before),
      transcript_viewport_height(after),
    )
  case changed {
    True -> {
      let width = transcript_width(after)
      let cached = refresh_record_cache(after, width)
      let rendered_rows = rendered_rows_for(cached, width)
      let rendered_row_count = list.length(rendered_rows)
      let anchored =
        anchored_scroll_offset(
          after.scroll_offset,
          before.rendered_row_count,
          rendered_row_count,
        )
      Model(
        ..cached,
        rendered_revision: cached.render_revision,
        rendered_row_count:,
        rendered_rows:,
        scroll_offset: bounded_scroll_offset(
          anchored,
          rendered_row_count,
          transcript_viewport_height(after),
        ),
      )
    }
    False -> after
  }
}

/// Reports whether prompt layout changed the transcript's usable height.
@internal
pub fn viewport_height_changed(before: Int, after: Int) -> Bool {
  before != after
}

// Durable history is immutable after admission, so wrapped record rows can be
// retained across live stream fragments. New records are rendered as one small
// batch and prepended to the newest-first cache; width, strand, and detail
// changes rebuild it from source because each changes the rendered shape.
fn refresh_record_cache(model: Model, width: Int) -> Model {
  let cache_matches =
    model.record_cache_valid
    && model.record_cache_width == width
    && model.record_cache_strand == model.active_strand
    && model.record_cache_details == model.details_expanded
  case cache_matches, model.pending_records {
    False, _ -> {
      let record_rows =
        model.transcript
        |> list.append(record_lines(
          model.records,
          model.active_strand,
          model.details_expanded,
        ))
        |> transcript_content
        |> fn(content) { markdown.wrap_lines(content.lines, width) }
        |> list.reverse
      Model(
        ..model,
        record_rows:,
        pending_records: [],
        record_cache_valid: True,
        record_cache_width: width,
        record_cache_strand: model.active_strand,
        record_cache_details: model.details_expanded,
      )
    }
    True, [] -> model
    True, pending -> {
      let newest_rows =
        pending
        |> record_lines(model.active_strand, model.details_expanded)
        |> transcript_content
        |> fn(content) { markdown.wrap_lines(content.lines, width) }
        |> list.reverse
      Model(
        ..model,
        record_rows: list.append(newest_rows, model.record_rows),
        pending_records: [],
      )
    }
  }
}

// The viewport consumes rows newest-first. Keeping that order in the cache
// makes each live frame prepend only the small transient stream projection.
fn rendered_rows_for(model: Model, width: Int) -> List(span.Line) {
  case model.help_open, model.notes_open {
    True, _ ->
      help_content().lines |> markdown.wrap_lines(width) |> list.reverse
    False, True ->
      notes_content(model.records, model.active_strand).lines
      |> markdown.wrap_lines(width)
      |> list.reverse
    False, False ->
      stream_lines(model.streams, model.active_strand, model.details_expanded)
      |> transcript_content
      |> fn(content) { markdown.wrap_lines(content.lines, width) }
      |> list.reverse
      |> list.append(model.record_rows)
  }
}

fn handle_paste(model: Model, text: String) -> Model {
  case composer.classify(text) {
    composer.Inline(text) ->
      Model(
        ..model,
        input: text_area.state_from_string(text),
        history_index: 0,
        history_draft: text,
      )
    composer.Compact(attachment) -> {
      let attachments = list.append(model.attachments, [attachment])
      let notice = composer.summary(attachments) |> option.unwrap("pasted text")
      Model(..model, attachments:, notice:)
    }
  }
}

fn drain_connection(model: Model, remaining: Int) -> Model {
  case remaining <= 0, connection.receive(model.inbox) {
    True, _ | _, Error(Nil) -> model
    False, Ok(message) ->
      drain_connection(handle_connection_message(model, message), remaining - 1)
  }
}

fn handle_connection_message(
  model: Model,
  incoming: connection.Message,
) -> Model {
  case incoming {
    connection.Connected -> Model(..model, notice: "connected")
    connection.Closed(reason) ->
      append_error(
        Model(..model, socket: None),
        "connection closed: " <> reason,
      )
    connection.NetworkFault(reason) ->
      append_error(model, "network: " <> reason)
    connection.Incoming(text) ->
      case protocol.decode_event(text) {
        Ok(event) -> apply_event(model, event)
        Error(reason) -> append_error(model, "protocol: " <> reason)
      }
  }
}

fn apply_event(model: Model, event: protocol.Event) -> Model {
  case event {
    protocol.FullSnapshot(session:, strands:, entries:, usage:) ->
      Model(
        ..model,
        session:,
        strands:,
        usage:,
        records: list.reverse(entries),
        streams: [],
        record_rows: [],
        pending_records: [],
        record_cache_valid: False,
        submitting: None,
        scroll_offset: 0,
        notice: "session synchronized",
        transcript: [Line(System, "attached to session " <> session)],
      )
      |> invalidate_transcript
    protocol.StrandsSnapshot(strands:) ->
      Model(..model, strands:, notice: agents.summary(strands))
    protocol.ModelsSnapshot(models:) -> {
      let overlay = case model.overlay {
        ModelSelector(selector) ->
          ModelSelector(model_selector.replace_models(
            selector,
            models,
            model.current_model,
          ))
        NoOverlay -> NoOverlay
        AgentInspector(selected) -> AgentInspector(selected)
      }
      Model(
        ..model,
        models:,
        overlay:,
        notice: int.to_string(list.length(models)) <> " models loaded",
      )
    }
    protocol.ConfigSnapshot(model_name:) ->
      case model_name {
        Some(name) ->
          Model(..model, current_model: name, notice: "model: " <> name)
        None -> model
      }
    protocol.EntryAdded(record:) -> {
      let protocol.EntryRecord(strand:, ..) = record
      let updated =
        Model(
          ..model,
          records: [record, ..model.records],
          streams: clear_streams(model.streams, strand),
          pending_records: case strand == model.active_strand {
            True -> [record, ..model.pending_records]
            False -> model.pending_records
          },
        )
      case strand == model.active_strand {
        True -> invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.StreamDelta(strand:, kind:, text:) -> {
      let updated =
        Model(
          ..model,
          streams: append_stream(model.streams, strand, kind, text),
          notice: "streaming " <> kind,
        )
      case strand == model.active_strand {
        True -> invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.OperationChanged(strand:, phase:) -> {
      let submitting = case model.submitting {
        Some(target) if target == strand -> None
        other -> other
      }
      let updated =
        Model(
          ..model,
          submitting:,
          strands: set_strand_phase(model.strands, strand, phase),
          streams: case phase == "done" {
            True -> clear_streams(model.streams, strand)
            False -> model.streams
          },
          notice: strand <> ": " <> phase,
        )
      let settled = settle_interrupt(updated, strand, phase)
      case phase == "done" && strand == model.active_strand {
        True -> invalidate_transcript(settled)
        False -> settled
      }
    }
    protocol.UsageChanged(usage:) -> {
      let usage = add_usage(model.usage, usage)
      Model(..model, usage:, notice: tokens(usage.total_tokens) <> " tokens")
    }
    protocol.EscalationPending(id:, tool:, preview: _) ->
      append_error(model, "approval required for " <> tool <> " [" <> id <> "]")
    protocol.ServerError(code:, message:) ->
      append_error(Model(..model, submitting: None), code <> ": " <> message)
    protocol.Ignored(_) -> model
  }
}

fn set_strand_phase(
  strands: List(protocol.Strand),
  target: String,
  phase: String,
) -> List(protocol.Strand) {
  list.map(strands, fn(strand) {
    let Strand(id:, ..) = strand
    case id == target, phase {
      True, "done" -> Strand(..strand, live_phase: None)
      True, _ -> Strand(..strand, live_phase: Some(phase))
      False, _ -> strand
    }
  })
}

fn append_stream(
  streams: List(Stream),
  strand: String,
  kind: String,
  fragment: String,
) -> List(Stream) {
  case streams {
    [] -> [Stream(strand:, kind:, fragments: [fragment])]
    [Stream(strand: owner, kind: stream_kind, fragments: current), ..rest] ->
      case owner == strand && stream_kind == kind {
        True -> [
          Stream(strand:, kind:, fragments: case kind {
            "tool_call" -> [fragment]
            _ -> [fragment, ..current]
          }),
          ..rest
        ]
        False -> [
          Stream(strand: owner, kind: stream_kind, fragments: current),
          ..append_stream(rest, strand, kind, fragment)
        ]
      }
  }
}

fn clear_streams(streams: List(Stream), strand: String) -> List(Stream) {
  list.filter(streams, fn(stream) {
    let Stream(strand: owner, ..) = stream
    owner != strand
  })
}

fn stream_lines(
  streams: List(Stream),
  active_strand: String,
  details_expanded: Bool,
) -> List(Line) {
  streams
  |> list.filter_map(fn(stream) {
    let Stream(strand:, kind:, fragments:) = stream
    case strand == active_strand {
      False -> Error(Nil)
      True -> {
        let text = fragments |> list.reverse |> string.concat
        Ok(case kind {
          "thinking" ->
            Line(Reasoning, case details_expanded {
              True -> text
              False -> compact(text, 140)
            })
          "tool_call" -> Line(ToolCall, live_tool_call_summary(text))
          _ -> Line(Assistant, text)
        })
      }
    }
  })
}

/// Bounds a partial tool call to its name until durable arguments arrive.
@internal
pub fn live_tool_call_summary(name: String) -> String {
  text_hygiene.single_line(name) <> " · preparing arguments…"
}

fn record_lines(
  records: List(protocol.EntryRecord),
  active_strand: String,
  details_expanded: Bool,
) -> List(Line) {
  records
  |> list.reverse
  |> list.filter(fn(record) {
    let protocol.EntryRecord(strand:, ..) = record
    strand == active_strand
  })
  |> list.flat_map(fn(record) {
    let protocol.EntryRecord(entry: value, ..) = record
    entry_lines(value, details_expanded)
  })
}

fn entry_lines(value: entry.Entry, details_expanded: Bool) -> List(Line) {
  case value {
    entry.MessageEntry(message: value, ..) ->
      case agent_notes_payload(value) {
        Some(_) -> []
        None -> message_lines(value, details_expanded)
      }
    entry.CompactionEntry(summary:, tokens_before:, ..) -> [
      Line(
        System,
        "compacted " <> tokens(tokens_before) <> " tokens · " <> summary,
      ),
    ]
    entry.BranchSummaryEntry(summary:, ..) -> [
      Line(System, "branch summary · " <> summary),
    ]
    entry.CustomEntry(custom_type:, data:, ..) -> [
      Line(System, "custom/" <> custom_type <> option_json(data)),
    ]
  }
}

const agent_notes_intro = "Your own notes for strand `"

/// Extracts the server-injected notes digest from a run-start message.
///
/// Run-start context is stored as an ordinary user-role message by the frozen
/// entry schema. The TUI recognizes the server-owned fenced preamble so this
/// machine context does not masquerade as operator-authored conversation.
@internal
pub fn agent_notes_payload(value: message.AgentMessage) -> Option(String) {
  case value {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) ->
      case
        string.starts_with(text, agent_notes_intro),
        string.split_once(text, "\n```agent-notes\n")
      {
        True, Ok(#(_, fenced)) ->
          case string.split_once(fenced, "\n```") {
            Ok(#(payload, _)) -> Some(payload)
            Error(Nil) -> None
          }
        _, _ -> None
      }
    _ -> None
  }
}

fn message_lines(
  value: message.AgentMessage,
  details_expanded: Bool,
) -> List(Line) {
  case value {
    message.UserMessage(content:, ..) -> [
      Line(
        User,
        content
          |> list.map(user_block_text)
          |> string.join("\n")
          |> composer.transcript_text(details_expanded),
      ),
    ]
    message.AssistantMessage(content:, error_message:, ..) -> {
      let lines =
        list.flat_map(content, assistant_block_lines(_, details_expanded))
      case error_message {
        Some(reason) -> list.append(lines, [Line(Failure, reason)])
        None -> lines
      }
    }
    message.ToolResultMessage(tool_name:, content:, details:, is_error:, ..) ->
      tool_result_lines(tool_name, content, details, is_error, details_expanded)
    message.CustomMessage(schema:, payload:) -> [
      Line(System, schema <> " · " <> json.to_string(payload)),
    ]
  }
}

fn user_block_text(block: message.UserBlock) -> String {
  case block {
    message.UserText(text:, ..) -> text
    message.UserImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

fn assistant_block_lines(
  block: message.AssistantBlock,
  details_expanded: Bool,
) -> List(Line) {
  case block {
    message.AssistantText(text:, ..) -> [Line(Assistant, text)]
    message.AssistantThinking(thinking:, redacted:, ..) ->
      case redacted {
        True -> [Line(Reasoning, "redacted")]
        False -> [
          Line(Reasoning, case details_expanded {
            True -> thinking
            False -> compact(thinking, 140)
          }),
        ]
      }
    message.AssistantToolCall(call:) -> {
      let message.ToolCall(name:, arguments:, ..) = call
      case
        code_mode_program(name, arguments, details_expanded),
        patch_program(name, arguments, details_expanded)
      {
        Some(program), _ -> [
          Line(ToolCall, "code_mode"),
          Line(ToolDetail, program),
        ]
        None, Some(program) -> [
          Line(ToolCall, "apply_patch"),
          Line(ToolDetail, program),
        ]
        None, None -> [
          Line(ToolCall, tool_call_summary(name, arguments, details_expanded)),
        ]
      }
    }
  }
}

fn patch_program(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> Option(String) {
  case name, arguments {
    "apply_patch", json.Object(fields) ->
      case string_field(fields, "patch") {
        Some(patch) -> {
          let source = case details_expanded {
            True -> patch
            False -> program_preview(patch, 24)
          }
          Some("```diff\n" <> source <> "\n```")
        }
        None -> None
      }
    _, _ -> None
  }
}

/// Renders a structured code-mode call as bounded fenced Gleam.
///
/// This is internal because the shape belongs to the transcript projection;
/// it is public only so the executed-program display law can be pinned.
///
/// ## Examples
///
/// ```gleam
/// let arguments = json.Object([#("program", json.String("pub fn main() {}"))])
/// let assert Some(source) = tui_gleam.code_mode_program("code_mode", arguments, True)
/// ```
@internal
pub fn code_mode_program(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> Option(String) {
  case name, arguments {
    "code_mode", json.Object(fields) ->
      case list.key_find(fields, "program") {
        Ok(json.String(program)) -> {
          let source = case details_expanded {
            True -> program
            False -> program_preview(program, 12)
          }
          Some(fenced_gleam(source))
        }
        Ok(_) | Error(Nil) -> None
      }
    _, _ -> None
  }
}

fn fenced_gleam(source: String) -> String {
  case string.ends_with(source, "\n") {
    True -> "```gleam\n" <> source <> "```"
    False -> "```gleam\n" <> source <> "\n```"
  }
}

fn program_preview(program: String, limit: Int) -> String {
  let lines = string.split(program, "\n")
  case list.drop(lines, limit) {
    [] -> program
    _ ->
      lines
      |> list.take(limit)
      |> list.append(["// …"])
      |> string.join("\n")
  }
}

/// Formats the operator-relevant part of a tool call without exposing the
/// transport JSON envelope as the primary UI.
@internal
pub fn tool_call_summary(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> String {
  let rendered = json.to_string(arguments)
  case name, arguments {
    "bash", json.Object(fields) ->
      case string_field(fields, "command") {
        Some(command) ->
          case details_expanded {
            True -> "Bash($ " <> command <> ")"
            False -> "Bash(" <> compact(command, 112) <> ")"
          }
        None -> generic_tool_call(name, rendered, details_expanded)
      }
    "read", json.Object(fields) ->
      case string_field(fields, "path") {
        Some(path) -> "Read(" <> compact(path, 112) <> ")"
        None -> generic_tool_call(name, rendered, details_expanded)
      }
    "agent_spawn", json.Object(fields) ->
      case string_field(fields, "purpose") {
        Some(purpose) ->
          case details_expanded {
            True ->
              "agent_spawn\npurpose: "
              <> purpose
              <> option_text(string_field(fields, "brief"), "\nbrief: ")
            False -> "agent_spawn · " <> compact(purpose, 108)
          }
        None -> generic_tool_call(name, rendered, details_expanded)
      }
    "agent_wait", json.Object(fields) ->
      case list.key_find(fields, "handles") {
        Ok(json.Array(handles)) ->
          "agent_wait · "
          <> int.to_string(list.length(handles))
          <> case handles {
            [_] -> " subagent"
            _ -> " subagents"
          }
        _ -> generic_tool_call(name, rendered, details_expanded)
      }
    "agent_note", json.Object(fields) ->
      "agent_note" <> option_text(string_field(fields, "key"), " · ")
    "agent_notes", json.Object(fields) ->
      "agent_notes" <> option_text(string_field(fields, "prefix"), " · ")
    _, _ -> generic_tool_call(name, rendered, details_expanded)
  }
}

fn generic_tool_call(
  name: String,
  rendered: String,
  details_expanded: Bool,
) -> String {
  case details_expanded {
    True -> name <> "\n" <> rendered
    False -> name <> " · " <> compact(rendered, 120)
  }
}

fn option_text(value: Option(String), prefix: String) -> String {
  case value {
    Some(text) -> prefix <> text
    None -> ""
  }
}

fn string_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Some(value)
    _ -> None
  }
}

fn tool_result_lines(
  tool_name: String,
  content: List(message.ToolResultBlock),
  details: Option(json.JsonValue),
  is_error: Bool,
  details_expanded: Bool,
) -> List(Line) {
  let result = content |> list.map(tool_result_text) |> string.join("\n")
  case tool_name, is_error, details {
    "code_mode", False, Some(json.Object(fields)) ->
      code_mode_result_lines(fields, result, details_expanded)
    _, True, _ -> [
      Line(ToolFailure, case details_expanded {
        True -> tool_name <> "\n" <> result
        False -> tool_name <> " · " <> compact(result, 120)
      }),
    ]
    _, False, _ -> [
      Line(ToolResult, case details_expanded {
        True -> tool_name <> "\n" <> result
        False -> tool_name <> " · " <> compact(result, 120)
      }),
    ]
  }
}

fn code_mode_result_lines(
  fields: List(#(String, json.JsonValue)),
  fallback: String,
  details_expanded: Bool,
) -> List(Line) {
  let status = string_field(fields, "status") |> option.unwrap("completed")
  let value = case list.key_find(fields, "value") {
    Ok(value) -> value
    Error(Nil) -> json.String(fallback)
  }
  let sandbox = sandbox_summary(fields)
  case details_expanded {
    False -> [
      Line(
        ToolResult,
        "code_mode · "
          <> status
          <> " · result "
          <> compact(json.to_string(value), 90)
          <> option_text(sandbox, " · "),
      ),
    ]
    True -> [
      Line(ToolResult, "code_mode · " <> status),
      Line(
        ToolDetail,
        "result\n\n```json\n" <> pretty_json(value, 0) <> "\n```",
      ),
      ..case sandbox {
        Some(summary) -> [Line(System, summary)]
        None -> []
      }
    ]
  }
}

fn sandbox_summary(fields: List(#(String, json.JsonValue))) -> Option(String) {
  case list.key_find(fields, "sandbox") {
    Ok(json.Object(sandbox)) -> {
      let build = enforcement_summary(sandbox, "build")
      let node = enforcement_summary(sandbox, "node")
      Some("sandbox · build " <> build <> " · satellite " <> node)
    }
    _ -> None
  }
}

fn enforcement_summary(
  sandbox: List(#(String, json.JsonValue)),
  name: String,
) -> String {
  case list.key_find(sandbox, name) {
    Ok(json.Object(report)) -> {
      let reported = case list.key_find(report, "reported") {
        Ok(json.Bool(value)) -> value
        _ -> False
      }
      let enforced = json_array_length(report, "enforced")
      let skipped = json_array_length(report, "skipped")
      case reported {
        True ->
          "enforced "
          <> int.to_string(enforced)
          <> " layers; skipped "
          <> int.to_string(skipped)
        False -> "not launched"
      }
    }
    _ -> "not reported"
  }
}

fn json_array_length(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Int {
  case list.key_find(fields, name) {
    Ok(json.Array(items)) -> list.length(items)
    _ -> 0
  }
}

fn pretty_json(value: json.JsonValue, depth: Int) -> String {
  let indent = string.repeat("  ", depth)
  let child_indent = string.repeat("  ", depth + 1)
  case value {
    json.Object([]) -> "{}"
    json.Object(fields) ->
      fields
      |> list.map(fn(field) {
        let #(name, value) = field
        child_indent
        <> json.to_string(json.String(name))
        <> ": "
        <> pretty_json(value, depth + 1)
      })
      |> string.join(",\n")
      |> fn(body) { "{\n" <> body <> "\n" <> indent <> "}" }
    json.Array([]) -> "[]"
    json.Array(items) ->
      items
      |> list.map(fn(item) { child_indent <> pretty_json(item, depth + 1) })
      |> string.join(",\n")
      |> fn(body) { "[\n" <> body <> "\n" <> indent <> "]" }
    scalar -> json.to_string(scalar)
  }
}

fn compact(text: String, limit: Int) -> String {
  let one_line = text_hygiene.single_line(text)
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _ -> string.slice(one_line, 0, limit - 1) <> "…"
  }
}

fn tool_result_text(block: message.ToolResultBlock) -> String {
  case block {
    message.ToolResultText(text:, ..) -> text
    message.ToolResultImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

fn option_json(value: Option(json.JsonValue)) -> String {
  case value {
    Some(data) -> " · " <> json.to_string(data)
    None -> ""
  }
}

fn tokens(value: Int) -> String {
  case value >= 1_000_000, value >= 1000 {
    True, _ -> int.to_string(value / 1_000_000) <> "m"
    False, True -> int.to_string(value / 1000) <> "k"
    False, False -> int.to_string(value)
  }
}

fn zero_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

fn add_usage(left: message.Usage, right: message.Usage) -> message.Usage {
  let message.UsageCost(
    input: left_cost_input,
    output: left_cost_output,
    cache_read: left_cost_cache_read,
    cache_write: left_cost_cache_write,
    total: left_cost_total,
  ) = left.cost
  let message.UsageCost(
    input: right_cost_input,
    output: right_cost_output,
    cache_read: right_cost_cache_read,
    cache_write: right_cost_cache_write,
    total: right_cost_total,
  ) = right.cost
  message.Usage(
    input: left.input + right.input,
    output: left.output + right.output,
    cache_read: left.cache_read + right.cache_read,
    cache_write: left.cache_write + right.cache_write,
    cache_write_1h: add_optional_int(left.cache_write_1h, right.cache_write_1h),
    reasoning: add_optional_int(left.reasoning, right.reasoning),
    total_tokens: left.total_tokens + right.total_tokens,
    cost: message.UsageCost(
      input: left_cost_input +. right_cost_input,
      output: left_cost_output +. right_cost_output,
      cache_read: left_cost_cache_read +. right_cost_cache_read,
      cache_write: left_cost_cache_write +. right_cost_cache_write,
      total: left_cost_total +. right_cost_total,
    ),
  )
}

fn add_optional_int(left: Option(Int), right: Option(Int)) -> Option(Int) {
  case left, right {
    None, None -> None
    Some(value), None | None, Some(value) -> Some(value)
    Some(left), Some(right) -> Some(left + right)
  }
}

/// Formats the server-reported session usage for the terminal footer.
@internal
pub fn usage_summary(usage: message.Usage) -> String {
  "in "
  <> tokens(usage.input)
  <> " · out "
  <> tokens(usage.output)
  <> " · cache "
  <> tokens(usage.cache_read)
  <> "/"
  <> tokens(usage.cache_write)
  <> " · $"
  <> float.to_string(usage.cost.total)
}

fn update_key(key: keys.Key, model: Model) -> Model {
  case key == keys.Ctrl("c") {
    True -> quit(model)
    False ->
      case model.overlay {
        ModelSelector(selector) -> update_model_selector(key, model, selector)
        AgentInspector(selected) -> update_agent_inspector(key, model, selected)
        NoOverlay -> update_main_key(key, model)
      }
  }
}

fn update_model_selector(
  key: keys.Key,
  model: Model,
  selector: model_selector.State,
) -> Model {
  case model_selector.update(key, selector) {
    model_selector.Continue(next) ->
      Model(..model, overlay: ModelSelector(next))
    model_selector.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "model selection cancelled",
      )
    model_selector.Choose(name) -> {
      let selected =
        Model(
          ..model,
          overlay: NoOverlay,
          current_model: name,
          repaint_phase: !model.repaint_phase,
          notice: "model: " <> name,
        )
        |> send_frame(protocol.set_model(
          model.next_id,
          model.active_strand,
          name,
        ))
      append_system(selected, "active model changed to " <> name)
    }
  }
}

fn update_agent_inspector(key: keys.Key, model: Model, selected: Int) -> Model {
  case key {
    keys.Escape | keys.Tab ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "agents closed",
      )
    keys.Up ->
      Model(
        ..model,
        overlay: AgentInspector(agents.move_selection(
          selected,
          list.length(model.strands),
          False,
        )),
      )
    keys.Down ->
      Model(
        ..model,
        overlay: AgentInspector(agents.move_selection(
          selected,
          list.length(model.strands),
          True,
        )),
      )
    keys.Enter ->
      case agents.selected_strand(model.strands, selected) {
        Some(strand) -> switch_active_strand(model, strand)
        None -> model
      }
    keys.PageUp
    | keys.PageDown
    | keys.Backspace
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.BackTab
    | keys.Home
    | keys.End
    | keys.Alt(_)
    | keys.Ctrl(_)
    | keys.Char(_)
    | keys.Insert
    | keys.F(_)
    | keys.Unknown(_) -> model
  }
}

fn update_main_key(key: keys.Key, model: Model) -> Model {
  let suggestions = command.suggestions(text_area.value(model.input))
  case suggestions, command_palette_escape(key), key {
    [_, ..], True, _ ->
      Model(
        ..model,
        input: text_area.state_new(),
        command_selected: 0,
        notice: "commands closed",
      )
    [_, ..], False, keys.Up ->
      Model(
        ..model,
        command_selected: command.move_selection(
          model.command_selected,
          list.length(suggestions),
          False,
        ),
      )
    [_, ..], False, keys.Down ->
      Model(
        ..model,
        command_selected: command.move_selection(
          model.command_selected,
          list.length(suggestions),
          True,
        ),
      )
    [_, ..], False, keys.Tab ->
      case command.selected(suggestions, model.command_selected) {
        Some(value) ->
          Model(
            ..model,
            input: text_area.state_from_string(value),
            command_selected: 0,
          )
        None -> model
      }
    _, _, _ -> update_main_key_without_palette(key, model)
  }
}

/// Reports whether Escape belongs to an open slash-command palette.
@internal
pub fn command_palette_escape(key: keys.Key) -> Bool {
  key == keys.Escape
}

fn update_main_key_without_palette(key: keys.Key, model: Model) -> Model {
  case key, model.help_open, model.notes_open {
    keys.Ctrl("g"), _, _ -> toggle_details(model)
    keys.PageUp, _, _ -> scroll_transcript(model, True, 10)
    keys.PageDown, _, _ -> scroll_transcript(model, False, 10)
    keys.Escape, True, _ ->
      Model(
        ..model,
        help_open: False,
        scroll_offset: 0,
        repaint_phase: !model.repaint_phase,
        notice: "help closed",
      )
    keys.Escape, False, True ->
      Model(
        ..model,
        notes_open: False,
        scroll_offset: 0,
        repaint_phase: !model.repaint_phase,
        notice: "agent notes closed",
      )
    keys.Escape, False, False -> interrupt_active(model)
    keys.Tab, False, False -> toggle_submission_mode(model)
    keys.BackTab, False, False -> toggle_agent_rail(model)
    keys.Up, False, False -> navigate_history(model, True)
    keys.Down, False, False -> navigate_history(model, False)
    keys.Enter, False, False -> submit(model)
    keys.Backspace, False, False ->
      case text_area.value(model.input), model.attachments {
        "", [_, ..] -> {
          let attachments = composer.drop_last(model.attachments)
          Model(
            ..model,
            attachments:,
            notice: composer.summary(attachments)
              |> option.unwrap("paste removed"),
          )
        }
        _, _ -> {
          let input = text_area.backspace(model.input)
          Model(
            ..model,
            input:,
            history_index: 0,
            history_draft: text_area.value(input),
            command_selected: 0,
          )
        }
      }
    keys.Left, False, False ->
      Model(..model, input: text_area.move_cursor_left(model.input))
    keys.Right, False, False ->
      Model(..model, input: text_area.move_cursor_right(model.input))
    keys.Home, False, False ->
      Model(..model, input: text_area.move_to_line_start(model.input))
    keys.End, False, False ->
      Model(..model, input: text_area.move_to_line_end(model.input))
    keys.Alt(character), False, False -> interrupt_and_insert(model, character)
    keys.Char(character), False, False -> {
      let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
      Model(
        ..model,
        input: text_area.insert_char(editor, model.input, character),
        history_index: 0,
        history_draft: text_area.value(model.input) <> character,
        command_selected: 0,
      )
    }
    _, _, _ -> model
  }
}

// Transcript movement has one definition for keyboard and wheel input. The
// offset is measured backward from the newest wrapped row, so moving toward
// the present clamps at zero and resumes tail following.
fn scroll_transcript(model: Model, older: Bool, rows: Int) -> Model {
  let scroll_offset =
    scroll_offset(model.scroll_offset, older, rows)
    |> bounded_scroll_offset(
      model.rendered_row_count,
      transcript_viewport_height(model),
    )
  Model(..model, scroll_offset:, notice: case scroll_offset == 0 {
    True -> "following output"
    False -> "scrollback"
  })
}

fn transcript_viewport_height(model: Model) -> Int {
  int.max(1, model.height - input_height(model) - 4)
}

fn transcript_width(model: Model) -> Int {
  let rail_width = case model.agent_rail_visible && model.width >= 100 {
    True -> 34
    False -> 0
  }
  int.max(1, model.width - rail_width - 2)
}

/// Moves a transcript offset without allowing it to cross the live tail.
///
/// This is internal because transcript offsets belong to the terminal model;
/// it is public only so the input law can be pinned without running a PTY.
///
/// ## Examples
///
/// ```gleam
/// assert tui_gleam.scroll_offset(3, False, 10) == 0
/// assert tui_gleam.scroll_offset(3, True, 10) == 13
/// ```
@internal
pub fn scroll_offset(offset: Int, older: Bool, rows: Int) -> Int {
  case older {
    True -> offset + rows
    False -> int.max(0, offset - rows)
  }
}

/// Clamps scrollback to the oldest full viewport that actually exists.
@internal
pub fn bounded_scroll_offset(
  offset: Int,
  total_rows: Int,
  viewport_rows: Int,
) -> Int {
  int.min(int.max(0, offset), int.max(0, total_rows - viewport_rows))
}

/// Keeps a historical viewport anchored as rows are appended or replaced.
///
/// A zero offset follows the live tail. A non-zero offset moves by the wrapped
/// row delta so provider fragments cannot pull the reader away from scrollback.
///
/// ## Examples
///
/// ```gleam
/// assert tui_gleam.anchored_scroll_offset(0, 20, 23) == 0
/// assert tui_gleam.anchored_scroll_offset(8, 20, 23) == 11
/// ```
@internal
pub fn anchored_scroll_offset(offset: Int, before: Int, after: Int) -> Int {
  case offset == 0 {
    True -> 0
    False -> int.max(0, offset + after - before)
  }
}

fn submit(model: Model) -> Model {
  let input = text_area.value(model.input)
  let expanded = composer.expand(input, model.attachments)
  let remembered = remember_submission(model, input)
  let cleared =
    Model(
      ..remembered,
      input: text_area.state_new(),
      history_index: 0,
      history_draft: "",
    )
  let prompt_cleared =
    Model(..cleared, attachments: [], submission_mode: SteerNow)
  case command.parse(input) {
    command.Empty ->
      case model.attachments {
        [] -> cleared
        _ -> send_prompt(prompt_cleared, expanded)
      }
    command.Quit -> quit(cleared)
    command.Help ->
      Model(
        ..cleared,
        help_open: True,
        notes_open: False,
        scroll_offset: 0,
        repaint_phase: !cleared.repaint_phase,
        notice: "/help",
      )
    command.Clear ->
      Model(
        ..cleared,
        transcript: [],
        records: [],
        record_rows: [],
        pending_records: [],
        record_cache_valid: False,
        notice: "local view cleared",
      )
      |> invalidate_transcript
    command.Models -> {
      let opened =
        Model(
          ..cleared,
          overlay: ModelSelector(model_selector.new(
            model.models,
            model.current_model,
          )),
          repaint_phase: !cleared.repaint_phase,
          notice: "model selector",
        )
      send_frame(opened, protocol.models(opened.next_id))
    }
    command.Model(name) -> {
      let switched =
        Model(..cleared, current_model: name)
        |> send_frame(protocol.set_model(
          cleared.next_id,
          cleared.active_strand,
          name,
        ))
      append_system(switched, "active model changed to " <> name)
    }
    command.Strands | command.Agents ->
      Model(
        ..cleared,
        overlay: AgentInspector(active_strand_index(
          cleared.strands,
          cleared.active_strand,
        )),
        repaint_phase: !cleared.repaint_phase,
        notice: "agent inspector",
      )
    command.Notes ->
      Model(
        ..cleared,
        help_open: False,
        notes_open: True,
        scroll_offset: 0,
        repaint_phase: !cleared.repaint_phase,
        notice: "agent notes",
      )
    command.Details -> toggle_details(cleared)
    command.Strand(name) ->
      case is_known_strand(cleared.strands, name) {
        True ->
          append_system(
            switch_active_strand(cleared, name),
            "active strand: " <> name,
          )
        False -> append_error(cleared, "unknown strand: " <> name)
      }
    command.Fork(name) ->
      send_frame(
        append_system(cleared, "fork queued: " <> name),
        protocol.fork(cleared.next_id, cleared.active_strand, name),
      )
    command.Compact ->
      send_frame(
        append_system(
          cleared,
          "compaction queued for " <> cleared.active_strand,
        ),
        protocol.compact(cleared.next_id, cleared.active_strand),
      )
    command.Abort ->
      send_frame(
        append_system(cleared, "abort queued for " <> cleared.active_strand),
        protocol.abort(cleared.next_id, cleared.active_strand),
      )
    command.Steer(text) ->
      send_explicit_steer(
        prompt_cleared,
        composer.expand(text, model.attachments),
        model,
      )
    command.Queue(text) ->
      send_follow_up(prompt_cleared, composer.expand(text, model.attachments))
    command.Unknown(name) -> append_error(cleared, "unknown command /" <> name)
    command.MissingArgument(name) ->
      append_error(cleared, "/" <> name <> " needs an argument")
    command.Prompt(_) -> send_user_text(prompt_cleared, expanded, model)
  }
}

// Submitted text is newest-first so Up is a constant-time move to the common
// case. Consecutive duplicates collapse because resend remains available
// without allowing accidental double-enter presses to crowd out useful history.
fn remember_submission(model: Model, text: String) -> Model {
  case string.trim(text), model.history {
    "", _ -> model
    value, [latest, ..] if value == latest -> model
    value, history -> Model(..model, history: [value, ..history])
  }
}

// The draft is captured exactly once when navigation leaves the live editor.
// Returning past the newest history item restores those unsent bytes rather
// than replacing them with an empty prompt.
fn navigate_history(model: Model, older: Bool) -> Model {
  let #(history_index, history_draft, value) =
    history_selection(
      model.history,
      model.history_index,
      model.history_draft,
      text_area.value(model.input),
      older,
    )
  Model(
    ..model,
    input: text_area.state_from_string(value),
    history_index:,
    history_draft:,
  )
}

/// Selects the next prompt-history value without owning terminal state.
///
/// ## Examples
///
/// ```gleam
/// assert tui_gleam.history_selection(["new", "old"], 0, "", "draft", True)
///   == #(1, "draft", "new")
/// assert tui_gleam.history_selection(["new"], 1, "draft", "new", False)
///   == #(0, "draft", "draft")
/// ```
@internal
pub fn history_selection(
  history: List(String),
  index: Int,
  draft: String,
  current: String,
  older: Bool,
) -> #(Int, String, String) {
  let saved_draft = case index == 0, older {
    True, True -> current
    _, _ -> draft
  }
  let target = case older {
    True -> int.min(list.length(history), index + 1)
    False -> int.max(0, index - 1)
  }
  case target {
    0 -> #(0, saved_draft, saved_draft)
    _ ->
      case history_item(history, target - 1) {
        Some(value) -> #(target, saved_draft, value)
        None -> #(index, saved_draft, current)
      }
  }
}

fn history_item(history: List(String), index: Int) -> Option(String) {
  case history, index {
    [item, ..], 0 -> Some(item)
    [_, ..rest], index -> history_item(rest, index - 1)
    [], _ -> None
  }
}

fn send_user_text(cleared: Model, text: String, before: Model) -> Model {
  case active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None ->
      case active_strand_live(before), before.submission_mode {
        False, _ -> send_prompt(cleared, text)
        True, SteerNow -> send_steer(cleared, text)
        True, QueueAfter -> send_follow_up(cleared, text)
      }
  }
}

fn send_explicit_steer(cleared: Model, text: String, before: Model) -> Model {
  case active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None -> send_steer(cleared, text)
  }
}

// The server refuses steer admissions after cancel_requested and abort drains
// anything admitted before it. The client therefore retains the instruction
// until the terminal transition, then starts the replacement turn exactly once.
fn hold_or_send_interrupt(
  cleared: Model,
  before: Model,
  strand: String,
  text: String,
) -> Model {
  case active_strand_live(before) {
    False -> send_prompt_to(Model(..cleared, interrupt: None), strand, text)
    True -> {
      let pending = case before.interrupt {
        Some(Interrupt(pending: Some(earlier), ..)) ->
          Some(earlier <> "\n\n" <> text)
        _ -> Some(text)
      }
      Model(
        ..cleared,
        interrupt: Some(Interrupt(strand:, pending:)),
        notice: "steer captured; waiting for stop",
      )
    }
  }
}

fn send_prompt(model: Model, text: String) -> Model {
  send_prompt_to(model, model.active_strand, text)
}

// The local submitting marker closes the interval between writing a prompt
// frame and receiving its first operation transition. Websocket ordering then
// lets an immediate Escape place abort after prompt on the same connection,
// even though the server's live phase has not reached the view yet.
fn send_prompt_to(model: Model, strand: String, text: String) -> Model {
  case model.socket {
    Some(_) ->
      send_frame(
        Model(
          ..model,
          submitting: Some(strand),
          notice: "prompt sent to " <> strand,
        ),
        protocol.prompt(model.next_id, strand, text),
      )
    None ->
      Model(
        ..model,
        transcript: list.append(model.transcript, [
          Line(User, composer.transcript_text(text, model.details_expanded)),
          Line(Assistant, "Design-preview echo received."),
        ]),
        record_cache_valid: False,
        notice: "prompt accepted",
      )
      |> invalidate_transcript
  }
}

fn send_steer(model: Model, text: String) -> Model {
  send_frame(
    Model(..model, notice: "steered " <> model.active_strand),
    protocol.steer(model.next_id, model.active_strand, text),
  )
}

fn send_follow_up(model: Model, text: String) -> Model {
  send_frame(
    Model(..model, notice: "queued after " <> model.active_strand),
    protocol.follow_up(model.next_id, model.active_strand, text),
  )
}

fn toggle_submission_mode(model: Model) -> Model {
  case
    active_interrupt(model),
    active_strand_live(model),
    model.submission_mode
  {
    Some(_), _, _ -> Model(..model, notice: "interrupt steer is already armed")
    None, False, _ ->
      Model(..model, notice: "queue is available while an agent runs")
    None, True, SteerNow ->
      Model(..model, submission_mode: QueueAfter, notice: "queue message")
    None, True, QueueAfter ->
      Model(..model, submission_mode: SteerNow, notice: "steer now")
  }
}

fn interrupt_active(model: Model) -> Model {
  case active_strand_phase(model), active_interrupt(model) {
    None, _ -> Model(..model, notice: "nothing is running")
    Some(_), Some(_) -> Model(..model, notice: "interrupt already requested")
    Some(_), None -> {
      let strand = model.active_strand
      send_frame(
        Model(
          ..model,
          interrupt: Some(Interrupt(strand:, pending: None)),
          submission_mode: SteerNow,
          notice: "interrupt requested; type the replacement steer",
        ),
        protocol.abort(model.next_id, strand),
      )
    }
  }
}

// Terminals encode Alt+character as Escape followed by that character. If a
// user begins typing immediately after Escape, the backend cannot distinguish
// the two intentions before its disambiguation timeout. The client reserves no
// Alt shortcuts, so preserving both actions here avoids dropping the first
// byte of a replacement steer.
fn interrupt_and_insert(model: Model, character: String) -> Model {
  let interrupted = interrupt_active(model)
  let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
  Model(
    ..interrupted,
    input: text_area.insert_char(editor, interrupted.input, character),
  )
}

fn active_interrupt(model: Model) -> Option(String) {
  case model.interrupt {
    Some(Interrupt(strand:, ..)) ->
      case strand == model.active_strand {
        True -> Some(strand)
        False -> None
      }
    None -> None
  }
}

fn settle_interrupt(model: Model, strand: String, phase: String) -> Model {
  case phase == "done", model.interrupt {
    True, Some(Interrupt(strand: target, pending:)) ->
      case target == strand, pending {
        True, Some(text) ->
          send_prompt_to(Model(..model, interrupt: None), target, text)
        True, None ->
          Model(..model, interrupt: None, notice: target <> ": interrupted")
        False, _ -> model
      }
    _, _ -> model
  }
}

fn toggle_agent_rail(model: Model) -> Model {
  let visible = !model.agent_rail_visible
  Model(
    ..model,
    agent_rail_visible: visible,
    repaint_phase: !model.repaint_phase,
    notice: case visible {
      True -> "agent rail shown"
      False -> "agent rail hidden"
    },
  )
}

fn active_strand_live(model: Model) -> Bool {
  case active_strand_phase(model) {
    Some(_) -> True
    None -> False
  }
}

fn active_strand_phase(model: Model) -> Option(String) {
  case model.submitting {
    Some(strand) if strand == model.active_strand -> Some("submitting")
    _ ->
      model.strands
      |> list.find_map(fn(strand) {
        let Strand(id:, live_phase:, ..) = strand
        case id == model.active_strand, live_phase {
          True, Some(phase) -> Ok(phase)
          _, _ -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None)
  }
}

fn toggle_details(model: Model) -> Model {
  let expanded = !model.details_expanded
  Model(
    ..model,
    details_expanded: expanded,
    repaint_phase: !model.repaint_phase,
    notice: case expanded {
      True -> "reasoning and tool detail expanded"
      False -> "reasoning and tool detail collapsed"
    },
  )
}

fn send_frame(model: Model, frame: String) -> Model {
  case model.socket {
    Some(socket) -> {
      connection.send(socket, frame)
      Model(..model, next_id: model.next_id + 1)
    }
    None -> model
  }
}

fn quit(model: Model) -> Model {
  case model.socket {
    Some(socket) -> connection.close(socket)
    None -> Nil
  }
  Model(..model, quit: True)
}

fn is_known_strand(strands: List(protocol.Strand), name: String) -> Bool {
  list.any(strands, fn(strand) {
    let Strand(id:, ..) = strand
    id == name
  })
}

fn switch_active_strand(model: Model, strand: String) -> Model {
  Model(
    ..model,
    overlay: NoOverlay,
    active_strand: strand,
    current_model: "loading…",
    scroll_offset: 0,
    record_cache_valid: False,
    repaint_phase: !model.repaint_phase,
    notice: "active strand: " <> strand,
  )
  |> invalidate_transcript
  |> send_frame(protocol.config(model.next_id, strand))
}

fn active_strand_index(strands: List(protocol.Strand), active: String) -> Int {
  active_strand_index_loop(strands, active, 0)
}

fn active_strand_index_loop(
  strands: List(protocol.Strand),
  active: String,
  index: Int,
) -> Int {
  case strands {
    [] -> 0
    [Strand(id:, ..), ..rest] ->
      case id == active {
        True -> index
        False -> active_strand_index_loop(rest, active, index + 1)
      }
  }
}

fn demo_models() -> List(protocol.ModelInfo) {
  [
    ModelInfo(
      name: "baseten-kimi-k3",
      dialect: "openai",
      model_id: "moonshotai/Kimi-K3",
      roles: ["default"],
      active: ["default"],
    ),
    ModelInfo(
      name: "baseten-deepseek-v4-flash",
      dialect: "openai",
      model_id: "deepseek-ai/DeepSeek-V4-Flash-0731",
      roles: ["fast"],
      active: [],
    ),
    ModelInfo(
      name: "baseten-glm-5-3",
      dialect: "openai",
      model_id: "zai-org/GLM-5.3",
      roles: ["deep"],
      active: [],
    ),
    ModelInfo(
      name: "baseten-glm-5-3-flash",
      dialect: "openai",
      model_id: "zai-org/GLM-5.3-Flash",
      roles: ["fast"],
      active: [],
    ),
  ]
}

fn demo_strands() -> List(protocol.Strand) {
  [
    Strand(id: "main", name: Some("main"), live_phase: Some("streaming")),
    Strand(
      id: "sub:main/catalog-audit-27af",
      name: Some("catalog audit"),
      live_phase: Some("running tools"),
    ),
    Strand(
      id: "sub:main/terminal-qa-8c1e",
      name: Some("terminal qa"),
      live_phase: None,
    ),
  ]
}

fn append_system(model: Model, text: String) -> Model {
  Model(
    ..model,
    transcript: list.append(model.transcript, [Line(System, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
}

fn append_error(model: Model, text: String) -> Model {
  Model(
    ..model,
    transcript: list.append(model.transcript, [Line(Failure, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
}

// Transcript revisions advance only beside mutations of the projection's
// source data. Keeping the invalidation token separate from terminal ticks
// prevents session history from becoming an idle-time CPU cost.
fn invalidate_transcript(model: Model) -> Model {
  Model(..model, render_revision: model.render_revision + 1)
}
