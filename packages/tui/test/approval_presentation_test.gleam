//// Approval is disabled if the exact requested authority cannot be inspected.
//// Escaping preserves the actual path and action rather than deleting terminal
//// controls or hiding bidi characters inside an apparently harmless label.

import core/json
import etui/buffer
import etui/geometry
import etui/keys
import gleam/list
import gleam/option.{None}
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
        #("kind", json.String("readable_root")),
        #("path", json.String(path)),
      ]),
    ]),
  )
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
