//// Approval is disabled if the exact requested authority cannot be inspected.
//// Escaping preserves the actual path and action rather than deleting terminal
//// controls or hiding bidi characters inside an apparently harmless label.

import core/json
import etui/buffer
import etui/geometry
import etui/keys
import etui/span
import etui/style
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import tui/appearance
import tui/approval
import tui/approval_panel
import tui/frame

fn review(path) {
  approval.Review(
    "esc",
    7,
    approval.Pending,
    "bash",
    "inspect requested path",
    None,
    approval.Exact("digest\u{202e}", [
      json.Object([
        #("type", json.String("readable_root")),
        #("path", json.String(path)),
      ]),
    ]),
  )
}

/// Renders the compact approval fixture for visual review at one terminal size.
pub fn approval_capture(width: Int, height: Int) -> String {
  let screen = geometry.rect_new(0, 0, width, height)
  let transcript =
    list.repeat(
      span.line_plain("transcript · completed work remains visible"),
      height,
    )
  let base =
    paragraph.render_styled(buffer.buffer_new(screen), screen, transcript)
  let panel =
    review("/Users/operator/project")
    |> approval_panel.new
    |> approval_panel.with_context(approval_panel.CapturedRequest(
      "sub:review",
      "run-1",
    ))
  approval_panel.render(base, screen, panel) |> frame.buffer_to_text
}

pub fn approval_presentation_ascii_escapes_hidden_paths_without_changing_authority_test() {
  let path = "/work/\u{202e}safe\u{1b}[2J\u{1f600}"
  let record = review(path)
  let assert Ok(detail) = approval.details(record)
    as "bounded exact authority is available for inspection"
  assert string.contains(detail, "\\u202e")
  assert string.contains(detail, "\\u001b")
  assert string.contains(detail, "\\ud83d\\ude00")
  assert !string.contains(detail, "\u{202e}")
  let assert Ok(json.Object(fields)) = json.parse(detail)
    as "literal display remains valid JSON with identical meanings"
  assert list.key_find(fields, "action") == Ok(json.String("digest\u{202e}"))
  let assert approval.Exact(_, grants) = record.permission
    as "the original exact grant set remains available"
  assert list.key_find(fields, "grants") == Ok(json.Array(grants))
  let assert Ok(_) = approval.approve(1, record)
    as "small exact authority remains approvable"
}

pub fn approval_presentation_oversized_hidden_grant_disables_approve_but_not_deny_test() {
  let record = review("/" <> string.repeat("x", approval.detail_limit))
  let assert Error(reason) = approval.details(record)
    as "an oversized grant is not silently omitted from the detail panel"
  assert string.contains(reason, "Incomplete detail")
  let assert Error(_) = approval.approve(1, record)
    as "the caller cannot approve the hidden suffix anyway"
  let assert Ok(_) = approval.deny(1, record)
    as "denial does not grant the undisplayed authority"
  let escaped = review("/" <> string.repeat("\u{202e}", 3000))
  let assert Error(_) = approval.details(escaped)
    as "the bound includes escaped display expansion, not only input bytes"
}

pub fn approval_presentation_exact_display_boundary_and_narrow_scrolling_test() {
  let assert Ok(base) = approval.details(review("/"))
    as "base detail has a measured escaped size"
  let exact =
    review(
      "/" <> string.repeat("x", approval.detail_limit - string.byte_size(base)),
    )
  let assert Ok(detail) = approval.details(exact)
    as "the exact16KiB boundary remains supported"
  assert string.byte_size(detail) == approval.detail_limit
  let assert Ok(_) = approval.approve(1, exact)
    as "the complete exact-bound detail may be approved"
  let assert Error(_) =
    approval.approve(
      1,
      review(
        "/"
        <> string.repeat(
          "x",
          approval.detail_limit - string.byte_size(base) + 1,
        ),
      ),
    )
    as "one more displayed byte disables approval"
  let panel =
    approval_panel.new(review(
      "/" <> string.repeat("x", 3000) <> "/unsafe-suffix",
    ))
  let screen = geometry.rect_new(0, 0, 80, 10)
  let draw = fn(panel) {
    approval_panel.render(buffer.buffer_new(screen), screen, panel)
    |> frame.buffer_to_text
  }
  assert !string.contains(draw(panel), "unsafe-suffix")
  let assert approval_panel.Continue(last) =
    approval_panel.update(keys.End, panel)
    as "End scrolls without making a decision"
  assert string.contains(draw(last), "unsafe-suffix")
    as "a narrow panel wraps and scrolls to the entire grant, not just its prefix"
  assert approval_panel.update(keys.Escape, last) == approval_panel.Close
}

