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
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript_lines

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
  let items = list.take(items(), count)
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
    |> list.append(extra)
  let view =
    snapshot_view.View(
      strands,
      dict.from_list([#("main", Some(id(list.length(items))))]),
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
        "tab",
        message.Origin("alice", "Alice"),
        snapshot.Operator,
      ),
      list.length(items) + 1,
      json.Null,
      snapshot.Window(items, list.length(items) * 100, None),
      None,
    )
  session_channel.Captured(cut, view, session_channel.Refreshed)
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

fn int_cost(tokens: Int, rate: Float) -> Float {
  case tokens {
    0 -> 0.0
    _ -> rate *. int.to_float(tokens)
  }
}
