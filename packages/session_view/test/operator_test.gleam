//// The operator's command arms: the frames a prompt, a steer and a decision
//// become, the rule that a decision names exactly the record it was drawn
//// from, and the bounded drain both hosts run.

import core/json
import gleam/option.{None}
import gleam/string
import session_view/approval
import session_view/operator
import session_view/session_channel
import session_view/snapshot

fn record(seq: Int, status: approval.Status) -> approval.Review {
  approval.Review(
    id: "esc-1",
    seq:,
    status:,
    tool: "bash",
    preview: "[\"ls\"]",
    origin: None,
    permission: approval.Exact("digest", [
      json.Object([#("kind", json.String("network"))]),
    ]),
  )
}

pub fn a_prompt_and_a_steer_are_their_own_frames_test() {
  let prompt = operator.frame(3, "main", "look", operator.Prompt)
  let steer = operator.frame(3, "main", "look", operator.Steer)
  assert string.contains(prompt, "\"cmd\":\"prompt\"")
  assert string.contains(steer, "\"cmd\":\"steer\"")
  assert string.contains(prompt, "\"strand\":\"main\"")
  assert string.contains(prompt, "\"text\":\"look\"")
}

pub fn a_decision_echoes_the_drawn_record_test() {
  let assert Ok(allowed) =
    operator.decision(1, record(12, approval.Pending), operator.AllowOnce)
  assert string.contains(allowed, "\"cmd\":\"approve\"")
  assert string.contains(allowed, "\"expected_seq\":12")
  assert string.contains(allowed, "\"action\":\"digest\"")
  let assert Ok(denied) =
    operator.decision(1, record(12, approval.Pending), operator.Deny)
  assert string.contains(denied, "\"cmd\":\"deny\"")
  assert string.contains(denied, "\"expected_seq\":12")
}

pub fn a_settled_record_cannot_be_approved_test() {
  assert operator.decision(1, record(12, approval.Approved), operator.AllowOnce)
    == Error("approval is no longer pending")
}

// A click names the record it was drawn from. Another sequence, another
// identity, or a record someone else already settled is not that record.
pub fn only_the_drawn_pending_record_is_found_test() {
  let pending = record(12, approval.Pending)
  let approvals = [pending]
  assert operator.drawn(approvals, "esc-1", 12) == Ok(pending)
  assert operator.drawn(approvals, "esc-1", 13) == Error(Nil)
  assert operator.drawn(approvals, "esc-2", 12) == Error(Nil)
  assert operator.drawn([record(12, approval.Rejected)], "esc-1", 12)
    == Error(Nil)
}

// A lane that has captured nothing has no authority to mutate with, so the
// arm's frame is refused by the lane rather than written.
pub fn the_lane_decides_whether_a_submission_is_sent_test() {
  let lane =
    session_channel.start(
      "socket",
      snapshot.Expected("session", "epoch", "incarnation"),
      now: 0,
    )
  let #(lane, _) = session_channel.take_outputs(lane)
  let #(lane, disposition) =
    operator.submit(lane, 1, "main", "look", operator.Prompt, 0)
  let assert session_channel.DefinitelyNotSent(_) = disposition
  let #(_, outputs) = session_channel.take_outputs(lane)
  assert outputs == []
}

// The drain takes oldest first and never more than its budget; what is past
// the budget stays held for the next drain.
pub fn the_drain_is_bounded_and_ordered_test() {
  let take = fn(state: #(List(Int), List(Int))) {
    case state.0 {
      [] -> #(state, Error(Nil))
      [next, ..rest] -> #(#(rest, state.1), Ok(next))
    }
  }
  let handle = fn(state: #(List(Int), List(Int)), message) {
    #(state.0, [message, ..state.1])
  }
  let #(left, seen) = operator.drain(#([1, 2, 3], []), 2, take, handle)
  assert seen == [2, 1]
  assert left == [3]
  let #(left, seen) = operator.drain(#([1], []), 5, take, handle)
  assert seen == [1]
  assert left == []
}
