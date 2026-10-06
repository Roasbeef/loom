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
import gleam/string
import session_view/composer
import session_view/decisions
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/step_words
import session_view/strand_framing
import session_view/transcript
import session_view/transcript_image
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
  |> turns.pieces(strands(), latest, turns.Skip)
}

fn shape(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block, _, _) ->
      case block.rows {
        [#(_, line), ..] -> "plain:" <> line.text
        [] -> "plain"
      }
    turns.Prompt(block:, name:, ..) ->
      case block.rows {
        [#(_, line), ..] -> "prompt:" <> name <> ":" <> line.text
        [] -> "prompt:" <> name
      }
    turns.Work(folding: turns.Folded, ..) -> "work:folded"
    turns.Work(folding: turns.Open, ..) -> "work:open"
    turns.Spawned(child:, ..) -> "spawn:" <> option.unwrap(child, "?")
    turns.Returned(child:, ..) -> "returned:" <> child
    turns.Nudged(..) -> "nudge"
    turns.Peer(session:, ..) -> "peer:" <> session
    turns.Sibling(strand:, ..) -> "sibling:" <> strand
    turns.Missed(..) -> "missed"
    turns.Decided(..) -> "decided"
    turns.Commentary(..) -> "commentary"
  }
}

pub fn a_settled_turn_folds_its_work_behind_one_divider_test() {
  let laid = pieces([])
  assert list.map(laid, shape)
    == [
      "prompt:Alice:review the patch",
      "work:folded",
      "spawn:" <> child,
      "returned:" <> child,
      "plain:Done: two files.",
      "peer:lint-census",
      "nudge",
    ]
  let assert [_, turns.Work(worked:, items:, ..), ..] = laid
  assert worked
    == turns.Worked(duration_ms: Some(48_000), steps: 3, files: 2, failed: 0)
  assert turns.divider(worked) == "Worked 48s · 3 steps · 2 files"

  // The response's reasoning and its two edits, each joined to its result,
  // and the wait are under the divider; the spawn and the child's result
  // are not, and the edits' results are not drawn a second time.
  assert list.length(items) == 4
  let assert [
    turns.Narrated(_, _, _),
    turns.Step(words: edit, standing:, ..),
    ..
  ] = items
  assert step_words.text(edit) == "Edit a.gleam"
  assert standing == turns.Done
}

