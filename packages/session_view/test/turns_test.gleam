//// `turns.pieces` lays one strand's lane out: an input, one divider for the
//// work that answered it, and the rows that never fold (a spawn, a child's
//// result, a delivered nudge, another session's message, a cache miss).
//// These tests build one capture holding each of them and check where each
//// lands, what the divider counts, and that a running turn stays open.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript
import session_view/transcript_line
import session_view/transcript_lines
import session_view/turns

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

fn strands() -> List(protocol.Strand) {
  [
    protocol.Strand("main", None, None),
    protocol.Strand("sub:main/review-1a2b3c", None, None),
    protocol.Strand("advisor", None, None),
  ]
}

fn view(leaf: Int, operations: List(#(String, String))) -> snapshot_view.View {
  snapshot_view.View(
    strands(),
    dict.from_list([#("main", Some(id(leaf)))]),
    dict.new(),
    dict.from_list(operations),
    usage(),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    None,
    None,
  )
}

fn cut(items: List(snapshot.Item)) -> snapshot.Captured {
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("session", "epoch", "incarnation"),
      "tab",
      message.Origin("principal-Alice", "Alice"),
      snapshot.Observer,
    ),
    list.length(items) + 1,
    json.Null,
    snapshot.Window(items, list.length(items) * 100, None),
    None,
  )
}

const child = "sub:main/review-1a2b3c"

// A turn that spawns a reviewer, edits two files, waits on the reviewer and
// answers; then a peer's message and a delivered nudge.
fn items() -> List(snapshot.Item) {
  [
    item(
      1,
      10_000,
      said("review the patch", Some(message.Origin("p", "Alice"))),
    ),
    item(
      2,
      11_000,
      assistant([
        message.AssistantThinking("plan it", None, False),
        call(
          "c1",
          "agent_spawn",
          json.Object([#("purpose", json.String("review <the> patch"))]),
        ),
        call("c2", "fs_edit", json.Object([#("path", json.String("a.gleam"))])),
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
                #("report", json.String("looks <fine>")),
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
      said("R8 census is 14", Some(message.PeerOrigin("lint-census", "main"))),
    ),
    item(
      10,
      61_000,
      said(
        transcript_lines.nudges_header
          <> "\n```"
          <> transcript_lines.nudges_fence
          <> "\n- Confirm the sweep excludes generated SQL.\n```",
        None,
      ),
    ),
  ]
}

fn pieces(operations: List(#(String, String))) -> List(turns.Piece) {
  pieces_of(items(), operations)
}

fn pieces_of(
  items: List(snapshot.Item),
  operations: List(#(String, String)),
) -> List(turns.Piece) {
  let cut = cut(items)
  let view = view(list.length(items), operations)
  let latest = case operations {
    [] -> turns.Settled
    _ -> turns.Running
  }
  transcript.blocks(cut, view, "main", [])
  |> turns.pieces(strands(), latest)
}

fn shape(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block) ->
      case block.rows {
        [#(_, line), ..] -> "plain:" <> line.text
        [] -> "plain"
      }
    turns.Work(folding: turns.Folded, ..) -> "work:folded"
    turns.Work(folding: turns.Open, ..) -> "work:open"
    turns.Spawned(child:, ..) -> "spawn:" <> option.unwrap(child, "?")
    turns.Returned(child:, ..) -> "returned:" <> child
    turns.Nudged(..) -> "nudge"
    turns.Peer(session:, ..) -> "peer:" <> session
    turns.Missed(..) -> "missed"
    turns.Commentary(..) -> "commentary"
  }
}

pub fn a_settled_turn_folds_its_work_behind_one_divider_test() {
  let laid = pieces([])
  assert list.map(laid, shape)
    == [
      "plain:Alice:\nreview the patch",
      "work:folded",
      "spawn:" <> child,
      "returned:" <> child,
      "plain:Done: two files.",
      "peer:lint-census",
      "nudge",
    ]
  let assert [_, turns.Work(worked:, items:, ..), ..] = laid
  assert worked == turns.Worked(duration_ms: Some(48_000), steps: 3, files: 2)
  assert turns.divider(worked) == "worked 48s · 3 steps · 2 files"

  // The response's reasoning and its two edits, each joined to its result,
  // and the wait are under the divider; the spawn and the child's result
  // are not, and the edits' results are not drawn a second time.
  assert list.length(items) == 4
  let assert [turns.Narrated(_), turns.Step(summary: edit, standing:, ..), ..] =
    items
  assert edit == "fs_edit · a.gleam"
  assert standing == turns.Done
}

pub fn a_running_turn_is_drawn_open_test() {
  // The strand is still working on the first turn: no later input yet.
  let laid = pieces_of(list.take(items(), 7), [#("main", "op-1")])
  assert list.contains(list.map(laid, shape), "work:open")
  assert !list.contains(list.map(laid, shape), "work:folded")
}

pub fn a_spawn_and_its_result_carry_the_childs_hue_test() {
  let laid = pieces([])
  let assert Ok(turns.Spawned(hue:, purpose:, ..)) =
    list.find(laid, fn(piece) {
      case piece {
        turns.Spawned(..) -> True
        _ -> False
      }
    })
  assert hue == turns.Sub(0)
  assert purpose == "review <the> patch"
  let assert Ok(turns.Returned(hue: returned, report:, outcome:, ..)) =
    list.find(laid, fn(piece) {
      case piece {
        turns.Returned(..) -> True
        _ -> False
      }
    })
  assert returned == turns.Sub(0)
  assert report == "looks <fine>"
  assert outcome == "completed"
}

pub fn a_peer_message_and_a_nudge_stay_outside_any_fold_test() {
  let laid = pieces([])
  let assert Ok(turns.Peer(strand:, text:, ..)) =
    list.find(laid, fn(piece) {
      case piece {
        turns.Peer(..) -> True
        _ -> False
      }
    })
  assert strand == "main"
  assert text == "R8 census is 14"
  let assert Ok(turns.Nudged(frame:, preview:, ..)) =
    list.find(laid, fn(piece) {
      case piece {
        turns.Nudged(..) -> True
        _ -> False
      }
    })
  assert frame == turns.Nudges
  assert preview == "- Confirm the sweep excludes generated SQL."
}

pub fn every_piece_keeps_its_key_when_the_turn_settles_test() {
  let keys = fn(laid: List(turns.Piece)) {
    list.map(laid, fn(piece) {
      case piece {
        turns.Plain(block) | turns.Commentary(block) -> block.key
        turns.Work(key:, ..)
        | turns.Spawned(key:, ..)
        | turns.Returned(key:, ..)
        | turns.Nudged(key:, ..)
        | turns.Peer(key:, ..)
        | turns.Missed(key:, ..) -> key
      }
    })
  }
  let running = list.take(items(), 8)
  assert keys(pieces_of(running, [#("main", "op-1")]))
    == keys(pieces_of(running, []))
}

pub fn a_cache_miss_is_its_own_row_test() {
  let notice =
    transcript_line.CacheNotice("main", id(8), "Cache miss after 12m idle")
  let laid =
    transcript.blocks(cut(items()), view(10, []), "main", [notice])
    |> turns.pieces(strands(), turns.Settled)
  let shapes = list.map(laid, shape)
  let assert [_, _, _, _, "plain:Done: two files.", "missed", ..] = shapes
}

// A delivered nudge starts a run the strand answers, so it opens a turn of
// its own: the answer to the person before it stays that turn's answer and
// is not folded away with the work.
pub fn a_delivered_nudge_opens_a_turn_of_its_own_test() {
  let answered =
    item(
      11,
      70_000,
      assistant([message.AssistantText("Checked the sweep.", None)]),
    )
  let laid = pieces_of(list.append(items(), [answered]), [])
  assert list.map(laid, shape)
    == [
      "plain:Alice:\nreview the patch",
      "work:folded",
      "spawn:" <> child,
      "returned:" <> child,
      "plain:Done: two files.",
      "peer:lint-census",
      "nudge",
      "plain:Checked the sweep.",
    ]
}

pub fn hues_follow_strand_position_test() {
  assert turns.hue(strands(), "main") == turns.Primary
  assert turns.hue(strands(), "advisor") == turns.Advisor
  assert turns.hue(strands(), child) == turns.Sub(0)
  assert turns.hue(strands(), "sub:elsewhere") == turns.Unplaced
}

// A wait preceded by reasoning makes its message a narrative, whose result
// arrives as a block of its own. The call side already draws the child's
// card from the joined result, so the result's block draws nothing more.
pub fn a_narrative_wait_draws_each_result_once_test() {
  let reasoned =
    list.map(items(), fn(listed) {
      case listed {
        snapshot.Loaded(entry.MessageEntry(seq: 6, ..), _) ->
          item(
            6,
            15_000,
            assistant([
              message.AssistantThinking("wait on the reviewer", None, False),
              call(
                "c4",
                "agent_wait",
                json.Object([#("handles", json.Array([json.String("h")]))]),
              ),
            ]),
          )
        _ -> listed
      }
    })
  let returned =
    pieces_of(reasoned, [])
    |> list.count(fn(piece) {
      case piece {
        turns.Returned(..) -> True
        _ -> False
      }
    })
  assert returned == 1
}

// `grouped` splits a lane where `pieces` splits it into turns: at every
// input. A window that holds the whole conversation has nothing before its
// first input; one that starts inside a turn has that turn's end as its
// lead. Either way the groups, put back together, are the blocks given.
pub fn grouped_splits_the_lane_at_its_inputs_test() {
  let whole = transcript.blocks(cut(items()), view(10, []), "main", [])
  let #(lead, opened) = turns.grouped(whole, strands())
  assert lead == []
  assert list.map(opened, list.length) == [list.length(whole) - 2, 1, 1]
  assert list.flatten(opened) == whole

  let inside =
    transcript.blocks(cut(list.drop(items(), 2)), view(10, []), "main", [])
  let #(lead, opened) = turns.grouped(inside, strands())
  assert lead != []
  assert list.length(opened) == 2
  assert list.append(lead, list.flatten(opened)) == inside
}
