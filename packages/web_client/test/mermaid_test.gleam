//// Revision ownership, source bounds and total frame-message decoding.
//// Browser identity checks and DOM cleanup are covered by the browser fixture.

import gleam/list
import gleam/string
import web_client/mermaid_rule as rule

fn waiting() -> rule.State {
  rule.read(rule.new(), "graph TD; A-->B", rule.Dark, 15)
}

fn rendering() -> rule.State {
  let state = waiting()
  rule.due(state, state.revision)
}

pub fn source_and_theme_changes_advance_but_identical_reads_do_not_test() {
  let first = waiting()
  assert first.phase == rule.Waiting
  assert rule.read(first, first.source, rule.Dark, 15) == first
  let changed = rule.read(first, first.source, rule.Light, 15)
  assert changed.revision == first.revision + 1
  assert changed.phase == rule.Waiting
}

pub fn only_the_current_quiet_interval_can_begin_rendering_test() {
  let old = waiting()
  let latest = rule.read(old, "graph TD; A-->C", rule.Dark, 15)
  assert rule.due(latest, old.revision) == latest
  let started = rule.due(latest, latest.revision)
  assert started.phase == rule.Rendering
  assert rule.due(started, latest.revision) == started
}

pub fn stale_results_and_failures_cannot_replace_a_new_source_test() {
  let old = rendering()
  let latest = rule.read(old, "sequenceDiagram\nA->>B: hi", rule.Dark, 24)
  list.each(
    [rule.Rendered(old.revision, 400), rule.Failed(old.revision)],
    fn(reply) {
      assert rule.receive(latest, reply) == latest
    },
  )
  assert rule.expire(latest, old.revision) == latest
}

pub fn dimensions_are_bounded_and_only_current_renders_can_resize_test() {
  let state = rendering()
  list.each([-1, 0, 119, 2001, 999_999], fn(height) {
    assert rule.receive(state, rule.Rendered(state.revision, height)) == state
  })
  let shown = rule.receive(state, rule.Rendered(state.revision, 120))
  assert shown.phase == rule.Shown(120)
  assert rule.receive(shown, rule.Rendered(shown.revision, 2000)).phase
    == rule.Shown(2000)
  assert rule.receive(shown, rule.Rendered(shown.revision - 1, 500)) == shown
  assert rule.expire(shown, shown.revision) == shown
}

pub fn timeout_and_failure_keep_source_and_do_not_accept_late_success_test() {
  let state = rendering()
  list.each(
    [
      rule.expire(state, state.revision),
      rule.receive(state, rule.Failed(state.revision)),
    ],
    fn(failed) {
      assert failed.phase == rule.Unavailable
      assert failed.source == state.source
      assert rule.receive(failed, rule.Rendered(state.revision, 300)) == failed
    },
  )
}

pub fn empty_and_oversized_sources_never_begin_rendering_test() {
  let state = rule.read(rendering(), " \n", rule.Dark, 2)
  assert state.phase == rule.Empty
  assert rule.due(state, state.revision) == state
  let large = rule.read(state, "graph TD", rule.Dark, rule.max_source + 1)
  assert large.phase == rule.TooLarge
  assert rule.due(large, large.revision) == large
  let at_limit = rule.read(state, "graph TD", rule.Dark, rule.max_source)
  assert at_limit.phase == rule.Waiting
}

pub fn frame_messages_are_totally_decoded_with_integer_fields_test() {
  assert rule.reply(
      "{\"kind\":\"ready\",\"padding\":\"" <> string.repeat("x", 600) <> "\"}",
    )
    == rule.Ignored
  assert rule.reply("{\"kind\":\"ready\"}") == rule.Ready
  assert rule.reply("{\"kind\":\"rendered\",\"revision\":2,\"height\":120}")
    == rule.Rendered(2, 120)
  assert rule.reply("{\"kind\":\"failed\",\"revision\":3}") == rule.Failed(3)
  list.each(
    [
      "",
      "null",
      "[]",
      "{}",
      "{\"kind\":\"svg\",\"svg\":\"<script>\"}",
      "{\"kind\":\"rendered\",\"revision\":1,\"height\":\"120\"}",
    ],
    fn(text) {
      assert rule.reply(text) == rule.Ignored
    },
  )
}

pub fn requests_encode_hostile_source_only_as_json_data_test() {
  let text = "</script><svg onload=alert(1)>\n\"quoted\""
  let state = rule.read(rule.new(), text, rule.Light, 48)
  let request = rule.request(state)
  assert string.contains(request, "\"theme\":\"default\"")
  assert string.contains(request, "\\n\\\"quoted\\\"")
  assert string.contains(rule.request(waiting()), "\"theme\":\"dark\"")
}
