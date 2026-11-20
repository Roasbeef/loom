//// The top bar's location and status: how a workspace path is shortened,
//// when the location is left out, which class the status pill takes, and what
//// the `live` mark, the pill that counts and the audience's chip draw.
////
//// These tests pin that the workspace is drawn as its last folder with the
//// whole path in a title, that the bar never repeats the session's name as its
//// location, that the pill's class follows the connection's tone, and that the
//// figures the bar once carried are not here: they are the stream's strip's
//// (`figures_test`).

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import web_view/view/heading
import web_view/view/stream_head

fn drawn(
  name: option.Option(String),
  workspace: option.Option(String),
  tone: heading.Tone,
) -> String {
  modelled(name, workspace, None, tone)
}

fn modelled(
  name: option.Option(String),
  workspace: option.Option(String),
  model: option.Option(String),
  tone: heading.Tone,
) -> String {
  heading.view(
    session_id: "0192ab34cd",
    home: element.none(),
    name:,
    workspace:,
    model:,
    status: "connected",
    tone:,
    notice: element.none(),
    doing: stream_head.Running,
    needing: 0,
    role: "owner · operating",
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

// The location is the workspace's last folder and then the name, as two spans,
// with the shortened whole path as the first one's title.
pub fn the_location_is_the_folder_and_then_the_name_test() {
  let bar =
    drawn(
      Some("ws · main"),
      Some("/Users/ada/loom-drives/webrev/project"),
      heading.Live,
    )
  assert string.contains(
    bar,
    "<span class=\"workspace\" title=\"~/loom-drives/webrev/project\">project</span>",
  )
  assert string.contains(bar, ">ws · main</h1>")
}

// A location that is only the name's first word is left out, and so is an
// unknown one.
pub fn a_location_that_repeats_the_name_is_left_out_test() {
  let repeated = drawn(Some("ws · main"), Some("/src/ws"), heading.Live)
  assert !string.contains(repeated, "class=\"workspace\"")
  assert string.contains(repeated, ">ws · main</h1>")

  let unknown = drawn(Some("docs"), None, heading.Live)
  assert !string.contains(unknown, "class=\"workspace\"")
}

// The pill's class follows the tone and never the words.
pub fn the_pill_class_follows_the_tone_test() {
  assert heading.tone_class(heading.Live) == "online"
  assert heading.tone_class(heading.Pending) == "pending"
  assert heading.tone_class(heading.Closed) == "ended"

  let live = drawn(None, None, heading.Live)
  assert string.contains(live, "class=\"status pill online\"")
  let pending = drawn(None, None, heading.Pending)
  assert string.contains(pending, "class=\"status pill pending\"")
  let ended = drawn(None, None, heading.Closed)
  assert string.contains(ended, "class=\"status pill ended\"")
}

// The `live` mark is drawn while the page is connected, with a dot that takes
// its class from what the session is doing, and is left out otherwise, so the
// mark and the status pill never both speak.
pub fn the_live_mark_follows_the_connection_test() {
  let live = drawn(Some("docs"), None, heading.Live)
  assert string.contains(
    live,
    "<span class=\"live-mark\"><span class=\"stream-dot stream-run\"></span>live</span>",
  )

  list.each([heading.Pending, heading.Closed], fn(tone) {
    assert !string.contains(drawn(Some("docs"), None, tone), "live-mark")
  })
}

// The pill that counts what needs the owner is drawn only above none, and the
// audience's chip is always drawn, both after the hidden title element so no
// child before it moves.
pub fn the_pill_and_the_chip_follow_the_title_element_test() {
  let bar =
    heading.view(
      session_id: "0192ab34cd",
      home: element.none(),
      name: Some("docs"),
      workspace: None,
      model: None,
      status: "connected",
      tone: heading.Live,
      notice: element.none(),
      doing: stream_head.Waiting,
      needing: 4,
      role: "owner · operating",
    )
    |> element.to_string

  assert string.contains(
    bar,
    "<loom-title hidden></loom-title><span class=\"need-pill\">4 need you</span>"
      <> "<span class=\"role-chip\">owner · operating</span></header>",
  )
  assert string.contains(bar, "stream-dot stream-wait")

  let none = drawn(Some("docs"), None, heading.Live)
  assert !string.contains(none, "need-pill")
  assert string.contains(
    none,
    "<span class=\"role-chip\">owner · operating</span>",
  )
}

// The tab's title is set by `<loom-title>` from the name the bar draws. The
// element is hidden, empty and has no attribute that could carry a name, so a
// hostile session name reaches the page only as the heading's escaped text and
// its inert `title` attribute.
pub fn the_title_element_is_empty_test() {
  let hostile = "</title><script>alert(1)</script>"
  let bar = drawn(Some(hostile), None, heading.Live)

  assert string.contains(bar, "<loom-title hidden></loom-title>")
  assert !string.contains(bar, "<script>")
  assert !string.contains(bar, "</title><")
  assert string.contains(
    bar,
    "&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;",
  )
}

// The main strand's model is drawn beside the name, in a wrapper that holds the
// bar's fourth child, so the `h1` keeps only the name (`<loom-title>` reads the
// tab's title from it) and every child after the wrapper keeps its place. The
// name of the model is a text node, and the upstream identifier is not drawn.
pub fn the_main_strands_model_sits_beside_the_name_test() {
  let bar = modelled(Some("docs"), None, Some("baseten-glm-5-3"), heading.Live)
  assert string.contains(
    bar,
    "<span class=\"session-title\"><h1 title=\"0192ab34cd\">docs</h1>"
      <> "<span class=\"session-model\" title=\"Model the main strand runs on\">"
      <> "baseten-glm-5-3</span>",
  )
}

// A model name is the owner's catalogue entry, but it is still drawn only as
// text: markup in it is escaped.
pub fn a_model_name_is_drawn_as_text_test() {
  let bar = modelled(None, None, Some("<b>x</b>"), heading.Live)
  assert string.contains(bar, ">&lt;b&gt;x&lt;/b&gt;</span>")
  assert !string.contains(bar, "<b>x")
}

// While the capture holds no model, or an empty name, the wrapper is still
// drawn and holds the name, so no later child moves.
pub fn an_unknown_model_draws_nothing_but_the_name_test() {
  list.each([None, Some("")], fn(model) {
    let bar = modelled(Some("docs"), None, model, heading.Pending)
    assert !string.contains(bar, "session-model")
  })

  let bar = modelled(Some("docs"), None, None, heading.Pending)
  assert string.contains(
    bar,
    "<span class=\"session-title\"><h1 title=\"0192ab34cd\">docs</h1></span>",
  )
}

pub fn a_whitespace_only_name_falls_back_to_the_id_test() {
  assert heading.session_name("0192ab34cd", Some("  \t")) == "Session 0192ab34"
  assert heading.session_name("0192ab34cd", Some("")) == "Session 0192ab34"
  assert heading.session_name("0192ab34cd", None) == "Session 0192ab34"
  assert heading.session_name("0192ab34cd", Some(" docs ")) == " docs "
}
