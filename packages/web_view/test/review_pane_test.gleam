//// Which sessions are "To review", and the life of an open review thread
//// (`web_view/review_scan_rule`, `web_view/review_pane`).

import core/attention
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import web_view/review_feed.{Review, Stat}
import web_view/review_outbox_rule
import web_view/review_pane as pane
import web_view/review_scan_rule as scan
import web_view/review_stage_rule as stage
import web_view/thread_send

fn review(
  repository: review_feed.Repository,
  paths: List(String),
  omitted: Int,
) -> review_feed.Review {
  Review(
    observed_at_ms: 1,
    repository:,
    stat: Stat(files: list.length(paths), added: 1, removed: 0),
    files: list.map(paths, fn(path) {
      review_feed.File(
        path:,
        change: review_feed.Modified,
        section: review_feed.Source,
        content: review_feed.Text,
        added: 1,
        removed: 0,
        hunks: [],
        hunks_omitted: 0,
        extent: review_feed.Whole,
      )
    }),
    omitted:,
    extent: review_feed.Whole,
  )
}

pub fn only_a_checkout_with_something_in_it_has_changes_test() {
  assert scan.changes_in(review(review_feed.Head, ["a"], 0)) == scan.Changed
  assert scan.changes_in(review(review_feed.Unborn, ["a"], 0)) == scan.Changed
  assert scan.changes_in(review(review_feed.Head, [], 2)) == scan.Changed
  assert scan.changes_in(review(review_feed.Head, [], 0)) == scan.Unchanged
  assert scan.changes_in(review(review_feed.NotRepository, ["a"], 0))
    == scan.Unchanged
}

