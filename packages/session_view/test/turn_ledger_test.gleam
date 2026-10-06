//// A closed turn is kept as what a page draws of it, and the records it was
//// drawn from are dropped.
////
//// These tests close the turns of a conversation in which every turn reads a
//// file per step, and read what the summary holds: the pieces of the turn with
//// its fold closed, the figures of its divider, where its records lie so they
//// can be read again, and when a scan has read enough of a stretch to close
//// it.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import session_view/fold_budget
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript
import session_view/turn_ledger
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

fn strands() -> List(protocol.Strand) {
  [protocol.Strand("main", None, None)]
}

// The records of a conversation whose turns each read a file per step, oldest
// first: a question, a call and its result for each step, and an answer.
fn reading(steps: List(Int)) -> List(snapshot.Item) {
  let #(_, items) =
    list.fold(steps, #(1, []), fn(acc, count) {
      let #(seq, items) = acc
      let turn = int.to_string(seq)
      let reads =
        list.flat_map(
          int.range(from: count, to: 0, with: [], run: fn(all, n) { [n, ..all] }),
          fn(step) {
            let name = "r" <> turn <> "-" <> int.to_string(step)
            let at = seq + 2 * step - 1
            [
              item(
                at,
                10_000 + at * 10,
                assistant([
                  message.AssistantToolCall(message.ToolCall(
                    name,
                    "fs_read",
                    json.Object([#("path", json.String("notes/" <> name))]),
                    None,
                    None,
                  )),
                ]),
              ),
              item(
                at + 1,
                10_000 + { at + 1 } * 10,
                message.ToolResultMessage(
                  name,
                  "fs_read",
                  [message.ToolResultText("ok", None)],
                  Some(json.Object([])),
                  None,
                  None,
                  False,
                  10_000 + { at + 1 } * 10,
                ),
              ),
            ]
          },
        )
      let last = seq + 2 * count + 1
      #(
        last + 1,
        list.flatten([
          items,
          [
            item(
              seq,
              10_000 + seq * 10,
              message.UserMessage(
                [message.UserText("question " <> turn, None)],
                0,
                None,
              ),
            ),
          ],
          reads,
          [
            item(
              last,
              10_000 + last * 10,
              assistant([message.AssistantText("answer " <> turn, None)]),
            ),
          ],
        ]),
      )
    })
  items
}

