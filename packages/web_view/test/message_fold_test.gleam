//// A shortened message opens in place to its whole text (protocol-change/070,
//// the addendum on messages).
////
//// A long paste is drawn as its opening and a token estimate. A button after
//// it opens the text the page already holds, and the text is drawn only while
//// the message is open, as text nodes. The terminal's `Ctrl+G` is the same
//// act for every collapsed row at once.

import gleam/list
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/view/expansion

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

// A paste whose tail is markup, so the whole text shows how it is drawn.
fn paste() -> String {
  "first line of the paste\n"
  <> string.repeat("filler words to make it long\n", 120)
  <> "the <b>tail</b> of it"
}

fn page(text: String) {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.prompted(text)])
}

fn drawn(model) -> String {
  element.to_string(component.view(model))
}

fn open(model) {
  component.update(model, component.MessageToggled("1.0")).0
}

// Shortened is the default: the row says roughly how much there is, the tail
// is not in the page, and the button offers the rest.
pub fn a_long_paste_is_shortened_with_a_button_after_it_test() {
  let html = drawn(page(paste()))
  assert string.contains(html, "first line of the paste")
  assert string.contains(html, " tokens]")
  assert string.contains(html, ">Show all</button>")
  assert !string.contains(html, "of it")
  assert !string.contains(html, "Ctrl+G")
}

// Opening draws the whole text, escaped, and the button offers to shorten it
// again; a second press returns the page to the shortened form.
pub fn opening_draws_the_whole_text_as_text_and_closing_undoes_it_test() {
  let opened = drawn(open(page(paste())))
  assert string.contains(opened, "the &lt;b&gt;tail&lt;/b&gt; of it")
  assert !string.contains(opened, "<b>tail")
  assert string.contains(opened, ">Show less</button>")
  assert string.contains(opened, "aria-expanded=\"true\"")

  let closed = drawn(open(open(page(paste()))))
  assert closed == drawn(page(paste()))
}

// A message that was not shortened has no button, and a key that names no
// shortened message changes nothing.
pub fn only_a_shortened_message_can_be_opened_test() {
  let short = page("a short question")
  assert !string.contains(drawn(short), "message-toggle")
  assert drawn(open(short)) == drawn(short)

  let long = page(paste())
  let forged = component.update(long, component.MessageToggled("9.9")).0
  assert drawn(forged) == drawn(long)
}

// The operator's page draws the same control.
pub fn the_operator_page_opens_a_message_too_test() {
  let model = page(paste())
  assert string.contains(
    element.to_string(operator_page.view(model)),
    ">Show all</button>",
  )
  assert string.contains(
    element.to_string(operator_page.view(open(model))),
    "the &lt;b&gt;tail&lt;/b&gt; of it",
  )
}

// The button's click is at a path the observer's socket admits, in both
// states, so the two cannot drift apart.
pub fn the_button_is_at_the_admitted_path_test() {
  let model = page(paste())
  list.each([model, open(model)], fn(shown) {
    let clicks =
      list.filter(every_handler(component.view(shown)), fn(key) {
        case string.split_once(key, "\n") {
          Ok(#(path, "click")) -> component.message_click(path)
          Ok(_) | Error(_) -> False
        }
      })
    assert list.length(clicks) == 1
  })
}

pub fn only_a_messages_own_paths_are_admitted_test() {
  assert component.message_click("0\t2\t1\t1\t1.0\t1\t0\t0\t1")
  assert component.message_click("0\t2\t1\t1\t1.0\t1\t0\t1\t0\t1")
  assert !component.message_click("0\t2\t1\t1\twork:1.0\t1\t0\t0\t1")
  assert !component.message_click("0\t2\t1\t1\t1.0\t1\t0\t0")
  assert !component.message_click("0\t2\t1\t1\t01.0\t1\t0\t0\t1")
  assert !component.message_click("0\t2\t1\t1\t1.0\t1\t0\t0\t1\t0")
}

// A strand's long message is the same case as a long paste, drawn on a card
// of its own: the card shows the opening and the estimate, and opens in
// place to the whole text, which the page held from the start.
fn sibling(text: String) -> String {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.sibling_saying(text)])
  |> component.view
  |> element.to_string
}

pub fn a_long_strand_message_opens_in_place_to_its_whole_text_test() {
  let html = sibling(paste())
  assert string.contains(html, "sibling-card")
  assert string.contains(html, "first line of the paste")
  assert string.contains(html, " tokens]")
  assert string.contains(html, "<loom-expand")
  assert !string.contains(html, "Ctrl+G")

  // The whole text is in the card's body, escaped, as text nodes.
  assert string.contains(html, "the &lt;b&gt;tail&lt;/b&gt; of it")
  assert !string.contains(html, "<b>tail")
}

pub fn a_short_strand_message_is_drawn_whole_without_an_opener_test() {
  let html = sibling("found <two> issues")
  assert string.contains(html, "found &lt;two&gt; issues")
  assert !string.contains(html, "<loom-expand")
  assert !string.contains(html, " tokens]")
}

// The opened body is cut to the page's bound for one expanded row, and the
// whole of it sits inside the fold, after the head, not beside it.
pub fn a_very_long_strand_message_is_cut_inside_the_fold_test() {
  let html = sibling(string.repeat("x\n", 5000) <> "the end")
  assert string.contains(html, expansion.notice())
  assert !string.contains(html, "the end")

  let assert Ok(#(_, body)) = string.split_once(html, "slot=\"body\"")
    as "the card has a fold body"
  assert string.contains(body, "x")
}

pub fn the_tail_of_a_long_strand_message_is_in_the_fold_body_test() {
  let assert Ok(#(head, body)) =
    string.split_once(sibling(paste()), "slot=\"body\"")
    as "the card has a fold body"
  assert !string.contains(head, "of it")
  assert string.contains(body, "the &lt;b&gt;tail&lt;/b&gt; of it")
}

// A message whose opening is a code fence parses to nothing as one line of
// Markdown; the fold still says what it opens.
pub fn a_strand_message_that_opens_with_a_fence_still_has_a_head_test() {
  let html = sibling("```gleam\n" <> string.repeat("let x = 1\n", 120) <> "```")
  let assert Ok(#(head, _)) = string.split_once(html, "slot=\"body\"")
    as "the card has a fold body"
  assert string.contains(head, "gleam")
}