// Owner context changes the presentation, never the exact captured decision.
pub fn approval_owner_context_preserves_exact_consent_test() {
  let record = review("/work/report")
  let panel =
    approval_panel.new(record)
    |> approval_panel.with_context(approval_panel.CapturedRequest(
      "sub:review",
      "run-1",
    ))
  let screen = geometry.rect_new(0, 0, 100, 24)
  let rendered =
    approval_panel.render(buffer.buffer_new(screen), screen, panel)
    |> frame.buffer_to_text
  assert string.contains(rendered, "Requested by sub:review")
  assert !string.contains(rendered, "operation run-1")
  let assert approval_panel.Continue(raw) =
    approval_panel.update(keys.Ctrl("g"), panel)
  let raw_rendered =
    approval_panel.render(buffer.buffer_new(screen), screen, raw)
    |> frame.buffer_to_text
  assert string.contains(raw_rendered, "operation run-1")
  let assert approval_panel.Continue(unselected) =
    approval_panel.update(keys.Enter, panel)
    as "adding owner context does not preselect consent"
  let assert approval_panel.Continue(selected) =
    approval_panel.update(keys.Right, unselected)
    as "the operator explicitly chooses once-only permission"
  let assert approval_panel.Decide(exact, approval_panel.AllowOnce) =
    approval_panel.update(keys.Enter, selected)
    as "confirmation returns the untouched captured request"
  assert exact == record
}

pub fn approval_panel_is_bottom_anchored_and_preserves_the_transcript_test() {
  let record = review("/work/report")
  let screen = geometry.rect_new(0, 0, 100, 40)
  let transcript =
    list.repeat(span.line_plain("transcript remains visible"), 40)
  let base =
    paragraph.render_styled(buffer.buffer_new(screen), screen, transcript)
  let rendered =
    approval_panel.render(base, screen, approval_panel.new(record))
    |> frame.buffer_to_lines
  let assert Ok(first) = list.first(rendered)
  assert first == "transcript remains visible"
  assert list.filter(rendered, fn(line) {
      string.contains(line, "transcript remains visible")
    })
    |> list.length
    |> fn(visible) { visible >= 22 }
  assert rendered
    |> list.drop(22)
    |> string.join("\n")
    |> string.contains("Permission required")
}

pub fn approval_panel_readable_and_raw_views_stay_compact_test() {
  let panel = approval_panel.new(review("/work/clear-name"))
  let screen = geometry.rect_new(0, 0, 96, 36)
  let draw = fn(panel) {
    approval_panel.render(buffer.buffer_new(screen), screen, panel)
    |> frame.buffer_to_text
  }
  assert string.contains(draw(panel), "Read files under")
  assert !string.contains(draw(panel), "Raw captured request")
  let assert approval_panel.Continue(raw) =
    approval_panel.update(keys.Ctrl("g"), panel)
  let raw_text = draw(raw)
  assert string.contains(raw_text, "Raw captured request")
  assert string.contains(raw_text, "\"grants\"")
  let rows = raw_text |> string.split("\n")
  assert rows
    |> list.take(18)
    |> list.all(fn(row) { !string.contains(row, "Raw captured request") })
    as "the detail toggle remains in a bottom panel rather than taking the screen"
}

pub fn common_json_action_preview_is_projected_without_hiding_exact_raw_test() {
  let record =
    approval.Review(
      ..review("/workspace"),
      tool: "fs_read",
      preview: "{\"limit\":32,\"offset\":101,\"path\":\"src/main.gleam\"}",
    )
  let assert Ok(readable) = approval.readable_details(record)
  assert string.contains(
    readable,
    "Read \"src/main.gleam\" from line 101 for at most 32 lines",
  )
  assert !string.contains(readable, "{\"limit\"")
  let assert Ok(raw) = approval.details(record)
  assert string.contains(raw, "\\\"limit\\\":32")
}