pub fn one_read_is_due_at_a_time_and_none_while_one_is_out_test() {
  let candidates = [#("a", "m1"), #("b", "m2")]
  assert scan.due(candidates, dict.new(), 0) == Some(#("a", "m1"))

  let out = scan.started(dict.new(), "a", "m1", 100)
  assert scan.due(candidates, out, 200) == None

  // A read that never answered stops holding the line after the stale bound.
  assert scan.due(candidates, out, 100 + scan.stale_ms) == Some(#("b", "m2"))
}

pub fn a_session_is_read_once_for_each_message_test() {
  let candidates = [#("a", "m1")]
  let seen =
    scan.answered(dict.new(), "a", "m1", Ok(review(review_feed.Head, ["x"], 0)))
  assert scan.due(candidates, seen, 0) == None
  assert scan.ready(candidates, seen) == ["a"]

  // A new message is read afresh and is not ready until it is.
  let said_more = [#("a", "m2")]
  assert scan.due(said_more, seen, 0) == Some(#("a", "m2"))
  assert scan.ready(said_more, seen) == []
}

// A verdict is the last successful read, and nothing after it removes it: not
// a read that is out, not a failure, not a refusal for the allowance.
pub fn a_verdict_survives_a_read_that_is_out_fails_or_is_refused_test() {
  let candidates = [#("a", "m1")]
  let seen =
    scan.answered(dict.new(), "a", "m1", Ok(review(review_feed.Head, ["x"], 0)))

  // The message moves on and a read starts: the new message is not ready, and
  // the old one coming back is, with no read in between.
  let reading = scan.started(seen, "a", "m2", 5)
  assert scan.ready([#("a", "m2")], reading) == []
  assert scan.ready(candidates, reading) == ["a"]

  // A refusal for the allowance leaves the verdict, and a failure does too.
  let refused = scan.answered(reading, "a", "m2", Error(scan.busy_words))
  assert scan.ready(candidates, refused) == ["a"]
  assert dict.size(refused) == 1
  let failed = scan.answered(reading, "a", "m2", Error("boom"))
  assert scan.ready(candidates, failed) == ["a"]

  // The message that came back is already known, so it is not read again.
  // The line is free by then, so the verdict is what says it is known.
  assert scan.due(candidates, reading, 5 + scan.stale_ms) == None

  // Only a read that answers replaces the verdict.
  let empty =
    scan.answered(reading, "a", "m1", Ok(review(review_feed.Head, [], 0)))
  assert scan.ready(candidates, empty) == []
}

// A read that keeps failing is tried `max_attempts` times and then left: the
// count survives each restart of the read.
pub fn a_read_that_keeps_failing_stops_at_the_bound_test() {
  let candidates = [#("a", "m")]
  let rounds = fn(seen, attempt) {
    assert scan.due(candidates, seen, 0) == Some(#("a", "m"))
    scan.answered(scan.started(seen, "a", "m", attempt), "a", "m", Error("no"))
  }
  let once = rounds(dict.new(), 1)
  let twice = rounds(once, 2)
  let thrice = rounds(twice, 3)
  assert scan.max_attempts == 3
  assert scan.due(candidates, thrice, 0) == None
}

pub fn a_refusal_for_a_session_never_read_leaves_it_unread_test() {
  let seen =
    scan.answered(
      scan.started(dict.new(), "a", "m1", 0),
      "a",
      "m1",
      Error(scan.busy_words),
    )
  assert dict.size(seen) == 0
}

pub fn a_clean_tree_is_not_ready_test() {
  let seen =
    scan.answered(dict.new(), "a", "m", Ok(review(review_feed.Head, [], 0)))
  assert scan.ready([#("a", "m")], seen) == []
}

pub fn failures_wait_for_unread_sessions_and_stop_at_the_bound_test() {
  let candidates = [#("a", "m"), #("b", "m")]
  let one = scan.answered(dict.new(), "a", "m", Error("busy"))
  assert scan.due(candidates, one, 0) == Some(#("b", "m"))

  let both = scan.answered(one, "b", "m", Error("busy"))
  let twice = scan.answered(both, "a", "m", Error("busy"))
  let thrice = scan.answered(twice, "a", "m", Error("busy"))
  assert scan.due([#("a", "m")], thrice, 0) == None
  assert scan.due(candidates, both, 0) == Some(#("a", "m"))
}

fn opened_with(paths: List(String)) -> pane.State {
  pane.loaded(
    pane.opened("s", "done"),
    "s",
    Ok(review(review_feed.Head, paths, 0)),
  )
}

pub fn a_read_for_another_session_is_dropped_test() {
  let state = pane.opened("s", "done")
  assert pane.loaded(state, "other", Ok(review(review_feed.Head, ["a"], 0)))
    == state
  assert pane.files(opened_with(["a", "b"])) == ["a", "b"]
}

pub fn a_find_cannot_be_staged_before_its_revision_is_read_test() {
  let state = pane.find_action(opened_with(["a"]), "f", attention.Fixed, "")
  assert state.problem != None
  assert state.staging == stage.empty()

  let read = pane.revision_read(state, "f", Ok(3))
  let staged = pane.find_action(read, "f", attention.Fixed, "ok")
  assert staged.problem == None
  assert list.map(staged.staging.finds, fn(each) { each.revision }) == [3]
}

pub fn a_send_applies_the_closes_and_then_delivers_the_prompt_test() {
  let state =
    opened_with(["a"])
    |> pane.revision_read("f1", Ok(3))
    |> pane.revision_read("f2", Ok(5))
    |> pane.find_action("f1", attention.Fixed, "")
    |> pane.find_action("f2", attention.Dismissed, "no")
    |> pane.comment("a", "wait")

  let #(sending, first) = pane.send(state)
  assert first == pane.CloseStep("f1", 3, attention.Fixed)

  let #(sending, second) =
    pane.closed_with(sending, "f1", attention.Fixed, pane.Done("Closed f1"))
  assert second == pane.CloseStep("f2", 5, attention.Dismissed)

  let #(sending, third) =
    pane.closed_with(sending, "f2", attention.Dismissed, pane.Done("Closed f2"))
  let assert pane.PromptStep(text) = third
  assert text
    == "I reviewed your changes.\n\nFile comments:\n\na:\nwait\n\nFinds I closed:\n\nf1: fixed.\nf2: dismissed. no"

  let settled =
    pane.prompted(sending, thread_send.Delivered(thread_send.Queued))
  assert settled.staging == stage.empty()
  let assert pane.Settled(receipt) = settled.progress
  assert pane.receipt_lines(receipt)
    == [
      "f1 (fixed): Closed f1",
      "f2 (dismissed): Closed f2",
      "Delivered to the session · queued",
    ]
}

pub fn a_refused_close_halts_the_send_and_is_not_applied_twice_test() {
  let state =
    opened_with(["a"])
    |> pane.revision_read("f1", Ok(3))
    |> pane.revision_read("f2", Ok(5))
    |> pane.find_action("f1", attention.Fixed, "")
    |> pane.find_action("f2", attention.Fixed, "")

  let #(sending, _) = pane.send(state)
  let #(sending, _) =
    pane.closed_with(sending, "f1", attention.Fixed, pane.Done("ok"))
  let #(halted, step) =
    pane.closed_with(sending, "f2", attention.Fixed, pane.Refused("moved"))
  assert step == pane.Halted
  let assert pane.Settled(receipt) = halted.progress
  assert pane.receipt_lines(receipt)
    == ["f1 (fixed): ok", "f2 (fixed): moved", "Nothing was sent to the agent."]

  // The refused action and the revision it named are dropped, so the find is
  // read afresh, and the next Send neither repeats the applied close nor the
  // refused one.
  assert !dict.has_key(halted.revisions, "f2")
  assert list.map(halted.staging.finds, fn(each) { each.id }) == ["f1"]
  let #(_, again) = pane.send(halted)
  let assert pane.PromptStep(_) = again

  // The next pass over the feed asks for the refused find's record again.
  let #(_, asked) = pane.ask_revisions(halted, ["f1", "f2"])
  assert asked == ["f2"]
}

pub fn staging_is_refused_while_a_send_is_out_test() {
  let state =
    opened_with(["a"])
    |> pane.revision_read("f1", Ok(3))
    |> pane.find_action("f1", attention.Fixed, "")
    |> pane.verdict(stage.Approve)

  let #(sending, _) = pane.send(state)

  // Nothing a person does while it is out changes what it checked.
  assert pane.verdict(sending, stage.RequestChanges) == sending
  assert pane.comment(sending, "a", "late") == sending
  assert pane.find_action(sending, "f1", attention.Dismissed, "late") == sending
  assert pane.cleared(sending) == sending
}

pub fn a_refused_prompt_keeps_the_staging_for_another_send_test() {
  let state =
    opened_with(["a"])
    |> pane.verdict(stage.Approve)
  let #(sending, step) = pane.send(state)
  let assert pane.PromptStep(_) = step

  let settled =
    pane.prompted(sending, thread_send.Refused(thread_send.QueueFull))
  assert settled.staging == state.staging
  let #(_, again) = pane.send(settled)
  let assert pane.PromptStep(_) = again
}

pub fn an_oversized_review_is_refused_before_any_close_test() {
  let big = string_of(2000)
  let state =
    opened_with(["a", "b", "c"])
    |> pane.revision_read("f1", Ok(3))
    |> pane.find_action("f1", attention.Fixed, big)
    |> pane.comment("a", big)
    |> pane.comment("b", big)
    |> pane.comment("c", big)
  let state =
    pane.find_action(
      pane.revision_read(state, "f2", Ok(1)),
      "f2",
      attention.Fixed,
      big,
    )

  let #(refused, step) = pane.send(state)
  assert step == pane.Halted
  let assert pane.Settled(receipt) = refused.progress
  let assert pane.NotSent(words) = receipt.prompt
  assert words
    == review_outbox_rule.refusal_words(
      review_outbox_rule.TooLong(bytes: bytes_of(state)),
    )
  assert receipt.closes == []
  assert refused.staging == state.staging
}

pub fn nothing_is_sent_for_an_unread_review_or_an_empty_outbox_test() {
  assert pane.send(pane.opened("s", "m")).1 == pane.Halted
  let #(settled, step) = pane.send(opened_with(["a"]))
  assert step == pane.Halted
  let assert pane.Settled(pane.Receipt(closes: [], prompt: pane.NotSent(_))) =
    settled.progress
}

fn string_of(count: Int) -> String {
  list.repeat("é", count) |> list.fold("", fn(sum, each) { sum <> each })
}

fn bytes_of(state: pane.State) -> Int {
  let assert Error(review_outbox_rule.TooLong(bytes:)) =
    review_outbox_rule.compose(pane.files(state), state.staging)
  bytes
}

// A read the daemon refused for the credential's allowance says nothing about
// the session: it is as if it were unread, and it is never counted as a try.
pub fn a_refusal_for_the_allowance_is_not_a_try_test() {
  let busy = Error(scan.busy_words)
  let seen =
    scan.answered(scan.started(dict.new(), "a", "m", 5), "a", "m", busy)
  assert dict.size(seen) == 0
  assert scan.due([#("a", "m")], seen, 6) == Some(#("a", "m"))

  // A refusal after real failures leaves those failures counted.
  let failed = scan.answered(dict.new(), "a", "m", Error("no"))
  let again = scan.answered(failed, "a", "m", busy)
  assert dict.size(again) == 0
}
