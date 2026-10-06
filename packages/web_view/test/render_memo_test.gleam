//// Editor and preview reuse, measured through Lustre's own render cache.
////
//// Counting the expensive constructors catches work performed before a memo
//// can hit, which comparing the final HTML alone cannot catch. The cache is
//// carried across unchanged and changed views, including a second unchanged
//// render, which catches a memo nested inside another memo losing its entry.
//// The private profiler counts only this test process and is stopped after
//// each callback, so another test cannot affect the counts.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import lustre/element.{type Element}
import page_fixture
import session_view/agent_roster
import session_view/agent_view
import session_view/connection_event
import session_view/operator
import session_view/turns
import web_view/component
import web_view/operator_page
import web_view/view/lane
import web_view/view/strand_detail
import web_view/view/strip

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

@external(erlang, "lane_memo_ffi", "patch_text")
fn patch(
  cache: Cache,
  old: Element(message),
  new: Element(message),
) -> #(String, Cache)

@external(erlang, "render_memo_ffi", "counted")
fn counted(run: fn() -> value) -> #(value, Int, Int)

pub fn unchanged_editor_reuses_commands_and_a_return_refreshes_it_test() {
  let page = page_fixture.ready(process.new_subject(), "operator")
  let #(#(view, cache), tables, _) =
    counted(fn() {
      let view = operator_page.view(page)
      #(view, first(view))
    })
  assert tables == 1

  let #(#(_, cache), tables, _) =
    counted(fn() { patch(cache, view, operator_page.view(page)) })
  assert tables == 0

  let #(#(_, cache), tables, _) =
    counted(fn() { patch(cache, view, operator_page.view(page)) })
  assert tables == 0

  let returned =
    connection_event.Incoming(
      "{\"v\":2,\"event\":\"held_input_returned\",\"body\":{\"strand\":\"main\",\"id\":\"h1\",\"kind\":\"queue\",\"text\":\"deploy when green\",\"attachment_count\":0}}",
    )
  let page = component.update(page, component.Arrived([returned])).0
  let #(#(text, _), tables, _) =
    counted(fn() { patch(cache, view, operator_page.view(page)) })
  assert tables == 1
  assert string.contains(text, "deploy when green")
}

// A refusal keeps the draft's editor, so its counter must invalidate the leaf
// memo even though neither returned prompt input changed.
pub fn a_refused_submit_refreshes_the_editor_and_then_reuses_it_test() {
  let page = page_fixture.ready(process.new_subject(), "operator")
  let view = operator_page.view(page)
  let cache = first(view)
  let refused =
    operator_page.update(
      page,
      operator_page.Submitted("   ", operator.Prompt, []),
    ).0
  assert component.refusals(refused) == component.refusals(page) + 1
  assert component.returns(refused) == component.returns(page)
  assert component.returned(refused) == component.returned(page)

  let #(#(text, view, cache), tables, _) =
    counted(fn() {
      let next = operator_page.view(refused)
      let #(text, cache) = patch(cache, view, next)
      #(text, next, cache)
    })
  assert tables == 1
  assert string.contains(text, "refused")

  let #(#(_, _), tables, _) =
    counted(fn() { patch(cache, view, operator_page.view(refused)) })
  assert tables == 0
}

fn chip() -> strip.Chip {
  strip.Chip(
    line: agent_roster.Line(
      id: "review",
      name: "review",
      status: agent_view.Idle,
      text: "",
      title: "",
      elapsed_s: None,
      tokens: None,
    ),
    hue: turns.Sub(0),
    cache: None,
    running_ms: None,
    model: "",
    recent: [],
    answer: Some("**first** answer"),
  )
}

pub fn preview_reuses_markdown_and_refreshes_answer_and_tools_test() {
  let chip = chip()
  let #(#(view, cache), _, parses) =
    counted(fn() {
      let view = strand_detail.view(chip)
      #(view, first(view))
    })
  assert parses == 1

  let #(#(_, cache), _, parses) =
    counted(fn() { patch(cache, view, strand_detail.view(chip)) })
  assert parses == 0

  let #(#(_, cache), _, parses) =
    counted(fn() { patch(cache, view, strand_detail.view(chip)) })
  assert parses == 0

  let changed = strip.Chip(..chip, answer: Some("**second** answer"))
  let #(#(text, view, cache), _, parses) =
    counted(fn() {
      let next = strand_detail.view(changed)
      let #(text, cache) = patch(cache, view, next)
      #(text, next, cache)
    })
  assert parses == 1
  assert string.contains(text, "second")

  let #(#(text, _), _, parses) =
    counted(fn() {
      patch(
        cache,
        view,
        strand_detail.view(strip.Chip(..changed, recent: ["read"])),
      )
    })
  assert parses == 0
  assert string.contains(text, "read")
}

fn report(text: String) -> Element(Nil) {
  lane.rows(
    [turns.Returned("result", "review", "completed", text, turns.Sub(0))],
    [],
    element.none(),
    fn(line) { element.text(line.text) },
    lane.NoReplies,
    lane.no_marks(),
    lane.NoFolds,
    "",
  )
}

pub fn report_reuses_preview_and_body_and_refreshes_them_together_test() {
  let #(#(view, cache), _, parses) =
    counted(fn() {
      let view = report("**first**\nfull body")
      #(view, first(view))
    })
  assert parses == 2

  let #(#(_, cache), _, parses) =
    counted(fn() { patch(cache, view, report("**first**\nfull body")) })
  assert parses == 0

  let #(#(_, cache), _, parses) =
    counted(fn() { patch(cache, view, report("**first**\nfull body")) })
  assert parses == 0

  let #(#(text, view, cache), _, parses) =
    counted(fn() {
      let next = report("**second**\nnew body")
      let #(text, cache) = patch(cache, view, next)
      #(text, next, cache)
    })
  assert parses == 2
  assert string.contains(text, "second")
  assert string.contains(text, "new body")

  let #(#(_, _), _, parses) =
    counted(fn() { patch(cache, view, report("**second**\nnew body")) })
  assert parses == 0
}
