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
import etui/widgets/block
import etui/widgets/paragraph
import etui/widgets/statusbar
import etui/widgets/textarea as text_area
import gleam/erlang/process.{type Subject}
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
  Tool
  ToolCode
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
  Stream(strand: String, kind: String, text: String)
}

type Overlay {
  NoOverlay
  ModelSelector(model_selector.State)
  AgentInspector
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

type Model {
  Model(
    quit: Bool,
    width: Int,
    height: Int,
    input: text_area.TextAreaState,
    attachments: List(composer.Attachment),
    submission_mode: SubmissionMode,
    transcript: List(Line),
    records: List(protocol.EntryRecord),
    notice: String,
    help_open: Bool,
    overlay: Overlay,
    models: List(protocol.ModelInfo),
    current_model: String,
    strands: List(protocol.Strand),
    active_strand: String,
    session: String,
    inbox: Subject(connection.Message),
    socket: Option(connection.Connection),
    next_id: Int,
    total_tokens: Int,
    agent_rail_visible: Bool,
    details_expanded: Bool,
    streams: List(Stream),
    scroll_offset: Int,
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
      submission_mode: SteerNow,
      transcript: [
        Line(System, "etui input and gateway paths ready"),
        Line(
          Reasoning,
          "Mapped the frozen ClientGateway events onto one immutable view model.",
        ),
        Line(Tool, "read · packages/client/CLAUDE.md"),
        Line(
          Assistant,
          "## Native client\n\nThe pure-Gleam path is live. Use `/model` to switch models or `/help` for the command map.",
        ),
      ],
      records: [],
      notice: "interactive design preview",
      help_open: False,
      overlay: NoOverlay,
      models: demo_models(),
      current_model: "baseten-kimi-k3",
      strands: demo_strands(),
      active_strand: "main",
      session: "demo",
      inbox:,
      socket: None,
      next_id: 1,
      total_tokens: 0,
      agent_rail_visible: False,
      details_expanded: False,
      streams: [],
      scroll_offset: 0,
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
          Model(
            ..base,
            session:,
            socket: Some(socket),
            next_id: 3,
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
      16,
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
  let #(header_area, body_area, input_area, footer_area) = layout(screen)
  let #(transcript_panel, agent_panel) =
    body_layout(body_area, model.width, model.agent_rail_visible)
  let transcript_block =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.quiet, style.Default)
    |> block.with_title(
      " transcript / " <> text_hygiene.single_line(model.active_strand) <> " ",
      block.Top,
    )
  let input_block =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, style.Default)
    |> block.with_title(input_title(model), block.Top)
  let transcript_area = block.inner(transcript_panel, transcript_block)
  let #(paste_area, editor_area) =
    input_layout(block.inner(input_area, input_block), model.attachments)
  let editor =
    text_area.textarea_new()
    |> text_area.with_max_lines(1)
    |> text_area.with_colors(theme.paper, style.Default)
    |> text_area.with_cursor_style(style.new(
      theme.graphite,
      theme.signal,
      style.bold(),
    ))
  let base =
    buffer.buffer_new(screen)
    |> render_header(header_area, model)
    |> block.render(transcript_panel, transcript_block)
    |> render_transcript(transcript_area, model)
    |> render_agent_rail(agent_panel, model)
    |> block.render(input_area, input_block)
    |> render_paste_chip(paste_area, model.attachments)
    |> text_area.render(editor_area, editor, model.input)
    |> render_footer(footer_area, model)
  let rendered = case model.overlay {
    NoOverlay -> base
    ModelSelector(selector) -> model_selector.render(base, screen, selector)
    AgentInspector ->
      agents.render_overlay(base, screen, model.strands, model.active_strand)
  }
  let cursor = case model.overlay {
    NoOverlay -> text_area.cursor_screen_pos(model.input, editor_area)
    ModelSelector(_) | AgentInspector -> Error(Nil)
  }
  #(rendered, cursor)
}

fn layout(screen: Rect) -> #(Rect, Rect, Rect, Rect) {
  case geometry.split_v(screen, [Length(1), Fill, Length(3), Length(1)]) {
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
  let content = case model.help_open {
    True -> help_content()
    False ->
      model.transcript
      |> list.append(record_lines(
        model.records,
        model.active_strand,
        model.details_expanded,
      ))
      |> list.append(stream_lines(
        model.streams,
        model.active_strand,
        model.details_expanded,
      ))
      |> transcript_content
  }
  // The transcript is a tail-following viewport. Scrolling walks backward
  // from the newest wrapped row, so new output never disappears below a
  // clipped paragraph and no widget holds a second copy of conversation data.
  let visible =
    content.lines
    |> markdown.wrap_lines(area.size.width)
    |> list.reverse
    |> list.drop(model.scroll_offset)
    |> list.take(area.size.height)
    |> list.reverse
  paragraph.render_styled(buf, area, visible)
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
    Tool -> #("✓ tool   ", theme.current_bold())
    ToolCode -> #("✓ tool   ", theme.current_bold())
    ToolFailure -> #("× tool   ", theme.danger_text())
    Failure -> #("! error  ", theme.danger_text())
  }
  case line.speaker {
    Assistant | ToolCode ->
      markdown.render(line.text)
      |> prefix_rendered_lines(mark, mark_style)
    System | User | Reasoning | Tool | ToolFailure | Failure ->
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

fn render_footer(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let shortcuts = case active_strand_live(model) {
    True ->
      case model.submission_mode {
        SteerNow -> [
          span.span_styled(" enter ", theme.signal_bold()),
          span.span_styled("steer now   ", theme.quiet_text()),
          span.span_styled("tab ", theme.signal_bold()),
          span.span_styled("queue message   ", theme.quiet_text()),
        ]
        QueueAfter -> [
          span.span_styled(" enter ", theme.signal_bold()),
          span.span_styled("queue message   ", theme.quiet_text()),
          span.span_styled("tab ", theme.signal_bold()),
          span.span_styled("steer now   ", theme.quiet_text()),
        ]
      }
    False -> [
      span.span_styled(" /help ", theme.signal_bold()),
      span.span_styled("commands   ", theme.quiet_text()),
      span.span_styled("/agents ", theme.signal_bold()),
      span.span_styled("agents   ", theme.quiet_text()),
    ]
  }
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([
      span.line_new(
        list.append(shortcuts, [
          span.span_styled("shift+tab ", theme.signal_bold()),
          span.span_styled("rail   ", theme.quiet_text()),
          span.span_styled("ctrl+g ", theme.signal_bold()),
          span.span_styled("detail", theme.quiet_text()),
        ]),
      ),
    ])
    |> statusbar.with_right([
      span.line_new([
        span.span_styled(
          " " <> agents.summary(model.strands) <> " · " <> model.notice <> " ",
          theme.quiet_text(),
        ),
      ]),
    ])
  statusbar.render(buf, area, bar)
}

fn input_layout(
  area: Rect,
  attachments: List(composer.Attachment),
) -> #(Rect, Rect) {
  case composer.summary(attachments) {
    None -> #(geometry.rect_zero(), area)
    Some(summary) -> {
      let width = int.min(area.size.width, string.length(summary) + 3)
      case geometry.split_h(area, [Length(width), Fill]) {
        [paste_area, editor_area] -> #(paste_area, editor_area)
        _ -> #(area, geometry.rect_zero())
      }
    }
  }
}

fn input_title(model: Model) -> String {
  case active_status_label(model), model.submission_mode {
    None, _ -> " prompt · / commands "
    Some(_), QueueAfter -> " queue after turn · enter queues · tab steers "
    Some(status), SteerNow -> " " <> status <> " · enter steers · tab queues "
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

fn update(event: backend.InputEvent, model: Model) -> Model {
  case event {
    backend.Resize(width, height) -> Model(..model, width:, height:)
    backend.Tick -> drain_connection(model, 64)
    backend.KeyPress(key) -> update_key(keys.match(key), model)
    backend.Paste(text) -> handle_paste(model, text)
    backend.MouseScroll(_, _, up) -> scroll_transcript(model, up, 3)
    backend.MousePress(..)
    | backend.MouseRelease(..)
    | backend.MouseDrag(..)
    | backend.MouseMove(..) -> model
  }
}

fn handle_paste(model: Model, text: String) -> Model {
  case composer.classify(text) {
    composer.Inline(text) ->
      Model(..model, input: text_area.state_from_string(text))
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
    protocol.FullSnapshot(session:, strands:, entries:) ->
      Model(
        ..model,
        session:,
        strands:,
        records: entries,
        streams: [],
        scroll_offset: 0,
        notice: "session synchronized",
        transcript: [Line(System, "attached to session " <> session)],
      )
    protocol.StrandsSnapshot(strands:) ->
      Model(..model, strands:, notice: agents.summary(strands))
    protocol.ModelsSnapshot(models:) -> {
      let current_model =
        catalogue_active_model(models, model.active_strand, model.current_model)
      let overlay = case model.overlay {
        ModelSelector(selector) ->
          ModelSelector(model_selector.replace_models(
            selector,
            models,
            current_model,
          ))
        NoOverlay -> NoOverlay
        AgentInspector -> AgentInspector
      }
      Model(
        ..model,
        models:,
        current_model:,
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
      Model(
        ..model,
        records: list.append(model.records, [record]),
        streams: clear_streams(model.streams, strand),
        scroll_offset: 0,
      )
    }
    protocol.StreamDelta(strand:, kind:, text:) ->
      Model(
        ..model,
        streams: append_stream(model.streams, strand, kind, text),
        scroll_offset: case strand == model.active_strand {
          True -> 0
          False -> model.scroll_offset
        },
        notice: "streaming " <> kind,
      )
    protocol.OperationChanged(strand:, phase:) ->
      Model(
        ..model,
        strands: set_strand_phase(model.strands, strand, phase),
        streams: case phase == "done" {
          True -> clear_streams(model.streams, strand)
          False -> model.streams
        },
        notice: strand <> ": " <> phase,
      )
    protocol.UsageChanged(total_tokens:) ->
      Model(..model, total_tokens:, notice: tokens(total_tokens) <> " tokens")
    protocol.EscalationPending(id:, tool:, preview: _) ->
      append_error(model, "approval required for " <> tool <> " [" <> id <> "]")
    protocol.ServerError(code:, message:) ->
      append_error(model, code <> ": " <> message)
    protocol.Ignored(_) -> model
  }
}

fn catalogue_active_model(
  models: List(protocol.ModelInfo),
  strand: String,
  fallback: String,
) -> String {
  let role = case string.starts_with(strand, "sub:") {
    True -> "subagent"
    False -> "main"
  }
  models
  |> list.find(fn(model) {
    let ModelInfo(active:, ..) = model
    list.contains(active, role)
  })
  |> result.map(fn(model) {
    let ModelInfo(name:, ..) = model
    name
  })
  |> result.unwrap(fallback)
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
    [] -> [Stream(strand:, kind:, text: fragment)]
    [Stream(strand: owner, kind: stream_kind, text: current), ..rest] ->
      case owner == strand && stream_kind == kind {
        True -> [Stream(strand:, kind:, text: current <> fragment), ..rest]
        False -> [
          Stream(strand: owner, kind: stream_kind, text: current),
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
    let Stream(strand:, kind:, text:) = stream
    case strand == active_strand {
      False -> Error(Nil)
      True ->
        Ok(case kind {
          "thinking" ->
            Line(Reasoning, case details_expanded {
              True -> text
              False -> compact(text, 140)
            })
          "tool_call" ->
            Line(Tool, case details_expanded {
              True -> text
              False -> compact(text, 120)
            })
          _ -> Line(Assistant, text)
        })
    }
  })
}

fn record_lines(
  records: List(protocol.EntryRecord),
  active_strand: String,
  details_expanded: Bool,
) -> List(Line) {
  records
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
      message_lines(value, details_expanded)
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
    message.AssistantMessage(content:, ..) ->
      list.flat_map(content, assistant_block_lines(_, details_expanded))
    message.ToolResultMessage(tool_name:, content:, is_error:, ..) -> {
      let speaker = case is_error {
        True -> ToolFailure
        False -> Tool
      }
      let result = content |> list.map(tool_result_text) |> string.join("\n")
      [
        Line(speaker, case details_expanded {
          True -> tool_name <> "\n" <> result
          False -> tool_name <> " · " <> compact(result, 120)
        }),
      ]
    }
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
      let rendered = json.to_string(arguments)
      case code_mode_program(name, arguments, details_expanded) {
        Some(program) -> [Line(ToolCode, program)]
        None -> [
          Line(Tool, case details_expanded {
            True -> name <> "\n" <> rendered
            False -> name <> " · " <> compact(rendered, 120)
          }),
        ]
      }
    }
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

fn update_key(key: keys.Key, model: Model) -> Model {
  case key == keys.Ctrl("c") {
    True -> quit(model)
    False ->
      case model.overlay {
        ModelSelector(selector) -> update_model_selector(key, model, selector)
        AgentInspector ->
          case key == keys.Escape || key == keys.Tab {
            True -> Model(..model, overlay: NoOverlay, notice: "agents closed")
            False -> model
          }
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
      Model(..model, overlay: NoOverlay, notice: "model selection cancelled")
    model_selector.Choose(name) -> {
      let selected =
        Model(
          ..model,
          overlay: NoOverlay,
          current_model: name,
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

fn update_main_key(key: keys.Key, model: Model) -> Model {
  case key, model.help_open {
    keys.Ctrl("g"), _ -> toggle_details(model)
    keys.Tab, False -> toggle_submission_mode(model)
    keys.BackTab, False -> toggle_agent_rail(model)
    keys.PageUp, False -> scroll_transcript(model, True, 10)
    keys.PageDown, False -> scroll_transcript(model, False, 10)
    keys.Escape, True -> Model(..model, help_open: False, notice: "help closed")
    keys.Enter, False -> submit(model)
    keys.Backspace, False ->
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
        _, _ -> Model(..model, input: text_area.backspace(model.input))
      }
    keys.Left, False ->
      Model(..model, input: text_area.move_cursor_left(model.input))
    keys.Right, False ->
      Model(..model, input: text_area.move_cursor_right(model.input))
    keys.Home, False ->
      Model(..model, input: text_area.move_to_line_start(model.input))
    keys.End, False ->
      Model(..model, input: text_area.move_to_line_end(model.input))
    keys.Char(character), False -> {
      let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
      Model(
        ..model,
        input: text_area.insert_char(editor, model.input, character),
      )
    }
    _, _ -> model
  }
}

// Transcript movement has one definition for keyboard and wheel input. The
// offset is measured backward from the newest wrapped row, so moving toward
// the present clamps at zero and resumes tail following.
fn scroll_transcript(model: Model, older: Bool, rows: Int) -> Model {
  let scroll_offset = scroll_offset(model.scroll_offset, older, rows)
  Model(..model, scroll_offset:, notice: case scroll_offset == 0 {
    True -> "following output"
    False -> "scrollback"
  })
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

fn submit(model: Model) -> Model {
  let input = text_area.value(model.input)
  let expanded = composer.expand(input, model.attachments)
  let cleared = Model(..model, input: text_area.state_new())
  let prompt_cleared =
    Model(..cleared, attachments: [], submission_mode: SteerNow)
  case command.parse(input) {
    command.Empty ->
      case model.attachments {
        [] -> cleared
        _ -> send_prompt(prompt_cleared, expanded)
      }
    command.Quit -> quit(cleared)
    command.Help -> Model(..cleared, help_open: True, notice: "/help")
    command.Clear ->
      Model(
        ..cleared,
        transcript: [],
        records: [],
        notice: "local view cleared",
      )
    command.Models -> {
      let opened =
        Model(
          ..cleared,
          overlay: ModelSelector(model_selector.new(
            model.models,
            model.current_model,
          )),
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
      Model(..cleared, overlay: AgentInspector, notice: "agent inspector")
    command.Details -> toggle_details(cleared)
    command.Strand(name) ->
      case is_known_strand(cleared.strands, name) {
        True ->
          append_system(
            Model(..cleared, active_strand: name),
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
      send_steer(prompt_cleared, composer.expand(text, model.attachments))
    command.Queue(text) ->
      send_follow_up(prompt_cleared, composer.expand(text, model.attachments))
    command.Unknown(name) -> append_error(cleared, "unknown command /" <> name)
    command.MissingArgument(name) ->
      append_error(cleared, "/" <> name <> " needs an argument")
    command.Prompt(_) -> send_user_text(prompt_cleared, expanded, model)
  }
}

fn send_user_text(cleared: Model, text: String, before: Model) -> Model {
  case active_strand_live(before), before.submission_mode {
    False, _ -> send_prompt(cleared, text)
    True, SteerNow -> send_steer(cleared, text)
    True, QueueAfter -> send_follow_up(cleared, text)
  }
}

fn send_prompt(model: Model, text: String) -> Model {
  case model.socket {
    Some(_) ->
      send_frame(
        Model(..model, notice: "prompt sent to " <> model.active_strand),
        protocol.prompt(model.next_id, model.active_strand, text),
      )
    None ->
      Model(
        ..model,
        transcript: list.append(model.transcript, [
          Line(User, composer.transcript_text(text, model.details_expanded)),
          Line(Assistant, "Design-preview echo received."),
        ]),
        notice: "prompt accepted",
      )
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
  case active_strand_live(model), model.submission_mode {
    False, _ -> Model(..model, notice: "queue is available while an agent runs")
    True, SteerNow ->
      Model(..model, submission_mode: QueueAfter, notice: "queue message")
    True, QueueAfter ->
      Model(..model, submission_mode: SteerNow, notice: "steer now")
  }
}

fn toggle_agent_rail(model: Model) -> Model {
  let visible = !model.agent_rail_visible
  Model(..model, agent_rail_visible: visible, notice: case visible {
    True -> "agent rail shown"
    False -> "agent rail hidden"
  })
}

fn active_strand_live(model: Model) -> Bool {
  case active_strand_phase(model) {
    Some(_) -> True
    None -> False
  }
}

fn active_strand_phase(model: Model) -> Option(String) {
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

fn toggle_details(model: Model) -> Model {
  let expanded = !model.details_expanded
  Model(..model, details_expanded: expanded, notice: case expanded {
    True -> "reasoning and tool detail expanded"
    False -> "reasoning and tool detail collapsed"
  })
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
    notice: text,
  )
}

fn append_error(model: Model, text: String) -> Model {
  Model(
    ..model,
    transcript: list.append(model.transcript, [Line(Failure, text)]),
    notice: text,
  )
}
