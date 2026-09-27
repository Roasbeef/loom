//// The web view draws what the terminal draws. One fixed capture goes into
//// the terminal through its own reducer and into the web component through
//// its own update; the transcript lines each produces are equal, and the
//// component's HTML holds every one of them, in order (ADR-014,
//// "Verification required").

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/element
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript_line.{type Line}
import tui
import tui/connection
import tui/inbound
import tui/projection
import tui/workspace
import web_view/component

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

fn user(seq: Int, parent: Option(Int), text: String) -> snapshot.Item {
  snapshot.Loaded(
    entry.MessageEntry(
      id(seq),
      option.map(parent, id),
      seq,
      1000,
      message.UserMessage([message.UserText(text, None)], 1000, None),
      False,
    ),
    100,
  )
}

fn assistant(seq: Int, parent: Int, text: String) -> snapshot.Item {
  snapshot.Loaded(
    entry.MessageEntry(
      id(seq),
      Some(id(parent)),
      seq,
      1000,
      message.AssistantMessage(
        [message.AssistantText(text, None)],
        "test",
        "test",
        "test",
        None,
        None,
        None,
        usage(),
        message.Stop,
        None,
        None,
        None,
        None,
        1000,
      ),
      False,
    ),
    100,
  )
}

// A short conversation on main, newest first as a capture holds it, with
// text that HTML must escape.
fn capture() -> #(snapshot.Captured, snapshot_view.View) {
  let items = [
    assistant(4, 3, "Done: `a < b` & `b > c` hold."),
    user(3, Some(2), "Check the <ordering> & report."),
    assistant(2, 1, "Hello. I read the repository."),
    user(1, None, "Hi, what is here?"),
  ]
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("session", "epoch", "incarnation"),
        "page",
        message.Origin("principal-Alice", "Alice"),
        snapshot.Observer,
      ),
      5,
      json.Null,
      snapshot.Window(items, 400, None),
      None,
    )
  let view =
    snapshot_view.View(
      [],
      dict.from_list([#("main", Some(id(4)))]),
      dict.new(),
      dict.new(),
      usage(),
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      [],
      None,
      None,
      None,
    )
  #(cut, view)
}

fn start() -> component.Start(Nil) {
  component.Start(
    session_id: "session",
    expected: snapshot.Expected("session", "epoch", "incarnation"),
    transport: component.Transport(
      connect: fn(_) { Ok(Nil) },
      transmit: fn(_, _) { Nil },
      shut: fn(_) { Nil },
      now: fn() { 0 },
    ),
  )
}

fn terminal_lines(update: session_channel.Update) -> List(Line) {
  let model =
    tui.new_model(connection.new_inbox(), workspace.Context("test", None))
    |> inbound.apply_channel_update(update)
  projection.record_projection(model).0
}

// Whether every needle occurs in `haystack`, each after the one before.
fn in_order(haystack: String, needles: List(String)) -> Bool {
  case needles {
    [] -> True
    [needle, ..rest] ->
      case string.split_once(haystack, needle) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}

pub fn the_web_view_draws_the_terminals_lines_test() {
  let #(cut, view) = capture()
  let update = session_channel.Captured(cut, view, session_channel.Refreshed)

  let terminal = terminal_lines(update)
  let page = component.new(start()) |> component.apply([update])
  let web = component.lines(page)

  assert web != []
  assert web == terminal

  // The page holds each line's text, escaped as Lustre escapes text, in
  // the order the terminal draws them.
  let html = element.to_string(component.view(page))
  let texts =
    web
    |> list.filter(fn(line) { line.text != "" })
    |> list.map(fn(line) { element.to_string(element.text(line.text)) })
  assert in_order(html, texts)
  assert string.contains(html, "&lt;ordering&gt; &amp; report")
}
