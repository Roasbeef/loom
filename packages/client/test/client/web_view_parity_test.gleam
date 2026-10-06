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
import core/register
import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import machine/codec as machine_codec
import machine/strand
import session_view/approval
import session_view/command
import session_view/commands
import session_view/connection_event
import session_view/markdown
import session_view/model as session_model
import session_view/msg
import session_view/operator
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/step as session_step
import session_view/transcript_line.{type Line}
import tui
import tui/buffered
import tui/connection
import tui/inbound
import tui/model as tui_model
import tui/projection
import tui/tick
import tui/workspace
import web_view/component
import web_view/operator_page
import web_view/sessions

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
    label: None,
    workspace_digest: "",
    expected: snapshot.Expected("session", "epoch", "incarnation"),
    standing: component.unplaced,
    transport: component.Transport(
      connect: fn(_, _) { Nil },
      transmit: fn(wire, frame) { process.send(wire, frame) },
      shut: fn(_) { Nil },
      now: fn() { 0 },
      sessions: fn(deliver) { deliver([]) },
      activity: fn(_, _) { Nil },
      open: fn(_) { sessions.Declined(sessions.NotHeld) },
      resume: fn(_, _) { Nil },
      invite: None,
      home: None,
      rename: None,
      shareable: None,
      worktree: None,
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
  // the order the terminal draws them. A line the terminal renders as
  // Markdown is drawn from its parsed tree, so its visible text is the
  // text of that tree's leaves rather than its source.
  let html = element.to_string(component.view(page))
  let texts =
    web
    |> list.filter(fn(line) { line.text != "" })
    |> list.flat_map(visible_texts)
    |> list.map(fn(text) { element.to_string(element.text(text)) })
  assert in_order(html, texts)
  assert string.contains(html, "&lt;ordering&gt; &amp; report")
  assert string.contains(
    html,
    "<code class=\"md-code-span\">a &lt; b</code> &amp; <code class=\"md-code-span\">b &gt; c</code>",
  )
}

// The text a line shows, in order: its source for a literal row, and the
// leaves of its Markdown tree for the speakers both hosts render as
// Markdown.
fn visible_texts(line: Line) -> List(String) {
  case line.speaker {
    transcript_line.Assistant
    | transcript_line.Reasoning
    | transcript_line.ToolDetail ->
      list.flat_map(markdown.parse(line.text), block_texts)
    transcript_line.System
    | transcript_line.ToolGroup
    | transcript_line.User
    | transcript_line.ReasoningDigest
    | transcript_line.SummarizedReasoning
    | transcript_line.SummarizedAdvice
    | transcript_line.ToolCall
    | transcript_line.ToolResult
    | transcript_line.ToolPatch
    | transcript_line.ToolFailure
    | transcript_line.Failure
    | transcript_line.Spacer
    | transcript_line.SentMessage
    | transcript_line.StrandMessage
    | transcript_line.PeerMessage
    | transcript_line.ProgramRunning
    | transcript_line.ProgramFailure
    | transcript_line.ProgramSettled
    | transcript_line.ImageRow(..) -> [line.text]
  }
}

fn block_texts(block: markdown.Block) -> List(String) {
  case block {
    markdown.Paragraph(inlines:) | markdown.Heading(inlines:, ..) ->
      list.flat_map(inlines, inline_texts)
    markdown.CodeBlock(text:, ..) -> [text]
    markdown.Quote(blocks:)
    | markdown.Alert(blocks:, ..)
    | markdown.Footnote(blocks:, ..) -> list.flat_map(blocks, block_texts)
    markdown.BulletList(items:) | markdown.OrderedList(items:, ..) ->
      list.flat_map(items, list.flat_map(_, block_texts))
    markdown.Table(header:, rows:) ->
      list.flat_map([header, ..rows], fn(row) {
        list.flat_map(row, fn(cell) {
          list.flat_map(cell.inlines, inline_texts)
        })
      })
    markdown.Rule -> []
  }
}

