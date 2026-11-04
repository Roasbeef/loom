//// Stage ownership and protocol-policy regressions for the iframe controller.
//// These tests do not import the runtime or pretend to exercise browser DOM.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import web_mermaid/controller as c

fn request(revision: Int) -> c.Request {
  c.Request("flowchart LR\nA-->B", c.Dark, revision)
}

fn drawing(revision: Int) -> c.Model {
  c.update(c.new(), c.Requested(request(revision))).0
}

fn checking(revision: Int) -> c.Model {
  c.update(drawing(revision), c.Rendered(revision, Ok("<svg/>"))).0
}

fn shown(revision: Int) -> c.Model {
  c.update(checking(revision), c.Published(revision, Ok(300.0))).0
}

pub fn publication_requires_both_current_stages_and_bounds_height_test() {
  let drawing = drawing(1)
  assert c.update(drawing, c.Published(1, Ok(500.0))) == #(drawing, [])
  let #(checking, effects) = c.update(drawing, c.Rendered(1, Ok("<svg/>")))
  assert checking.phase == c.Busy(c.Checking, request(1), None)
  assert effects == [c.Inspect(1, "<svg/>")]
  assert c.update(checking, c.Rendered(1, Ok("duplicate"))) == #(checking, [])
  let #(shown, effects) = c.update(checking, c.Published(1, Ok(120.1)))
  assert shown.phase == c.Idle
  assert shown.shown == Some(1)
  assert effects == [c.ReplyToParent(c.RenderedReply(1, 121))]
  assert c.update(shown, c.Published(1, Ok(500.0))) == #(shown, [])
  assert c.update(checking, c.Published(1, Ok(-100.0))).1
    == [c.ReplyToParent(c.RenderedReply(1, 120))]
  assert c.update(checking, c.Published(1, Ok(100_000.0))).1
    == [c.ReplyToParent(c.RenderedReply(1, 2000))]
}

pub fn newer_source_during_inspection_cannot_publish_old_svg_test() {
  let #(model, _) = c.update(checking(1), c.Requested(request(2)))
  assert model.phase == c.Busy(c.Checking, request(1), Some(request(2)))
  let #(model, effects) = c.update(model, c.Published(1, Ok(400.0)))
  assert model.phase == c.Busy(c.Drawing, request(2), None)
  assert model.shown == None
  assert effects == [c.Begin(request(2))]
  let #(model, effects) = c.update(model, c.Rendered(2, Ok("current")))
  assert effects == [c.Inspect(2, "current")]
  let #(model, effects) = c.update(model, c.Published(2, Ok(500.0)))
  assert model.shown == Some(2)
  assert effects == [c.ReplyToParent(c.RenderedReply(2, 500))]
}

pub fn both_failure_stages_clear_and_refuse_without_late_revival_test() {
  let cases = [
    #(drawing(1), c.Rendered(1, Error(""))),
    #(checking(1), c.Published(1, Error(Nil))),
  ]
  list.each(cases, fn(pair) {
    let #(failed, effects) = c.update(pair.0, pair.1)
    assert failed.phase == c.Idle
    assert failed.shown == None
    assert effects == [c.Clear, c.ReplyToParent(c.FailedReply(1, ""))]
    assert c.update(failed, c.Published(1, Ok(500.0))) == #(failed, [])
    assert c.update(failed, c.Rendered(1, Ok("late"))) == #(failed, [])
  })
}

pub fn refusing_queued_work_does_not_release_the_active_vendor_slot_test() {
  let #(model, _) = c.update(drawing(1), c.Requested(request(2)))
  let #(model, effects) = c.update(model, c.Refused(3))
  assert model.phase == c.Busy(c.Drawing, request(1), None)
  assert model.latest == 3
  assert model.shown == None
  assert effects == [c.Clear, c.ReplyToParent(c.FailedReply(3, ""))]
  let #(idle, effects) = c.update(model, c.Rendered(1, Ok("stale")))
  assert idle.phase == c.Idle
  assert effects == []

  let #(queued, _) = c.update(model, c.Requested(request(4)))
  assert queued.phase == c.Busy(c.Drawing, request(1), Some(request(4)))
  let #(next, effects) = c.update(queued, c.Rendered(1, Error("")))
  assert next.phase == c.Busy(c.Drawing, request(4), None)
  assert effects == [c.Begin(request(4))]
}

pub fn stale_requests_refusals_and_wrong_completion_revisions_are_ignored_test() {
  let drawing = drawing(2)
  list.each(
    [
      c.Requested(request(1)),
      c.Requested(request(2)),
      c.Refused(1),
      c.Refused(2),
      c.Rendered(1, Error("")),
    ],
    fn(message) {
      assert c.update(drawing, message) == #(drawing, [])
    },
  )
  let checking = checking(2)
  assert c.update(checking, c.Published(1, Error(Nil))) == #(checking, [])
}

pub fn resize_replies_require_a_current_shown_revision_and_changed_width_test() {
  let #(empty, effects) = c.update(c.new(), c.Resized(800.0))
  assert empty.width == 800.0
  assert effects == []
  let #(current, effects) = c.update(shown(2), c.Resized(800.0))
  assert effects == [c.Measure(2)]
  assert c.update(current, c.Resized(800.0)) == #(current, [])
  assert c.update(current, c.Measured(2, 150.1)).1
    == [c.ReplyToParent(c.RenderedReply(2, 151))]
  assert c.update(current, c.Measured(2, 3000.0)).1
    == [c.ReplyToParent(c.RenderedReply(2, 2000))]
  assert c.update(current, c.Measured(1, 3000.0)) == #(current, [])
  let #(newer, _) = c.update(current, c.Requested(request(3)))
  assert c.update(newer, c.Measured(2, 500.0)) == #(newer, [])
}