pub fn action_preview_falls_back_when_a_projection_would_hide_arguments_test() {
  let write =
    approval.Review(
      ..review("/workspace"),
      tool: "fs_write",
      preview: "{\"content\":\"important body\",\"path\":\"report.md\"}",
    )
  let edit =
    approval.Review(
      ..review("/workspace"),
      tool: "fs_edit",
      preview: "{\"edits\":[{\"new_text\":\"kept\"}],\"path\":\"report.md\"}",
    )
  let extra_read =
    approval.Review(
      ..review("/workspace"),
      tool: "fs_read",
      preview: "{\"path\":\"report.md\",\"unknown\":\"must remain\"}",
    )
  let extra_write =
    approval.Review(
      ..write,
      preview: "{\"path\":\"report.md\",\"content\":\"kept\",\"unknown\":\"write extra remains\"}",
    )
  let assert Ok(write_text) = approval.readable_details(write)
  let assert Ok(edit_text) = approval.readable_details(edit)
  let assert Ok(read_text) = approval.readable_details(extra_read)
  let assert Ok(extra_write_text) = approval.readable_details(extra_write)
  assert string.contains(write_text, "important body")
  assert string.contains(edit_text, "new_text")
  assert string.contains(edit_text, "kept")
  assert string.contains(read_text, "must remain")
  assert string.contains(extra_write_text, "write extra remains")
}

/// A plain preview has not already passed through JSON string escaping.
pub fn plain_preview_preserves_control_bytes_as_visible_escapes_test() {
  let record =
    approval.Review(
      ..review("/work/report"),
      preview: "before\u{1b}[2J\n\t\r\u{7}after\\n",
    )
  let assert Ok(presented) = approval.presentation(record)
    as "a bounded plain preview remains inspectable"
  assert string.contains(presented.action, "\\u001b[2J")
  assert string.contains(presented.action, "\\n")
  assert string.contains(presented.action, "\\t")
  assert string.contains(presented.action, "\\r")
  assert string.contains(presented.action, "\\u0007")
  assert string.contains(presented.action, "after\\\\n")
  assert !string.contains(presented.action, "\u{1b}")
  assert !string.contains(presented.action, "\n")
}

/// File lines retain their structure while terminal controls stay literal.
pub fn write_preview_separates_file_lines_from_terminal_controls_test() {
  let record =
    approval.Review(
      ..review("/work/report"),
      tool: "fs_write",
      preview: json.to_string(
        json.Object([
          #("path", json.String("report.md")),
          #("content", json.String("first\nsecond\\n\u{1b}[2J\u{202e}\n")),
        ]),
      ),
    )
  let assert Ok(presented) = approval.presentation(record)
  assert string.contains(
    presented.action,
    "first\nsecond\\\\n\\u001b[2J\\u202e\n",
  )
    as "real lines, literal backslashes, and escaped controls remain distinct"
  assert !string.contains(presented.action, "\u{1b}")
  assert !string.contains(presented.action, "\u{202e}")
}

/// Every byte of long exact detail must be reachable through page navigation.
pub fn approval_paging_cannot_skip_detail_rows_test() {
  let markers =
    int.range(0, 80, [], fn(markers, index) {
      ["MARK" <> int.to_string(index) <> "END", ..markers]
    })
  let record =
    approval.Review(
      ..review("/work/report"),
      preview: string.join(markers, " "),
    )
  let screen = geometry.rect_new(0, 0, 40, 12)
  let #(pages, _) =
    int.range(0, 100, #([], approval_panel.new(record)), fn(acc, _) {
      let #(pages, panel) = acc
      let rendered =
        approval_panel.render(buffer.buffer_new(screen), screen, panel)
      let assert approval_panel.Continue(next) =
        approval_panel.update(keys.PageDown, panel)
        as "paging never chooses a decision"
      #([frame.buffer_to_text(rendered), ..pages], next)
    })
  list.each(markers, fn(marker) {
    assert list.any(pages, fn(page) { string.contains(page, marker) })
      as "page navigation skipped part of the exact request"
  })
}

pub fn unavailable_approval_can_only_select_deny_test() {
  let record =
    approval.Review(
      "esc-unsupported",
      11,
      approval.Pending,
      "shell",
      "unknown authority",
      None,
      approval.Unavailable("unsupported requested grant kind"),
    )
  let panel = approval_panel.new(record)
  let assert approval_panel.Continue(selected) =
    approval_panel.update(keys.Right, panel)
  let assert approval_panel.Decide(exact, approval_panel.Deny) =
    approval_panel.update(keys.Enter, selected)
  assert exact == record
  let rendered =
    approval_panel.render(
      buffer.buffer_new(geometry.rect_new(0, 0, 52, 12)),
      geometry.rect_new(0, 0, 52, 12),
      panel,
    )
    |> frame.buffer_to_text
  assert string.contains(rendered, "Allow once (unavailable)")
  assert string.contains(rendered, "Allow for session (unavailable)")
  assert string.contains(rendered, "Deny")
}