fn inline_texts(inline: markdown.Inline) -> List(String) {
  case inline {
    markdown.Text(text:) | markdown.Code(text:) -> [text]
    markdown.Emphasis(children:)
    | markdown.Strong(children:)
    | markdown.Strikethrough(children:) -> list.flat_map(children, inline_texts)
    markdown.Link(label:, ..) -> list.flat_map(label, inline_texts)
    markdown.Image(..)
    | markdown.Task(..)
    | markdown.FootnoteRef(..)
    | markdown.Break -> []
  }
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

// The cells that list `main` as a strand: its configuration, its leaf and
// its state. A capture that lists no strand has no recipient, and the shared
// step refuses a command to it, which the page now runs its commands
// through.
fn main_cells() -> List(json.JsonValue) {
  let cell = fn(namespace, seq, value) {
    json.Object([
      #("namespace", json.String(register.ns_to_string(namespace))),
      #("key", json.String("main")),
      #("seq", json.Int(seq)),
      #("value", value),
    ])
  }
  [
    cell(
      register.StrandConfig,
      1,
      machine_codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("test", "test"),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, 2, json.Null),
    cell(
      register.StrandState,
      3,
      machine_codec.encode_strand_state(strand.StrandState(None, [])),
    ),
  ]
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
        #("cells", json.Array([escalation, ..main_cells()])),
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
  {
    let base =
      tui.new_model(connection.new_inbox(), workspace.Context("test", None))
    tui_model.Model(
      shared: session_model.Shared(
        ..base.shared,
        peer: session_model.Attached,
        stamp: msg.Stamp(now_ms: 0, transport_ms: 0),
        channel: Some(
          session_channel.replay(snapshot.Expected(
            "session",
            "epoch",
            "incarnation",
          )),
        ),
      ),
      view: tui_model.View(..base.view, transport_time_ms: fn() { 0 }),
    )
  }
}

// One step of the shared script, as each host receives it.
type Step {
  Frame(connection_event.Message)
  Tick
  Prompt(String)
  Deny(String)
}

// The terminal's tick over a model that has taken the traffic the event
// carried: the side surfaces' reads, the lane's own tick, and the shared
// step's settle against the model the event started from. These are the
// units the page's `step.update` runs for the same event, and the terminal
// calls them one at a time.
fn ticked(
  started: tui_model.Model,
  drained: tui_model.Model,
) -> tui_model.Model {
  let read =
    tui_model.run_shared(drained, session_step.service_reads)
    |> inbound.tick_channel
  tui_model.run_shared(read, session_step.settle(started.shared, _))
}

// A command the terminal's own key handlers would hand the step, settled as
// the terminal settles every event.
fn acted(model: tui_model.Model, command: msg.Command) -> tui_model.Model {
  tui_model.run_shared(model, fn(shared) {
    session_step.settle(shared, commands.act(shared, command))
  })
}

fn on_terminal(model: tui_model.Model, step: Step) -> tui_model.Model {
  case step {
    Frame(message) ->
      ticked(model, inbound.accept_connection_message(model, message))
    Tick -> ticked(model, model)
    Prompt(text) ->
      acted(
        model,
        msg.Submit(
          draft: text,
          command: command.Prompt(text),
          delivery: operator.Prompt,
        ),
      )
    Deny(id) ->
      case list.find(model.shared.approvals, fn(record) { record.id == id }) {
        Ok(record) ->
          acted(model, msg.Decide(review: record, choice: operator.Deny))
        Error(Nil) -> model
      }
  }
}

// The page reduces a frame as it arrives, in a batch of one, which is the
// terminal's receive-then-tick in one message: the frame is drained, the side
// surfaces' reads go out, and the lane ticks at the batch's reading. At the
// script's reading of zero no deadline is due, as none is for the terminal's
// step.
fn on_page(
  page: component.Model(process.Subject(String)),
  step: Step,
) -> component.Model(process.Subject(String)) {
  let messages = case step {
    Frame(message) -> [operator_page.Observed(component.Arrived([message]))]
    Tick -> [operator_page.Observed(component.Ticked)]
    Prompt(text) -> [operator_page.Submitted(text, operator.Prompt, [])]
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
    |> operator_page.update(operator_page.Observed(component.Opened(wire)))
  perform(page.1)

  // The first capture makes both hosts read the strand's notes, the
  // session's context, the advisor's pending nudges and the goal, one after
  // the other, each sent when the one before is answered. The script answers
  // them by refusal, so the lane is free for the prompt. The page then asks
  // for the session's decided approvals, request eight, which the terminal
  // does not (`mirror_decided_read`); the script answers it as well.
  let script =
    list.flatten([
      list.map(transfer(), Frame),
      [Tick],
      list.map([4, 5, 6, 7, 8], fn(id) { Frame(refusal(id)) }),
      [Prompt("inspect the tree"), Deny("esc-1"), Tick],
    ])
  let #(terminal, page, _) =
    list.fold(script, #(terminal(), page.0, Owed), fn(hosts, step) {
      let #(terminal, asked) =
        mirror_decided_read(on_terminal(hosts.0, step), hosts.2)
      let page = on_page(hosts.1, step)
      let assert Some(web_lane) = component.lane(page)
        as "the page holds a lane"
      let assert Some(terminal_lane) = terminal.shared.channel
        as "the terminal holds a lane"
      assert session_channel.state(web_lane)
        == session_channel.state(terminal_lane)
      #(terminal, page, asked)
    })

  // The two hosts offer the same approvals and draw the same lines.
  assert pending(component.pending(page)) != []
  assert pending(component.pending(page)) == pending(terminal.shared.approvals)
  assert component.lines(page) == projection.record_projection(terminal).0

  // What the page wrote is the prompt. The decision that followed it met a
  // lane with the prompt's reply outstanding, which the shared step refuses
  // for the terminal's dialog as for the page's card, so one command is out.
  let frames = drain(wire)
  let assert [prompt] =
    list.filter(frames, fn(frame) {
      string.contains(frame, "\"cmd\":\"prompt\"")
      || string.contains(frame, "\"cmd\":\"deny\"")
    })
    as "one command left the page while the prompt's reply is outstanding"
  assert string.contains(prompt, "\"cmd\":\"prompt\"")
}

// Whether the terminal has made the read the page makes for the decided
// approvals.
type Decided {
  Owed
  Asked
}

// The page reads the session's decided approvals once its lane idles after the
// first capture, as the terminal does not. So that the two lanes stay
// comparable, the terminal makes the same read at the same moment: when its
// lane can send it after a step, and once.
fn mirror_decided_read(
  model: tui_model.Model,
  asked: Decided,
) -> #(tui_model.Model, Decided) {
  case asked, model.shared.channel {
    Owed, Some(lane) ->
      case session_channel.decided(lane, now: model.shared.stamp.transport_ms) {
        Ok(lane) -> #(
          tui_model.Model(
            ..model,
            shared: session_model.hold_channel(model.shared, lane),
          ),
          Asked,
        )
        Error(_) -> #(model, Owed)
      }
    Owed, None | Asked, _ -> #(model, asked)
  }
}

