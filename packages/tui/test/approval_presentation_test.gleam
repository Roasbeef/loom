//// Approval is disabled if the exact requested authority cannot be inspected.
//// Escaping preserves the actual path and action rather than deleting terminal
//// controls or hiding bidi characters inside an apparently harmless label.

import core/json
import etui/buffer
import etui/geometry
import etui/keys
import etui/span
import etui/widgets/paragraph
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
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
    |> fn(visible) { visible >= 24 }
  assert rendered
    |> list.drop(24)
    |> string.join("\n")
    |> string.contains("Permission request")
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
    |> list.take(20)
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
  let assert Ok(write_text) = approval.readable_details(write)
  let assert Ok(edit_text) = approval.readable_details(edit)
  let assert Ok(read_text) = approval.readable_details(extra_read)
  assert string.contains(write_text, "important body")
  assert string.contains(edit_text, "new_text")
  assert string.contains(edit_text, "kept")
  assert string.contains(read_text, "must remain")
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
  assert string.contains(
    string.join(lines, "\n"),
    "Tab choose · Enter · ↑↓ scroll",
  )

  let tiny = geometry.rect_new(0, 0, 24, 6)
  let tiny_lines =
    approval_panel.render(buffer.buffer_new(tiny), tiny, panel)
    |> frame.buffer_to_lines
  assert list.length(tiny_lines) == 6
  assert list.all(tiny_lines, fn(line) { string.length(line) <= 24 })
}

fn row_index(lines: List(String), needle: String) -> Int {
  lines
  |> list.index_map(fn(line, index) { #(line, index) })
  |> list.find(fn(row) { string.contains(row.0, needle) })
  |> result.map(fn(row) { row.1 })
  |> result.unwrap(-1)
}