fn view(leaf: Int) -> snapshot_view.View {
  snapshot_view.View(
    strands(),
    dict.from_list([#("main", Some(id(leaf)))]),
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
    snapshot.Window(list.reverse(items), list.length(items) * 100, None),
    None,
  )
}

// What a page holds of the records `items` (oldest first): their blocks, as
// `turns.grouped` cuts them, and the records of the strand, newest first.
fn held(items: List(snapshot.Item)) {
  let newest =
    list.fold(items, 0, fn(seq, held) { int.max(seq, snapshot.sequence(held)) })
  let current = view(newest)
  let captured = cut(items)
  let branch = snapshot_view.branch(current, captured.window, "main")
  let blocks = transcript.branch_blocks(branch, captured, current, "main", [])
  let records = branch.records
  let #(lead, opened) = turns.grouped(blocks, strands())
  #(blocks, records, lead, opened)
}

fn closed(items: List(snapshot.Item)) -> List(turn_ledger.Sealed) {
  let #(_, records, lead, opened) = held(items)
  let groups = case lead {
    [] -> opened
    [_, ..] -> [lead, ..opened]
  }
  turn_ledger.seal_all(groups, [], records, strands())
}

fn divider_of(sealed: turn_ledger.Sealed) -> String {
  let assert Ok(turns.Work(worked:, ..)) =
    list.find(sealed.pieces, fn(piece) {
      case piece {
        turns.Work(..) -> True
        turns.Plain(..)
        | turns.Prompt(..)
        | turns.Spawned(..)
        | turns.Returned(..)
        | turns.Nudged(..)
        | turns.Commentary(..)
        | turns.Peer(..)
        | turns.Sibling(..)
        | turns.Missed(..)
        | turns.Decided(..) -> False
      }
    })
  turns.divider(worked)
}

// A closed turn is its prompt, its divider and its answer, whatever it did.
// The divider counts every call of the turn and holds none of them, and the
// turn's records are named by where they start and end.
pub fn a_closed_turn_is_its_prompt_its_divider_and_its_answer_test() {
  let sealed = closed(reading([3, 110, 2]))
  let assert [first, second, third] = sealed
  assert list.length(second.pieces) == 3
  let assert [
    turns.Plain(..),
    turns.Work(items: [], folding: turns.Folded, ..),
    turns.Plain(..),
  ] = second.pieces
  assert divider_of(first) == "Worked <1s · 3 steps"
  assert divider_of(second) == "Worked 2s · 110 steps"
  assert divider_of(third) == "Worked <1s · 2 steps"
  assert first.first_seq == 1
  assert first.parent == None
  assert second.first_seq == 9
  assert third.end.seq == 236
}

// Each turn ends at the record its successor has as its parent, which is how a
// read of the turns below one starts from the right record, and a turn that is
// followed by nothing ends at the newest record.
pub fn a_turn_ends_where_the_next_one_begins_test() {
  let assert [first, second, third] = closed(reading([3, 4, 5]))
  assert second.parent == Some(first.end.id)
  assert third.parent == Some(second.end.id)
  assert first.end.seq + 1 == second.first_seq
  assert second.end.seq + 1 == third.first_seq
  assert third.end.seq == 30
  assert second.end.seq == 18
}

// A turn closed while the turn after it stays open ends where that one begins,
// not at the newest record the window holds: the open turn's records are not
// the closed turn's, and a page that trimmed to the wrong end would lose them.
pub fn a_turn_closed_beside_an_open_one_ends_before_it_test() {
  let #(_, records, _, opened) = held(reading([3, 4]))
  let assert [first, second] = opened
  let assert [sealed] =
    turn_ledger.seal_all([first], [second], records, strands())
  assert sealed.end.seq == 8
  let assert [alone] = turn_ledger.seal_all([first], [], records, strands())
  assert alone.end.seq == 18
}

// The rows a closed turn's fold may add are capped at what a read of the fold
// keeps, since that is the most the page ever holds of it.
pub fn a_folds_weight_is_capped_at_what_a_read_keeps_test() {
  let assert [long] = closed(reading([400]))
  assert long.weight.base == 3
  let assert Some(fold) = long.weight.fold
  assert fold.rows == fold_budget.fold_rows
  assert turn_ledger.fold_id(long) == Some(fold.id)
  assert turn_ledger.worked_steps(long) == 400
}

// A turn that folds no work has no fold to name and no steps to count.
pub fn a_turn_with_no_work_has_no_fold_test() {
  let assert [answered] = closed(reading([0]))
  assert turn_ledger.fold_id(answered) == None
  assert turn_ledger.worked_steps(answered) == 0
}

// A scan that has found only the end of a turn, and can be asked for more, has
// closed nothing: a turn is whole once its input is among the records.
pub fn a_stretch_without_enough_turns_is_not_closed_while_more_can_be_read_test() {
  let items = reading([3, 3, 3])
  let tail = list.filter(items, fn(held) { snapshot.sequence(held) >= 12 })
  let #(blocks, records, _, _) = held(tail)
  assert turn_ledger.older(blocks, records, strands(), 10, turn_ledger.Readable)
    == Error(Nil)
}

// Enough whole turns close the stretch, and the blocks before the first input
// are left for the next read.
pub fn a_stretch_with_enough_whole_turns_closes_them_test() {
  let items = reading([3, 3, 3, 3])
  let tail = list.filter(items, fn(held) { snapshot.sequence(held) >= 12 })
  let #(blocks, records, lead, _) = held(tail)
  assert lead != []
  let assert Ok(found) =
    turn_ledger.older(blocks, records, strands(), 2, turn_ledger.Readable)
  assert list.length(found) == 2
  assert list.map(found, fn(turn) { turn.first_seq }) == [17, 25]
}

// When nothing more can be read, the blocks before the first input close as a
// turn of their own, keyed by the start of the window, so the strand's start or
// a bound ends a read and not the page.
pub fn a_stretch_that_cannot_be_read_further_closes_what_it_has_test() {
  let items = reading([3, 3])
  let tail = list.filter(items, fn(held) { snapshot.sequence(held) >= 4 })
  let #(blocks, records, _, _) = held(tail)
  let assert Ok(found) =
    turn_ledger.older(blocks, records, strands(), 10, turn_ledger.Exhausted)
  let assert [headless, whole] = found
  assert headless.first_seq == 4
  assert whole.first_seq == 9
  let assert Ok(turns.Work(key:, ..)) =
    list.find(headless.pieces, fn(piece) {
      case piece {
        turns.Work(..) -> True
        _ -> False
      }
    })
  assert key == "work:4.0"
}

// The turn a window held only the end of is closed once the scan has reached
// its input, and only that turn: the turns below it are the host's to read when
// the reader asks.
pub fn a_turn_a_window_began_inside_is_closed_when_its_input_arrives_test() {
  let items = reading([3, 3, 3])
  let tail = list.filter(items, fn(held) { snapshot.sequence(held) >= 20 })
  let #(blocks, records, _, _) = held(tail)
  assert turn_ledger.completed(blocks, records, strands(), turn_ledger.Readable)
    == Error(Nil)
  let reached = list.filter(items, fn(held) { snapshot.sequence(held) >= 9 })
  let #(blocks, records, _, _) = held(reached)
  let assert Ok(turn_ledger.Whole([whole])) =
    turn_ledger.completed(blocks, records, strands(), turn_ledger.Readable)
  assert whole.first_seq == 17
  assert divider_of(whole) == "Worked <1s · 3 steps"
}

// The steps of a fold read are the newest that fit what a page draws of one
// fold, and what the read left out is counted. A read that reached the turn's
// input has them all; one that stopped early says how many it did not reach.
pub fn the_steps_of_a_fold_are_the_newest_that_fit_test() {
  let items = reading([150])
  let #(blocks, _, _, _) = held(items)
  let assert Ok(whole) =
    turn_ledger.steps(blocks, strands(), turns.Skip, 150, turn_ledger.Readable)
  assert fold_budget.item_rows(whole.items) <= fold_budget.fold_rows
  assert whole.unread > 0
  assert list.length(whole.items) + whole.unread == 150

  // Only the end of the turn has been read, and it already fills a fold.
  let end = list.filter(items, fn(held) { snapshot.sequence(held) > 100 })
  let #(partial, _, _, _) = held(end)
  let assert Ok(early) =
    turn_ledger.steps(partial, strands(), turns.Skip, 150, turn_ledger.Readable)
  assert fold_budget.item_rows(early.items) <= fold_budget.fold_rows

  // A result whose call the read did not reach is not drawn, so the steps
  // drawn and the steps the read did not reach are the turn's, exactly.
  assert list.length(early.items) + early.unread == 150
}

// A model that makes its calls in one message and gets the results as many
// records: one question, then for each size one message of that many calls and
// that many results, and an answer.
fn batched(sizes: List(Int)) -> List(snapshot.Item) {
  let question =
    item(
      1,
      10_010,
      message.UserMessage([message.UserText("question", None)], 0, None),
    )
  let #(seq, batches) =
    list.fold(sizes, #(2, []), fn(acc, size) {
      let #(seq, held) = acc
      let names =
        int.range(from: size, to: 0, with: [], run: fn(all, n) { [n, ..all] })
        |> list.map(fn(n) {
          "b" <> int.to_string(seq) <> "-" <> int.to_string(n)
        })
      let calls =
        item(
          seq,
          10_000 + seq * 10,
          assistant(
            list.map(names, fn(name) {
              message.AssistantToolCall(message.ToolCall(
                name,
                "fs_read",
                json.Object([#("path", json.String("notes/" <> name))]),
                None,
                None,
              ))
            }),
          ),
        )
      let results =
        list.index_map(names, fn(name, index) {
          let at = seq + 1 + index
          item(
            at,
            10_000 + at * 10,
            message.ToolResultMessage(
              name,
              "fs_read",
              [message.ToolResultText("ok", None)],
              Some(json.Object([])),
              None,
              None,
              False,
              10_000 + at * 10,
            ),
          )
        })
      #(seq + 1 + size, list.append(held, [calls, ..results]))
    })
  list.flatten([
    [question],
    batches,
    [
      item(
        seq,
        10_000 + seq * 10,
        assistant([message.AssistantText("answer", None)]),
      ),
    ],
  ])
}

// The read that fills a fold stops between a batch's calls and its results.
// Those results name no call, so none is drawn, and what the page says it does
// not show is the divider's count of steps less the steps it draws.
pub fn a_read_cut_inside_a_batch_draws_no_result_without_its_call_test() {
  let items = batched([60, 110])
  let assert [sealed] = closed(items)
  let worked = turn_ledger.worked_steps(sealed)
  assert worked == 170

  // Batch one's calls are record 2 and its results 3 to 62; the window holds
  // the last twenty of those results and all of batch two, a hundred and ten
  // calls.
  let end = list.filter(items, fn(held) { snapshot.sequence(held) >= 43 })
  let #(blocks, _, _, _) = held(end)
  let assert Ok(steps) =
    turn_ledger.steps(
      blocks,
      strands(),
      turns.Skip,
      worked,
      turn_ledger.Readable,
    )
  assert steps.items != []
  assert list.all(steps.items, fn(step) {
    case step {
      turns.Step(..) -> True
      turns.Narrated(..) | turns.Memory(..) -> False
    }
  })
  assert fold_budget.item_rows(steps.items) <= fold_budget.fold_rows
  assert list.length(steps.items) + steps.unread == worked
}

// A read that holds only results has drawn nothing yet: it asks for more, or,
// with nothing more to read, draws no step and says every step is not shown.
pub fn a_read_of_results_alone_draws_nothing_test() {
  let items = batched([60, 110])
  let results =
    list.filter(items, fn(held) {
      snapshot.sequence(held) >= 43 && snapshot.sequence(held) <= 62
    })
  let #(blocks, _, _, _) = held(results)
  assert turn_ledger.steps(
      blocks,
      strands(),
      turns.Skip,
      170,
      turn_ledger.Readable,
    )
    == Error(Nil)
  let assert Ok(steps) =
    turn_ledger.steps(blocks, strands(), turns.Skip, 170, turn_ledger.Exhausted)
  assert steps.items == []
  assert steps.unread == 170
}

// A read that has not filled a fold and has not reached the turn's input needs
// more, unless nothing more can be read.
pub fn a_read_that_holds_too_little_asks_for_more_test() {
  let items = reading([150])
  let end = list.filter(items, fn(held) { snapshot.sequence(held) > 280 })
  let #(blocks, _, _, _) = held(end)
  assert turn_ledger.steps(
      blocks,
      strands(),
      turns.Skip,
      150,
      turn_ledger.Readable,
    )
    == Error(Nil)
  let assert Ok(steps) =
    turn_ledger.steps(blocks, strands(), turns.Skip, 150, turn_ledger.Exhausted)
  assert steps.unread >= 139
}

// The turn's own sequence of the newest tool result, which tells a host to read
// the workspace again.
pub fn the_newest_tool_result_is_the_closed_turns_to_report_test() {
  let assert [first, second] = closed(reading([3, 3]))
  assert first.latest_result == first.end.seq - 1
  assert second.latest_result == second.end.seq - 1
}

// A scan that cannot be read further and has not reached the turn's input
// closes nothing: what it holds is not a turn, and the host is told so and not
// handed a turn whose parent is a record in the middle of another.
pub fn a_scan_that_never_reaches_the_input_closes_nothing_test() {
  let items = reading([3, 3])
  let end = list.filter(items, fn(held) { snapshot.sequence(held) >= 12 })
  let end = list.filter(end, fn(held) { snapshot.sequence(held) <= 16 })
  let #(blocks, records, _, opened) = held(end)
  assert opened == []
  assert turn_ledger.completed(
      blocks,
      records,
      strands(),
      turn_ledger.Exhausted,
    )
    == Ok(turn_ledger.Partial)
}

// Two turns the window began inside are keyed by their first records, not both
// by the window's start, so a page holding two of them has no duplicate key.
pub fn a_closed_lead_is_keyed_by_its_first_record_test() {
  let items = reading([3, 3, 3])
  let tail = list.filter(items, fn(held) { snapshot.sequence(held) >= 12 })
  let #(_, records, lead, _) = held(tail)
  let assert [one] = turn_ledger.seal_all([lead], [], records, strands())
  let keys =
    list.filter_map(one.pieces, fn(piece) {
      case piece {
        turns.Work(key:, ..) -> Ok(key)
        _ -> Error(Nil)
      }
    })
  assert keys == ["work:12.0"]
}

// A summary says how many bytes of text it holds, so a host can hold closed
// turns to a budget of them beside its rows: a long prompt is one row and many
// bytes.
pub fn a_summary_counts_the_bytes_of_its_text_test() {
  let small = closed(reading([2]))
  let assert [turn] = small
  assert turn.bytes > 0
  assert turn.bytes < 200
}
