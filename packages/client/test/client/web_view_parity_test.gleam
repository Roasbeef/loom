//// The web view draws what the terminal draws, and decides what the
//// terminal decides. One fixed capture goes into the terminal through its
//// own reducer and into the web component through its own update; the
//// transcript lines each produces are equal, and the component's HTML holds
//// every one of them, in order. And one script of frames and operator
//// commands, run through both hosts, leaves the two lanes in equal engine
//// states with the same approvals on offer (ADR-014, "Verification
//// required"; protocol-change/051, the operator addendum).

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import session_view/approval
import session_view/connection_event
import session_view/operator
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript_line.{type Line}
import tui
import tui/connection
import tui/inbound
import tui/model as tui_model
import tui/msg
import tui/projection
import tui/workspace
import web_view/component
import web_view/operator_page

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

fn start() -> component.Start(process.Subject(String)) {
  component.Start(
    session_id: "session",
    expected: snapshot.Expected("session", "epoch", "incarnation"),
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: fn(wire, frame) { process.send(wire, frame) },
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

fn reply(id: Int, event: String, body: json.JsonValue) {
  connection_event.Incoming(
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(id)),
        #("event", json.String(event)),
        #("body", body),
      ]),
    ),
  )
}

// One credited transfer for an operator's attachment, whose metadata holds
// one pending escalation with its whole authority captured.
fn transfer() -> List(connection_event.Message) {
  let escalation =
    json.Object([
      #("namespace", json.String("fact.custom")),
      #("key", json.String("escalation/esc-1")),
      #("seq", json.Int(7)),
      #(
        "value",
        json.Object([
          #("id", json.String("esc-1")),
          #("status", json.String("pending")),
          #("tool", json.String("fs_write")),
          #("preview", json.String("write the file")),
          #("action", json.String("captured-action")),
          #("origin", json.Null),
          #(
            "denial",
            json.Object([
              #(
                "wanted",
                json.Array([
                  json.Object([
                    #("grant", json.String("writable_root")),
                    #("path", json.String("/shared/output")),
                  ]),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])
  let data =
    json.to_string(
      json.Object([
        #("cells", json.Array([escalation])),
        #("message_count", json.Int(0)),
        #("usage", codec.encode_usage(usage())),
        #(
          "host_run_settings",
          json.Object([
            #("queue_mode", json.String("one_at_a_time")),
            #("tool_execution", json.String("parallel")),
            #("origin", json.Null),
          ]),
        ),
        #("peers", json.Array([])),
      ]),
    )
  [
    reply(
      1,
      "snapshot_begin",
      json.Object([
        #("snapshot_id", json.String("1:1")),
        #("session_id", json.String("session")),
        #("epoch", json.String("epoch")),
        #("incarnation", json.String("incarnation")),
        #("connection_id", json.String("connection")),
        #(
          "origin",
          json.Object([
            #("principal", json.String("alice")),
            #("name", json.String("Alice")),
          ]),
        ),
        #("role", json.String("operator")),
        #("next_seq", json.Int(10)),
        #("oldest_seq", json.Null),
        #("window", json.String("recent")),
        #("complete_history", json.Bool(False)),
        #("record_bytes_limit", json.Int(snapshot.record_limit)),
        #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
      ]),
    ),
    reply(
      2,
      "snapshot_chunk",
      json.Object([
        #("snapshot_id", json.String("1:1")),
        #("index", json.Int(0)),
        #("kind", json.String("metadata")),
        #("record_id", json.String("metadata")),
        #("record_seq", json.Null),
        #("total_bytes", json.Int(string.byte_size(data))),
        #("offset", json.Int(0)),
        #(
          "data",
          json.String(bit_array.base64_encode(bit_array.from_string(data), True)),
        ),
      ]),
    ),
    reply(
      3,
      "snapshot_end",
      json.Object([
        #("snapshot_id", json.String("1:1")),
        #("index", json.Int(1)),
        #("next_seq", json.Int(10)),
        #("more_after", json.Null),
      ]),
    ),
  ]
}

// The terminal as it stands once attached: an attached peer whose lane has
// no socket, so nothing it decides is written anywhere and what it keeps is
// exactly the engine's state. Its clock reads zero, as the page's does.
fn terminal() -> tui_model.Model {
  tui_model.Model(
    ..tui.new_model(connection.new_inbox(), workspace.Context("test", None)),
    peer: tui_model.Attached,
    transport_time_ms: fn() { 0 },
    stamp: msg.Stamp(now_ms: 0, transport_ms: 0, wall_ms: 0),
    channel: Some(
      session_channel.replay(snapshot.Expected(
        "session",
        "epoch",
        "incarnation",
      )),
    ),
  )
}

// One step of the shared script, as each host receives it.
type Step {
  Frame(connection_event.Message)
  Tick
  Prompt(String)
  Deny(String)
}

fn on_terminal(model: tui_model.Model, step: Step) -> tui_model.Model {
  case step {
    Frame(message) -> inbound.accept_connection_message(model, message)
    Tick -> inbound.tick_channel(model)
    Prompt(text) -> inbound.send_prompt_to(model, "main", text)
    Deny(id) -> inbound.decide(model, id, operator.Deny)
  }
}

// The page takes a frame at arrival and reduces it at the next tick, so a
// frame step is filed and then ticked, which is the terminal's
// receive-then-apply in the page's two messages.
fn on_page(
  page: component.Model(process.Subject(String)),
  step: Step,
) -> component.Model(process.Subject(String)) {
  let messages = case step {
    Frame(message) -> [
      operator_page.Observed(component.Arrived(message, 0)),
      operator_page.Observed(component.Ticked(0)),
    ]
    Tick -> [operator_page.Observed(component.Ticked(0))]
    Prompt(text) -> [operator_page.Submitted(text, operator.Prompt)]
    Deny(id) ->
      case list.find(component.pending(page), fn(record) { record.id == id }) {
        Ok(record) -> [operator_page.Decided(id, record.seq, component.Deny)]
        Error(Nil) -> []
      }
  }
  list.fold(messages, page, fn(page, message) {
    let #(page, effects) = operator_page.update(page, message)
    perform(effects)
    page
  })
}

// Performs a page's effects as Lustre would, so what it transmits reaches
// the test's wire. Nothing the pages dispatch from an effect is fed back:
// they dispatch only from their subscriptions, which this test drives.
fn perform(effects: effect.Effect(message)) -> Nil {
  effect.perform(
    effects,
    fn(_) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { dynamic.nil() },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
}

fn pending(approvals: List(approval.Review)) -> List(approval.Review) {
  list.filter(approvals, fn(record) { record.status == approval.Pending })
}

pub fn one_script_leaves_both_hosts_in_one_engine_state_test() {
  let wire = process.new_subject()
  let page =
    component.new(start())
    |> operator_page.update(operator_page.Observed(component.Opened(wire, 0)))
  perform(page.1)
  let script =
    list.flatten([
      list.map(transfer(), Frame),
      [Tick, Prompt("inspect the tree"), Deny("esc-1"), Tick],
    ])
  let #(terminal, page) =
    list.fold(script, #(terminal(), page.0), fn(hosts, step) {
      let terminal = on_terminal(hosts.0, step)
      let page = on_page(hosts.1, step)
      let assert Some(web_lane) = component.lane(page)
        as "the page holds a lane"
      let assert Some(terminal_lane) = terminal.channel
        as "the terminal holds a lane"
      assert session_channel.state(web_lane)
        == session_channel.state(terminal_lane)
      #(terminal, page)
    })

  // The two hosts offer the same approvals and draw the same lines.
  assert pending(component.pending(page)) != []
  assert pending(component.pending(page)) == pending(terminal.approvals)
  assert component.lines(page) == projection.record_projection(terminal).0

  // What the page wrote is the prompt, then the decision the lane queued
  // behind it once the prompt's reply is outstanding: one command out.
  let frames = drain(wire)
  let assert [prompt] =
    list.filter(frames, fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
    as "one command left the page while the prompt's reply is outstanding"
  assert string.contains(prompt, "\"cmd\":\"prompt\"")
}

fn drain(wire: process.Subject(String)) -> List(String) {
  case process.receive(wire, 0) {
    Ok(frame) -> [frame, ..drain(wire)]
    Error(Nil) -> []
  }
}