// A failed call is counted on the divider, so a folded turn says it went
// wrong before anyone opens it.
pub fn the_divider_counts_failed_calls_test() {
  assert turns.divider(turns.Worked(Some(48_000), 4, 2, 1))
    == "Worked 48s · 4 steps · 2 files · 1 failed"
  assert turns.divider(turns.Worked(None, 2, 0, 0)) == "Worked · 2 steps"
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
        turns.Plain(block, _, _)
        | turns.Prompt(block:, ..)
        | turns.Commentary(block:, ..) -> block.key
        turns.Work(key:, ..)
        | turns.Spawned(key:, ..)
        | turns.Returned(key:, ..)
        | turns.Nudged(key:, ..)
        | turns.Peer(key:, ..)
        | turns.Sibling(key:, ..)
        | turns.Missed(key:, ..)
        | turns.Decided(key:, ..) -> key
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
    |> turns.pieces(strands(), turns.Settled, turns.Skip)
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
      "prompt:Alice:review the patch",
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

// --- expanding a row ---------------------------------------------------------

// The pieces of one turn (a prompt, a response holding `parts`, the result
// of its call `c` if any, and an answer), built with `expansion`.
fn expanding(
  parts: List(message.AssistantBlock),
  outcome: Option(message.AgentMessage),
  expansion: turns.Expansion,
) -> List(turns.Piece) {
  let bodies =
    list.flatten([
      [said("run it", None), assistant(parts)],
      case outcome {
        Some(result) -> [result]
        None -> []
      },
      [assistant([message.AssistantText("Ran it.", None)])],
    ])
  let items =
    list.index_map(bodies, fn(body, index) {
      item(index + 1, 10_000 + index * 1000, body)
    })
  transcript.blocks(cut(items), view(list.length(items), []), "main", [])
  |> turns.pieces(strands(), turns.Settled, expansion)
}

fn whole() -> turns.Expansion {
  turns.Expand(fn(lines) { lines })
}

fn text_result(text: String) -> message.AgentMessage {
  message.ToolResultMessage(
    "c",
    "code_mode",
    [message.ToolResultText(text, None)],
    Some(json.Object([])),
    None,
    None,
    False,
    12_000,
  )
}

fn work_items(pieces: List(turns.Piece)) -> List(turns.Item) {
  let assert [_, turns.Work(items:, ..), ..] = pieces
    as "a prompt, then the turn's work"
  items
}

pub fn a_settled_code_mode_call_expands_to_its_program_and_output_test() {
  let program =
    "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5\nlet f = 6\nlet g = 7"
  let pieces =
    expanding(
      [
        call(
          "c",
          "code_mode",
          json.Object([#("program", json.String(program))]),
        ),
      ],
      Some(text_result("all done")),
      whole(),
    )
  let assert [turns.Step(full:, ..)] = work_items(pieces)

  // The whole program is there, where the compact rows dropped it on
  // success, and the result follows it.
  assert list.any(full, fn(line) {
    line.speaker == transcript_line.ToolDetail
    && string.contains(line.text, "let g = 7")
    && !string.contains(line.text, "// …")
  })
  assert list.any(full, fn(line) { string.contains(line.text, "all done") })
}

pub fn the_hosts_cap_cuts_what_the_piece_holds_test() {
  let pieces =
    expanding(
      [
        call(
          "c",
          "code_mode",
          json.Object([#("program", json.String("a\nb\nc"))]),
        ),
      ],
      Some(text_result("out")),
      turns.Expand(fn(lines) { list.take(lines, 1) }),
    )
  let assert [turns.Step(full:, ..)] = work_items(pieces)
  assert list.length(full) == 1
}

pub fn a_host_that_skips_gets_no_expansion_test() {
  let pieces =
    expanding(
      [
        call("c", "code_mode", json.Object([#("program", json.String("a\nb"))])),
      ],
      Some(text_result("out")),
      turns.Skip,
    )
  let assert [turns.Step(full:, ..)] = work_items(pieces)
  assert full == []
}

pub fn a_long_bash_command_is_shown_whole_when_expanded_test() {
  let command = string.repeat("echo hello; ", 20) <> "echo the-end"
  let pieces =
    expanding(
      [call("c", "bash", json.Object([#("command", json.String(command))]))],
      None,
      whole(),
    )
  let assert [turns.Step(full:, ..)] = work_items(pieces)
  assert list.any(full, fn(line) { string.contains(line.text, "the-end") })
}

pub fn a_call_with_nothing_more_to_show_has_no_expansion_test() {
  let pieces =
    expanding(
      [call("c", "bash", json.Object([#("command", json.String("ls"))]))],
      None,
      whole(),
    )
  let assert [turns.Step(full:, ..)] = work_items(pieces)
  assert full == []
}

pub fn only_the_reasoning_row_of_a_response_expands_test() {
  let pieces =
    expanding(
      [
        message.AssistantThinking("first\nsecond\nthird", None, False),
        message.AssistantText("Ran it, twice.", None),
      ],
      None,
      whole(),
    )
  let assert [
    _,
    turns.Work(items: [turns.Narrated(block:, thoughts:, ..)], ..),
    ..
  ] = pieces
    as "the reasoning is work, the answer stays outside"
  let assert [#(key, _)] = dict.to_list(thoughts)
  assert list.key_find(block.rows, key)
    == Ok(transcript_line.Line(transcript_line.ReasoningDigest, "first"))
  assert dict.get(thoughts, key)
    == Ok([
      transcript_line.Line(transcript_line.Reasoning, "first\nsecond\nthird"),
    ])
}

pub fn reasoning_that_is_one_line_has_nothing_more_to_show_test() {
  let pieces =
    expanding([message.AssistantThinking("short", None, False)], None, whole())
  let assert [_, turns.Work(items: [turns.Narrated(thoughts:, ..)], ..), ..] =
    pieces
    as "the reasoning is work"
  assert dict.is_empty(thoughts)
}

// --- images --------------------------------------------------------------

fn user_with_images() -> message.AgentMessage {
  message.UserMessage(
    [
      message.UserText("what is this", None),
      message.UserImage("AAAA", "image/png"),
      message.UserImage("BBBB", "image/jpeg"),
    ],
    0,
    None,
  )
}

fn image_result(data: String) -> message.AgentMessage {
  message.ToolResultMessage(
    "c",
    "read",
    [message.ToolResultImage(data, "image/webp")],
    None,
    None,
    None,
    False,
    12_000,
  )
}

pub fn a_message_with_images_is_a_pictured_row_test() {
  let lane =
    pieces_of(
      [
        item(1, 1000, user_with_images()),
        item(2, 2000, assistant([message.AssistantText("A photo.", None)])),
      ],
      [],
    )

  // The image rows stay text rows, and the pictures are alongside them,
  // named by the block's key and their place in the message.
  assert turns.pictured(lane)
    == [
      #("1.0", [
        transcript_image.Image("image/png", "AAAA"),
        transcript_image.Image("image/jpeg", "BBBB"),
      ]),
    ]
  assert turns.picture(lane, "1.0", 1)
    == Ok(transcript_image.Image("image/jpeg", "BBBB"))
}

pub fn a_result_image_belongs_to_its_step_test() {
  let lane =
    expanding(
      [call("c", "read", json.Object([#("path", json.String("a.png"))]))],
      Some(image_result("CCCC")),
      turns.Skip,
    )
  let assert [turns.Step(key:, images:, ..)] = work_items(lane)
  assert images == [transcript_image.Image("image/webp", "CCCC")]

  // The step's key is `block/index`, whose slash a path cannot carry.
  assert string.contains(key, "/")
  assert turns.pictured(lane) == [#(transcript_image.ref(key), images)]
  assert turns.picture(lane, transcript_image.ref(key), 0)
    == Ok(transcript_image.Image("image/webp", "CCCC"))
}

pub fn a_call_with_no_result_or_a_text_result_has_no_pictures_test() {
  let asked = call("c", "read", json.Object([]))
  assert turns.pictured(expanding([asked], None, turns.Skip)) == []
  assert turns.pictured(expanding([asked], Some(text_result("hi")), turns.Skip))
    == []
}

pub fn a_lookup_finds_only_a_row_the_lane_holds_test() {
  let lane = pieces_of([item(1, 1000, user_with_images())], [])
  assert turns.picture(lane, "9.0", 0) == Error(Nil)
  assert turns.picture(lane, "1.0", 2) == Error(Nil)
  assert turns.picture(lane, "1.0", -1) == Error(Nil)
  assert turns.picture(lane, "", 0) == Error(Nil)
  assert turns.picture([], "1.0", 0) == Error(Nil)
}

fn sibling_text(strand: String) -> String {
  strand_framing.message_head(strand)
  <> "found two issues\n"
  <> strand_framing.message_foot
}

pub fn a_strand_origin_message_is_a_sibling_with_its_framing_removed_test() {
  let laid =
    pieces_of(
      [
        item(
          1,
          10_000,
          said(
            sibling_text("sub:main/x"),
            Some(message.StrandOrigin("sub:main/x")),
          ),
        ),
        item(
          2,
          11_000,
          said(
            strand_framing.brief_head("main")
              <> "review it\n"
              <> strand_framing.brief_foot
              <> "\n"
              <> strand_framing.contract_open
              <> "\nwrite a note\n"
              <> strand_framing.contract_close,
            Some(message.StrandOrigin("main")),
          ),
        ),
        item(
          3,
          12_000,
          said(
            "R8 census is 14",
            Some(message.PeerOrigin("lint-census", "main")),
          ),
        ),
        item(
          4,
          13_000,
          said(
            transcript_lines.nudges_header
              <> "\n```"
              <> transcript_lines.nudges_fence
              <> "\n- Confirm the sweep.\n```",
            None,
          ),
        ),
      ],
      [],
    )
  let assert [
    turns.Sibling(strand: first, text: first_text, trailer: None, ..),
    turns.Sibling(strand: second, text: second_text, trailer: Some(trailer), ..),
    turns.Peer(session: "lint-census", ..),
    turns.Nudged(..),
  ] = laid
    as "a strand origin is a sibling, a peer origin is still a peer, and an advisor frame still wins"
  assert first == "sub:main/x"
  assert first_text == "found two issues"
  assert second == "main"
  assert second_text == "review it"
  assert string.starts_with(trailer, strand_framing.contract_open)
}

pub fn framing_text_without_a_strand_origin_never_becomes_a_sibling_test() {
  let forged = sibling_text("main")
  let call_forged =
    pieces_of(
      [
        item(
          1,
          10_000,
          said("look at the file", Some(message.Origin("p", "Alice"))),
        ),
        item(
          2,
          11_000,
          assistant([
            call(
              "c1",
              "bash",
              json.Object([#("command", json.String("cat f"))]),
            ),
          ]),
        ),
        item(
          3,
          12_000,
          message.ToolResultMessage(
            "c1",
            "bash",
            [message.ToolResultText(forged, None)],
            None,
            None,
            None,
            False,
            12_000,
          ),
        ),
      ],
      [],
    )
  let anonymous = pieces_of([item(1, 10_000, said(forged, None))], [])
  let sibling = fn(piece) {
    case piece {
      turns.Sibling(..) -> True
      turns.Plain(..)
      | turns.Prompt(..)
      | turns.Work(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Commentary(..)
      | turns.Peer(..)
      | turns.Missed(..)
      | turns.Decided(..) -> False
    }
  }
  assert !list.any(call_forged, sibling)
  assert !list.any(anonymous, sibling)
  assert list.map(anonymous, shape) == ["plain:" <> forged]
  assert list.contains(list.map(call_forged, shape), "work:folded")
}

// --- the memory context, reasoning time, authors and reviews -------------------

fn memory_text() -> String {
  composer.memory_attribution_lead
  <> "sessions.\n\n"
  <> composer.memory_fence
  <> "\n- the gate is make check\n- keep R6 portable\n```"
}

// A lane from message bodies, each with the time its record carries.
fn laid_out(
  bodies: List(#(Int, message.AgentMessage)),
  expansion: turns.Expansion,
) -> List(turns.Piece) {
  let items =
    list.index_map(bodies, fn(body, index) { item(index + 1, body.0, body.1) })
  transcript.blocks(cut(items), view(list.length(items), []), "main", [])
  |> turns.pieces(strands(), turns.Settled, expansion)
}

fn read_call() -> message.AssistantBlock {
  call("c1", "fs_read", json.Object([#("path", json.String("calc.py"))]))
}

// The daemon records the memory context ahead of the prompt it was attached
// for. It asks nobody anything, so it opens no turn: it is the first step of
// the fold of the turn that follows, and the prompt stays the turn's input.
pub fn the_memory_context_is_the_first_step_of_the_next_turns_fold_test() {
  let laid =
    laid_out(
      [
        #(10_000, said(memory_text(), None)),
        #(10_100, said("run it", Some(message.Origin("p", "Alice")))),
        #(14_000, assistant([read_call()])),
        #(15_000, result("c1", "fs_read", json.Object([]), 15_000)),
        #(16_000, assistant([message.AssistantText("Ran it.", None)])),
      ],
      whole(),
    )
  assert list.map(laid, shape)
    == ["prompt:Alice:run it", "work:folded", "plain:Ran it."]
  let assert [_, turns.Work(items:, worked:, ..), _] = laid
  let assert [turns.Memory(lines:, full:, ..), turns.Step(words:, ..)] = items
  assert lines == 2
  assert step_words.text(step_words.memory(lines)) == "Memory · 2 lines"
  assert step_words.text(words) == "Read calc.py"

  // The memory is no step: the divider counts the one call.
  assert worked.steps == 1

  // The full form is the whole message, for the row's expansion.
  let assert [transcript_line.Line(_, shown)] = full
  assert string.contains(shown, "the gate is make check")
}

pub fn a_host_that_draws_no_expansion_still_gets_the_memory_count_test() {
  let laid =
    laid_out(
      [
        #(10_000, said(memory_text(), None)),
        #(10_100, said("run it", Some(message.Origin("p", "Alice")))),
        #(16_000, assistant([message.AssistantText("Ran it.", None)])),
      ],
      turns.Skip,
    )
  let assert [
    _,
    turns.Work(items: [turns.Memory(lines: 2, full: [], ..)], ..),
    _,
  ] = laid
}

// `grouped` cuts a paged window between turns, so the memory block that
// precedes a prompt belongs to the turn of that prompt, as `pieces` places it.
pub fn grouped_keeps_the_memory_block_with_the_prompt_it_precedes_test() {
  let items = [
    item(1, 10_000, said("first", Some(message.Origin("p", "Alice")))),
    item(2, 11_000, assistant([message.AssistantText("one", None)])),
    item(3, 12_000, said(memory_text(), None)),
    item(4, 12_100, said("second", Some(message.Origin("p", "Alice")))),
    item(5, 13_000, assistant([message.AssistantText("two", None)])),
  ]
  let blocks = transcript.blocks(cut(items), view(5, []), "main", [])
  let #(lead, opened) = turns.grouped(blocks, strands())
  assert lead == []
  assert list.map(opened, list.length) == [2, 3]
  assert list.flatten(opened) == blocks
}

pub fn a_reasoning_block_knows_how_long_its_response_took_test() {
  let laid =
    laid_out(
      [
        #(10_000, said("run it", Some(message.Origin("p", "Alice")))),
        #(
          14_000,
          assistant([
            message.AssistantThinking("plan it", None, False),
            read_call(),
          ]),
        ),
        #(15_000, result("c1", "fs_read", json.Object([]), 15_000)),
        #(16_500, assistant([message.AssistantText("Ran it.", None)])),
      ],
      whole(),
    )
  let assert [
    _,
    turns.Work(items: [turns.Narrated(took:, ..), ..], ..),
    turns.Plain(took: answered, ..),
  ] = laid
  assert took == Some(4000)
  assert step_words.text(step_words.reasoning(took)) == "Reasoning · 4s"

  // The answer's own time runs from the result before it.
  assert answered == Some(1500)
}

pub fn a_prompt_draws_its_sender_apart_from_its_words_test() {
  let laid =
    laid_out(
      [
        #(10_000, said("run it", Some(message.Origin("principal-1", "Alice")))),
        #(11_000, assistant([message.AssistantText("Ran it.", None)])),
      ],
      whole(),
    )
  let assert [turns.Prompt(block:, principal:, name:, role:), _] = laid
  assert principal == "principal-1"
  assert name == "Alice"
  assert role == None

  // The rows are the words alone: the `Alice:` the transcript puts before an
  // attributed message is the lane's who-line now.
  let assert [#(_, transcript_line.Line(transcript_line.User, text))] =
    block.rows
  assert text == "run it"

  // A sender's role is set on their own messages and no one else's, from
  // the roles their attachments hold. An observer's attachment is not one a
  // message was sent in, so the observer who is also the sender's page
  // gives no role, and an operator attachment gives `operator`.
  let roles =
    turns.authors([
      snapshot_view.Peer(
        "c1",
        message.Origin("principal-1", "Alice"),
        snapshot.Observer,
      ),
      snapshot_view.Peer(
        "c2",
        message.Origin("principal-1", "Alice"),
        snapshot.Operator,
      ),
      snapshot_view.Peer(
        "c3",
        message.Origin("principal-2", "Bob"),
        snapshot.Observer,
      ),
    ])
  let assert [turns.Prompt(role: mine, ..), _] = turns.attributed(laid, roles)
  assert mine == Some("operator")
  let assert [turns.Prompt(role: theirs, ..), _] =
    turns.attributed(
      laid,
      turns.authors([
        snapshot_view.Peer(
          "c3",
          message.Origin("principal-2", "Bob"),
          snapshot.Operator,
        ),
      ]),
    )
  assert theirs == None
}

// The author's role is the operator capacity when they hold it, else owner, and the
// viewer's own role never enters: a principal seen only as an observer
// authored nothing in that capacity.
pub fn an_authors_role_prefers_operator_to_owner_test() {
  let who = message.Origin("principal-1", "Alice")
  assert turns.authors([
      snapshot_view.Peer("c1", who, snapshot.Operator),
      snapshot_view.Peer("c2", who, snapshot.Owner),
      snapshot_view.Peer("c3", who, snapshot.Owner),
    ])
    == dict.from_list([#("principal-1", "operator")])
  assert turns.authors([snapshot_view.Peer("c1", who, snapshot.Owner)])
    == dict.from_list([#("principal-1", "owner")])
  assert turns.authors([snapshot_view.Peer("c1", who, snapshot.Observer)])
    == dict.new()
  assert turns.authors([
      snapshot_view.Peer(
        "c1",
        message.PeerOrigin("host", "p"),
        snapshot.Operator,
      ),
    ])
    == dict.new()
}

fn review(key: String) -> transcript_lines.Block {
  transcript_lines.Block(key, transcript_lines.FromAdvisor, [
    #(
      key <> ":0",
      transcript_line.Line(transcript_line.System, "Advisor · reviewed"),
    ),
  ])
}

// Two reviews with nothing between them say the same thing twice, so they
// are one piece that keeps the first review's key and counts both.
pub fn reviews_that_follow_each_other_are_one_piece_test() {
  let answer =
    transcript_lines.Block(
      "9.0",
      transcript_lines.FromEntry(entry.MessageEntry(
        id(9),
        None,
        9,
        0,
        assistant([message.AssistantText("ok", None)]),
        False,
      )),
      [#("9.0:0", transcript_line.Line(transcript_line.Assistant, "ok"))],
    )
  let laid =
    turns.pieces(
      [review("3.0"), review("4.0"), answer, review("10.0")],
      [],
      turns.Settled,
      turns.Skip,
    )
  let assert [
    turns.Commentary(block: first, reviews: 2),
    _,
    turns.Commentary(reviews: 1, ..),
  ] = laid
  assert first.key == "3.0"
}

// A recorded approval decision is placed by the sequence that committed it:
// before the first piece that starts after it, so it follows the step it
// decided. One older than the window's first record is dropped, and one
// newer than every piece goes last.
pub fn a_decision_line_is_placed_by_its_sequence_test() {
  let decide = fn(seq, verdict) {
    decisions.Decision(
      seq:,
      strand: "main",
      who: "Owner",
      verdict:,
      tool: "bash",
    )
  }
  let laid =
    pieces([])
    |> turns.with_decisions([
      decide(0, decisions.Denied),
      decide(5, decisions.Denied),
      decide(500, decisions.Allowed),
    ])
  assert list.map(laid, shape)
    == [
      "prompt:Alice:review the patch",
      "work:folded",
      "spawn:" <> child,
      "decided",
      "returned:" <> child,
      "plain:Done: two files.",
      "peer:lint-census",
      "nudge",
      "decided",
    ]
  let assert Ok(turns.Decided(decision:, ..)) =
    list.find(laid, fn(piece) {
      case piece {
        turns.Decided(..) -> True
        _ -> False
      }
    })
  assert decisions.words(decision) == "Owner denied bash"
}

// A turn's work folds behind one divider, and a decision raised inside that
// turn must not fold with it: it is a piece of its own, outside the Work, so
// the fold's items are the same with or without the decision.
pub fn a_decision_inside_a_folded_turn_stays_a_visible_row_test() {
  let bare = pieces([])
  let laid =
    turns.with_decisions(bare, [
      decisions.Decision(
        seq: 5,
        strand: "main",
        who: "Owner",
        verdict: decisions.Denied,
        tool: "bash",
      ),
    ])
  let assert [_, turns.Work(folding: turns.Folded, items: held, ..), after, ..] =
    laid
  let assert [_, turns.Work(items: bare_items, ..), ..] = bare
  assert held == bare_items
  assert shape(after) == "spawn:" <> child
  assert list.count(laid, fn(piece) { shape(piece) == "decided" }) == 1
}

pub fn no_decisions_leave_the_pieces_untouched_test() {
  assert turns.with_decisions(pieces([]), []) == pieces([])
}

fn failed_response(reason: String) -> message.AgentMessage {
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
    Some(reason),
    None,
    None,
    0,
  )
}

// A response that failed before it said anything is work with nothing to
// fold: its cause is a row of the lane, not a line behind a divider.
pub fn a_failed_turn_shows_its_cause_outside_the_fold_test() {
  let laid =
    laid_out(
      [
        #(10_000, said("run it", Some(message.Origin("p", "Alice")))),
        #(10_500, failed_response("secret KEY is not available")),
      ],
      whole(),
    )
  assert list.map(laid, shape)
    == ["prompt:Alice:run it", "plain:secret KEY is not available"]
}

// When the failing response also made calls, the calls fold and the cause
// still stands after the divider.
pub fn a_failure_after_work_stays_beside_the_divider_test() {
  let laid =
    laid_out(
      [
        #(10_000, said("run it", Some(message.Origin("p", "Alice")))),
        #(14_000, assistant([read_call()])),
        #(15_000, result("c1", "fs_read", json.Object([]), 15_000)),
        #(16_000, failed_response("the provider refused")),
      ],
      whole(),
    )
  assert list.map(laid, shape)
    == [
      "prompt:Alice:run it",
      "work:folded",
      "plain:the provider refused",
    ]
}

// A turn cut inside a long run of calls holds results whose calls are older
// than the window. Each is still one call, so the divider counts it and the
// figure grows as older rows are loaded.
pub fn results_whose_calls_are_cut_count_as_steps_test() {
  let laid =
    laid_out(
      [
        #(10_000, said("run it", Some(message.Origin("p", "Alice")))),
        #(15_000, result("c1", "fs_read", json.Object([]), 15_000)),
        #(16_000, result("c2", "fs_read", json.Object([]), 16_000)),
        #(17_000, assistant([message.AssistantText("Done.", None)])),
      ],
      whole(),
    )
  let assert [_, turns.Work(worked:, ..), _] = laid
  assert worked.steps == 2
  assert turns.divider(worked) == "Worked 7s · 2 steps"
}