// The daemon's refusal of the read sent as request `id`.
fn refusal(id: Int) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(id)
    <> ",\"event\":\"error\",\"body\":{\"code\":\"unavailable\",\"message\":\"busy\"}}",
  )
}

fn drain(wire: process.Subject(String)) -> List(String) {
  case process.receive(wire, 0) {
    Ok(frame) -> [frame, ..drain(wire)]
    Error(Nil) -> []
  }
}

// The frames a script delivers, held in the terminal's inbox as the runtime
// leaves them before a step.
fn filed(
  model: tui_model.Model,
  frames: List(connection_event.Message),
) -> tui_model.Model {
  let inbox = list.fold(frames, model.shared.inbox, buffered.push)
  tui_model.Model(..model, shared: session_model.Shared(..model.shared, inbox:))
}

// The terminal's real tick, not a copy of it. `session_step.update` is the
// shared step's composition of the units the terminal runs one at a time, and
// `tui/tick.update_tick` is the order the terminal actually runs them in.
// Nothing but a test holds the two to one order, and the copy of the
// terminal's tick in `session_view/step_test` checks the step against its own
// documentation, so a reordering inside `update_tick` fails it not at all.
// This test files a first capture into the terminal's inbox, ticks the real
// `update_tick` and then the `session_step.settle` that `tui.settle_update`
// runs after every event, ticks `session_step.update` over the record the
// terminal started from, and requires the same record. The terminal's
// projection and frame cache are left out, since they write fields the step
// has no surface for. The lane here has no socket, so no frame leaves; a
// mis-ordered read still shows in the lane's state.
//
// The capture is the order-sensitive script. The drain comes before the
// reads, so the strand's notes read leaves in the tick that drained the
// capture; a tick that serviced the reads first would send it a tick later.
pub fn the_terminals_real_tick_runs_the_shared_steps_order_test() {
  let held = filed(terminal(), transfer())
  let at = msg.Stamp(now_ms: 10, transport_ms: 10)
  let #(by_step, _) =
    session_step.update(held.shared, msg.Input(at, msg.Ticked))
  let started = session_model.Shared(..held.shared, stamp: at)
  let ticked =
    tui_model.run_shared(
      tick.update_tick(tui_model.Model(..held, shared: started)),
      session_step.settle(started, _),
    )
  let by_terminal = ticked.shared

  assert by_step.captured != None as "the capture was drained"
  assert by_terminal == by_step
}
