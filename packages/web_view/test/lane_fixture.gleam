//// One capture that holds every piece the lane draws: a person's prompt,
//// a turn of work that spawns a reviewer, edits two files and waits on the
//// reviewer's result, the answer, a message from another session, and a
//// delivered advisor nudge; and three strands besides `main`: the reviewer,
//// a second working agent, and the advisor.
////
//// Every string the session could have written holds markup, so a test that
//// renders the page can check it arrives only as escaped text: the child's
//// name, the spawn's purpose, the reviewer's report, the step's path, the
//// peer's message and the nudge.

import core/clock
import core/entry
import core/glance
import core/ids
import core/json
import core/message
import core/register
import core/todo_list
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import page_fixture
import session_view/composer
import session_view/connection_event
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/strand_framing
import session_view/transcript_lines
import session_view/turns
import web_view/component

/// The reviewer's minted strand name; its slug holds markup.
pub const child = "sub:main/<b>review-1a2b3c"

/// A second working agent, listed after the reviewer.
pub const tester = "sub:main/tests-4d5e6f"

/// An operation identity in the daemon's own form, so the capture's
/// metadata cells for it decode.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.op(1)
/// ```
pub fn op(n: Int) -> String {
  ids.op_id_to_string(ids.mint_op(ids.generator(clock.fixed(n), n)).0)
}

/// The reviewer's running operation.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.review_op()
/// ```
pub fn review_op() -> String {
  op(1)
}

/// The tester's running operation.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.tests_op()
/// ```
pub fn tests_op() -> String {
  op(2)
}

/// `main`'s running operation, when a test runs it.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.main_op()
/// ```
pub fn main_op() -> String {
  op(3)
}

/// The Unix millisecond instant every fixture operation started at: a
/// realistic one, in September 2026.
pub const started_at = 1_790_000_000_000

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

/// The identity of the record with this sequence, as the lineage read names it.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.entry_text(300)
/// ```
pub fn entry_text(seq: Int) -> String {
  ids.entry_id_to_string(id(seq))
}

fn item(seq: Int, at: Int, body: message.AgentMessage) -> snapshot.Item {
  let parent = case seq {
    1 -> None
    _ -> Some(id(seq - 1))
  }
  snapshot.Loaded(
    entry.MessageEntry(id(seq), parent, seq, at, body, False),
    100,
  )
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

fn said(text: String, origin: Option(message.Origin)) -> message.AgentMessage {
  message.UserMessage([message.UserText(text, None)], 0, origin)
}

fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content,
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
    0,
  )
}

fn call(id: String, name: String, arguments: json.JsonValue) {
  message.AssistantToolCall(message.ToolCall(id, name, arguments, None, None))
}

fn result(
  id: String,
  name: String,
  details: json.JsonValue,
  at: Int,
) -> message.AgentMessage {
  message.ToolResultMessage(
    id,
    name,
    [message.ToolResultText("ok", None)],
    Some(details),
    None,
    None,
    False,
    at,
  )
}

