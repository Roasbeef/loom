//// Paints the model into an etui buffer.
////
//// `view` and `cached_frame` are the entry points; `render_frame` splits
//// the screen with `tui/layout` and draws the header, transcript, agent
//// rail, changes panel, composer, pending band, footer and whichever
//// overlay or surface owns focus. Rendering is a pure function of the
//// model: nothing here sends a frame or changes state, which is what lets
//// the tick cache a frame and repaint it only when a revision moved.
////
//// Transcript rows arrive as `Line`s from `tui/transcript_lines`, already
//// ordered; this module styles them, applies Markdown, wraps them to the
//// pane width, and adds the speaker gutter.

import core/entry
import core/json
import core/message
import core/register
import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import etui/widgets/statusbar
import etui/widgets/textarea as text_area
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/advisor_pending
import tui/agent_message_panel
import tui/agent_messages
import tui/agent_strip
import tui/agents
import tui/appearance
import tui/approval_panel
import tui/collaboration_view
import tui/command
import tui/completion_summary
import tui/composer
import tui/context_panel
import tui/context_view
import tui/diff_panel
import tui/focused_goal_panel
import tui/layout
import tui/live_jobs
import tui/markdown
import tui/model.{
  type Line, type Model, AgentInspector, ApprovalInspector, Assistant,
  DaemonSelector, Disconnected, Failure, FrameCache, GoalInspector, Line, Model,
  ModelSelector, NoOverlay, PeerLinkManager, PromptNext, Reasoning,
  ReasoningDigest, ReconnectAttempting, ReconnectIdle, ReconnectSpent,
  SessionSelector, Spacer, SteerNow, System, ToolCall, ToolDetail, ToolFailure,
  ToolPatch, ToolResult, User,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/notes_view
import tui/peer_links
import tui/protocol
import tui/queue_editor
import tui/queue_panel
import tui/selection
import tui/session_selector
import tui/sessions
import tui/snapshot_view
import tui/summary_panel
import tui/text_hygiene
import tui/theme
import tui/todo_panel
import tui/transcript_lines
import tui/workspace
import tui/worktree_view

// The frame on screen is whatever `refresh_frame_cache` last decided to
// render, including a frame it deliberately left stale to pace a burst. The
// view therefore never consults the revision: rendering here would undo the
// deferral, and would also build a frame nobody caches. Only a screen etui
// reports that the cache was not drawn for falls through to a fresh render.
/// Returns the frame for one screen, cached or freshly rendered.
///
/// ## Examples
///
/// ```gleam
/// let #(frame, cursor) = tui.view(model, geometry.rect_new(0, 0, 80, 24))
/// ```
@internal
pub fn view(
  model: Model,
  screen: Rect,
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  case model.frame_cache {
    Some(FrameCache(screen: cached_screen, rendered:, ..)) ->
      cached_frame(rendered, cached_screen, screen, fn() {
        render_frame(model, screen)
      })
    None -> render_frame(model, screen)
  }
}

/// Reuses a completed frame while it was rendered for this screen.
///
/// The cached tuple is returned directly rather than reconstructed, preserving
/// the Buffer term identity that etui uses as its constant-time diff fast path.
/// Whether the cache is current or deliberately stale is `frame_decision`'s
/// question, answered when the event was handled, not here.
@internal
pub fn cached_frame(
  cached: #(buffer.Buffer, Result(geometry.Position, Nil)),
  cached_screen: Rect,
  screen: Rect,
  build: fn() -> #(buffer.Buffer, Result(geometry.Position, Nil)),
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  case cached_screen == screen {
    True -> cached
    False -> build()
  }
}

/// Paints one complete frame and returns it with the terminal cursor
/// position, if the focused surface shows one.
@internal
pub fn render_frame(
  model: Model,
  screen: Rect,
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  let #(header_area, body_area, input_area, footer_area) =
    layout.layout(screen, model)
  let #(conversation_area, queue_area) =
    layout.queue_body_layout(body_area, model)
  let #(transcript_panel, agent_panel, changes_panel) =
    layout.body_layout(conversation_area, model)
  let transcript_area = layout.panel_inner(transcript_panel)
  let #(pending_area, composer_area) =
    layout.pending_layout(layout.panel_inner(input_area), model)
  let #(paste_area, editor_area) =
    layout.input_layout(composer_area, model.attachments)
  let #(footer_area, strip_area) = layout.footer_split(footer_area, model)
  let strip = layout.strip_lines(model)

  // The editor is wrapped to the cells the chip leaves it, never resized to
  // fit: the source text and cursor stay exactly what history will replay.
  let input_view = layout.input_view_state(model.input, editor_area.size.width)
  let editor =
    text_area.textarea_new()
    |> text_area.with_max_lines(0)
    |> text_area.with_colors(theme.paper, style.Default)
    |> text_area.with_cursor_style(style.new(
      theme.graphite,
      theme.signal,
      style.bold(),
    ))

  // Paint order is also z-order: the canvas owns every cell, the panels draw
  // only their borders over it, and the palette and overlays land last.
  let base =
    repaint_canvas(screen, model.repaint_phase)
    |> render_header(header_area, model)
    |> render_conversation_heading(transcript_panel, model)
    |> render_transcript(transcript_area, model)
    |> render_agent_rail(agent_panel, model)
    |> render_changes_panel(changes_panel, model)
    |> render_inline_queue(queue_area, model)
    |> render_todo_panel(layout.todo_area(body_area, model), model)
    |> render_composer_chrome(
      input_area,
      input_title(model),
      agent_strip.badge(strip, model.active_strand),
    )
    |> render_pending_band(pending_area, model)
    |> render_paste_chip(paste_area, model.attachments)
    |> text_area.render(editor_area, editor, input_view)
    |> render_footer(footer_area, model)
    |> agent_strip.render(
      strip_area,
      strip,
      model.strip.focus,
      model.active_strand,
    )
    |> render_command_palette(body_area, model)
  let base = case layout.borrowed_diff_panel(model) {
    Some(area) ->
      base
      |> buffer.clear(area)
      |> render_panel_border(area, diff_title(model), theme.signal)
      |> render_diff_view(layout.panel_inner(area), model)
    None -> base
  }
  let rendered = case model.overlay {
    NoOverlay -> base
    ModelSelector(selector) -> model_selector.render(base, screen, selector)
    AgentInspector(selected) ->
      agents.render_inspection(
        base,
        body_area,
        layout.displayed_agents(model),
        model.active_strand,
        selected,
        agent_detail_content(model, selected),
      )
    GoalInspector(state) ->
      focused_goal_panel.render(
        base,
        layout.goal_inspector_area(body_area, editor_area),
        state,
        goal_availability(model),
      )
    SessionSelector(selector) -> sessions.render(base, screen, selector)
    DaemonSelector(selector) -> session_selector.render(base, screen, selector)
    PeerLinkManager(state) -> peer_links.render(base, screen, state)
    ApprovalInspector(panel) -> approval_panel.render(base, screen, panel)
  }

  let rendered = case model.overlay {
    AgentInspector(agents.Inspector(focus: agents.Composing, ..)) ->
      render_command_palette(
        rendered,
        body_area,
        Model(..model, overlay: NoOverlay),
      )
    _ -> rendered
  }

  // Selected cells keep their original contents. A growing pending/reviewer
  // band may shrink the pane, so restore only its current intersection; the
  // selected transcript must never paint over newly visible controls.
  let rendered = case model.selection {
    Some(selected) -> {
      let current_area =
        [
          transcript_area,
          layout.panel_inner(agent_panel),
          layout.panel_inner(changes_panel),
          layout.panel_inner(input_area),
        ]
        |> list.find(fn(area) { area.position == selected.area.position })
        |> result.unwrap(selected.area)
      case
        model.selection_frame,
        geometry.intersect(selected.area, current_area)
      {
        Some(original), Ok(area) ->
          buffer.blit(
            rendered,
            selection.highlight(original, selected),
            area,
            area.position,
          )
        None, _ -> selection.highlight(rendered, selected)
        Some(_), Error(Nil) -> rendered
      }
    }
    None -> rendered
  }
  let cursor = case model.overlay, model.queue_editor.surface {
    NoOverlay, queue_editor.Editor -> queue_editor_cursor(model, queue_area)
    NoOverlay, _ -> text_area.cursor_screen_pos(input_view, editor_area)
    AgentInspector(agents.Inspector(focus: agents.Composing, ..)), _ ->
      text_area.cursor_screen_pos(input_view, editor_area)
    ModelSelector(_), _
    | AgentInspector(_), _
    | GoalInspector(_), _
    | SessionSelector(_), _
    | DaemonSelector(_), _
    | PeerLinkManager(_), _
    | ApprovalInspector(_), _
    -> Error(Nil)
  }
  let #(rendered, cursor) =
    render_summary_surface(rendered, cursor, screen, model)
  let #(rendered, cursor) =
    render_context_surface(rendered, cursor, screen, model)
  #(appearance.apply(rendered, model.palette), cursor)
}

/// Draws a rounded border and a left-aligned title, leaving the interior alone.
///
/// This is etui's `block.render` without its interior clear. That clear walks
/// every inner cell, repainting an area the canvas already owns; `make
/// bench-tui` measures the area-dependent work this removes. Leaving the
/// interior to the canvas also keeps its repaint phase on vacated cells, which
/// is what lets a detail-mode toggle rewrite positions the diff would otherwise
/// retain. The bytes on the wire for a steady frame are the same as the
/// block's; the test pins that.
///
/// ## Examples
///
/// ```gleam
/// let screen = geometry.rect_new(0, 0, 12, 3)
/// buffer.buffer_new(screen)
/// |> tui.render_panel_border(screen, " title ", theme.quiet)
/// ```
@internal
pub fn render_panel_border(
  buf: buffer.Buffer,
  area: Rect,
  title: String,
  color: style.Color,
) -> buffer.Buffer {
  let width = area.size.width
  let height = area.size.height
  case width < 2 || height < 2 {
    True -> buf
    False -> {
      let x0 = area.position.x
      let y0 = area.position.y
      let x_right = geometry.right(area) - 1
      let y_bottom = geometry.bottom(area) - 1
      let border = style.new(color, style.Default, style.none())
      let horizontal = string.repeat("─", width - 2)

      // One string write per edge row is one array pass each, and the two
      // verticals are one cell per row: a few dozen writes for the whole
      // frame of the panel instead of one per interior cell.
      let framed =
        buf
        |> buffer.set_string(
          geometry.Position(x0, y0),
          "╭" <> horizontal <> "╮",
          border,
        )
        |> buffer.set_string(
          geometry.Position(x0, y_bottom),
          "╰" <> horizontal <> "╯",
          border,
        )
        |> render_vertical_edges(x0, x_right, y0 + 1, y_bottom, border)

      // The title sits one cell in from the corner and is cut to the top
      // edge with an ellipsis, exactly where the block would have put it.
      let title_width = width - 2
      buffer.set_string(
        framed,
        geometry.Position(x0 + 1, y0),
        text.truncate(title, title_width, "…"),
        border,
      )
    }
  }
}

fn render_vertical_edges(
  buf: buffer.Buffer,
  x_left: Int,
  x_right: Int,
  y: Int,
  y_end: Int,
  border: style.Style,
) -> buffer.Buffer {
  case y >= y_end {
    True -> buf
    False ->
      buf
      |> buffer.set_string(geometry.Position(x_left, y), "│", border)
      |> buffer.set_string(geometry.Position(x_right, y), "│", border)
      |> render_vertical_edges(x_left, x_right, y + 1, y_end, border)
  }
}

fn render_changes_panel(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case area.size.width > 0 {
    True ->
      buf
      |> render_panel_border(area, diff_title(model), theme.divider)
      |> render_diff_view(layout.panel_inner(area), model)
    False -> buf
  }
}

fn render_agent_rail(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case area.size.width > 0 {
    True -> {
      let extra = studio_observation_lines(model)
      let panes =
        geometry.split_v(area, [
          Fill,
          Length(int.min(6, list.length(extra) + 1)),
        ])
      case panes {
        [roster, observations] ->
          buf
          |> agents.render_rail(
            roster,
            layout.displayed_agents(model),
            model.active_strand,
          )
          |> paragraph.render_styled(
            observations,
            list.map(extra, fn(row) {
              span.line_new([
                span.span_styled(
                  text.truncate(" " <> row, observations.size.width, "…"),
                  theme.quiet_text(),
                ),
              ])
            }),
          )
        _ ->
          agents.render_rail(
            buf,
            area,
            layout.displayed_agents(model),
            model.active_strand,
          )
      }
    }
    False -> buf
  }
}

// The rail reports captured observations. Opening /diff owns refreshing Git;
// a missing or stale observation must not become a fabricated clean worktree.
fn studio_observation_lines(model: Model) -> List(String) {
  let advice = case model.nudges {
    Some(board) -> list.take(advisor_pending.lines(board), 1)
    None ->
      case list.any(model.strands, fn(strand) { strand.id == "advisor" }) {
        True -> ["Advisor nudges · not observed"]
        False -> []
      }
  }
  let changes = case model.worktree.board {
    None -> ["CHANGES · /diff (not observed)"]
    Some(board) -> [
      "CHANGES · " <> int.to_string(board.total) <> " files · /diff",
      ..board.files
      |> list.take(2)
      |> list.map(fn(file) {
        file.index_status
        <> file.worktree_status
        <> " "
        <> text_hygiene.single_line(file.path)
      })
      |> list.append([model.worktree.message])
    ]
  }
  list.append(advice, changes)
}

// Names are presentation only. Pairing one with its identity prevents a
// legacy switch or replay from showing a previous session's title.
fn session_title(model: Model) -> String {
  case model.session_label {
    Some(#(id, name)) if id == model.session && name != "" -> name
    Some(_) | None -> model.session
  }
}

fn render_header(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let identity = " ◆ loom "
  let details =
    text.truncate(
      " "
        <> text_hygiene.single_line(model.current_model)
        <> " · Ctrl+g details ",
      int.max(0, area.size.width / 3),
      "…",
    )

  // A long checkout path must not hide which session owns this terminal.
  // Reserve the two fixed ends before fitting the session and its context.
  let room =
    int.max(
      0,
      area.size.width - text.cell_width(identity) - text.cell_width(details),
    )
  let context =
    text.truncate(
      text_hygiene.single_line(session_title(model))
        <> " · "
        <> text_hygiene.single_line(workspace.label(model.workspace)),
      room,
      "…",
    )
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([
      span.line_new([span.span_styled(identity, theme.signal_bold())]),
    ])
    |> statusbar.with_center([span.line_plain(context)])
    |> statusbar.with_right([
      span.line_new([span.span_styled(details, theme.quiet_text())]),
    ])
  statusbar.render(buf, area, bar)
}

// A reading surface needs a heading and gutter, not four persistent edges.
// Keeping its interior geometry preserves selection and semantic anchors.
fn render_conversation_heading(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  buffer.set_string(
    buf,
    area.position,
    text.truncate(
      case tui_model.reading_history(model) {
        True -> " ↓ Scrollback · click for latest · End with empty prompt "
        False -> transcript_title(model)
      },
      area.size.width,
      "…",
    ),
    theme.quiet_text(),
  )
}

// Horizontal rules distinguish input from output without boxing the whole
// conversation. The editor keeps its established inset for selection/copy.
// The badge names the task of the agent being viewed, right-aligned on the
// composer's top rule, so an operator who opened a sub-agent from the strip
// can see which task the transcript and the composer now belong to. It
// yields to the title: the send mode is never truncated to fit a badge.
fn render_composer_chrome(
  buf: buffer.Buffer,
  area: Rect,
  title: String,
  badge: Option(String),
) -> buffer.Buffer {
  let width = int.max(0, area.size.width - 2)
  let border = style.new(theme.signal, style.Default, style.none())
  let title = text.truncate(title, width, "…")
  let badge = case badge {
    None -> ""
    Some(words) ->
      text.truncate(
        " " <> text_hygiene.single_line(words) <> " ",
        int.max(0, width - text.cell_width(title) - 2),
        "… ",
      )
  }
  let gap = int.max(0, width - text.cell_width(title) - text.cell_width(badge))
  buf
  |> buffer.set_string(
    area.position,
    "─" <> title <> string.repeat(" ", gap + text.cell_width(badge)) <> "─",
    border,
  )
  |> buffer.set_string(
    geometry.Position(
      area.position.x + 1 + text.cell_width(title) + gap,
      area.position.y,
    ),
    badge,
    style.new(theme.graphite, theme.current, style.bold()),
  )
  |> buffer.set_string(
    geometry.Position(area.position.x, geometry.bottom(area) - 1),
    string.repeat("─", area.size.width),
    style.new(theme.divider, style.Default, style.none()),
  )
}

fn render_transcript(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case model.notes_open, layout.main_shows_diff(model) {
    True, _ ->
      paragraph.render_styled(
        buffer.clear(buf, area),
        area,
        notes_content(model, area, model.active_strand).lines,
      )
    False, True -> render_diff_view(buf, area, model)
    False, False ->
      render_rows(
        buf,
        area,
        model.rendered_rows,
        model.scroll_offset + tui_model.viewport_backlog(model),
      )
  }
}

fn render_rows(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(span.Line),
  offset: Int,
) -> buffer.Buffer {
  let visible =
    rows
    |> list.drop(offset)
    |> list.take(area.size.height)
    |> list.reverse
    |> list.map(fn(line) {
      case line.spans {
        [first, ..]
          if first.style.bg == theme.user_background
          || first.style.bg == theme.assistant_background
        ->
          span.Line(
            ..line,
            spans: list.append(line.spans, [
              span.span_styled(
                string.repeat(
                  " ",
                  int.max(0, area.size.width - span.line_width(line)),
                ),
                first.style,
              ),
            ]),
          )
        _ -> line
      }
    })
  paragraph.render_styled(buf, area, visible)
}

fn transcript_title(model: Model) -> String {
  let surface = case
    model.help_open,
    model.notes_open,
    layout.main_shows_diff(model)
  {
    True, _, _ -> "help"
    False, True, _ -> "agent notes"
    False, False, True -> diff_title(model)
    False, False, False -> "transcript"
  }
  " "
  <> surface
  <> " / "
  <> text_hygiene.single_line(model.active_strand)
  <> " "
}

fn transcript_content(lines: List(Line), width: Int) -> span.Text {
  lines
  |> list.flat_map(render_line(_, width))
  |> span.text_new
}

/// Rows for one transcript line, wrapped to the pane and ready to paint.
///
/// The wrapping lives here rather than at the call sites because only this
/// function knows which bodies arrive already wrapped. A Markdown body is
/// wrapped inside `marked_markdown_rows`, at the room the mark leaves rather
/// than at the full pane, which is what seats a continuation row at the
/// gutter instead of the left margin; prefixing the mark brings those rows
/// back to exactly `width`. A second pass over them would re-measure every
/// span of every row to arrive at the rows it was handed, and the live stream
/// re-renders its whole body on every delta, so that pass was paid per token.
@internal
pub fn render_line(line: Line, width: Int) -> List(span.Line) {
  case line.speaker {
    Assistant | Reasoning -> speaker_rows(line, width)

    // Every other body is laid out against the full pane and has never been
    // measured, so it is wrapped on the way out.
    System
    | User
    | ReasoningDigest
    | ToolCall
    | ToolResult
    | ToolDetail
    | ToolPatch
    | ToolFailure
    | Failure
    | Spacer -> speaker_rows(line, width) |> markdown.wrap_lines(width)
  }
}

// The rows one speaker's body occupies, before any wrapping the speaker did
// not already do for itself. Every arm ends by handing its mark to
// `prefix_rendered_lines` or drawing it inline, so the mark and the gutter
// beneath it are decided in one place.
fn speaker_rows(line: Line, width: Int) -> List(span.Line) {
  let #(mark, mark_style) = case line.speaker {
    System -> #("◇ ", theme.quiet_text())
    User -> #("› ", theme.signal_bold())
    Assistant -> #("◆ ", theme.current_bold())
    Reasoning -> #("∴ Reasoning ", theme.quiet_text())
    ReasoningDigest -> #(markdown.digest_mark, theme.quiet_text())
    ToolCall ->
      case string.starts_with(line.text, "✓ ") {
        True -> #("✓ ", theme.success_text())
        False -> #("● ", theme.current_bold())
      }
    ToolResult -> #("└ ", theme.quiet_text())
    ToolDetail | ToolPatch -> #("  ", theme.quiet_text())
    ToolFailure -> #("└ × ", theme.danger_text())
    Failure -> #("! error ", theme.danger_text())
    Spacer -> #("", theme.quiet_text())
  }
  let body = case
    line.speaker == ToolCall && string.starts_with(line.text, "✓ ")
  {
    True -> string.drop_start(line.text, 2)
    False -> line.text
  }
  case line.speaker {
    User -> {
      let body_style =
        style.new(theme.paper, theme.user_background, style.none())
      let label_style =
        style.new(theme.signal, theme.user_background, style.bold())

      // A separate label and shaded block identify the speaker without
      // depending on hue. Wrapped rows retain the same background, and copy
      // continues to read the exact visible frame rather than another layout.
      [
        span.line_plain(""),
        span.line_new([span.span_styled(" › User", label_style)]),
        ..line.text
        |> text_hygiene.multiline
        |> string.split("\n")
        |> list.map(fn(text) {
          span.line_new([span.span_styled("   " <> text, body_style)])
        })
        |> list.append([span.line_plain("")])
      ]
    }
    Assistant -> [
      span.line_plain(""),
      ..marked_markdown_rows(line.text, mark, mark_style, width)
      |> assistant_rows
    ]
    Reasoning -> [
      span.line_plain(""),
      ..marked_markdown_rows(line.text, mark, mark_style, width)
    ]
    ToolPatch -> markdown.diff(line.text)

    // The spacer is a row and nothing else: the fold that placed it has
    // already decided it belongs here, so there is no mark to draw and
    // nothing to wrap.
    Spacer -> [span.line_plain("")]

    // A digest stands in for a whole reasoning block, and the one property
    // it has to keep is its height: the collapsed live row and the
    // collapsed settled row are the same row with different words in it.
    // So it is drawn literally, with no blank above or below it and no
    // Markdown pass which could answer a stray fence with a second row.
    ReasoningDigest -> [digest_row(line.text, mark, mark_style, width)]

    ToolDetail ->
      markdown.render(line.text, width - string.length(mark))
      |> prefix_rendered_lines(mark, mark_style)
    System | ToolCall | ToolResult | ToolFailure | Failure ->
      body
      |> text_hygiene.multiline
      |> string.split("\n")
      |> list.index_map(fn(text, index) {
        let prefix = case index == 0 {
          True -> mark
          False -> speaker_gutter
        }
        span.line_new([
          span.span_styled(prefix, mark_style),
          span.span_plain(text),
        ])
      })
      |> list.append(case transcript_lines.closes_bare(line.speaker) {
        True -> []
        False -> [span.line_plain("")]
      })
  }
}

// Plain Markdown spans share one shaded style for the whole block. Rebuilding
// that identical record for every word makes the bounded live tail retain
// hundreds of duplicate style tuples. Emphasis keeps its own foreground and
// modifiers, while blank rows carry the same background to the pane edge.
fn assistant_rows(rows: List(span.Line)) -> List(span.Line) {
  let plain = style.default_style()
  let shaded = style.with_bg(plain, theme.assistant_background)
  list.map(rows, fn(line) {
    let span.Line(spans:, alignment:) = line
    let spans = case spans {
      [] -> [span.span_styled(" ", shaded)]
      spans ->
        list.map(spans, fn(value) {
          let painted = case value.style == plain {
            True -> shaded
            False -> style.with_bg(value.style, theme.assistant_background)
          }
          span.Span(..value, style: painted)
        })
    }
    span.Line(spans:, alignment:)
  })
}

// One row, whatever the pane is. Clipping rather than wrapping is what makes
// the height invariant hold at every width: bounding the digest text by a
// character count only moves the width at which it wraps, because the mark
// and the expand hint are a further thirty-four cells the count knows nothing
// about. The hint is the part a reader acts on, so the opening line gives up
// cells for it; when the pane cannot hold even the hint, the whole body is
// clipped and the hint goes with it rather than crowding out the words.
fn digest_row(
  text: String,
  mark: String,
  mark_style: style.Style,
  width: Int,
) -> span.Line {
  let body = text_hygiene.single_line(text)
  let room = width - text.cell_width(mark)
  let #(opening, hint) = case
    string.ends_with(body, transcript_lines.expand_hint)
  {
    True -> #(
      string.drop_end(body, string.length(transcript_lines.expand_hint)),
      transcript_lines.expand_hint,
    )
    False -> #(body, "")
  }
  let for_opening = room - text.cell_width(hint)
  let clipped = case for_opening > 0 {
    True -> text.truncate(opening, for_opening, "…") <> hint
    False -> text.truncate(body, room, "…")
  }
  span.line_new([
    span.span_styled(mark, mark_style),
    span.span_plain(clipped),
  ])
}

