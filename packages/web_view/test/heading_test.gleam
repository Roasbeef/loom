//// The top bar's location and status: how a workspace path is shortened,
//// when the location is left out, and which class the status pill takes.
////
//// These tests pin that the path is drawn whole with the home directory
//// written as `~`, that the bar never repeats the session's name as its
//// location, that the pill's class follows the connection's tone, and that
//// the cost figure carries no `session` prefix.

import gleam/option.{None, Some}
import gleam/string
import lustre/element
import web_view/view/heading

fn drawn(
  name: option.Option(String),
  workspace: option.Option(String),
  tone: heading.Tone,
  cost: String,
) -> String {
  heading.view(
    session_id: "0192ab34cd",
    name:,
    workspace:,
    status: "connected",
    tone:,
    context: "ctx ~2%",
    cost:,
    notice: element.none(),
  )
  |> element.to_string
}

// The owner's home directory is written `~` on both home roots, a path
// outside it is left as it is, and the home directory itself is `~`.
pub fn a_path_under_the_home_directory_is_shortened_test() {
  assert heading.shorten_path("/Users/ada/loom-drives/webrev/ws")
    == "~/loom-drives/webrev/ws"
  assert heading.shorten_path("/home/ada/src/loom") == "~/src/loom"
  assert heading.shorten_path("/home/ada") == "~"
  assert heading.shorten_path("/srv/loom") == "/srv/loom"
  assert heading.shorten_path("/Users") == "/Users"
  assert heading.shorten_path("/home/me/src/loom/") == "~/src/loom"
}

// The location is the shortened path and then the name, as two spans, with
// the whole path as the first one's title.
pub fn the_location_is_the_path_and_then_the_name_test() {
  let bar =
    drawn(
      Some("ws · main"),
      Some("/Users/ada/loom-drives/webrev/ws"),
      heading.Live,
      "est —",
    )
  assert string.contains(
    bar,
    "<span class=\"workspace\" title=\"/Users/ada/loom-drives/webrev/ws\">~/loom-drives/webrev/ws</span>",
  )
  assert string.contains(bar, ">ws · main</h1>")
}

// A location that is only the name's first word is left out, and so is an
// unknown one.
pub fn a_location_that_repeats_the_name_is_left_out_test() {
  let repeated = drawn(Some("ws · main"), Some("ws"), heading.Live, "est —")
  assert !string.contains(repeated, "class=\"workspace\"")
  assert string.contains(repeated, ">ws · main</h1>")

  let unknown = drawn(Some("docs"), None, heading.Live, "est —")
  assert !string.contains(unknown, "class=\"workspace\"")
}

// The pill's class follows the tone and never the words.
pub fn the_pill_class_follows_the_tone_test() {
  assert heading.tone_class(heading.Live) == "online"
  assert heading.tone_class(heading.Pending) == "pending"
  assert heading.tone_class(heading.Closed) == "ended"

  let live = drawn(None, None, heading.Live, "est —")
  assert string.contains(live, "class=\"status pill online\"")
  let pending = drawn(None, None, heading.Pending, "est —")
  assert string.contains(pending, "class=\"status pill pending\"")
  let ended = drawn(None, None, heading.Closed, "est —")
  assert string.contains(ended, "class=\"status pill ended\"")
}

// The figures are a word and an emphasised number, and the cost no longer
// says `session`, which read as `session est $0.00`.
pub fn the_figures_emphasise_the_number_test() {
  let bar = drawn(None, None, heading.Live, "est $0.04")
  assert string.contains(bar, "ctx <span class=\"num\">~2%</span>")
  assert string.contains(bar, "est <span class=\"num\">$0.04</span>")
  assert !string.contains(bar, "session est")

  let unpriced = drawn(None, None, heading.Live, "est —")
  assert string.contains(unpriced, "est <span class=\"num\">—</span>")
  assert string.contains(unpriced, "title=\"No priced usage yet\"")
  assert string.contains(
    bar,
    "title=\"Estimated context use of the strand shown\"",
  )
}
