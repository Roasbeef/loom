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