// The cells every row of a block after its first is indented by.
//
// A speaker mark is a heading, not a left edge. Repeating its whole width
// under a message's second paragraph, list or fence left that body
// hanging in from the margin while the first paragraph's own wrapped rows
// fell back to column zero, so one message had two left edges and neither was
// the glyph's. Every mark this transcript draws opens with a glyph and a
// space, so two cells is the one column all of them can share, and a list's
// own nesting is then measured from it.
const speaker_gutter = "  "

// Markdown is wrapped here rather than left to the caller because the wrap
// width and the prefix are a single decision. Row zero pays for the whole
// mark and every later row pays for `speaker_gutter`, so a body measured
// against the bare pane would overrun row zero, and the wrapper the caller
// runs afterwards would answer that overrun by dropping the spilled words to
// column zero — which is the two-left-edges bug itself. Measuring every row
// against the widest of the two prefixes is what the fix costs: a
// continuation row stops a few cells short of the pane, in exchange for one
// left edge shared by a wrapped paragraph, a list and a fence alike.
fn marked_markdown_rows(
  body: String,
  mark: String,
  mark_style: style.Style,
  width: Int,
) -> List(span.Line) {
  // The mark is measured in cells rather than codepoints for the same reason
  // `digest_row` measures it that way: a two-cell glyph counted as one would
  // leave row zero a cell short of the room it was promised and spill.
  let room = int.max(1, width - text.cell_width(mark))

  markdown.render(body, room)
  |> markdown.wrap_lines(room)
  |> prefix_rendered_lines(mark, mark_style)
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
      False -> speaker_gutter
    }
    span.Line(
      spans: [span.span_styled(prefix, mark_style), ..spans],
      alignment:,
    )
  })
}

