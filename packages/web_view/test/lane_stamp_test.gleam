//// What the stream's gutter and the running turn's tool lines say that the
//// records give them: the time of each row, and `needs approval` on a call an
//// undecided approval holds.
////
//// The pieces are built by hand, since the tests need a running turn with one
//// call pending, and drawn through `lane.view` with the marks the page would
//// pass.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/set
import gleam/string
import lustre/element
import session_view/step_words
import session_view/turns
import web_view/view/lane
import web_view/view/phrase
import web_view/view/stamp

fn call(key: String, call: String, standing: turns.Standing) -> turns.Item {
  turns.Step(
    key:,
    call:,
    standing:,
    words: step_words.Words("Ran", step_words.Mono("make check"), None),
    detail: [],
    full: [],
    images: [],
    since: None,
    result_source: None,
    program: None,
  )
}

fn running(items: List(turns.Item)) -> turns.Piece {
  turns.Work(
    key: "work:1.0",
    worked: turns.Worked(None, 2, 0, 0, turns.Finished),
    items:,
    folding: turns.Open,
    id: None,
  )
}

fn drawn(pieces: List(turns.Piece), marks: lane.Marks) -> String {
  lane.view(
    pieces,
    [],
    lane.Beginning,
    Nil,
    lane.NoReplies,
    marks,
    lane.NoFolds,
    "",
  )
  |> element.to_string
}

pub fn a_call_held_by_an_approval_says_so_and_a_settled_one_does_not_test() {
  let pieces = [
    running([
      call("2.0/0", "call-a", turns.Pending),
      call("2.0/1", "call-b", turns.Pending),
      call("2.0/2", "call-a", turns.Done),
    ]),
  ]
  let marks = lane.Marks(..lane.no_marks(), holding: set.from_list(["call-a"]))
  let html = drawn(pieces, marks)

  // Only the pending call the approval names is tagged: not the pending call
  // of another id, and not a settled call that shares the id.
  assert string.split(html, "work-item approving") |> list.length == 2
  assert string.split(html, "class=\"work-item\"") |> list.length == 3
}

pub fn a_tool_line_carries_the_time_its_records_give_it_test() {
  let pieces = [
    running([
      call("2.0/0", "call-a", turns.Done),
      call("2.0/1", "call-b", turns.Pending),
    ]),
  ]
  let marks =
    lane.Marks(
      ..lane.no_marks(),
      times: dict.from_list([#("2.0/0", 1_790_030_460_000)]),
    )
  let html = drawn(pieces, marks)

  // The call with a time draws it; the one with none draws nothing, rather
  // than a time it was not given.
  assert string.contains(
    html,
    "<loom-time at=\"1790030460000\" class=\"tl-time\" title=\"22:41 UTC\">22:41</loom-time>",
  )
  assert string.split(html, "<loom-time") |> list.length == 2
}

// A time is never drawn with a sign in its digits: an instant before the epoch,
// which a monotonic or unset clock can produce, reads `00:00` through every
// function that draws a `<loom-time>`.
pub fn a_negative_instant_reads_as_the_epoch_test() {
  assert stamp.utc(-5) == "00:00"
  assert stamp.utc(-90_000_000) == "00:00"
  assert element.to_string(phrase.clock(-60_000))
    == "<loom-time at=\"-60000\" title=\"00:00 UTC\">00:00</loom-time>"
}
