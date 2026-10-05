//// A `code_mode` program in the lane is syntax highlighted.
////
//// The program is a fenced `gleam` block in a call's body, so it takes the
//// same path as a fence in an answer (`web_view/code_view`). These tests
//// render a whole component from a capture and read the HTML: the token
//// spans are there, and a program whose strings try to close a tag or open
//// a script is drawn as escaped text.

import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component

fn drawn(program: String) -> String {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.programmed(program, "done")])
  |> component.view
  |> element.to_string
}

pub fn a_program_body_is_drawn_as_token_spans_test() {
  let html = drawn("pub fn main() {\n  let n = 42\n  Ok(n) // done\n}")
  assert string.contains(html, "<span class=\"tok-kw\">pub</span>")
  assert string.contains(html, "<span class=\"tok-kw\">let</span>")
  assert string.contains(html, "<span class=\"tok-num\">42</span>")
  assert string.contains(html, "<span class=\"tok-type\">Ok</span>")
  assert string.contains(html, "<span class=\"tok-com\">// done</span>")
}

pub fn a_hostile_program_string_stays_escaped_text_test() {
  let html = drawn("let s = \"</span><script>alert(1)</script>\"")
  assert string.contains(
    html,
    "<span class=\"tok-str\">&quot;&lt;/span&gt;&lt;script&gt;alert(1)&lt;/script&gt;&quot;</span>",
  )
  assert !string.contains(html, "<script>")
}