pub fn malformed_request_fields_and_unsafe_revisions_never_reach_the_vendor_test() {
  let prefix = "{\"source\":\"graph TD\",\"theme\":\"dark\",\"revision\":"
  list.each(
    [
      "",
      "null",
      "[]",
      "{}",
      prefix <> "0}",
      prefix <> "-1}",
      prefix <> "1.5}",
      prefix <> "9007199254740992}",
      prefix <> "1e100}",
      "{\"source\":false,\"theme\":\"dark\",\"revision\":1}",
      "{\"source\":\"x\",\"theme\":\"forest\",\"revision\":1}",
    ],
    fn(text) {
      assert c.input(text) == c.Ignored
    },
  )
  assert c.input(prefix <> "9007199254740991}")
    == c.Accepted(c.Request("graph TD", c.Dark, 9_007_199_254_740_991))
}

pub fn configuration_pins_every_security_and_layout_option_test() {
  let expected = #(
    False,
    "strict",
    True,
    32_000,
    250,
    False,
    "dark",
    "dagre",
    False,
  )
  assert json.parse(c.configuration(c.Dark), config_decoder()) == Ok(expected)
  assert json.parse(c.configuration(c.Light), config_decoder())
    == Ok(#(
      False,
      "strict",
      True,
      32_000,
      250,
      False,
      "default",
      "dagre",
      False,
    ))
  assert c.color_scheme(c.Dark) == "dark"
  assert c.color_scheme(c.Light) == "light"
  assert c.reply_json(c.Ready) == "{\"kind\":\"ready\"}"
  assert c.reply_json(c.FailedReply(3, ""))
    == "{\"kind\":\"failed\",\"revision\":3,\"diagnostic\":\"\"}"
}

pub fn svg_restrictions_cover_root_descendants_and_all_reference_attributes_test() {
  assert !c.safe_svg([])
  list.each(["a", "foreignObject", "script", "image", "parsererror"], fn(name) {
    assert !c.safe_svg([c.Node("svg", []), c.Node(name, [])])
  })
  list.each(["href", "xlink:href", "any:href"], fn(name) {
    list.each(
      [
        "",
        "https://not-used.invalid",
        "javascript:alert(1)",
        "data:image/svg+xml,x",
        "other.svg#node",
      ],
      fn(value) {
        assert !c.safe_svg([c.Node("svg", [c.Attribute(name, value)])])
        assert !c.safe_svg([
          c.Node("svg", []),
          c.Node("use", [c.Attribute(name, value)]),
        ])
      },
    )
    assert c.safe_svg([
      c.Node("svg", []),
      c.Node("use", [c.Attribute(name, "#local")]),
    ])
  })
  assert !c.safe_svg([c.Node("html", [])])
  assert c.safe_svg([c.Node("svg", [c.Attribute("role", "img")])])
  assert string.contains(
    c.reply_json(c.RenderedReply(4, 300)),
    "\"height\":300",
  )
}

fn config_decoder() -> decode.Decoder(
  #(Bool, String, Bool, Int, Int, Bool, String, String, Bool),
) {
  use start <- decode.field("startOnLoad", decode.bool)
  use security <- decode.field("securityLevel", decode.string)
  use errors <- decode.field("suppressErrorRendering", decode.bool)
  use size <- decode.field("maxTextSize", decode.int)
  use edges <- decode.field("maxEdges", decode.int)
  use labels <- decode.field("htmlLabels", decode.bool)
  use theme <- decode.field("theme", decode.string)
  use layout <- decode.field("layout", decode.string)
  use flow <- decode.field("flowchart", {
    use labels <- decode.field("htmlLabels", decode.bool)
    decode.success(labels)
  })
  decode.success(#(
    start,
    security,
    errors,
    size,
    edges,
    labels,
    theme,
    layout,
    flow,
  ))
}

/// Retains the current vendor error without publishing a superseded diagnostic.
pub fn diagnostic_belongs_to_the_active_revision_test() {
  let diagnostic = "Parse error on line 8:\nExpected ACTOR, got loop"
  let #(failed, effects) =
    c.update(drawing(1), c.Rendered(1, Error(diagnostic)))
  assert failed.phase == c.Idle
  assert effects == [c.Clear, c.ReplyToParent(c.FailedReply(1, diagnostic))]

  // A queued successor owns the display even if the active parser fails first.
  let #(queued, _) = c.update(drawing(1), c.Requested(request(2)))
  let #(next, effects) = c.update(queued, c.Rendered(1, Error(diagnostic)))
  assert next.phase == c.Busy(c.Drawing, request(2), None)
  assert effects == [c.Begin(request(2))]
}

/// Bounds Unicode and JSON escape expansion without turning text into markup.
pub fn diagnostic_reply_is_bounded_and_preserves_literal_text_test() {
  let diagnostic = "<img src=x onerror=alert(1)>\nExpected 'ACTOR' at \"Loop\""
  let decoder = {
    use diagnostic <- decode.field("diagnostic", decode.string)
    decode.success(diagnostic)
  }
  assert json.parse(c.reply_json(c.FailedReply(1, diagnostic)), decoder)
    == Ok(diagnostic)
  list.each(["💜", "\u{0}", "e\u{301}"], fn(point) {
    let encoded = c.reply_json(c.FailedReply(1, string.repeat(point, 3000)))
    assert string.byte_size(encoded) <= 12_512
    let assert Ok(decoded) = json.parse(encoded, decoder)
    assert list.length(string.to_utf_codepoints(decoded)) == 2000
  })
}