/// The slash-command help text, as shown when the help surface is open.
@internal
pub fn help_content() -> span.Text {
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

fn agent_detail_content(model: Model, inspector: agents.Inspector) {
  let selected = inspector.selected
  let message = inspector.message
  let scroll = inspector.scroll
  case inspector.detail {
    agents.Overview -> None
    agents.Messages ->
      Some(fn(area: Rect) {
        agent_message_content(model, selected, message, scroll, area).lines
      })
    agents.Notes ->
      Some(fn(area: Rect) { notes_content(model, area, selected).lines })
    agents.Collaboration ->
      Some(fn(area: Rect) {
        case model.captured {
          Some(#(cut, view)) ->
            collaboration_view.lines(
              view,
              cut.window,
              selected,
              area.size.width,
            )
          None -> [span.line_plain("Collaboration capture unavailable")]
        }
      })
  }
}

fn agent_message_content(
  model: Model,
  selected: String,
  message: Option(String),
  scroll: Int,
  area: Rect,
) -> span.Text {
  model.agent_messages
  |> agent_messages.for_strand(selected)
  |> agent_message_panel.render(message, scroll, area)
}

fn notes_content(model: Model, area: Rect, target: String) -> span.Text {
  let rows = prepared_notes(model, target, area)
  let context = note_context(model, target)
  note_panel.render(rows, model.note_selected, model.note_scroll, context, area)
}

/// The notes panel's rows for `target`, wrapped to the panel width with
/// the selected note marked.
@internal
pub fn prepared_notes(
  model: Model,
  target: String,
  area: Rect,
) -> List(note_panel.Row) {
  let width = note_panel.body_width(area)
  case model.note_board {
    Some(board) if board.strand == target -> {
      let chosen = selected_note(model, board)
      list.map(board.notes, fn(note) {
        let extent = case note.extent {
          notes_view.Complete -> "Complete"
          notes_view.Excerpt -> "Excerpt"
        }
        let body = case chosen == Some(note.key) {
          False -> []
          True -> {
            let value = case model.note_mode, note.extent {
              note_panel.Raw, notes_view.Complete -> raw_note_line(note.text)
              note_panel.Readable, notes_view.Complete ->
                Line(ToolDetail, notes_view.readable_note(note))
              note_panel.Raw, notes_view.Excerpt
              | note_panel.Readable, notes_view.Excerpt
              -> Line(ToolResult, note.text)
            }
            transcript_content([value], width).lines
          }
        }
        note_panel.Row(
          key: note.key,
          seq: note.seq,
          excerpt: transcript_lines.compact(notes_view.summary(note), 48),
          extent:,
          relation: note_turn_relation(note.seq, model, target),
          body:,
        )
      })
    }
    Some(_) | None -> historical_note_rows(model, target, width)
  }
}

fn historical_note_rows(model: Model, target: String, width: Int) {
  case historical_note_payload(model, target) {
    None -> []
    Some(payload) -> [
      note_panel.Row(
        key: "historical run-start digest",
        seq: 0,
        excerpt: transcript_lines.compact(notes_view.historical(payload), 48),
        extent: "Historical",
        relation: " · not a current read",
        body: transcript_content(
          [
            case model.note_mode {
              note_panel.Raw ->
                Line(ToolDetail, "```text\n" <> payload <> "\n```")
              note_panel.Readable ->
                Line(ToolDetail, notes_view.historical(payload))
            },
          ],
          width,
        ).lines,
      ),
    ]
  }
}

fn note_context(model: Model, target: String) -> List(String) {
  case model.note_board {
    Some(board) if board.strand == target -> [
      "notes for "
        <> target
        <> " · read at revision "
        <> int.to_string(board.as_of),
      note_read_status(board, model),
      note_compact_status(board, model),
    ]
    Some(_) -> missing_note_context(model, target)
    None ->
      case historical_note_payload(model, target) {
        Some(_) -> ["Historical run-start digest · r fetches current notes"]
        None ->
          case model.overlay {
            AgentInspector(_) -> [
              "no agent notes are available for " <> target <> " · r refresh",
            ]
            NoOverlay
            | ModelSelector(_)
            | GoalInspector(_)
            | SessionSelector(_)
            | DaemonSelector(_)
            | PeerLinkManager(_)
            | ApprovalInspector(_) -> ["No observed notes for " <> target]
          }
      }
  }
}

fn missing_note_context(model: Model, target: String) -> List(String) {
  case model.overlay {
    AgentInspector(_) -> [
      "no agent notes are available for " <> target <> " · r refresh",
    ]
    NoOverlay
    | ModelSelector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | ApprovalInspector(_) -> ["No observed notes for " <> target]
  }
}

fn note_compact_status(board: notes_view.Board, model: Model) -> String {
  let freshness = case model.captured {
    Some(#(cut, _)) if cut.next_seq - 1 > board.as_of -> "stale · "
    _ -> "current read · "
  }
  let omitted = case board.total - list.length(board.notes) {
    count if count > 0 -> int.to_string(count) <> " more notes omitted · "
    _ -> ""
  }
  freshness <> omitted <> "↑/↓ or [/] select · r refresh · Ctrl+g readable/raw"
}

fn historical_note_payload(model: Model, target: String) -> Option(String) {
  model.records
  |> list.find_map(fn(record) {
    let protocol.EntryRecord(strand:, entry:) = record
    case strand == target, entry {
      True, entry.MessageEntry(message: value, ..) ->
        transcript_lines.agent_notes_payload(value) |> option.to_result(Nil)
      _, _ -> Error(Nil)
    }
  })
  |> result.map(Some)
  |> result.unwrap(None)
}

fn note_read_status(board: notes_view.Board, model: Model) -> String {
  case model.captured {
    Some(#(cut, _)) if cut.next_seq - 1 > board.as_of ->
      "Session advanced since this read · r refreshes. Saved plans may need correction."
    _ ->
      "Last observed note values. Saved plans may need correction as work progresses."
  }
}

// Only the accepted operation's own revision establishes that a note predates
// this turn. Unrelated session activity says nothing about the note's accuracy.
fn note_turn_relation(seq: Int, model: Model, target: String) -> String {
  case model.captured {
    None -> ""
    Some(#(_, view)) -> {
      let started = {
        use current <- result.try(dict.get(view.operations, target))
        list.find(view.cells, fn(cell) {
          cell.namespace == register.OpMeta && cell.key == current
        })
      }
      case started {
        Ok(cell) if seq < cell.seq -> " · written before current turn"
        _ -> ""
      }
    }
  }
}

// Raw inspection keeps the JSON representation but gives its structure rows.
// Excerpts never enter this path because a cut value may not parse completely.
fn raw_note_line(text: String) -> Line {
  case json.parse(text) {
    Ok(value) ->
      Line(
        ToolDetail,
        "```json\n" <> transcript_lines.pretty_json(value, 0) <> "\n```",
      )
    Error(_) -> Line(ToolResult, text)
  }
}

/// The key of the selected note on `board`, falling back to the first note
/// when the recorded selection is no longer on the board.
@internal
pub fn selected_note(model: Model, board: notes_view.Board) -> Option(String) {
  case
    list.find(board.notes, fn(note) { Some(note.key) == model.note_selected })
  {
    Ok(note) -> Some(note.key)
    Error(Nil) ->
      list.first(board.notes)
      |> result.map(fn(note) { note.key })
      |> option.from_result
  }
}

fn render_footer(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  use <- bool.lazy_guard(!model.details_expanded, fn() {
    render_compact_footer(buf, area, model)
  })
  let #(project, model_name, usage, status, combined) = footer_sections(model)
  case area.size.height {
    1 -> render_single_footer(buf, area, project, usage, combined)
    2 -> render_stacked_footer(buf, area, project, model_name, usage, status)
    _ -> render_split_footer(buf, area, project, model_name, usage, status)
  }
}

// Billing detail is available with Ctrl+g. Everyday work needs the model,
// context estimate, session cost, and attention state rather than cache totals.
fn render_compact_footer(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  // The outlook leads the line when present. The footer truncates from the
  // right, so placing it after cost hid the only forward-looking reading at
  // ordinary terminal widths.
  let info =
    text_hygiene.single_line(model.current_model)
    <> " · "
    <> context_view.footer(model.context)
    <> " · est $"
    <> transcript_lines.money(model.usage.cost.total)
  let status = agents.summary_rows(layout.displayed_agents(model))
  let context = case model.cache_outlook, model.notice {
    "", "" -> info
    "", notice -> text_hygiene.single_line(notice) <> " · " <> info
    cache, "" -> cache <> " · " <> info
    cache, notice ->
      cache <> " · " <> text_hygiene.single_line(notice) <> " · " <> info
  }
  case area.size.height > 1 {
    True ->
      paragraph.render_styled(
        buf,
        area,
        list.map([context, status], fn(row) {
          span.line_new([
            span.span_styled(
              text.truncate(" " <> row, area.size.width, "…"),
              theme.footer_text(),
            ),
          ])
        }),
      )
    False -> {
      let left_width = int.max(0, area.size.width - text.cell_width(status) - 3)
      let row =
        " "
        <> text.pad_right(text.truncate(context, left_width, "…"), left_width)
        <> "  "
        <> status
      paragraph.render_styled(buf, area, [
        span.line_new([span.span_styled(row, theme.footer_text())]),
      ])
    }
  }
}

fn footer_sections(
  model: Model,
) -> #(span.Line, span.Line, span.Line, span.Line, span.Line) {
  let project_text =
    model.workspace |> workspace.label |> text_hygiene.single_line
  let model_text = text_hygiene.single_line(model.current_model)
  let status_text = model |> model_footer_status |> text_hygiene.single_line
  let project =
    span.line_new([
      span.span_styled(
        " "
          <> transcript_lines.compact(
          project_text,
          footer_project_limit(model.width),
        )
          <> " ",
        theme.footer_text(),
      ),
    ])
  let model_name =
    span.line_new([
      span.span_styled(
        " " <> transcript_lines.compact(model_text, 28) <> " ",
        theme.footer_text(),
      ),
    ])
  let usage =
    span.line_new([
      span.span_styled(
        " "
          <> transcript_lines.compact(
          transcript_lines.cache_section_label(model.cache_outlook)
            <> context_view.footer(model.context)
            <> " · "
            <> transcript_lines.usage_summary(model.usage)
            <> transcript_lines.output_rate_label(model.output_rate_tps),
          footer_usage_limit(model.width),
        )
          <> " ",
        theme.footer_text(),
      ),
    ])
  let status =
    span.line_new([
      span.span_styled(" " <> status_text <> " ", theme.footer_text()),
    ])
  let combined =
    span.line_new([
      span.span_styled(
        " "
          <> transcript_lines.compact(model_text, 28)
          <> " · "
          <> status_text
          <> " ",
        theme.footer_text(),
      ),
    ])
  #(project, model_name, usage, status, combined)
}

fn model_footer_status(model: Model) -> String {
  footer_status(
    model.agent_summary,
    model.notice,
    footer_status_limit(model.width),
  )
}

/// Preserves transient operator feedback beside the agent summary, within
/// the cells the footer's layout leaves it.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_status("0 live", "copied 2 lines", 40)
///   == "0 live · copied 2 lines"
/// ```
@internal
pub fn footer_status(
  agent_summary: String,
  notice: String,
  limit: Int,
) -> String {
  let safe_summary = text_hygiene.single_line(agent_summary)
  let safe_notice = text_hygiene.single_line(notice)
  case string.starts_with(safe_notice, "model: ") {
    True -> transcript_lines.compact(safe_summary, limit)
    False ->
      transcript_lines.compact(safe_summary <> " · " <> safe_notice, limit)
  }
}

/// The cells the footer's workspace label may take at a terminal width.
///
/// On one row the label shares the row with usage and the model, so its
/// cap holds. On two or three rows it shares the primary row with the model
/// alone, and every column past the two caps is otherwise idle: a long
/// `path (branch)` cut to sixty-eight cells beside fifty blank ones was the
/// same fixed cap outliving its reason that `footer_status_limit` retired.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_project_limit(213) == 68
/// assert tui.footer_project_limit(150) == 118
/// ```
@internal
pub fn footer_project_limit(width: Int) -> Int {
  let floor = layout.footer_project_cells - 2
  case layout.footer_rows(width) {
    1 -> floor
    _ -> int.max(floor, width - layout.footer_model_cells - 2)
  }
}

/// The cells the footer status may take at a terminal width.
///
/// The row count is decided from fixed caps so it cannot flap with the
/// notice text, and the status keeps the cap's forty cells as a floor. A
/// terminal wider than the single row needs hands the status every spare
/// cell, because a notice such as `steer captured; waiting for stop` cut
/// to forty cells on a 246-column screen was the fixed cap outliving its
/// reason. On two rows the status shares its row with usage; on three it
/// has the row to itself.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_status_limit(213) == 40
/// assert tui.footer_status_limit(246) == 73
/// ```
@internal
pub fn footer_status_limit(width: Int) -> Int {
  let floor = layout.footer_status_cells - 2
  case layout.footer_rows(width) {
    1 -> floor + width - layout.footer_single_row_cells()
    2 -> int.max(floor, width - layout.footer_usage_cells - 2)
    _ -> int.max(floor, width - 2)
  }
}

/// The cells the footer's cumulative usage may take at a terminal width.
///
/// On one and two rows the section shares its row with others and the fixed
/// cap is what keeps the row count decidable from the width alone. On three
/// rows the usage has the row to itself and that row can be narrower than
/// the cap, so the cap comes down to the width: at fifty columns a cap of
/// sixty-eight never fired, and the render buffer clipped the last digit of
/// `cache 0/0` with no ellipsis to say anything had been dropped.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_usage_limit(213) == 68
/// assert tui.footer_usage_limit(50) == 48
/// ```
@internal
pub fn footer_usage_limit(width: Int) -> Int {
  let cap = layout.footer_usage_cells - 2
  case layout.footer_rows(width) {
    1 | 2 -> cap
    _ -> int.min(cap, width - 2)
  }
}

fn render_single_footer(
  buf: buffer.Buffer,
  area: Rect,
  left: span.Line,
  usage: span.Line,
  right: span.Line,
) -> buffer.Buffer {
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([left])
    |> statusbar.with_center([usage])
    |> statusbar.with_right([right])
  statusbar.render(buf, area, bar)
}

fn render_stacked_footer(
  buf: buffer.Buffer,
  area: Rect,
  project: span.Line,
  model_name: span.Line,
  usage: span.Line,
  status: span.Line,
) -> buffer.Buffer {
  let primary =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([project])
    |> statusbar.with_right([model_name])
  let usage_bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([usage])
    |> statusbar.with_right([status])
  case geometry.split_v(area, [Length(1), Length(1)]) {
    [primary_area, usage_area] ->
      buf
      |> statusbar.render(primary_area, primary)
      |> statusbar.render(usage_area, usage_bar)
    _ -> statusbar.render(buf, area, primary)
  }
}

fn render_split_footer(
  buf: buffer.Buffer,
  area: Rect,
  project: span.Line,
  model_name: span.Line,
  usage: span.Line,
  status: span.Line,
) -> buffer.Buffer {
  let primary =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([project])
    |> statusbar.with_right([model_name])
  let usage_bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([usage])
  let status_bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([status])
  case geometry.split_v(area, [Length(1), Length(1), Length(1)]) {
    [primary_area, usage_area, status_area] ->
      buf
      |> statusbar.render(primary_area, primary)
      |> statusbar.render(usage_area, usage_bar)
      |> statusbar.render(status_area, status_bar)
    _ -> statusbar.render(buf, area, primary)
  }
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

fn render_pending_band(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  paragraph.render_styled(
    buf,
    area,
    list.map(layout.composer_status_lines(model), fn(status) {
      span.line_new([
        span.span_styled(
          transcript_lines.compact(status, area.size.width),
          theme.quiet_text(),
        ),
      ])
    }),
  )
}

fn input_title(model: Model) -> String {
  let behavior = case model.overlay, model.strip.focus {
    AgentInspector(agents.Inspector(focus: agents.Browsing, ..)), _ ->
      " Tab writes · Enter opens agent "
    _, agent_strip.Browsing(_) ->
      " ↑↓ select agent · enter opens · x stops · esc back "
    _, agent_strip.Composing -> input_behavior(model)
  }
  " To " <> recipient_label(model) <> " ·" <> behavior
}

// A long child ID must not hide whether Enter sends, queues, or steers.
// Its distinguishing suffix remains visible; the workspace shows it in full.
fn recipient_label(model: Model) -> String {
  model.active_strand
  |> text_hygiene.single_line
  |> string.reverse
  |> text.truncate(int.max(8, int.min(32, model.width / 3)), "…")
  |> string.reverse
}

fn input_behavior(model: Model) -> String {
  use <- bool.guard(
    model.captured != None
      && !tui_model.is_known_strand(model.strands, model.active_strand),
    " recipient unavailable · draft retained · F2 agents ",
  )
  use <- bool.guard(model.peer == Disconnected, case model.reconnect {
    ReconnectAttempting(..) -> " Reconnecting to the daemon · draft retained "
    ReconnectIdle | ReconnectSpent ->
      " Disconnected · /sessions to reconnect · draft retained "
  })
  case
    tui_model.active_interrupt(model),
    layout.active_status_label(model),
    model.submission_mode
  {
    Some(_), _, _ -> " stopped · enter sends held input with your message "
    None, None, _ -> " prompt · enter sends · / commands "
    None, Some(_), SteerNow -> " steer this turn · enter steers · tab queues "
    None, Some(_), PromptNext -> " enter queues · tab steers "
  }
}

fn render_paste_chip(
  buf: buffer.Buffer,
  area: Rect,
  attachments: List(composer.Attachment),
) -> buffer.Buffer {
  let rows = composer.preview_lines(attachments)
  let lines =
    rows
    |> list.take(area.size.height)
    |> list.map(fn(row) {
      let truncated = text.truncate(row, int.max(0, area.size.width - 2), "…")
      span.line_new([
        span.span_styled("[" <> truncated <> "]", theme.signal_bold()),
      ])
    })
  paragraph.render_styled(buf, area, lines)
}

fn render_command_palette(
  buf: buffer.Buffer,
  body: Rect,
  model: Model,
) -> buffer.Buffer {
  let suggestions =
    command.suggestions_with_skills(text_area.value(model.input), model.skills)
  case suggestions, model.overlay {
    [], _
    | _, ModelSelector(_)
    | _, AgentInspector(_)
    | _, GoalInspector(_)
    | _, SessionSelector(_)
    | _, DaemonSelector(_)
    | _, PeerLinkManager(_)
    | _, ApprovalInspector(_)
    -> buf
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

/// Whether the goal panel may start a new goal command, or is waiting on
/// one already sent.
@internal
pub fn goal_availability(model: Model) -> focused_goal_panel.Availability {
  case model.goal_request {
    Some(_) -> focused_goal_panel.Pending
    None -> focused_goal_panel.Ready
  }
}

// The panel paints every cell of its rows, padded to the width, so it needs
// no interior clear; it is inset one column to line up with the
// conversation's own left margin.
fn render_todo_panel(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case layout.todo_board(model), area.size.height {
    None, _ | _, 0 -> buf
    Some(board), rows -> {
      let inset =
        geometry.Rect(
          position: geometry.Position(
            x: area.position.x + 1,
            y: area.position.y,
          ),
          size: geometry.Size(
            width: int.max(area.size.width - 2, 0),
            height: rows,
          ),
        )
      paragraph.render_styled(
        buf,
        inset,
        todo_panel.lines(board, inset.size.width, rows),
      )
    }
  }
}

fn render_inline_queue(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let state = model.queue_editor
  case state.surface, area.size.height {
    _, 0 -> buf
    queue_editor.Closed, _ -> {
      let rows = layout.queue_rows(model)
      buf
      |> render_panel_border(
        area,
        case area.size.height <= 2 {
          True -> tiny_queue_title(rows, 0, 0, "Alt+q", area.size.width)
          False ->
            " queue · "
            <> int.to_string(list.length(rows))
            <> " pending · Alt+q inspect "
        },
        theme.signal,
      )
      |> paragraph.render_styled(
        layout.panel_inner(area),
        queue_panel.compact(rows, layout.panel_inner(area)),
      )
    }
    queue_editor.Inspector, _ -> {
      let rows = layout.queue_rows(model)
      let inner = layout.panel_inner(area)
      let body = layout.queue_content_area(area)
      let title = case area.size.height {
        height if height <= 2 ->
          tiny_queue_title(
            rows,
            state.selected,
            state.preview_scroll,
            layout.tiny_queue_controls(),
            area.size.width,
          )
        height if height <= 4 -> " queue · ↑↓ Pg ↵ e Esc "
        _ -> " queued inputs · " <> model.active_strand <> " "
      }
      buf
      |> buffer.clear(area)
      |> render_panel_border(area, title, theme.signal)
      |> paragraph.render_styled(inner, queue_inspector_controls(state, inner))
      |> paragraph.render_styled(body, case area.size.height <= 4 {
        True -> [
          queue_panel.tiny_line(
            rows,
            state.selected,
            state.preview_scroll,
            body.size.width,
          ),
        ]
        False ->
          queue_panel.lines(rows, state.selected, state.preview_scroll, body)
      })
    }
    queue_editor.Editor, _ -> render_queue_draft(buf, area, state)
  }
}

fn tiny_queue_title(
  rows: List(snapshot_view.PendingInput),
  selected: Int,
  preview_scroll: Int,
  controls: String,
  width: Int,
) -> String {
  case list.first(list.drop(rows, selected)) {
    Error(Nil) -> " queue · " <> controls <> " "
    Ok(row) -> {
      let #(suffix, preview_width) =
        layout.tiny_queue_measure(row, controls, width)
      let wrapped =
        row.text
        |> text_hygiene.multiline
        |> string.split("\n")
        |> list.flat_map(fn(line) { text.wrap(line, preview_width) })
      let offset = int.min(preview_scroll, int.max(0, list.length(wrapped) - 1))
      let preview =
        wrapped
        |> list.drop(offset)
        |> list.first
        |> result.unwrap("")
      " "
      <> text.truncate(text_hygiene.single_line(preview), preview_width, "")
      <> suffix
      <> " "
    }
  }
}

fn queue_inspector_controls(
  state: queue_editor.State,
  area: Rect,
) -> List(span.Line) {
  let lines = [
    span.line_new([span.span_styled(state.message, theme.overlay_quiet())]),
    span.line_new([
      span.span_styled(
        "↑/↓ select · Enter fetch/edit · e resume draft · Esc back",
        theme.overlay_signal(),
      ),
    ]),
    span.line_new([
      span.span_styled(
        "PgUp/PgDn scroll captured excerpt",
        theme.overlay_signal(),
      ),
    ]),
  ]
  list.take(lines, layout.queue_control_rows(area))
}

fn render_queue_draft(
  buf: buffer.Buffer,
  area: Rect,
  state: queue_editor.State,
) -> buffer.Buffer {
  case state.draft {
    None -> buf
    Some(draft) -> {
      let inner = layout.panel_inner(area)
      let editor_area = layout.queue_draft_area(area)
      let priority = case draft.document.kind {
        queue_editor.Queue -> "queue"
        queue_editor.Steer -> "steer"
      }
      let delivery = case draft.delivery {
        queue_editor.Editable -> "editable revision"
        queue_editor.Saving -> "save awaiting acknowledgement"
        queue_editor.Unknown -> "save outcome unknown"
      }

      // Presentation removes terminal controls while the full source remains
      // unchanged in the draft. Saving never round-trips displayed excerpts.
      let safe =
        text_area.TextAreaState(
          ..draft.input,
          lines: list.map(draft.input.lines, text_hygiene.single_line),
        )
      let input = queue_input_view(safe, editor_area)
      buf
      |> buffer.clear(area)
      |> render_panel_border(
        area,
        " queued input · "
          <> text_hygiene.single_line(draft.document.id)
          <> " · revision "
          <> int.to_string(draft.document.revision)
          <> " ",
        theme.signal,
      )
      |> paragraph.render_styled(
        inner,
        list.take(
          [
            span.line_plain(
              priority
              <> " · "
              <> delivery
              <> " · "
              <> int.to_string(draft.document.attachment_count)
              <> " image attachments retained",
            ),
            span.line_plain(state.message),
            span.line_new([
              span.span_styled(
                "Ctrl+s save · Ctrl+r reconcile · Esc back · Enter newline",
                theme.overlay_signal(),
              ),
            ]),
          ],
          layout.queue_control_rows(area),
        ),
      )
      |> text_area.render(
        editor_area,
        text_area.textarea_new() |> text_area.with_max_lines(0),
        input,
      )
    }
  }
}

fn queue_input_view(input: text_area.TextAreaState, area: Rect) {
  let wrapped = layout.input_view_state(input, area.size.width)
  let offset = int.max(0, wrapped.cursor_y - int.max(1, area.size.height) + 1)
  text_area.TextAreaState(
    ..wrapped,
    lines: wrapped.lines |> list.drop(offset) |> list.take(area.size.height),
    cursor_y: wrapped.cursor_y - offset,
  )
}

fn queue_editor_cursor(model: Model, area: Rect) {
  case model.queue_editor.draft {
    Some(draft) -> {
      let editor_area = layout.queue_draft_area(area)
      let safe =
        text_area.TextAreaState(
          ..draft.input,
          lines: list.map(draft.input.lines, text_hygiene.single_line),
        )
      text_area.cursor_screen_pos(
        queue_input_view(safe, editor_area),
        editor_area,
      )
    }
    None -> Error(Nil)
  }
}

fn diff_title(model: Model) -> String {
  case model.worktree.focus, model.worktree.board {
    worktree_view.Navigator, Some(_) -> " worktree · NAV ↑↓ r Enter PgUp/Dn "
    worktree_view.Navigator, None -> " captured · NAV ↑↓ r Enter PgUp/Dn "
    worktree_view.Composer, Some(_) -> " worktree · COMPOSER Ctrl+d "
    worktree_view.Composer, None -> " captured changes · COMPOSER Ctrl+d "
  }
}

type DiffTone {
  DiffCurrent
  DiffAdded
  DiffChanged
  DiffRemoved
  DiffQuiet
}

type DiffNavigationItem {
  DiffNavigationItem(label: String, tone: DiffTone)
}

fn diff_navigation_items(
  state: worktree_view.State,
) -> List(DiffNavigationItem) {
  case state.board {
    None -> [DiffNavigationItem("[ALL] Captured edits", DiffQuiet)]
    Some(board) ->
      list.append(
        [
          DiffNavigationItem(
            "[ALL] " <> int.to_string(board.total) <> " files",
            DiffCurrent,
          ),
          ..list.map(board.files, fn(file) {
            let status =
              text_hygiene.single_line(
                file.index_status <> file.worktree_status,
              )
            let badge = case file.kind {
              "binary" -> "[BIN]"
              "metadata_only" -> "[META]"
              "no_net_change" -> "[NO Δ]"
              _ -> "[" <> string.trim(status) <> "]"
            }
            DiffNavigationItem(
              badge <> " " <> text_hygiene.single_line(file.path),
              diff_tone(status, file.kind),
            )
          })
        ],
        [DiffNavigationItem("[COMMITS] Since session start", DiffQuiet)],
      )
  }
}

fn diff_tone(status: String, kind: String) -> DiffTone {
  case kind, string.contains(status, "D"), string.contains(status, "A") {
    _, True, _ -> DiffRemoved
    _, False, True -> DiffAdded
    "binary", False, False -> DiffCurrent
    "metadata_only", False, False | "no_net_change", False, False -> DiffQuiet
    _, False, False -> DiffChanged
  }
}

fn diff_navigation_line(
  item: DiffNavigationItem,
  index: Int,
  selected: Int,
  width: Int,
) -> span.Line {
  let DiffNavigationItem(label, tone) = item
  let chosen = index == selected
  let marker = case chosen {
    True -> "▸ "
    False -> "  "
  }
  let background = case chosen {
    True -> theme.raised
    False -> theme.graphite
  }
  let foreground = case tone {
    DiffCurrent -> theme.current
    DiffAdded -> theme.added
    DiffChanged -> theme.signal
    DiffRemoved -> theme.danger
    DiffQuiet -> theme.quiet
  }
  let value =
    marker
    <> label
    |> text.truncate(width, "…")
    |> text.pad_right(width)
  span.line_new([
    span.span_styled(value, style.new(foreground, background, style.none())),
  ])
}

fn diff_selected_header(state: worktree_view.State, width: Int) -> span.Line {
  let label = case state.board {
    None -> "Captured edits · current worktree unavailable"
    Some(board) -> {
      let files = board.files
      let commits_index = list.length(files) + 1
      case state.selected {
        0 ->
          "All files · observation "
          <> board.extent
          <> " · "
          <> int.to_string(board.omitted)
          <> " omitted"
        selected if selected == commits_index -> {
          let worktree_view.Committed(message, _, extent) = board.committed
          text_hygiene.single_line(message) <> " · " <> extent
        }
        selected ->
          case list.first(list.drop(files, selected - 1)) {
            Ok(file) ->
              text_hygiene.single_line(file.path)
              <> " · "
              <> file.kind
              <> " · "
              <> file.extent
            Error(Nil) -> "Selected file unavailable in this observation"
          }
      }
    }
  }
  let value =
    label
    |> text.truncate(width, "…")
    |> text.pad_right(width)
  span.line_new([
    span.span_styled(value, style.new(theme.paper, theme.raised, style.none())),
  ])
}

fn render_diff_view(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let items = diff_navigation_items(model.worktree)
  let panel =
    diff_panel.layout(area, list.length(items), model.worktree.selected)
  buf
  |> paragraph.render_styled(
    panel.heading,
    diff_heading_lines(model.worktree, panel.heading.size.height),
  )
  |> paragraph.render_styled(
    panel.navigation,
    items
      |> list.drop(panel.navigation_offset)
      |> list.take(panel.navigation.size.height)
      |> list.index_map(fn(item, index) {
        diff_navigation_line(
          item,
          panel.navigation_offset + index,
          model.worktree.selected,
          panel.navigation.size.width,
        )
      }),
  )
  |> paragraph.render_styled(panel.selected, [
    diff_selected_header(model.worktree, panel.selected.size.width),
  ])
  |> render_rows(panel.patch, model.diff_rows, model.diff_scroll_offset)
}

fn diff_heading_lines(
  state: worktree_view.State,
  height: Int,
) -> List(span.Line) {
  let focus = case state.focus {
    worktree_view.Composer ->
      "Composer focus · Ctrl+d file navigation · Esc close"
    worktree_view.Navigator ->
      "Navigator focus · ↑/↓ files · r refresh · PgUp/PgDn patch · Enter composer · Esc close"
  }
  case height {
    0 -> []
    1 -> [
      span.line_new([span.span_styled(state.message, theme.overlay_quiet())]),
    ]
    _ -> [
      span.line_new([span.span_styled(state.message, theme.overlay_quiet())]),
      span.line_new([span.span_styled(focus, theme.overlay_signal())]),
    ]
  }
}

fn queue_count_line(model: Model) -> String {
  case model.captured {
    Some(#(_, view)) ->
      case view.pending_inputs {
        Some(rows) ->
          "Queued inputs: "
          <> int.to_string(
            list.length(
              list.filter(rows, fn(row) { row.strand == model.active_strand }),
            ),
          )
        None -> "Queued input count unavailable"
      }
    None -> "Queued input count unavailable"
  }
}

/// The rows of the summary surface for the selected tab.
@internal
pub fn summary_lines(model: Model, width: Int) -> List(span.Line) {
  let #(jobs, jobs_notice) = case model.jobs {
    Some(board) if board.strand == model.active_strand -> #(
      Some(board),
      model.jobs_notice,
    )
    Some(_) -> #(None, "Live jobs unavailable for the current strand")
    None -> #(None, model.jobs_notice)
  }
  summary_panel.lines(
    model.summary_tab,
    completion_summary.latest(model.completion, model.active_strand),
    model.usage,
    context_usage_line(model),
    queue_count_line(model),
    jobs,
    jobs_notice,
    jobs_observation_line(model),
    model.summary_job_selected,
    width,
  )
}

fn jobs_observation_line(model: Model) -> String {
  case model.jobs_observed_ms {
    Some(observed) ->
      "Job ages and deadlines are at last refresh · observation received "
      <> live_jobs.duration(int.max(0, model.last_frame_ms - observed))
      <> " ago"
    None ->
      "Job ages and deadlines are at last refresh · receipt age unavailable"
  }
}

// Context belongs to one measured provider request. Session usage accumulates
// every request and strand, so it can never stand in for this number.
fn context_usage_line(model: Model) -> String {
  let records = case model.captured {
    Some(#(cut, view)) ->
      snapshot_view.branch(view, cut.window, model.active_strand).records
    None -> model.records
  }
  let measured =
    records
    |> list.find_map(fn(record) {
      case record.entry {
        entry.MessageEntry(message: message.AssistantMessage(usage:, ..), ..)
          if usage.total_tokens > 0
        -> Ok(usage)
        _ -> Error(Nil)
      }
    })
  case measured {
    Ok(usage) ->
      "Context at last measured request: "
      <> transcript_lines.tokens(
        usage.input + usage.cache_read + usage.cache_write,
      )
      <> " input tokens (including cache); output "
      <> transcript_lines.tokens(usage.output)
      <> case usage.reasoning {
        Some(count) ->
          " (includes " <> transcript_lines.tokens(count) <> " reasoning)"
        None -> ""
      }
    Error(Nil) -> "Context: no measured request loaded for this strand"
  }
}

fn render_summary_surface(buf, cursor, screen, model: Model) {
  case model.summary_surface {
    queue_editor.Closed -> #(buf, cursor)
    queue_editor.Inspector | queue_editor.Editor -> {
      let inner = layout.panel_inner(screen)
      let body = layout.summary_body_area(screen)
      let lines = summary_lines(model, body.size.width)
      let offset =
        int.min(
          model.summary_scroll,
          int.max(0, list.length(lines) - body.size.height),
        )
      let rendered =
        buffer.buffer_new(screen)
        |> render_panel_border(screen, " summary ", theme.signal)
        |> paragraph.render_styled(
          geometry.rect_new(
            inner.position.x,
            inner.position.y,
            inner.size.width,
            int.min(2, inner.size.height),
          ),
          [
            summary_panel.tab_line(model.summary_tab, inner.size.width),
            span.line_new([
              span.span_styled(
                "[] job · PgUp/Dn · r jobs · Esc back",
                theme.overlay_signal(),
              ),
            ]),
          ],
        )
        |> paragraph.render_styled(body, list.drop(lines, offset))
      #(rendered, Error(Nil))
    }
  }
}

fn render_context_surface(buf, cursor, screen, model: Model) {
  case model.context.surface {
    context_view.Hidden -> #(buf, cursor)
    context_view.Overview | context_view.All -> {
      let inner = layout.panel_inner(screen)
      let title = case screen.size.width < 60 {
        True -> " context · a · PgUp/Dn · r · Esc "
        False -> " context · a detail · PgUp/Dn · r refresh · Esc back "
      }
      let lines = context_panel.lines(model.context, inner.size.width)
      let offset =
        int.min(
          model.context.scroll,
          int.max(0, list.length(lines) - inner.size.height),
        )
      let rendered =
        buffer.buffer_new(screen)
        |> render_panel_border(screen, title, theme.signal)
        |> paragraph.render_styled(inner, list.drop(lines, offset))
      #(rendered, Error(Nil))
    }
  }
}
