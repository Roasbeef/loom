//// The source guard must recognize the pinned vendor's ECMAScript whitespace.

import gleam/json
import gleam/list
import gleam/string
import web_mermaid/controller as c

fn input(source: String) -> c.Input {
  c.input(
    json.to_string(
      json.object([
        #("source", json.string(source)),
        #("theme", json.string("dark")),
        #("revision", json.int(1)),
      ]),
    ),
  )
}

pub fn ecmascript_whitespace_cannot_hide_frontmatter_fences_test() {
  let spaces = [
    "\t", "\u{b}", "\u{c}", " ", "\u{a0}", "\u{1680}", "\u{2000}", "\u{2001}",
    "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}",
    "\u{2008}", "\u{2009}", "\u{200a}", "\u{202f}", "\u{205f}", "\u{3000}",
    "\u{feff}",
  ]
  list.each(spaces, fn(space) {
    assert input(
        space
        <> "---"
        <> space
        <> "\nconfig:\n  theme: forest\n"
        <> space
        <> "---"
        <> space
        <> "\nflowchart TD\nA-->B",
      )
      == c.Forbidden(1)
  })
}

pub fn ecmascript_line_boundaries_cannot_hide_frontmatter_test() {
  list.each(["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"], fn(newline) {
    assert input(
        "---"
        <> newline
        <> "config:"
        <> newline
        <> "  theme: forest"
        <> newline
        <> "---"
        <> newline
        <> "flowchart TD"
        <> newline
        <> "A-->B",
      )
      == c.Forbidden(1)
  })
}

pub fn click_whitespace_and_cross_line_arguments_are_refused_test() {
  list.each(
    ["\t", "\u{a0}", "\u{feff}", "\r", "\n", "\u{2028}", "\u{2029}"],
    fn(space) {
      assert input("flowchart TD\nA-->B\nclick" <> space <> "A call")
        == c.Forbidden(1)
    },
  )
  assert input("flowchart TD\nA-->B\nclick \u{301}A call") == c.Forbidden(1)
  assert input("flowchart TD\nclick\n\nA-->B") == c.Forbidden(1)
  assert input("flowchart TD\nclick")
    == c.Accepted(c.Request("flowchart TD\nclick", c.Dark, 1))
  assert input("flowchart TD\nclickable-->B")
    == c.Accepted(c.Request("flowchart TD\nclickable-->B", c.Dark, 1))
}

pub fn near_limit_many_line_source_does_not_exhaust_the_call_stack_test() {
  let source = string.repeat("\n", 31_980) <> "graph TD\nA-->B"
  assert input(source) == c.Accepted(c.Request(source, c.Dark, 1))
}