/// The records of `main`, oldest first: ten entries, the last a delivered
/// nudge.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.items()
/// ```
pub fn items() -> List(snapshot.Item) {
  [
    item(
      1,
      10_000,
      said("review the <patch> & report", Some(message.Origin("p", "Alice"))),
    ),
    item(
      2,
      11_000,
      assistant([
        message.AssistantThinking("plan the review", None, False),
        call(
          "c1",
          "agent_spawn",
          json.Object([#("purpose", json.String("review <the> patch"))]),
        ),
        call(
          "c2",
          "fs_edit",
          json.Object([#("path", json.String("src/<a>.gleam"))]),
        ),
        call("c3", "fs_write", json.Object([#("path", json.String("b.gleam"))])),
      ]),
    ),
    item(
      3,
      12_000,
      result(
        "c1",
        "agent_spawn",
        json.Object([#("strand", json.String(child))]),
        12_000,
      ),
    ),
    item(4, 13_000, result("c2", "fs_edit", json.Object([]), 13_000)),
    item(5, 14_000, result("c3", "fs_write", json.Object([]), 14_000)),
    item(
      6,
      15_000,
      assistant([
        call(
          "c4",
          "agent_wait",
          json.Object([#("handles", json.Array([json.String("h")]))]),
        ),
      ]),
    ),
    item(
      7,
      40_000,
      result(
        "c4",
        "agent_wait",
        json.Object([
          #(
            "results",
            json.Array([
              json.Object([
                #("strand", json.String(child)),
                #("state", json.String("ready")),
                #("outcome", json.String("completed")),
                #("report", json.String("looks <fine> & tidy")),
              ]),
            ]),
          ),
        ]),
        40_000,
      ),
    ),
    item(
      8,
      58_000,
      assistant([message.AssistantText("Done: two files.", None)]),
    ),
    item(
      9,
      60_000,
      said(
        "R8 census is <14> & rising",
        Some(message.PeerOrigin("lint-census", "main")),
      ),
    ),
    item(
      10,
      61_000,
      said(
        transcript_lines.nudges_header
          <> "\n```"
          <> transcript_lines.nudges_fence
          <> "\n- Confirm the <sweep> excludes generated SQL.\n```",
        None,
      ),
    ),
  ]
}

/// A capture of the first `count` of `items`, with `main` running under
/// `operation` when one is given, and the reviewer and the tester running.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.captured(10, None)
/// ```
pub fn captured(
  count: Int,
  operation: Option(String),
) -> session_channel.Update {
  captured_with(count, operation, [#(child, review_op()), #(tester, tests_op())])
}

/// The metadata cell of a pending escalation on `strand` under its operation
/// `op`: the evidence `agent_view` requires before it says a strand needs
/// input. Pass it as `captured_cells`'s `extra`.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.pending_approval("main", lane_fixture.main_op())
/// ```
pub fn pending_approval(strand: String, op: String) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.FactCustom,
    "escalation/esc-1",
    7,
    json.Object([
      #("id", json.String("esc-1")),
      #("status", json.String("pending")),
      #("tool", json.String("fs_write")),
      #("preview", json.String("write the file")),
      #("action", json.String("captured-action")),
      #("origin", json.Null),
      #(
        "scope",
        json.Object([
          #("strand", json.String(strand)),
          #("operation", json.String(op)),
        ]),
      ),
    ]),
  )
}

/// A capture of the first `count` of `items`, with `main` running under
/// `operation` when one is given and each of `running` running its
/// operation. A strand not running is idle.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.captured_with(10, None, [#(lane_fixture.child, lane_fixture.review_op())])
/// ```
pub fn captured_with(
  count: Int,
  operation: Option(String),
  running: List(#(String, String)),
) -> session_channel.Update {
  captured_cells(count, operation, running, [])
}

/// `captured_with`, with `extra` cells in the capture's metadata beside the
/// operations' own, such as a pending escalation.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.captured_cells(10, None, [], [])
/// ```
pub fn captured_cells(
  count: Int,
  operation: Option(String),
  running: List(#(String, String)),
  extra: List(snapshot_view.Cell),
) -> session_channel.Update {
  capture_of(list.take(items(), count), operation, running, extra)
}

/// A capture of `main` holding a prompt and then one `todo` call and result
/// per board, so the newest of `boards` is the strand's board, with each of
/// `running` running its operation: the page has a board to draw and, when a
/// reviewer runs, a band.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.planned([todo_list.empty()], [])
/// ```
pub fn planned(
  boards: List(todo_list.Board),
  running: List(#(String, String)),
) -> session_channel.Update {
  let calls =
    list.index_map(boards, fn(board, index) {
      let call_id = "plan-" <> int.to_string(index)
      let details = json.Object([#("todo", todo_list.encode(board))])
      let seq = 2 + index * 2
      [
        item(
          seq,
          11_000 + seq,
          assistant([call(call_id, "todo", json.Object([]))]),
        ),
        item(seq + 1, 11_000 + seq + 1, result(call_id, "todo", details, 0)),
      ]
    })
  capture_of(
    [item(1, 10_000, said("plan it", None)), ..list.flatten(calls)],
    None,
    running,
    [],
  )
}

/// A capture of `main` holding one prompt and then one assistant answer per
/// text, with nothing running: the rows the Markdown tests draw.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.answered(["**bold**"])
/// ```
pub fn answered(texts: List(String)) -> session_channel.Update {
  let answers =
    list.index_map(texts, fn(text, index) {
      item(
        index + 2,
        11_000 + index,
        assistant([message.AssistantText(text, None)]),
      )
    })
  capture_of([item(1, 10_000, said("go", None)), ..answers], None, [], [])
}

/// The bytes of the smallest thing `pasted_image.media_type` takes for a PNG,
/// base64 encoded: an image the page will draw.
pub const png = "iVBORw0KGgo="

/// Text an SVG file starts with, base64 encoded: what a session that declared
/// `image/svg+xml` would hold. The page must not draw it.
pub const svg = "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPg=="

/// A capture of `main` holding a prompt that carries three images (a PNG, an
/// image declared SVG and one declared PNG whose bytes are not), a call to
/// `read` whose result is a WebP, and an answer. The WebP's bytes are
/// `RIFF....WEBP`, so a server would answer with them.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.pictured()
/// ```
pub fn pictured() -> session_channel.Update {
  let webp =
    bit_array.base64_encode(
      <<"RIFF":utf8, 0:32, "WEBP":utf8, "VP8 ":utf8>>,
      True,
    )
  capture_of(
    [
      item(
        1,
        10_000,
        message.UserMessage(
          [
            message.UserText("look <here>", None),
            message.UserImage(png, "image/png"),
            message.UserImage(svg, "image/svg+xml"),
            message.UserImage(png, "image/x-<b>evil</b>"),
          ],
          0,
          None,
        ),
      ),
      item(
        2,
        11_000,
        assistant([
          call("c1", "read", json.Object([#("path", json.String("a.webp"))])),
        ]),
      ),
      item(
        3,
        12_000,
        message.ToolResultMessage(
          "c1",
          "read",
          [message.ToolResultImage(webp, "image/webp")],
          None,
          None,
          None,
          False,
          12_000,
        ),
      ),
      item(
        4,
        13_000,
        assistant([message.AssistantText("It is a picture.", None)]),
      ),
    ],
    None,
    [],
    [],
  )
}

/// A capture of `main` holding only the prompt "go", with `operation`
/// running when one is given: the state in which a response is streaming
/// and its answer, the entry after the prompt, is not committed yet. The
/// capture `answered` makes is the one that holds that entry.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.asked(Some(lane_fixture.main_op()))
/// ```
pub fn asked(operation: Option(String)) -> session_channel.Update {
  capture_of([item(1, 10_000, said("go", None))], operation, [], [])
}

/// `update`, a capture, with the daemon's sampled preview of the answer
/// running under `main`'s operation: what a page that attaches mid-answer
/// is told about the text so far, before any pushed fragment.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.previewed(lane_fixture.asked(None), "Hello wor")
/// ```
pub fn previewed(
  update: session_channel.Update,
  text: String,
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, trigger) ->
      session_channel.Captured(
        cut,
        snapshot_view.View(
          ..view,
          preview: Some(snapshot_view.Preview(
            1,
            main_op(),
            generation(2),
            "text",
            text,
          )),
        ),
        trigger,
      )
    other -> other
  }
}

/// The identity of the request whose answer will be committed as record
/// `seq`, as the daemon writes it: the entry it reserved is the last element.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.generation(2)
/// ```
pub fn generation(seq: Int) -> String {
  "[\"generation\",\""
  <> main_op()
  <> "\",0,\""
  <> ids.entry_id_to_string(id(seq))
  <> "\"]"
}

/// One pushed fragment of `kind` (`thinking` or `text`) of the request
/// `generation`, on `main`'s running operation.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.fragment(lane_fixture.generation(2), "text", "Hello")
/// ```
pub fn fragment(
  generation: String,
  kind: String,
  text: String,
) -> session_channel.Update {
  session_channel.Streamed("main", main_op(), generation, kind, text)
}

/// The push that says the request `generation` committed record `seq` with
/// `text`: the daemon's entry event, which clears the strand's streams
/// before the next capture holds the record.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.committed(2, "Hello")
/// ```
pub fn committed(seq: Int, text: String) -> session_channel.Update {
  let assert snapshot.Loaded(record, _) =
    item(seq, 11_000, assistant([message.AssistantText(text, None)]))
    as "an item built from a message is loaded"
  session_channel.Auxiliary(
    protocol.EntryAdded(protocol.EntryRecord("main", record)),
  )
}

/// A capture of `main` holding the records `from` to `to` of a
/// conversation in which every turn is three records: a person's question,
/// a working note and the answer, so each turn is an input, a work divider
/// holding the note, and the answer, three rows in all. Turn `n` is the
/// records `3n - 2` to `3n`. A capture that starts after the first record
/// names a parent it does not hold, so older history exists below it.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.conversation(301, 450)
/// ```
pub fn conversation(from: Int, to: Int) -> session_channel.Update {
  capture_of(exchange(from, to), None, [], [])
}

// The numbers one to `count`, in order.
fn counted(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: fn(numbers, number) {
    [number, ..numbers]
  })
}

/// A capture of `main` holding the records `from` onward of a conversation
/// whose turns are as long as `steps` says: each turn is a question, that many
/// working notes and the answer, so a turn of `n` steps is `n + 2` records and
/// folds `n` items under one divider. The turns follow one another from the
/// first record, and a capture that starts after it names a parent it does not
/// hold, so older history exists below it. The question of turn `t` reads
/// `question t`, its notes `step t.i` and its answer `answer t`.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.weighty(1, [170, 3])
/// ```
pub fn weighty(from: Int, steps: List(Int)) -> session_channel.Update {
  let #(_, _, items) =
    list.fold(steps, #(1, 1, []), fn(acc, count) {
      let #(turn, seq, items) = acc
      let label = int.to_string(turn)
      let notes =
        list.map(counted(count), fn(index) {
          assistant([
            message.AssistantText(
              "step " <> label <> "." <> int.to_string(index),
              None,
            ),
          ])
        })
      let bodies = [
        said("question " <> label, None),
        ..list.append(notes, [
          assistant([message.AssistantText("answer " <> label, None)]),
        ])
      ]
      let made =
        list.index_map(bodies, fn(body, index) {
          item(seq + index, 10_000 + seq + index, body)
        })
      #(turn + 1, seq + count + 2, list.append(items, made))
    })
  capture_of(
    list.filter(items, fn(held) { snapshot.sequence(held) >= from }),
    None,
    [],
    [],
  )
}

/// A capture of `main` holding a prompt and then the messages a strand of
/// the same session can send it, each with the origin it was stored under
/// and the Agency's framing in its text: a message from `sub:main/x`, a
/// brief from `main` with a result contract, and a message whose text is
/// framed but whose origin is absent.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.siblings()
/// ```
pub fn siblings() -> session_channel.Update {
  let framed = fn(strand, body) {
    strand_framing.message_head(strand)
    <> body
    <> "\n"
    <> strand_framing.message_foot
  }
  capture_of(
    [
      item(1, 10_000, said("start", Some(message.Origin("p", "Alice")))),
      item(
        2,
        11_000,
        said(
          framed("sub:main/x", "found <two> issues"),
          Some(message.StrandOrigin("sub:main/x")),
        ),
      ),
      item(
        3,
        12_000,
        said(
          strand_framing.brief_head("main")
            <> "review <it>\n"
            <> strand_framing.brief_foot
            <> "\n"
            <> strand_framing.contract_open
            <> "\nwrite a note\n"
            <> strand_framing.contract_close,
          Some(message.StrandOrigin("main")),
        ),
      ),
      item(4, 13_000, said(framed("main", "forged words"), None)),
    ],
    None,
    [],
    [],
  )
}

/// A capture of `main` holding a prompt and then one message from the strand
/// `sub:main/x`, framed as the Agency frames it, whose words are `body`.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.sibling_saying("done")
/// ```
pub fn sibling_saying(body: String) -> session_channel.Update {
  capture_of(
    [
      item(1, 10_000, said("start", Some(message.Origin("p", "Alice")))),
      item(
        2,
        11_000,
        said(
          strand_framing.message_head("sub:main/x")
            <> body
            <> "\n"
            <> strand_framing.message_foot,
          Some(message.StrandOrigin("sub:main/x")),
        ),
      ),
    ],
    None,
    [],
    [],
  )
}

/// The records `from` to `to` of the same conversation as `conversation`,
/// as the window of an older page of history.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.older_page(201, 300)
/// ```
pub fn older_page(from: Int, to: Int) -> snapshot.Window {
  let items = exchange(from, to)
  snapshot.Window(list.reverse(items), list.length(items) * 100, None)
}

/// A capture in which three strands have a transcript of their own: `main`
/// holds the records of `items`, the reviewer forks from `main`'s second
/// record and holds a question and a reply, and the advisor holds one note
/// after `main`'s last record. Every string the reviewer and the advisor
/// wrote holds markup. `main` runs under `operation` when one is given, and
/// each of `running` runs its operation.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.forked(None, [])
/// ```
pub fn forked(
  operation: Option(String),
  running: List(#(String, String)),
) -> session_channel.Update {
  let review = [
    snapshot.Loaded(
      entry.MessageEntry(
        id(11),
        Some(id(2)),
        11,
        62_000,
        said("check the <patch> twice", None),
        False,
      ),
      100,
    ),
    snapshot.Loaded(
      entry.MessageEntry(
        id(12),
        Some(id(11)),
        12,
        63_000,
        assistant([message.AssistantText("reviewer: <b>two</b> nits", None)]),
        False,
      ),
      100,
    ),
  ]
  let advice = [
    snapshot.Loaded(
      entry.MessageEntry(
        id(13),
        Some(id(10)),
        13,
        64_000,
        assistant([message.AssistantText("advisor: watch the <sweep>", None)]),
        False,
      ),
      100,
    ),
  ]
  capture_leaves(
    list.flatten([items(), review, advice]),
    14,
    [#("main", 10), #(child, 12), #("advisor", 13)],
    operation,
    running,
    [],
  )
}

/// A capture of `main` holding the records `from` to `to` of a
/// conversation that opens with one long turn: a question at 1 and a
/// working note at every sequence from 2 to 141, 141 rows in all. From 142
/// on, every turn is three records, as in `conversation`, so turn `n` of
/// those is the records `139 + 3n` to `141 + 3n`.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.long_turn(142, 291)
/// ```
pub fn long_turn(from: Int, to: Int) -> session_channel.Update {
  capture_of(long_items(from, to), None, [], [])
}

/// The records `from` to `to` of `long_turn`'s conversation, as the window
/// of an older page of history.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.long_turn_page(42, 141)
/// ```
pub fn long_turn_page(from: Int, to: Int) -> snapshot.Window {
  let items = long_items(from, to)
  snapshot.Window(list.reverse(items), list.length(items) * 100, None)
}

fn long_items(from: Int, to: Int) -> List(snapshot.Item) {
  int.range(from: to, to: from - 1, with: [], run: fn(items, seq) {
    let body = case seq, seq < 142 {
      1, _ -> said("question 0", None)
      _, True ->
        assistant([message.AssistantText("step " <> int.to_string(seq), None)])
      _, False -> {
        let turn = int.to_string({ seq - 139 } / 3)
        case { seq - 142 } % 3 {
          0 -> said("question " <> turn, None)
          1 -> assistant([message.AssistantText("working on " <> turn, None)])
          _ ->
            assistant([message.AssistantText("**answer " <> turn <> "**", None)])
        }
      }
    }
    [item(seq, 10_000 + seq, body), ..items]
  })
}

// The conversation's records `from` to `to`, oldest first.
fn exchange(from: Int, to: Int) -> List(snapshot.Item) {
  int.range(from: to, to: from - 1, with: [], run: fn(items, seq) {
    let turn = int.to_string({ seq + 2 } / 3)
    let body = case seq % 3 {
      1 -> said("question " <> turn, None)
      2 -> assistant([message.AssistantText("working on " <> turn, None)])
      _ -> assistant([message.AssistantText("**answer " <> turn <> "**", None)])
    }
    [item(seq, 10_000 + seq, body), ..items]
  })
}

fn capture_of(
  items: List(snapshot.Item),
  operation: Option(String),
  running: List(#(String, String)),
  extra: List(snapshot_view.Cell),
) -> session_channel.Update {
  // The leaf and the cursor follow the newest record held, which for a
  // capture from the first record is also the number of records.
  let newest =
    list.fold(items, 0, fn(newest, item) {
      int.max(newest, snapshot.sequence(item))
    })
  capture_leaves(items, newest, [#("main", newest)], operation, running, extra)
}

// A capture of `items` whose cursor is after `newest`, with each of `leaves`
// naming the last record of a strand's ancestry by its sequence.
fn capture_leaves(
  items: List(snapshot.Item),
  newest: Int,
  leaves: List(#(String, Int)),
  operation: Option(String),
  running: List(#(String, String)),
  extra: List(snapshot_view.Cell),
) -> session_channel.Update {
  let operations = case operation {
    Some(op) -> [#("main", op), ..running]
    None -> running
  }
  let phase = fn(id) {
    case list.key_find(operations, id) {
      Ok(_) -> Some("generating")
      Error(Nil) -> None
    }
  }
  let strands =
    list.map(["main", child, tester, "advisor"], fn(id) {
      protocol.Strand(id, None, phase(id))
    })
  let cells =
    list.flat_map(operations, fn(pair) {
      let #(strand, op) = pair
      [run_state(op), started(strand, op), ..glanced(strand, op)]
    })
    |> list.append(finished_cells(operations))
    |> list.append(extra)
  let view =
    snapshot_view.View(
      strands,
      dict.from_list(list.map(leaves, fn(leaf) { #(leaf.0, Some(id(leaf.1))) })),
      dict.new(),
      dict.from_list(operations),
      usage(),
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      cells,
      None,
      None,
      None,
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("A", "epoch", "incarnation"),
        "connection",
        message.Origin("alice", "Alice"),
        snapshot.Operator,
      ),
      newest + 1,
      // The capture's raw metadata is what the view is projected from, so a
      // capture with another view has other metadata. The shared step treats
      // two cuts with one cursor and one metadata as the same cut.
      json.String(string.inspect(#(strands, operations, cells))),
      snapshot.Window(list.reverse(items), list.length(items) * 100, None),
      None,
    )
  session_channel.Captured(cut, view, session_channel.Refreshed)
}

/// `update`, a capture, with the daemon's host queue listing `inputs`
/// (`snapshot_view.View.pending_inputs`), as a modern cut carries it. The
/// cut's metadata is changed with the queue, since the shared step treats two
/// cuts with one cursor and one metadata as the same cut.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.holding(lane_fixture.captured(10, None), [lane_fixture.steer("1", "go left")])
/// ```
pub fn holding(
  update: session_channel.Update,
  inputs: List(snapshot_view.PendingInput),
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, mode) ->
      session_channel.Captured(
        snapshot.Captured(
          ..cut,
          metadata: json.String(
            string.inspect(#(cut.metadata, list.map(inputs, fn(i) { i.id }))),
          ),
        ),
        snapshot_view.View(..view, pending_inputs: Some(inputs)),
        mode,
      )
    other -> other
  }
}

/// A steer the daemon holds for `main`, with `id` and the person's `text`.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.steer("h1", "go left")
/// ```
pub fn steer(id: String, text: String) -> snapshot_view.PendingInput {
  snapshot_view.PendingInput(
    id,
    "main",
    snapshot_view.Steer,
    text,
    0,
    snapshot_view.ReadOnly,
  )
}

/// A prompt the daemon holds for `strand` behind its turn.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.queued("h2", "main", "then the tests")
/// ```
pub fn queued(
  id: String,
  strand: String,
  text: String,
) -> snapshot_view.PendingInput {
  snapshot_view.PendingInput(
    id,
    strand,
    snapshot_view.Queue,
    text,
    0,
    snapshot_view.ReadOnly,
  )
}

// The register cell of an operation that is running and has just started,
// in the wire form `machine/codec.encode_state` writes, so an agent row reads
// it as work in progress.
fn run_state(op: String) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.OpState,
    op,
    1,
    json.Object([
      #("kind", json.String("run")),
      #("control", json.Object([#("status", json.String("running"))])),
      #(
        "settings",
        json.Object([
          #(
            "compaction",
            json.Object([
              #("enabled", json.Bool(False)),
              #("reserveTokens", json.Int(0)),
              #("keepRecentTokens", json.Int(0)),
            ]),
          ),
          #("steeringMode", json.String("all")),
          #("followUpMode", json.String("all")),
          #("toolExecution", json.String("parallel")),
        ]),
      ),
      #("phase", json.Object([#("kind", json.String("starting"))])),
      #(
        "inbox",
        json.Object([
          #("steer", json.Array([])),
          #("followUp", json.Array([])),
          #("writes", json.Array([])),
        ]),
      ),
      #("latestAssistantEntryId", json.Null),
    ]),
  )
}

// The sub-agents that are not running have run: the daemon records how each
// ended, and a strand with no operation and no result is one that has never
// run (a fresh fork), which the strip lists as a card and not as settled.
fn finished_cells(
  operations: List(#(String, String)),
) -> List(snapshot_view.Cell) {
  [#(child, review_op()), #(tester, tests_op())]
  |> list.filter(fn(pair) { list.key_find(operations, pair.0) == Error(Nil) })
  |> list.map(fn(pair) {
    snapshot_view.Cell(
      register.StrandLastResult,
      pair.0,
      1,
      json.Object([
        #("kind", json.String("run")),
        #("operationId", json.String(pair.1)),
        #("leafId", json.Null),
        #("outcome", json.String("completed")),
        #("runCompletion", json.String("assistant")),
      ]),
    )
  })
}

// The operation's metadata cell in the wire form `machine/codec` writes,
// which says when it started.
fn started(strand: String, op: String) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.OpMeta,
    op,
    1,
    json.Object([
      #("operationId", json.String(op)),
      #("strand", json.String(strand)),
      #("sourceLeafId", json.Null),
      #("startedAt", json.Int(started_at)),
      #(
        "intent",
        json.Object([
          #("kind", json.String("run")),
          #("promptEntryIds", json.Array([])),
        ]),
      ),
    ]),
  )
}

// A glance for each agent: the words and context size the daemon's glance
// loop writes, seven seconds into the operation by the daemon's clock. The
// reviewer's summary holds markup.
fn glanced(strand: String, op: String) -> List(snapshot_view.Cell) {
  let words = case strand {
    "main" -> Ok(#("Review the patch", "Waiting for the reviewer", 41_200))
    _ if strand == child ->
      Ok(#("Review", "Reading <manager>.go line by line", 9100))
    _ if strand == tester -> Ok(#("Tests", "Running the tui suite", 18_400))
    _ -> Error(Nil)
  }
  case words {
    Ok(#(title, summary, tokens)) -> [
      snapshot_view.Cell(
        register.FactCustom,
        glance.key(strand),
        2,
        glance.encode(glance.Glance(
          op,
          title,
          summary,
          started_at + 7000,
          tokens,
        )),
      ),
    ]
    Error(Nil) -> []
  }
}

/// A usage push for `strand` with no durable sequence, which the page
/// compares at once: a request that read `cache_read` tokens from the
/// cache and wrote `cache_write`, with a one-hour write when `hour` is
/// positive.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.usage_push("main", 40_000, 0, 1)
/// ```
pub fn usage_push(
  strand: String,
  cache_read: Int,
  cache_write: Int,
  hour: Int,
) -> session_channel.Update {
  session_channel.Auxiliary(protocol.UsageChanged(
    strand:,
    seq: None,
    operation: None,
    usage: message.Usage(
      input: 200,
      output: 400,
      cache_read:,
      cache_write:,
      cache_write_1h: Some(hour),
      reasoning: None,
      total_tokens: 200 + 400 + cache_read + cache_write,
      cost: message.UsageCost(
        0.0006,
        0.006,
        int_cost(cache_read, 0.0000003),
        int_cost(cache_write, 0.00000375),
        0.0,
      ),
    ),
  ))
}

/// A capture of `main` holding a prompt and one response that reasons over
/// three lines, calls `code_mode` with `program`, and gets `output` back,
/// then the answer: the rows an expander is drawn for.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.programmed("pub fn main() { 1 }", "1")
/// ```
pub fn programmed(program: String, output: String) -> session_channel.Update {
  let outcome =
    message.ToolResultMessage(
      "p1",
      "code_mode",
      [message.ToolResultText(output, None)],
      Some(json.Object([])),
      None,
      None,
      False,
      12_000,
    )
  capture_of(
    [
      item(1, 10_000, said("run it", None)),
      item(
        2,
        11_000,
        assistant([
          message.AssistantThinking("first <idea>\nsecond\nthird", None, False),
          call(
            "p1",
            "code_mode",
            json.Object([#("program", json.String(program))]),
          ),
        ]),
      ),
      item(3, 12_000, outcome),
      item(4, 13_000, assistant([message.AssistantText("Ran it.", None)])),
    ],
    None,
    [],
    [],
  )
}

fn int_cost(tokens: Int, rate: Float) -> Float {
  case tokens {
    0 -> 0.0
    _ -> rate *. int.to_float(tokens)
  }
}

/// The digest lines the memory context below carries. The second holds
/// markup, so a test can check the expansion arrives as escaped text.
pub const memory_digest =
  "- (fact) the gate is make check\n- (decision) keep <b>R6</b> portable"

/// The message the daemon attaches to a run as distilled memory, in the
/// shape `client/memory.wrapped` writes: the attribution, then the digest
/// in a `loom-memory` fence.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.memory_context()
/// ```
pub fn memory_context() -> String {
  composer.memory_attribution_lead
  <> "sessions.\n\n"
  <> composer.memory_fence
  <> "\n"
  <> memory_digest
  <> "\n```"
}

/// A capture of `main` holding the memory context and then the owner's
/// prompt and an answer, which is how a run's records read when the
/// daemon has distilled memory to attach.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.remembered()
/// ```
pub fn remembered() -> session_channel.Update {
  capture_of(
    [
      item(1, 10_000, said(memory_context(), None)),
      item(2, 10_001, said("please run the gate", None)),
      item(3, 10_002, assistant([message.AssistantText("**done**", None)])),
    ],
    None,
    [],
    [],
  )
}

/// A capture of `main` holding a prompt the page's own person sent, the
/// principal the capture's attachment holds, and an answer: what the lane
/// draws with the reader's role beside the name.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.own_prompt()
/// ```
pub fn own_prompt() -> session_channel.Update {
  capture_of(
    [
      item(
        1,
        10_000,
        said("my own prompt", Some(message.Origin("alice", "Alice"))),
      ),
      item(2, 10_001, assistant([message.AssistantText("done", None)])),
    ],
    None,
    [],
    [],
  )
}

/// A capture of `main` holding one prompt and then one successful `fs_edit`
/// call and result per edit, each edit a path and the unified diff its result
/// reports, which is how a page's records read when the agent has edited
/// files.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.edited([#("src/a.gleam", "@@ -1 +1 @@\n-a\n+b")])
/// ```
pub fn edited(edits: List(#(String, String))) -> session_channel.Update {
  let calls =
    list.index_map(edits, fn(edit, index) {
      let call_id = "edit-" <> int.to_string(index)
      let details =
        json.Object([
          #("path", json.String(edit.0)),
          #("diff", json.String(edit.1)),
        ])
      let seq = 2 + index * 2

      [
        item(
          seq,
          11_000 + seq,
          assistant([call(call_id, "fs_edit", json.Object([]))]),
        ),
        item(seq + 1, 11_000 + seq + 1, result(call_id, "fs_edit", details, 0)),
      ]
    })

  capture_of(
    [item(1, 10_000, said("edit it", None)), ..list.flatten(calls)],
    None,
    [],
    [],
  )
}

/// A capture of a session that runs two `code_mode` programs, in order, the
/// first finishing with `value` and the second still running: the rows the
/// Trace pane lists.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.traced("// count functions\npub fn main() { 3 }", "3")
/// ```
pub fn traced(program: String, value: String) -> session_channel.Update {
  let outcome =
    message.ToolResultMessage(
      "t1",
      "code_mode",
      [message.ToolResultText(value, None)],
      Some(
        json.Object([
          #("status", json.String("completed")),
          #("value", json.String(value)),
        ]),
      ),
      None,
      None,
      False,
      12_000,
    )
  capture_of(
    [
      item(1, 10_000, said("run it", None)),
      item(
        2,
        11_000,
        assistant([
          call(
            "t1",
            "code_mode",
            json.Object([
              #("program", json.String(program)),
              #("within_ms", json.Int(30_000)),
            ]),
          ),
        ]),
      ),
      item(3, 12_000, outcome),
      item(
        4,
        13_000,
        assistant([
          call(
            "t2",
            "code_mode",
            json.Object([#("program", json.String("pub fn main() { loop() }"))]),
          ),
        ]),
      ),
    ],
    None,
    [],
    [],
  )
}

/// `update`, when it is a capture, with `peers` as the session's presence
/// rows. Any other update is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.attended(lane_fixture.captured(10, None), [])
/// ```
pub fn attended(
  update: session_channel.Update,
  peers: List(snapshot_view.Peer),
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, refresh) ->
      session_channel.Captured(cut, snapshot_view.View(..view, peers:), refresh)
    other -> other
  }
}

/// A capture of a session whose every region the page draws holds `marker`:
/// its prompt, an edit's path and diff, a `todo` board's phase
/// and task, a program and its output, the answer, a message from a peer
/// session named for the marker, a pending escalation's tool and preview, and
/// a viewer. `running` are the strands that run, and each is drawn with the
/// glance the fixture writes for it. A test that opens two sessions with two
/// markers can then look for one session's words on the other's page.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.marked("alpha", [])
/// ```
pub fn marked(
  marker: String,
  running: List(#(String, String)),
) -> session_channel.Update {
  let board =
    todo_list.Board([
      todo_list.Phase(marker <> " phase", [
        todo_list.Task(marker <> " task", todo_list.Active),
      ]),
    ])
  let outcome =
    message.ToolResultMessage(
      "m3",
      "code_mode",
      [message.ToolResultText(marker <> " output", None)],
      Some(json.Object([])),
      None,
      None,
      False,
      15_000,
    )
  let items = [
    item(1, 10_000, said(marker <> " prompt", None)),
    item(
      2,
      11_000,
      assistant([
        call("m1", "fs_edit", json.Object([])),
        call("m2", "todo", json.Object([])),
        call(
          "m3",
          "code_mode",
          json.Object([#("program", json.String(marker <> "_program"))]),
        ),
      ]),
    ),
    item(
      3,
      12_000,
      result(
        "m1",
        "fs_edit",
        json.Object([
          #("path", json.String(marker <> "/edited.gleam")),
          #("diff", json.String("@@ -1 +1 @@\n-old\n+" <> marker <> " diff")),
        ]),
        12_000,
      ),
    ),
    item(
      4,
      13_000,
      result(
        "m2",
        "todo",
        json.Object([#("todo", todo_list.encode(board))]),
        13_000,
      ),
    ),
    item(5, 14_000, outcome),
    item(
      6,
      16_000,
      assistant([message.AssistantText(marker <> " answer", None)]),
    ),
    item(
      7,
      17_000,
      said(
        marker <> " peer says",
        Some(message.PeerOrigin(marker <> "-peer", "main")),
      ),
    ),
  ]
  let escalation = case
    page_fixture.escalation(
      "esc-" <> marker,
      90,
      "tool-" <> marker,
      marker <> " preview",
    )
  {
    json.Object(fields) -> fields
    _ -> []
  }
  let cells = case
    list.key_find(escalation, "value"),
    list.key_find(escalation, "seq")
  {
    Ok(value), Ok(json.Int(seq)) -> [
      snapshot_view.Cell(
        register.FactCustom,
        "escalation/esc-" <> marker,
        seq,
        value,
      ),
    ]
    _, _ -> []
  }
  attended(capture_of(items, None, running, cells), [
    snapshot_view.Peer(
      marker <> "-connection",
      message.Origin(marker <> "-principal", marker <> " viewer"),
      snapshot.Operator,
    ),
  ])
}

/// `update`, when it is a capture, as a capture in which `strand` has never
/// run: it has neither an operation nor a recorded result, as a fresh fork has
/// not. Any other update is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.unrun(lane_fixture.captured_with(10, None, []), lane_fixture.tester)
/// ```
pub fn unrun(
  update: session_channel.Update,
  strand: String,
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, refresh) ->
      session_channel.Captured(
        cut,
        snapshot_view.View(
          ..view,
          cells: list.filter(view.cells, fn(cell) {
            !{
              cell.namespace == register.StrandLastResult && cell.key == strand
            }
          }),
        ),
        refresh,
      )
    other -> other
  }
}

/// `update`, when it is a capture, with `main`'s last run recorded as failed
/// (a provider refused the key). Nothing is pending and `main` is not running
/// in a capture that did not run it, so the session waits on nobody.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.failed_main(lane_fixture.captured_with(10, None, []))
/// ```
pub fn failed_main(update: session_channel.Update) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, refresh) ->
      session_channel.Captured(
        cut,
        snapshot_view.View(..view, cells: [
          snapshot_view.Cell(
            register.StrandLastResult,
            "main",
            2,
            json.Object([
              #("kind", json.String("run")),
              #("operationId", json.String(op(9))),
              #("leafId", json.Null),
              #("outcome", json.String("failed")),
              #(
                "error",
                json.Object([
                  #("code", json.String("provider_refused")),
                  #("message", json.String("the key was refused")),
                ]),
              ),
            ]),
          ),
          ..list.filter(view.cells, fn(cell) {
            !{
              cell.namespace == register.StrandLastResult && cell.key == "main"
            }
          })
        ]),
        refresh,
      )
    other -> other
  }
}

/// `update`, when it is a capture, as the page of a reader attached in `role`:
/// the cut's own attachment carries it, and the presence rows are left as
/// they were. Any other update is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.viewed_as(lane_fixture.own_prompt(), snapshot.Observer)
/// ```
pub fn viewed_as(
  update: session_channel.Update,
  role: snapshot.Role,
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, refresh) ->
      session_channel.Captured(
        snapshot.Captured(
          ..cut,
          attachment: snapshot.Attachment(..cut.attachment, role:),
        ),
        view,
        refresh,
      )
    other -> other
  }
}

/// `update`, when it is a capture, with every strand that has a live phase in
/// `phase` instead of the fixture's own label, which is a word the server
/// never emits. The server's phase for a model generating is `assistant`. Any
/// other update is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.phased(lane_fixture.asked(Some(lane_fixture.main_op())), "assistant")
/// ```
pub fn phased(
  update: session_channel.Update,
  phase: String,
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, refresh) ->
      session_channel.Captured(
        cut,
        snapshot_view.View(
          ..view,
          strands: list.map(view.strands, fn(strand) {
            case strand.live_phase {
              Some(_) -> protocol.Strand(..strand, live_phase: Some(phase))
              None -> strand
            }
          }),
        ),
        refresh,
      )
    other -> other
  }
}

/// `update`, a capture, with the strand `name` left out of the strands it
/// lists, as a capture is when that strand has retired. The records are
/// untouched. A retired strand's parked history window is released on the
/// next capture that omits it.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.without_strand(lane_fixture.conversation(301, 451), "advisor")
/// ```
pub fn without_strand(
  update: session_channel.Update,
  name: String,
) -> session_channel.Update {
  case update {
    session_channel.Captured(cut, view, refresh) ->
      session_channel.Captured(
        cut,
        snapshot_view.View(
          ..view,
          strands: list.filter(view.strands, fn(strand) { strand.id != name }),
        ),
        refresh,
      )
    other -> other
  }
}

/// The handler keys of a page, as `page_events_ffi` lists them (a path, a
/// newline and the event's name), without the clicks of settled turns'
/// dividers, which are the lane's and not what a test of another region counts.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.beyond_dividers(["0\t2\t1\t0\t0\nclick"])
/// ```
pub fn beyond_dividers(keys: List(String)) -> List(String) {
  list.filter(keys, fn(key) {
    case string.split_once(key, "\n") {
      Ok(#(path, _)) -> !component.fold_click(path)
      Error(Nil) -> True
    }
  })
}

/// The page with every closed fold of work it holds opened, as a reader would
/// by pressing each divider. A settled turn's steps are drawn only while its
/// fold is open, so a test that reads a step or a result opens the page first.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.opened(component.apply(component.new(page_fixture.start()), [lane_fixture.captured(7, None)]))
/// ```
pub fn opened(model: component.Model(socket)) -> component.Model(socket) {
  let page =
    list.fold(component.pieces(model), model, fn(page, piece) {
      case piece {
        turns.Work(id: Some(id), folding: turns.Folded, ..) ->
          component.update(page, component.FoldToggled(id)).0
        turns.Work(..)
        | turns.Plain(..)
        | turns.Prompt(..)
        | turns.Spawned(..)
        | turns.Returned(..)
        | turns.Nudged(..)
        | turns.Peer(..)
        | turns.Sibling(..)
        | turns.Missed(..)
        | turns.Decided(..)
        | turns.Commentary(..) -> page
      }
    })

  // A page over its limit closes the folds it cannot hold, which would leave
  // a test reading steps that are not there, so say so here.
  list.each(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(id: Some(_), folding: turns.Folded, ..) ->
        panic as "opened: a fold did not fit the page, so it stayed closed"
      _ -> Nil
    }
  })
  page
}

/// The records of a conversation whose turns each read a file per step, oldest
/// first, as a session's records read when the agent works through a tree: turn
/// `t` is its question (`question t`), then for each of its `steps` an
/// `fs_read` call and its result, then its answer (`answer t`). A turn of `n`
/// steps is `2n + 2` records and its divider counts `n` steps.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.reading([3, 110])
/// ```
pub fn reading(steps: List(Int)) -> List(snapshot.Item) {
  worked_turns(steps, fn(_) { [] })
}

/// `reading`, with a long reasoning block (`thought`, of the response's
/// sequence) opening each step's response, so every step has one block the
/// summarizer labels, at content index 0.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.thinking([3, 110])
/// ```
pub fn thinking(steps: List(Int)) -> List(snapshot.Item) {
  worked_turns(steps, fn(at) {
    [message.AssistantThinking(thought(at), None, False)]
  })
}

// The turns of `reading`, each response opening with the blocks `opening`
// gives for its sequence.
fn worked_turns(
  steps: List(Int),
  opening: fn(Int) -> List(message.AssistantBlock),
) -> List(snapshot.Item) {
  let #(_, _, items) =
    list.fold(steps, #(1, 1, []), fn(acc, count) {
      let #(turn, seq, items) = acc
      let label = int.to_string(turn)
      let reads =
        list.flat_map(counted(count), fn(index) {
          let name = "t" <> label <> "-" <> int.to_string(index)
          let at = seq + 2 * index - 1
          [
            item(
              at,
              10_000 + at * 10,
              assistant(
                list.append(opening(at), [
                  call(
                    name,
                    "fs_read",
                    json.Object([
                      #("path", json.String("notes/" <> name <> ".txt")),
                    ]),
                  ),
                ]),
              ),
            ),
            item(
              at + 1,
              10_000 + { at + 1 } * 10,
              result(name, "fs_read", json.Object([]), 10_000 + { at + 1 } * 10),
            ),
          ]
        })
      let last = seq + 2 * count + 1
      let bodies = [
        item(seq, 10_000 + seq * 10, said("question " <> label, None)),
        ..list.append(reads, [
          item(
            last,
            10_000 + last * 10,
            assistant([message.AssistantText("answer " <> label, None)]),
          ),
        ])
      ]
      #(turn + 1, last + 1, list.append(items, bodies))
    })
  items
}

/// The records of a conversation whose turns each make their calls in batches,
/// as a model that issues parallel calls does, oldest first: turn `t` is its
/// question, then for each size in its list one assistant message holding that
/// many `fs_read` calls followed by that many results, then its answer. A batch
/// of `n` calls is `n + 1` records and a read that stops among its results holds
/// results whose call it did not reach.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.batched([[40, 40], [3]])
/// ```
pub fn batched(batches: List(List(Int))) -> List(snapshot.Item) {
  let #(_, _, items) =
    list.fold(batches, #(1, 1, []), fn(acc, sizes) {
      let #(turn, seq, items) = acc
      let label = int.to_string(turn)
      let #(next, reads) =
        list.fold(sizes, #(seq + 1, []), fn(acc, size) {
          let #(at, held) = acc
          let names =
            list.map(counted(size), fn(index) {
              "t"
              <> label
              <> "-"
              <> int.to_string(at)
              <> "-"
              <> int.to_string(index)
            })
          let calls =
            item(
              at,
              10_000 + at * 10,
              assistant(
                list.map(names, fn(name) {
                  call(
                    name,
                    "fs_read",
                    json.Object([
                      #("path", json.String("notes/" <> name <> ".txt")),
                    ]),
                  )
                }),
              ),
            )
          let results =
            list.index_map(names, fn(name, index) {
              let place = at + 1 + index
              item(
                place,
                10_000 + place * 10,
                result(name, "fs_read", json.Object([]), 10_000 + place * 10),
              )
            })
          #(at + 1 + size, list.append(held, [calls, ..results]))
        })
      let bodies = [
        item(seq, 10_000 + seq * 10, said("question " <> label, None)),
        ..list.append(reads, [
          item(
            next,
            10_000 + next * 10,
            assistant([message.AssistantText("answer " <> label, None)]),
          ),
        ])
      ]
      #(turn + 1, next + 1, list.append(items, bodies))
    })
  items
}

/// `items` (oldest first) and then `count` records of the `advisor` strand,
/// which the session writes after the turn settles: a review of it. The advisor's
/// records hang off one another from the first record of the conversation, so
/// none of them is on `main`'s ancestry, and they take the sequences after
/// `main`'s.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.advised(lane_fixture.batched([[55]]), 60)
/// ```
pub fn advised(items: List(snapshot.Item), count: Int) -> List(snapshot.Item) {
  let last =
    list.fold(items, 0, fn(newest, held) {
      int.max(newest, snapshot.sequence(held))
    })
  let review =
    list.map(counted(count), fn(index) {
      let seq = last + index
      let parent = case index {
        1 -> id(1)
        _ -> id(seq - 1)
      }
      snapshot.Loaded(
        entry.MessageEntry(
          id(seq),
          Some(parent),
          seq,
          10_000 + seq * 10,
          assistant([
            message.AssistantText("review " <> int.to_string(index), None),
          ]),
          False,
        ),
        100,
      )
    })
  list.append(items, review)
}

/// The records of a session whose advisor has reviewed it `count` times: a
/// question and its answer on `main` and then, on the `advisor` strand, a feed
/// and the advisor's reply for each review, which every one of its runs answers.
/// The feed is the only message the advisor's strand receives, so its history is
/// as long as its reviews are many.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.reviews(1500)
/// ```
pub fn reviews(count: Int) -> List(snapshot.Item) {
  let feed =
    "[advisor feed: what the primary did since your last review]\n"
    <> "user:\nquestion 1\n"
    <> "[end feed. Review it and answer with exactly one advise call.]"
  [
    item(1, 10_000, said("question 1", None)),
    item(2, 10_010, assistant([message.AssistantText("answer 1", None)])),
    ..list.flat_map(counted(count), fn(index) {
      let seq = 2 * index + 1
      [
        item(seq, 10_000 + seq * 10, said(feed, None)),
        item(
          seq + 1,
          10_000 + { seq + 1 } * 10,
          assistant([
            message.AssistantText("review " <> int.to_string(index), None),
          ]),
        ),
      ]
    })
  ]
}

/// A capture holding the newest `count` of `items` (oldest first), as a
/// gateway's cut holds the newest records of the whole session whichever strand
/// wrote them, with each of `leaves` naming the last record of a strand's
/// ancestry by its sequence, and every strand idle.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.newest_by(items, 50, [#("main", 59), #("advisor", 119)])
/// ```
pub fn newest_by(
  items: List(snapshot.Item),
  count: Int,
  leaves: List(#(String, Int)),
) -> session_channel.Update {
  let held = list.drop(items, list.length(items) - count)
  let newest =
    list.fold(held, 0, fn(newest, item) {
      int.max(newest, snapshot.sequence(item))
    })
  capture_leaves(held, newest, leaves, None, [], [])
}

/// `items` (oldest first) and then what a strand does when it resumes the turn
/// it was in with no new input: `steps` more calls, each with its result, and a
/// last answer (`answer resumed`). The records continue the sequence, so the
/// strand's ancestry is unbroken, and none of them is a person's message.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.resumed(lane_fixture.reading([110]), 3)
/// ```
pub fn resumed(items: List(snapshot.Item), steps: Int) -> List(snapshot.Item) {
  let next = list.length(items) + 1
  let more =
    list.flat_map(counted(steps), fn(index) {
      let name = "resumed-" <> int.to_string(index)
      let at = next + 2 * index - 2
      [
        item(
          at,
          10_000 + at * 10,
          assistant([
            call(
              name,
              "fs_read",
              json.Object([#("path", json.String("notes/" <> name <> ".txt"))]),
            ),
          ]),
        ),
        item(
          at + 1,
          10_000 + { at + 1 } * 10,
          result(name, "fs_read", json.Object([]), 10_000 + { at + 1 } * 10),
        ),
      ]
    })
  let last = next + 2 * steps
  list.flatten([
    items,
    more,
    [
      item(
        last,
        10_000 + last * 10,
        assistant([message.AssistantText("answer resumed", None)]),
      ),
    ],
  ])
}

/// A capture of `main` holding the records of `items` (oldest first) from the
/// sequence `from` on, with `main` running under `operation` when one is
/// given: what a gateway's cut carries when it holds only the newest records
/// of a long session. A capture that starts after the first record names a
/// parent it does not hold.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.since(lane_fixture.reading([3]), 4, None)
/// ```
pub fn since(
  items: List(snapshot.Item),
  from: Int,
  operation: Option(String),
) -> session_channel.Update {
  capture_of(
    list.filter(items, fn(held) { snapshot.sequence(held) >= from }),
    operation,
    [],
    [],
  )
}

/// A capture of the newest `count` of `items` (oldest first), as a cut holds
/// them, and `main` idle.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.newest(lane_fixture.reading([570]), 100)
/// ```
pub fn newest(
  items: List(snapshot.Item),
  count: Int,
) -> session_channel.Update {
  since(items, list.length(items) - count + 1, None)
}

/// The reads `page` wrote to `wire`, answered from `archive` (the records of
/// the session, oldest first) as a gateway would, until the page writes no
/// more. A history read is answered with the records of the interval it names,
/// a catch-up with an empty session, as the fixture's lane carries one, and
/// `restore` is applied after it, so the page has again the capture a real
/// session's catch-up would have brought; any other read is refused.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.serve(page, wire, archive, capture)
/// ```
pub fn serve(
  page: component.Model(page_fixture.Wire),
  wire: page_fixture.Wire,
  archive: List(snapshot.Item),
  restore: session_channel.Update,
) -> component.Model(page_fixture.Wire) {
  served(page, wire, archive, restore, "operator").0
}

/// `serve` for an attachment with `role`, and every frame it answered, oldest
/// first, as the frames the page wrote.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.served(page, wire, archive, capture, "observer")
/// ```
pub fn served(
  page: component.Model(page_fixture.Wire),
  wire: page_fixture.Wire,
  archive: List(snapshot.Item),
  restore: session_channel.Update,
  role: String,
) -> #(component.Model(page_fixture.Wire), List(String)) {
  served_labelled(page, wire, archive, restore, role, [])
}

/// `served`, with the summarizer's stored labels `labels` (an entry's text,
/// a content index and the label), which a `block_summaries` read is
/// answered from: each block it names that the list holds, and nothing for
/// the others, as the daemon answers.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.served_labelled(page, wire, archive, capture, "operator", [#(lane_fixture.entry_text(2), 0, "Reads.")])
/// ```
pub fn served_labelled(
  page: component.Model(page_fixture.Wire),
  wire: page_fixture.Wire,
  archive: List(snapshot.Item),
  restore: session_channel.Update,
  role: String,
  labels: List(#(String, Int, String)),
) -> #(component.Model(page_fixture.Wire), List(String)) {
  serving(page, wire, archive, restore, role, labels, 400, [])
}

fn serving(
  page: component.Model(page_fixture.Wire),
  wire: page_fixture.Wire,
  archive: List(snapshot.Item),
  restore: session_channel.Update,
  role: String,
  labels: List(#(String, Int, String)),
  rounds: Int,
  written: List(String),
) -> #(component.Model(page_fixture.Wire), List(String)) {
  let frames =
    list.filter(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case frames, rounds {
    [], _ | _, 0 -> #(page, written)
    _, _ -> {
      let answered =
        page_fixture.run(page, component.update, [
          component.Arrived(
            list.flat_map(frames, fn(frame) {
              answer(frame, archive, role, labels)
            }),
          ),
        ])
      let page = case
        list.any(frames, fn(frame) {
          string.contains(frame, "\"cmd\":\"catch_up\"")
        })
      {
        True -> component.apply(answered, [restore])
        False -> answered
      }
      serving(
        page,
        wire,
        archive,
        restore,
        role,
        labels,
        rounds - 1,
        list.append(written, frames),
      )
    }
  }
}

// The gateway's reply to one frame the page wrote: the records of the
// interval a history read names, an empty catch-up, or a refusal.
fn answer(
  frame: String,
  archive: List(snapshot.Item),
  role: String,
  labels: List(#(String, Int, String)),
) -> List(connection_event.Message) {
  let id = page_fixture.request_id(frame)
  case string.contains(frame, "\"cmd\":\"block_summaries\"") {
    True -> [page_fixture.block_summaries(id, named(frame, labels))]
    False -> answered_from(frame, archive, role, id)
  }
}

// The labels among `labels` that a `block_summaries` frame names.
fn named(
  frame: String,
  labels: List(#(String, Int, String)),
) -> List(#(String, Int, String)) {
  let assert Ok(json.Object(fields)) = json.parse(frame)
  let assert Ok(json.Object(body)) = list.key_find(fields, "body")
  let assert Ok(json.Array(blocks)) = list.key_find(body, "blocks")
  list.filter(labels, fn(label) {
    list.any(blocks, fn(block) {
      block
      == json.Object([
        #("entry", json.String(label.0)),
        #("block", json.Int(label.1)),
      ])
    })
  })
}

fn answered_from(
  frame: String,
  archive: List(snapshot.Item),
  role: String,
  id: Int,
) -> List(connection_event.Message) {
  case
    string.contains(frame, "\"cmd\":\"history_lineage\""),
    string.contains(frame, "\"cmd\":\"history\""),
    string.contains(frame, "\"cmd\":\"catch_up\"")
  {
    True, _, _ -> {
      let assert Ok(json.Object(fields)) = json.parse(frame)
      let assert Ok(json.Object(body)) = list.key_find(fields, "body")
      let assert Ok(json.String(from)) = list.key_find(body, "from")
      page_fixture.lineage(
        id,
        role,
        lineage_of(archive, from),
        high_water(archive),
      )
    }
    False, True, _ -> {
      let assert Ok(json.Object(fields)) = json.parse(frame)
      let assert Ok(json.Object(body)) = list.key_find(fields, "body")
      let assert Ok(json.Int(after)) = list.key_find(body, "after_seq")
      let assert Ok(json.Int(before)) = list.key_find(body, "before_seq")
      let held =
        list.filter(archive, fn(held) {
          snapshot.sequence(held) > after && snapshot.sequence(held) < before
        })
      page_fixture.history(
        id,
        role,
        snapshot.Window(list.reverse(held), list.length(held) * 100, None),
        before,
      )
    }
    False, False, True -> page_fixture.catch_up(id, role)
    False, False, False -> [page_fixture.refusal(id)]
  }
}

// The records a lineage read from the entry `from` returns: that entry and the
// ones below it down their parent links, at most a hundred and no more than a
// page's bytes, newest first, as the lane holds a page. An entry the archive
// does not hold has no records.
fn lineage_of(archive: List(snapshot.Item), from: String) -> snapshot.Window {
  let held =
    dict.from_list(
      list.map(archive, fn(item) { #(snapshot.identity(item), item) }),
    )
  let records = walked(held, Some(from), 100, [])
  snapshot.Window(records, list.length(records) * 100, None)
}

fn walked(
  held: dict.Dict(String, snapshot.Item),
  next: Option(String),
  remaining: Int,
  found: List(snapshot.Item),
) -> List(snapshot.Item) {
  case next, remaining {
    None, _ | _, 0 -> list.reverse(found)
    Some(id), _ ->
      case dict.get(held, id) {
        Error(Nil) -> list.reverse(found)
        Ok(item) -> {
          let parent = case item {
            snapshot.Loaded(entry, _) ->
              option.map(entry.parent, ids.entry_id_to_string)
            snapshot.Unloaded(..) -> None
          }
          walked(held, parent, remaining - 1, [item, ..found])
        }
      }
  }
}

// The first sequence the archive has not used, which is what a daemon's capture
// carries as its high-water.
fn high_water(archive: List(snapshot.Item)) -> Int {
  1
  + list.fold(archive, 0, fn(newest, item) {
    int.max(newest, snapshot.sequence(item))
  })
}

/// A capture of `main` holding one turn that was stopped: a question, one call
/// and its result, and a response that was aborted with no text and carries
/// `diagnostic`, as the records read after a Stop or a steer ended a response
/// that was being written.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.stopped("provider request was cancelled (runtime: explicit stop)")
/// ```
pub fn stopped(diagnostic: String) -> session_channel.Update {
  capture_of(
    [
      item(1, 10_000, said("write the essay", None)),
      item(2, 11_000, assistant([call("c1", "fs_read", json.Object([]))])),
      item(3, 12_000, result("c1", "fs_read", json.Object([]), 12_000)),
      item(
        4,
        13_000,
        message.AssistantMessage(
          [],
          "test",
          "test",
          "test",
          None,
          None,
          None,
          usage(),
          message.Aborted,
          None,
          Some(diagnostic),
          None,
          None,
          0,
        ),
      ),
    ],
    None,
    [],
    [],
  )
}

/// The records of `turns` turns that each failed: a question (`FAIL t`) and a
/// response that carries no text and says the provider refused the request, as
/// the records read after a run that ended in an error. Oldest first.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.failing(2)
/// ```
pub fn failing(turns: Int) -> List(snapshot.Item) {
  list.flat_map(counted(turns), fn(turn) {
    let seq = 2 * turn - 1
    [
      item(seq, 10_000 + seq, said("FAIL " <> int.to_string(turn), None)),
      item(
        seq + 1,
        10_000 + seq + 1,
        message.AssistantMessage(
          [],
          "test",
          "test",
          "test",
          None,
          None,
          None,
          usage(),
          message.Errored,
          None,
          Some("provider returned http 400"),
          None,
          None,
          0,
        ),
      ),
    ]
  })
}

/// A capture of `main` holding `turns` turns of two records, each a one-line question
/// and an answer of `size` characters: few rows, many bytes.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.heavy(3, 9_000_000)
/// ```
pub fn heavy(turns: Int, size: Int) -> session_channel.Update {
  let long = string.repeat("x", size)
  capture_of(
    list.flat_map(counted(turns), fn(turn) {
      let seq = 2 * turn - 1
      [
        item(seq, 10_000 + seq, said("question " <> int.to_string(turn), None)),
        item(
          seq + 1,
          10_000 + seq + 1,
          assistant([
            message.AssistantText(int.to_string(turn) <> long, None),
          ]),
        ),
      ]
    }),
    None,
    [],
    [],
  )
}

/// The reasoning a long block holds: well over the 512 bytes the summarizer
/// labels, opening with a first line that names `seq`, so a test can tell the
/// raw row from a labelled one and one block from another.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.thought(2)
/// ```
pub fn thought(seq: Int) -> String {
  "Thought "
  <> int.to_string(seq)
  <> ": weigh the locking order against the retry path.\n"
  <> string.repeat("Then compare it with what the second reader sees. ", 14)
}

/// A capture of `main` whose turns each think before every step. A complete
/// turn is a question (`question t`), then for each of its `steps` a response
/// whose first content block is a long reasoning block (`thought`, of the
/// response's sequence) beside an `fs_read` call, and the call's result, then
/// an answer (`answer t`); a turn of `n` steps is `2n + 2` records. With
/// `running` given, a last turn (`question running`) follows the complete ones
/// with the same steps and no answer, and `main` runs under that operation.
/// The response of step `s` in the turn that starts at sequence `first` is
/// `first + 2s - 1`, and its reasoning is content block 0.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.reasoned(2, 1, None)
/// ```
pub fn reasoned(
  complete: Int,
  steps: Int,
  running: Option(String),
) -> session_channel.Update {
  let per_turn = 2 * steps + 2
  let done =
    list.flat_map(counted(complete), fn(turn) {
      let label = int.to_string(turn)
      reasoned_turn(label, { turn - 1 } * per_turn + 1, steps, [
        assistant([message.AssistantText("answer " <> label, None)]),
      ])
    })
  let live = case running {
    Some(_) -> reasoned_turn("running", complete * per_turn + 1, steps, [])
    None -> []
  }
  capture_of(list.append(done, live), running, [], [])
}

/// A capture of `main` whose complete turns each end in a response that thinks
/// before it answers: a question (`question t`), then one response whose first
/// content block is a long reasoning block (`thought`, of the response's
/// sequence) and whose second is the answer (`answer t`). A turn is two records,
/// so the response of turn `t` is sequence `2t`. With `running` given, a last
/// turn (`question running`) follows and `main` runs under that operation.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.reasoned_answers(2, None)
/// ```
pub fn reasoned_answers(
  complete: Int,
  running: Option(String),
) -> session_channel.Update {
  let done =
    list.flat_map(counted(complete), fn(turn) {
      let label = int.to_string(turn)
      let first = { turn - 1 } * 2 + 1
      reasoned_turn(label, first, 0, [
        assistant([
          message.AssistantThinking(thought(first + 1), None, False),
          message.AssistantText("answer " <> label, None),
        ]),
      ])
    })
  let live = case running {
    Some(_) -> reasoned_turn("running", complete * 2 + 1, 0, [])
    None -> []
  }
  capture_of(list.append(done, live), running, [], [])
}

// One turn: its question, its thinking steps and then `ending`, which is the
// answer for a complete turn and nothing for the turn still running.
fn reasoned_turn(
  label: String,
  first: Int,
  steps: Int,
  ending: List(message.AgentMessage),
) -> List(snapshot.Item) {
  let worked =
    list.flat_map(counted(steps), fn(step) {
      let seq = first + 2 * step - 1
      let call_id = "r" <> int.to_string(seq)
      [
        item(
          seq,
          10_000 + seq,
          assistant([
            message.AssistantThinking(thought(seq), None, False),
            call(
              call_id,
              "fs_read",
              json.Object([#("path", json.String("a.gleam"))]),
            ),
          ]),
        ),
        item(
          seq + 1,
          10_000 + seq + 1,
          result(call_id, "fs_read", json.Object([]), 10_000 + seq + 1),
        ),
      ]
    })
  let closing =
    list.index_map(ending, fn(body, index) {
      let seq = first + 2 * steps + 1 + index
      item(seq, 10_000 + seq, body)
    })
  list.flatten([
    [item(first, 10_000 + first, said("question " <> label, None))],
    worked,
    closing,
  ])
}

/// A capture of `main` holding one prompt of `text`, as the page's own person
/// sent it, and an answer. A long `text` is drawn shortened.
///
/// ## Examples
///
/// ```gleam
/// lane_fixture.prompted(string.repeat("word ", 500))
/// ```
pub fn prompted(text: String) -> session_channel.Update {
  capture_of(
    [
      item(1, 10_000, said(text, Some(message.Origin("alice", "Alice")))),
      item(2, 10_001, assistant([message.AssistantText("done", None)])),
    ],
    None,
    [],
    [],
  )
}