pub fn narrow_approval_stacks_choices_and_tiny_terminal_stays_bounded_test() {
  let panel = approval_panel.new(review("/work/report"))
  let narrow = geometry.rect_new(0, 0, 48, 12)
  let lines =
    approval_panel.render(buffer.buffer_new(narrow), narrow, panel)
    |> frame.buffer_to_lines
  let once = row_index(lines, "Allow once")
  let session = row_index(lines, "Allow for session")
  let deny = row_index(lines, "Deny")
  assert once >= 0
  assert session >= 0
  assert deny >= 0
  assert once < session && session < deny
  assert string.contains(string.join(lines, "\n"), "↑↓")

  let tiny = geometry.rect_new(0, 0, 24, 6)
  let tiny_lines =
    approval_panel.render(buffer.buffer_new(tiny), tiny, panel)
    |> frame.buffer_to_lines
  assert list.length(tiny_lines) == 6
  assert list.all(tiny_lines, fn(line) { string.length(line) <= 24 })
}

/// Styling must survive wrapping and fill the entire selected choice row.
pub fn approval_styles_keep_panel_backgrounds_and_choice_focus_test() {
  let screen = geometry.rect_new(0, 0, 100, 40)
  let panel = approval_panel.new(review("/work/report"))
  let draw = fn(state) {
    approval_panel.render(buffer.buffer_new(screen), screen, state)
  }
  let initial = draw(panel)
  let rows = frame.buffer_to_lines(initial)
  let once = row_index(rows, "Allow once")
  let session = row_index(rows, "Allow for session")
  let deny = row_index(rows, "Deny")
  let top = row_index(rows, "Permission required")
  assert top >= 22
  assert once > top && session > once && deny > session

  // Explicit backgrounds prevent terminal-default text from punching holes
  // through the filled panel, including the trailing cells after a short line.
  int.range(top + 1, 39, Nil, fn(_, y) {
    int.range(3, 97, Nil, fn(_, x) {
      assert buffer.get_cell(initial, geometry.Position(x, y)).style.bg
        != style.Default
    })
  })
  let assert approval_panel.Continue(selected) =
    approval_panel.update(keys.Down, panel)
    as "Down explicitly selects the first available choice"
  let focused = draw(selected)
  let focus = buffer.get_cell(focused, geometry.Position(6, once)).style
  let before = buffer.get_cell(initial, geometry.Position(6, once)).style
  assert focus.bg != before.bg
  assert buffer.get_cell(focused, geometry.Position(92, once)).style.bg
    == focus.bg
    as "focus extends beyond the label across the choice row"
  assert focused
    |> appearance.apply(appearance.Plain)
    |> frame.buffer_to_text
    |> string.contains("› Allow once")
    as "selection remains visible when the terminal disables color"
  let assert approval_panel.Decide(exact, approval_panel.AllowOnce) =
    approval_panel.update(keys.Enter, selected)
    as "focus confirms the captured request only after explicit selection"
  assert exact == review("/work/report")
}

/// Scrolling long detail must not choose or change the pending decision.
pub fn approval_detail_scrolling_is_separate_from_vertical_choices_test() {
  let panel = approval_panel.new(review("/work/report"))
  let assert approval_panel.Continue(scrolled) =
    approval_panel.update(keys.PageDown, panel)
    as "PageDown scrolls detail without selecting an answer"
  let assert approval_panel.Continue(_) =
    approval_panel.update(keys.Enter, scrolled)
    as "scrolling alone cannot authorize a request"
  let assert approval_panel.Continue(once) =
    approval_panel.update(keys.Down, scrolled)
  let assert approval_panel.Continue(session) =
    approval_panel.update(keys.Down, once)
  let assert approval_panel.Continue(back) =
    approval_panel.update(keys.Up, session)
  let assert approval_panel.Decide(exact, approval_panel.AllowOnce) =
    approval_panel.update(keys.Enter, back)
  assert exact == review("/work/report")
}

fn row_index(lines: List(String), needle: String) -> Int {
  lines
  |> list.index_map(fn(line, index) { #(line, index) })
  |> list.find(fn(row) { string.contains(row.0, needle) })
  |> result.map(fn(row) { row.1 })
  |> result.unwrap(-1)
}
