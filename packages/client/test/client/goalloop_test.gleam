//// The goal loop's transitions, unit-pinned and property-walked.
////
//// The unit tests below each name a way the edge-triggered draft
//// stranded a goal, and each fails against that draft. The properties
//// after them walk the state space the units cannot: `next_action` is a
//// function of four statuses, three phases, three counters and what two
//// strands are running, and the bug that mattered was a combination
//// nobody had enumerated — an Active goal, an idle primary, an idle
//// reviewer, and nothing to do.
////
//// The generator is a seeded SplitMix64 threaded by hand, the idiom
//// `packages/core/test/support/generate.gleam` established: a failing
//// property reproduces from its seed alone, and the walk is a pure
//// function so it needs no process.

import client/advisorslice
import client/goalloop
import client/goalstate
import core/clock
import core/entry
import core/ids.{type OpId}
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// --- fixtures ---------------------------------------------------------------

// A goal with room in every bound, so a test that wants a bound reached
// says so rather than inheriting it.
fn a_goal() -> goalstate.Goal {
  goalstate.new("get the branch green", 400_000, 1000, accounted_from: 0)
}

// The observation of an idle session: nothing running on either strand,
// and a stretch that did work. Tests override the one field they are
// about.
fn idle(event: goalloop.Event) -> goalloop.Observed {
  goalloop.Observed(
    primary: None,
    advisor: None,
    progress: goalloop.Progressed,
    woken_ending: goalloop.RanItsCourse,
    event:,
    now_ms: 2000,
    check_timeout_ms: a_short_wall,
  )
}

// The wall these tests run checks under. Short, and short on purpose: the
// deadline arithmetic is what the tests assert on, so a production-sized
// number would only make the expected instants harder to read.
const a_short_wall = 1000

fn an_op(n: Int) -> OpId {
  let #(id, _later) = ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: n))
  id
}

// --- finding 1: the loop must never rest in the stalled combination ---------

// An Active goal with nothing owed, an idle primary and an idle reviewer
// is the occasion a goal feed exists for. The edge-triggered draft could
// reach it with nothing scheduled — a restart, an abandoned feed, a
// failed send — and then nothing would ever start the loop again.
pub fn an_idle_session_with_an_active_goal_is_fed_test() {
  let #(moved, action) = goalloop.next_action(a_goal(), idle(goalloop.Level))

  assert action == goalloop.FeedReviewer
  assert moved == a_goal()
}

// A restart reads the phase from the cell, so it knows a verdict is owed
// and by which reviewer run. While that run is open the loop waits.
pub fn an_owed_verdict_survives_a_restart_test() {
  let review = an_op(7)
  let owed =
    goalstate.Goal(..a_goal(), phase: goalstate.AwaitingVerdict(feed: review))
  let seen = goalloop.Observed(..idle(goalloop.Level), advisor: Some(review))

  let #(moved, action) = goalloop.next_action(owed, seen)

  assert action == goalloop.Rest
  assert moved.phase == goalstate.AwaitingVerdict(feed: review)
}

// A reviewer run that ends without a verdict returns the phase to idle,
// so the very next evaluation offers the feed again. The draft closed the
// feed and waited for the primary's next idle boundary, which an idle
// primary cannot produce.
pub fn a_reviewer_run_that_ends_owing_a_verdict_refeeds_test() {
  let review = an_op(7)
  let owed =
    goalstate.Goal(..a_goal(), phase: goalstate.AwaitingVerdict(feed: review))

  let #(moved, action) =
    goalloop.next_action(owed, idle(goalloop.AdvisorEnded(operation: review)))

  assert moved.phase == goalstate.Idle
  assert moved.unanswered_feeds == 1

  // The re-offer is the tick's, not this run end's. Offering again here spent
  // three tries inside the time it takes a provider to refuse three requests,
  // so a thirty-second rate limit paused the goal for a reviewer that would
  // have answered a minute later.
  assert action == goalloop.Rest
  assert goalloop.defers_the_refeed(
    owed,
    goalloop.AdvisorEnded(operation: review),
  )

  // And the very next level read offers it, which is what makes the deferral
  // a delay rather than a stall.
  let #(again, offered) = goalloop.next_action(moved, idle(goalloop.Level))
  assert offered == goalloop.FeedReviewer
  assert again.unanswered_feeds == 1
    as "the level read that re-offers does not count a second failure"
}

// A review that ended owing nothing is not the deferred case: an ordinary
// review's end is an occasion like any other, and a goal waiting to be fed is
// fed there.
pub fn an_unrelated_review_end_still_offers_the_feed_test() {
  let #(moved, action) =
    goalloop.next_action(
      a_goal(),
      idle(goalloop.AdvisorEnded(operation: an_op(99))),
    )

  assert action == goalloop.FeedReviewer
  assert moved.unanswered_feeds == 0
}

// The same repair from the level alone, which is what covers a lost
// `AdvisorEnded` cast: the phase names a reviewer run the store no
// longer shows open.
pub fn a_lost_review_end_is_repaired_by_the_level_test() {
  let review = an_op(7)
  let owed =
    goalstate.Goal(..a_goal(), phase: goalstate.AwaitingVerdict(feed: review))

  let #(moved, action) = goalloop.next_action(owed, idle(goalloop.Level))

  assert moved.phase == goalstate.Idle
  assert action == goalloop.FeedReviewer
}

// A reviewer that never answers pauses the goal rather than being
// re-fed forever, and the pause says which of the four pauses it was.
pub fn an_unresponsive_reviewer_pauses_the_goal_test() {
  let review = an_op(7)
  let owed =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.AwaitingVerdict(feed: review),
      unanswered_feeds: goalloop.unanswered_feed_limit - 1,
    )

  let #(moved, action) =
    goalloop.next_action(owed, idle(goalloop.AdvisorEnded(operation: review)))

  assert moved.status == goalstate.Paused(by: goalstate.ByUnresponsiveReviewer)
  assert action == goalloop.Rest
}

// A feed the host would not deliver counts against the same bound an
// unanswered one does, so a send that keeps failing pauses the goal
// instead of being retried at every tick forever.
pub fn a_refused_feed_is_bounded_like_an_unanswered_one_test() {
  let once = goalloop.feed_refused(a_goal(), 2000)
  let twice = goalloop.feed_refused(once, 3000)
  let thrice = goalloop.feed_refused(twice, 4000)

  assert once.unanswered_feeds == 1
  assert thrice.status == goalstate.Paused(by: goalstate.ByUnresponsiveReviewer)
}

// --- finding 3: the two bounds that did not work ----------------------------

// A run start the loop did not open resets the continuation cap. Without
// this the count only ever rose, so the cap was a lifetime cap and a
// resume after a trip tripped again on its first evaluation.
pub fn a_foreign_run_start_resets_the_continuation_count_test() {
  let spent =
    goalstate.Goal(..a_goal(), continuations: goalloop.continuation_cap)
  let operators_run = an_op(11)

  let #(moved, _action) =
    goalloop.next_action(
      spent,
      goalloop.Observed(
        ..idle(goalloop.PrimaryStarted(
          operation: operators_run,
          origin: goalloop.Foreign,
        )),
        primary: Some(operators_run),
      ),
    )

  assert moved.continuations == 0
}

// The loop's own woken run coming back around is not somebody arriving
// with work, so it resets nothing.
//
// The origin here is `Foreign` on purpose: this is the restarted actor,
// which has forgotten what it woke and reads the run only from the phase.
// The phase is the second answer `harness_opened` gives, and this is the
// test that holds it.
pub fn the_loops_own_run_start_resets_nothing_test() {
  let woken = an_op(12)
  let mid =
    goalstate.Goal(
      ..a_goal(),
      continuations: 3,
      phase: goalstate.Continuing(woken:, since_seq: 0),
    )

  let #(moved, _action) =
    goalloop.next_action(
      mid,
      goalloop.Observed(
        ..idle(goalloop.PrimaryStarted(
          operation: woken,
          origin: goalloop.Foreign,
        )),
        primary: Some(woken),
      ),
    )

  assert moved.continuations == 3
}

// A run the harness opened that the *phase* does not name resets nothing
// either, and this is the finding the origin exists for: a reviewer's nudge
// wake and a tripped bound's wrap-up both open runs on an idle primary, and
// neither shows up as `Continuing`. Read as somebody arriving with work they
// cleared the cap, so a reviewer that nudged between continuations could
// hold the bound off for as long as it kept nudging.
pub fn a_harness_wake_the_phase_does_not_name_resets_nothing_test() {
  let nudge_wake = an_op(14)
  let spent =
    goalstate.Goal(
      ..a_goal(),
      continuations: goalloop.continuation_cap - 1,
      zero_progress: 1,
      phase: goalstate.Idle,
    )

  let #(moved, _action) =
    goalloop.next_action(
      spent,
      goalloop.Observed(
        ..idle(goalloop.PrimaryStarted(
          operation: nudge_wake,
          origin: goalloop.Harness,
        )),
        primary: Some(nudge_wake),
      ),
    )

  assert moved.continuations == goalloop.continuation_cap - 1
    as "a harness wake must not forgive the continuation cap"
  assert moved.zero_progress == 1
    as "a harness wake must not forgive the zero-progress count"
}

// A cap already reached stops the loop instead of continuing it, and the
// wrap-up names the cap rather than the token budget.
pub fn the_continuation_cap_stops_the_loop_test() {
  let spent =
    goalstate.Goal(..a_goal(), continuations: goalloop.continuation_cap)

  let #(moved, action) = goalloop.next_action(spent, idle(goalloop.Level))

  assert moved.status == goalstate.Limited(by: goalstate.ByContinuationCap)
  assert action
    == goalloop.WrapUp(text: goalloop.wrap_up_text(goalstate.ByContinuationCap))
}

// A resumed goal whose cap was reset runs again. This is the pairing the
// draft got wrong: resume flipped the status and the very next evaluation
// tripped the same cap.
pub fn a_resumed_goal_past_the_cap_runs_again_test() {
  let resumed =
    goalstate.Goal(
      ..a_goal(),
      status: goalstate.Active,
      phase: goalstate.Idle,
      continuations: 0,
    )

  let #(_moved, action) = goalloop.next_action(resumed, idle(goalloop.Level))

  assert action == goalloop.FeedReviewer
}

// Zero progress is measured on the woken run's own stretch, and a
// stretch that did nothing moves the goal one step toward the pause.
pub fn two_stalled_woken_runs_pause_the_goal_test() {
  let woken = an_op(13)
  let once =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.Continuing(woken:, since_seq: 0),
      zero_progress: goalloop.zero_progress_limit - 1,
    )
  let stalled =
    goalloop.Observed(
      ..idle(goalloop.PrimaryEnded(operation: woken)),
      progress: goalloop.Stalled,
    )

  let #(moved, action) = goalloop.next_action(once, stalled)

  assert moved.status == goalstate.Paused(by: goalstate.ByZeroProgress)
  assert action == goalloop.Rest
}

// Real work clears the count, so a single quiet stretch between two
// productive ones never accumulates toward the pause.
pub fn real_work_clears_the_zero_progress_count_test() {
  let woken = an_op(13)
  let once =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.Continuing(woken:, since_seq: 0),
      zero_progress: 1,
    )

  let #(moved, action) =
    goalloop.next_action(once, idle(goalloop.PrimaryEnded(operation: woken)))

  assert moved.zero_progress == 0
  assert action == goalloop.FeedReviewer
}

// The predicate itself. A goal continuation is a user message the
// harness wrote and is committed after the cursor advances, so the
// draft's "any user message is progress" rule meant every woken stretch
// progressed and the bound could never fire.
pub fn a_harness_frame_is_not_progress_test() {
  let continuation =
    advisorslice.continuation_message(a_goal(), "the tests still fail", 5)

  assert goalloop.progress_of([an_entry(continuation)]) == goalloop.Stalled
}

pub fn an_operator_turn_is_progress_test() {
  let typed =
    message.UserMessage(
      content: [
        message.UserText(text: "try the other lock order", text_signature: None),
      ],
      timestamp: 5,
      origin: None,
    )

  assert goalloop.progress_of([an_entry(typed)]) == goalloop.Progressed
}

pub fn a_tool_result_is_progress_test() {
  let ran =
    message.ToolResultMessage(
      tool_call_id: "t1",
      tool_name: "bash",
      content: [message.ToolResultText(text: "ok", text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 5,
    )

  assert goalloop.progress_of([an_entry(ran)]) == goalloop.Progressed
}

// The advisor's own nudge and advice frames are the harness's too, so
// neither is work toward an objective.
pub fn the_advisors_frames_are_not_progress_test() {
  let advice = advisorslice.advice_message("watch the lock order", 5)
  let nudges = advisorslice.nudges_message(["name the file"], 5)

  assert goalloop.progress_of([an_entry(advice), an_entry(nudges)])
    == goalloop.Stalled
}

fn an_entry_id() -> ids.EntryId {
  let #(id, _later) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed: 5))
  id
}

fn an_entry(carried: message.AgentMessage) -> entry.Entry {
  entry.MessageEntry(
    id: an_entry_id(),
    parent: None,
    seq: 1,
    ts: 5,
    message: carried,
    terminate: False,
  )
}

// --- the verdicts -----------------------------------------------------------

// A `continue` against an open feed wakes the primary and counts the
// turn before the wake, so a crash in that window costs headroom rather
// than an uncounted turn.
pub fn a_continue_wakes_the_primary_test() {
  let review = an_op(7)
  let owed =
    goalstate.Goal(..a_goal(), phase: goalstate.AwaitingVerdict(feed: review))

  let #(moved, action) =
    goalloop.next_action(
      owed,
      idle(
        goalloop.Answered(answer: goalloop.Continued(text: "the race remains")),
      ),
    )

  assert action == goalloop.WakePrimary(text: "the race remains")
  assert moved.continuations == 1
  assert moved.unanswered_feeds == 0
}

// A `complete` is terminal and records the reviewer's note.
pub fn a_complete_stops_the_loop_test() {
  let review = an_op(7)
  let owed =
    goalstate.Goal(..a_goal(), phase: goalstate.AwaitingVerdict(feed: review))

  let #(moved, action) =
    goalloop.next_action(
      owed,
      idle(
        goalloop.Answered(answer: goalloop.Completed(text: "the suite is green")),
      ),
    )

  assert moved.status == goalstate.Complete
  assert moved.reviewer_note == Some("the suite is green")
  assert action == goalloop.Rest
}

// A verdict arriving against no open feed wakes nobody: the feed was
// closed by a run that ended, or the operator moved the goal while the
// reviewer judged, and the continuation count does not move.
//
// It does not rest either. A stale verdict is still an occasion, so it
// falls through to the level read — which on this idle session offers the
// feed again. That is what keeps the no-stall invariant free of
// exceptions.
pub fn a_stale_verdict_wakes_nobody_test() {
  let #(moved, action) =
    goalloop.next_action(
      a_goal(),
      idle(goalloop.Answered(answer: goalloop.Continued(text: "keep going"))),
    )

  assert action == goalloop.FeedReviewer
  assert moved.continuations == 0
  assert moved == a_goal()
}

// A budget already crossed stops the loop instead of continuing it, and
// the reviewer's `continue` wakes nobody.
pub fn a_continue_past_the_budget_stops_the_loop_test() {
  let review = an_op(7)
  let spent =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.AwaitingVerdict(feed: review),
      token_budget: 100,
      tokens_used: 100,
    )

  let #(moved, action) =
    goalloop.next_action(
      spent,
      idle(goalloop.Answered(answer: goalloop.Continued(text: "keep going"))),
    )

  assert moved.status == goalstate.Limited(by: goalstate.ByTokenBudget)
  assert action
    == goalloop.WrapUp(text: goalloop.wrap_up_text(goalstate.ByTokenBudget))
}

// The budget is read before the phase, so a primary that crossed its
// budget mid-run is told to stop soon rather than at an idle boundary it
// may be an hour from reaching.
pub fn a_budget_crossed_mid_run_stops_the_loop_test() {
  let woken = an_op(13)
  let spent =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.Continuing(woken:, since_seq: 0),
      token_budget: 100,
      tokens_used: 250,
    )
  let working = goalloop.Observed(..idle(goalloop.Level), primary: Some(woken))

  let #(moved, action) = goalloop.next_action(spent, working)

  assert moved.status == goalstate.Limited(by: goalstate.ByTokenBudget)
  assert action
    == goalloop.WrapUp(text: goalloop.wrap_up_text(goalstate.ByTokenBudget))
}

// --- the abort --------------------------------------------------------------

// An abort of the loop's own run holds the goal, with `aborted` as the
// reason rather than the bare `paused` the draft wrote for all four
// causes.
pub fn an_abort_of_the_loops_run_holds_the_goal_test() {
  let woken = an_op(13)
  let mid =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.Continuing(woken:, since_seq: 0),
    )

  let #(moved, action) =
    goalloop.next_action(mid, idle(goalloop.Aborted(operation: woken)))

  assert moved.status == goalstate.Paused(by: goalstate.ByAbort)
  assert action == goalloop.Rest
}

// The same pause from the durable ending alone, which is what covers a
// dropped abort notice: the phase names a run the store no longer shows open,
// and its terminal record says the operator cancelled it.
//
// Without this the level read called it a finished stretch, returned the goal
// to idle and fed the reviewer, so the operator's Ctrl-C was answered with
// another continuation within the repair tick's interval. The notice is a
// cast and a cast is dropped when the actor is absent, so a supervisor
// restart between the abort and the run's finish is all it took.
pub fn an_aborted_woken_run_pauses_from_the_level_alone_test() {
  let woken = an_op(13)
  let mid =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.Continuing(woken:, since_seq: 0),
    )
  let cancelled =
    goalloop.Observed(..idle(goalloop.Level), woken_ending: goalloop.Cancelled)

  let #(moved, action) = goalloop.next_action(mid, cancelled)

  assert moved.status == goalstate.Paused(by: goalstate.ByAbort)
    as "a cancelled woken run holds the goal, notice or no notice"
  assert action == goalloop.Rest as "a held goal wakes nobody"

  // The same level with an ordinary ending is the finished stretch it was,
  // so the repair does not swallow a run that simply ended.
  let #(ended, offered) = goalloop.next_action(mid, idle(goalloop.Level))
  assert ended.status == goalstate.Active
  assert offered == goalloop.FeedReviewer
}

// An abort of somebody else's run is the operator changing their mind
// about their own work.
pub fn an_abort_of_another_run_leaves_the_goal_test() {
  let woken = an_op(13)
  let mid =
    goalstate.Goal(
      ..a_goal(),
      phase: goalstate.Continuing(woken:, since_seq: 0),
    )

  let #(moved, _action) =
    goalloop.next_action(mid, idle(goalloop.Aborted(operation: an_op(99))))

  assert moved.status == goalstate.Active
}

// --- coalescing -------------------------------------------------------------

// A busy primary means the feed's occasion has not arrived; a busy
// reviewer means the feed coalesces with the review it is holding. Both
// rest, and the level read reaches them again.
pub fn a_busy_strand_defers_the_feed_test() {
  let working =
    goalloop.Observed(..idle(goalloop.Level), primary: Some(an_op(21)))
  let reviewing =
    goalloop.Observed(..idle(goalloop.Level), advisor: Some(an_op(22)))

  assert goalloop.next_action(a_goal(), working) == #(a_goal(), goalloop.Rest)
  assert goalloop.next_action(a_goal(), reviewing) == #(a_goal(), goalloop.Rest)
}

// --- the operator's check ---------------------------------------------------

// A goal with a check does not feed until the check has run: the occasion
// that would have sent the feed asks for the check instead, and the phase
// records the deadline the caller must run it under.
pub fn a_configured_check_runs_before_the_feed_test() {
  let #(moved, action) =
    goalloop.next_action(a_checked_goal(), idle(goalloop.Level))

  assert action == goalloop.RunCheck(command: "make check")
  assert moved.phase == goalstate.Checking(deadline_ms: 2000 + a_short_wall)
}

// The result the loop was waiting for is recorded and the feed follows in
// the same step, so a check costs one evaluation rather than a round of the
// periodic tick.
pub fn a_check_result_records_and_feeds_test() {
  let owed =
    goalstate.Goal(
      ..a_checked_goal(),
      phase: goalstate.Checking(deadline_ms: 3000),
    )
  let result = a_failing_check()

  let #(moved, action) =
    goalloop.next_action(
      owed,
      idle(goalloop.Checked(deadline_ms: 3000, result:)),
    )

  assert moved.last_check == Some(result)
  assert moved.phase == goalstate.ReadyToFeed
  assert action == goalloop.FeedReviewer
}

// The check runs once per feed, not in a loop with it. The phase the result
// moved the goal into feeds; it does not ask for the check again.
pub fn a_recorded_check_is_not_run_again_test() {
  let ready =
    goalstate.Goal(
      ..a_checked_goal(),
      phase: goalstate.ReadyToFeed,
      last_check: Some(a_failing_check()),
    )

  let #(moved, action) = goalloop.next_action(ready, idle(goalloop.Level))

  assert action == goalloop.FeedReviewer
  assert moved.last_check == Some(a_failing_check())
}

// A check whose deadline has passed is abandoned rather than waited on, and
// the reviewer is fed with the absence recorded as the evidence. This is the
// repair for a task that was killed at its wall and for an actor that was
// replaced while the check ran.
pub fn a_check_past_its_deadline_feeds_anyway_test() {
  let stuck =
    goalstate.Goal(
      ..a_checked_goal(),
      phase: goalstate.Checking(deadline_ms: 1500),
    )

  let #(moved, action) = goalloop.next_action(stuck, idle(goalloop.Level))

  assert action == goalloop.FeedReviewer
  assert moved.phase == goalstate.ReadyToFeed
  assert moved.last_check
    == Some(goalstate.CheckResult(
      command: "make check",
      ending: goalstate.DidNotFinish(reason: goalloop.check_did_not_finish(
        a_short_wall,
      )),
      output: "",
      ran_at_ms: 2000,
    ))
}

// A check inside its deadline is work in flight, so the loop waits for it
// the way it waits for a review.
pub fn a_check_inside_its_deadline_waits_test() {
  let running =
    goalstate.Goal(
      ..a_checked_goal(),
      phase: goalstate.Checking(deadline_ms: 9000),
    )

  let #(moved, action) = goalloop.next_action(running, idle(goalloop.Level))

  assert action == goalloop.Rest
  assert moved.phase == goalstate.Checking(deadline_ms: 9000)
}

// A result against a deadline the loop is no longer waiting for records
// nothing: this is the check whose goal was cleared, paused or re-checked
// while it ran.
pub fn a_check_result_for_another_deadline_is_ignored_test() {
  let owed =
    goalstate.Goal(
      ..a_checked_goal(),
      phase: goalstate.Checking(deadline_ms: 9000),
    )

  let #(moved, action) =
    goalloop.next_action(
      owed,
      idle(goalloop.Checked(deadline_ms: 3000, result: a_failing_check())),
    )

  assert moved.last_check == None
  assert moved.phase == goalstate.Checking(deadline_ms: 9000)
  assert action == goalloop.Rest
}

// A paused goal's in-flight check reports into a goal that acts on nothing,
// which is what "pausing mid-check leaves nothing that acts later" means
// from the loop's side.
pub fn a_check_result_for_a_paused_goal_does_nothing_test() {
  let held =
    goalstate.Goal(
      ..a_checked_goal(),
      status: goalstate.Paused(by: goalstate.ByOperator),
      phase: goalstate.Checking(deadline_ms: 3000),
    )

  let #(moved, action) =
    goalloop.next_action(
      held,
      idle(goalloop.Checked(deadline_ms: 3000, result: a_failing_check())),
    )

  assert action == goalloop.Rest
  assert moved.status == goalstate.Paused(by: goalstate.ByOperator)
}

// A check that always fails must not defeat the loop's own bounds. The
// continuation cap is read before the phase, so a goal at the cap wraps up
// rather than running its check again — an operator whose check can never
// pass pays the cap, not an unbounded loop.
pub fn an_always_failing_check_still_hits_the_cap_test() {
  let capped =
    goalstate.Goal(
      ..a_checked_goal(),
      continuations: goalloop.continuation_cap,
      last_check: Some(a_failing_check()),
    )

  let #(moved, action) = goalloop.next_action(capped, idle(goalloop.Level))

  assert moved.status == goalstate.Limited(by: goalstate.ByContinuationCap)
  assert action
    == goalloop.WrapUp(text: goalloop.wrap_up_text(goalstate.ByContinuationCap))
}

// And a check in flight does not hold off an exhausted budget either: the
// bound is read before the phase, so a goal that crossed its budget while
// its check ran stops rather than feeding.
pub fn a_check_in_flight_does_not_outlast_the_budget_test() {
  let spent =
    goalstate.Goal(
      ..a_checked_goal(),
      phase: goalstate.Checking(deadline_ms: 9000),
      tokens_used: 400_000,
    )

  let #(moved, action) = goalloop.next_action(spent, idle(goalloop.Level))

  assert moved.status == goalstate.Limited(by: goalstate.ByTokenBudget)
  assert action
    == goalloop.WrapUp(text: goalloop.wrap_up_text(goalstate.ByTokenBudget))
}

fn a_checked_goal() -> goalstate.Goal {
  goalstate.Goal(..a_goal(), check: Some("make check"))
}

fn a_failing_check() -> goalstate.CheckResult {
  goalstate.CheckResult(
    command: "make check",
    ending: goalstate.Exited(status: 1),
    output: "stdout:\nFAIL client",
    ran_at_ms: 1900,
  )
}

// --- the properties ---------------------------------------------------------

// The stall, stated as a property over every reachable state the walk
// can produce: an Active goal that owes nothing, with both strands idle,
// never rests. This is the one invariant the whole rework exists for.
pub fn the_loop_never_rests_in_the_stalled_combination_test() {
  walk(seed(41), 400, fn(reached) {
    let #(goal, observed) = reached
    let #(moved, action) = goalloop.next_action(goal, observed)

    // One occasion is deliberately quiet and the property excludes it by
    // name: the run end of a reviewer that owed a verdict leaves the re-offer
    // to the periodic tick, so a provider refusing three times inside one
    // rate-limit window does not spend the whole bound. The goal is not
    // stranded, because the tick is unconditional — and the property below
    // holds for the level read that tick makes.
    use <- skipping(goalloop.defers_the_refeed(goal, observed.event))

    case moved.status, moved.phase, observed.primary, observed.advisor {
      goalstate.Active, goalstate.Idle, None, None -> {
        assert action != goalloop.Rest
          as "an active goal with nothing owed and nothing running must act"
      }

      // `ReadyToFeed` owes nothing either: the check has already run, so
      // this is the stalled combination reached through the check's own
      // path and it must act for the same reason.
      goalstate.Active, goalstate.ReadyToFeed, None, None -> {
        assert action != goalloop.Rest
          as "an active goal whose check has run must feed the reviewer"
      }

      _status, _phase, _primary, _advisor -> Nil
    }
  })
}

// A check in flight is the one phase that may rest, and the level read is
// what bounds how long: whatever state the walk reaches, a level read never
// leaves a `Checking` phase whose deadline has passed. That is what keeps a
// check from becoming a sixth way to strand the goal — the periodic tick is
// a level read, so a check nobody will report on is abandoned within one
// tick of its deadline.
//
// It is stated against a level read rather than against every event for the
// reason the feed's own repair is: a notification is about the thing that
// happened, and repairing a state it says nothing about is the tick's job.
pub fn a_level_read_never_leaves_a_check_past_its_deadline_test() {
  walk(seed(47), 400, fn(reached) {
    let #(goal, observed) = reached
    let level = goalloop.Observed(..observed, event: goalloop.Level)
    let #(moved, _action) = goalloop.next_action(goal, level)

    case moved.phase {
      goalstate.Checking(deadline_ms:) -> {
        assert deadline_ms > level.now_ms
          as "a level read never leaves a check past its deadline"
      }

      goalstate.Idle
      | goalstate.ReadyToFeed
      | goalstate.AwaitingVerdict(..)
      | goalstate.Continuing(..) -> Nil
    }
  })
}

// A check result the loop was not waiting for moves nothing. The walk draws
// both a matching deadline and one it never used, so this covers the late
// report of a check the operator cleared or paused out from under.
pub fn a_stale_check_result_is_inert_test() {
  walk(seed(46), 400, fn(reached) {
    let #(goal, observed) = reached

    case observed.event, goal.phase {
      goalloop.Checked(deadline_ms:, ..), goalstate.Checking(deadline_ms: owed)
        if deadline_ms != owed
      -> {
        let #(moved, _action) = goalloop.next_action(goal, observed)

        assert moved.last_check == goal.last_check
          as "a stale check result is never recorded"
      }

      // Every other pairing is either the result the loop owed or an event
      // this property is not about.
      _event, _phase -> Nil
    }
  })
}

// Every bound holds whatever sequence of events reached it: no walk
// leaves a goal past its cap, past its zero-progress limit, or past its
// unanswered-feed limit.
pub fn the_bounds_are_never_exceeded_test() {
  walk(seed(42), 400, fn(reached) {
    let #(goal, observed) = reached
    let #(moved, _action) = goalloop.next_action(goal, observed)

    assert moved.continuations <= goalloop.continuation_cap
      as "the continuation count never passes its cap"
    assert moved.zero_progress <= goalloop.zero_progress_limit
      as "the zero-progress count never passes its limit"
    assert moved.unanswered_feeds <= goalloop.unanswered_feed_limit
      as "the unanswered-feed count never passes its limit"
  })
}

// An exhausted token budget always stops the loop: the goal is never left
// running, and never fed.
//
// The walk refuted two stronger forms of this before it settled here, and
// both refutations are findings rather than noise. The first asserted
// *which* stopped status the goal lands in, and a goal whose budget is
// spent and whose reviewer has also stopped answering is paused for the
// unresponsive reviewer rather than limited for the budget — the more
// specific and more actionable of the two causes. The second included the
// continuation cap, and a run start the loop did not open legitimately
// clears the cap, which is the whole of the finding-3 fix: a goal at the
// cap when the operator arrives with work of their own is not a goal that
// should stop. The token budget is the bound no event clears, so it is the
// one this property can state unconditionally.
pub fn an_exhausted_budget_always_stops_the_loop_test() {
  walk(seed(43), 400, fn(reached) {
    let #(goal, observed) = reached
    let #(moved, action) = goalloop.next_action(goal, observed)

    case goal.status, goal.tokens_used >= goal.token_budget {
      goalstate.Active, True -> {
        assert moved.status != goalstate.Active
          as "an exhausted budget never leaves the goal running"
        assert action != goalloop.FeedReviewer
          as "an exhausted budget never feeds the reviewer"
      }

      _status, _room -> Nil
    }
  })
}

// `Complete` is terminal. No event moves a complete goal's status, and
// no action is asked for one.
pub fn complete_is_terminal_test() {
  walk(seed(44), 400, fn(reached) {
    let #(goal, observed) = reached
    let done = goalstate.Goal(..goal, status: goalstate.Complete)
    let #(moved, action) = goalloop.next_action(done, observed)

    assert moved.status == goalstate.Complete as "nothing moves a complete goal"
    assert action == goalloop.Rest as "a complete goal asks for nothing"
  })
}

// Only an operator command leaves a stopped status, and the operator's
// commands are the caller's. No event this function sees ever moves a
// paused or limited goal back to active.
pub fn only_the_operator_leaves_a_stopped_status_test() {
  walk(seed(45), 400, fn(reached) {
    let #(goal, observed) = reached

    list.each(stopped_statuses(), fn(status) {
      let held = goalstate.Goal(..goal, status:)
      let #(moved, action) = goalloop.next_action(held, observed)

      assert moved.status == status as "no event moves a stopped goal's status"
      assert action == goalloop.Rest as "a stopped goal asks for nothing"
    })
  })
}

// A guard for a property's excluded case, written as a `use` so the excluded
// arm reads as one line at the top rather than as a nested `case` around the
// whole assertion.
fn skipping(excluded: Bool, check: fn() -> Nil) -> Nil {
  case excluded {
    True -> Nil
    False -> check()
  }
}

fn stopped_statuses() -> List(goalstate.Status) {
  [
    goalstate.Paused(by: goalstate.ByOperator),
    goalstate.Paused(by: goalstate.ByAbort),
    goalstate.Paused(by: goalstate.ByZeroProgress),
    goalstate.Paused(by: goalstate.ByUnresponsiveReviewer),
    goalstate.Limited(by: goalstate.ByTokenBudget),
    goalstate.Limited(by: goalstate.ByContinuationCap),
  ]
}

// --- the walk ---------------------------------------------------------------

// One step of a random walk: a goal and an observation, drawn together so
// the pair is coherent — an observation that names a running operation
// names one the goal's phase could plausibly be about, which is what
// makes the reachable states reachable rather than arbitrary.
type Reached =
  #(goalstate.Goal, goalloop.Observed)

fn walk(from: Seed, remaining: Int, check: fn(Reached) -> a) -> Nil {
  case remaining <= 0 {
    True -> Nil

    False -> {
      let #(reached, next_seed) = draw(from)
      let _checked = check(reached)
      walk(next_seed, remaining - 1, check)
    }
  }
}

fn draw(from: Seed) -> #(Reached, Seed) {
  let #(goal, from) = draw_goal(from)
  let #(observed, from) = draw_observed(from, goal)

  #(#(goal, observed), from)
}

fn draw_goal(from: Seed) -> #(goalstate.Goal, Seed) {
  let #(phase, from) = draw_phase(from)
  let #(budget, from) = between(from, 1, 200)
  let #(used, from) = between(from, 0, 300)
  // The continuation cap is drawn up to and including its limit, because a
  // goal *does* sit at it: reaching the cap is read on the next evaluation
  // rather than applied at the increment, which is what lets the bound trip
  // before a continuation rather than after one.
  let #(continuations, from) = between(from, 0, goalloop.continuation_cap)

  // The two counters that pause the goal on reaching their limit are drawn
  // strictly below it, because a goal at either limit is not a reachable
  // state: the transition that reaches the limit is the one that leaves
  // `Active`, and `goal_set` and `goal_resume` both clear the counters on
  // the way back. Drawing one at its limit would assert against a state no
  // sequence of events produces, which is what the first draft of this
  // generator did.
  let #(zeros, from) = between(from, 0, goalloop.zero_progress_limit - 1)
  let #(unanswered, from) = between(from, 0, goalloop.unanswered_feed_limit - 1)
  let #(check, from) = draw_check(from)

  #(
    goalstate.Goal(
      ..a_goal(),
      phase:,
      check:,
      token_budget: budget,
      tokens_used: used,
      continuations:,
      zero_progress: zeros,
      unanswered_feeds: unanswered,
    ),
    from,
  )
}

fn draw_phase(from: Seed) -> #(goalstate.Phase, Seed) {
  let #(which, from) = between(from, 0, 4)

  case which {
    0 -> #(goalstate.Idle, from)
    1 -> #(goalstate.AwaitingVerdict(feed: walked_review()), from)

    // Both sides of the check's deadline are drawn, because they are two
    // different states: one rests and one must not. The walk's clock reads
    // 5,000, so 4,000 is a deadline already passed and 6,000 is one in the
    // future.
    2 -> #(goalstate.Checking(deadline_ms: 4000), from)
    3 -> #(goalstate.ReadyToFeed, from)
    _continuing -> #(
      goalstate.Continuing(woken: walked_woken(), since_seq: 0),
      from,
    )
  }
}

// Whether the walked goal carries a check. Drawn, because the check changes
// which action the un-stalled combination answers with and a walk that never
// pinned one would leave `RunCheck` out of every property below.
fn draw_check(from: Seed) -> #(Option(String), Seed) {
  let #(which, from) = between(from, 0, 1)

  case which {
    0 -> #(None, from)
    _pinned -> #(Some("make check"), from)
  }
}

// The walk draws from three named operations rather than fresh ones,
// because what the transitions turn on is whether an observed run
// *matches* the one the phase names, and three values give every answer:
// the review's own run, the loop's own woken run, and somebody else's.
fn walked_review() -> OpId {
  an_op(101)
}

fn walked_woken() -> OpId {
  an_op(202)
}

fn walked_other() -> OpId {
  an_op(303)
}

fn draw_observed(
  from: Seed,
  goal: goalstate.Goal,
) -> #(goalloop.Observed, Seed) {
  let #(primary, from) = draw_run(from, walked_woken())
  let #(advisor, from) = draw_run(from, walked_review())
  let #(progressed, from) = between(from, 0, 1)
  let #(cancelled, from) = between(from, 0, 1)
  let #(event, from) = draw_event(from, goal)

  #(
    goalloop.Observed(
      primary:,
      advisor:,
      progress: case progressed {
        0 -> goalloop.Progressed
        _stalled -> goalloop.Stalled
      },
      // Drawn rather than fixed, because the durable ending is a second
      // way out of the `Continuing` phase and a walk that never produced
      // one would leave the abort-repair path untested by every property
      // below.
      woken_ending: case cancelled {
        0 -> goalloop.RanItsCourse
        _aborted -> goalloop.Cancelled
      },
      event:,
      now_ms: 5000,
      check_timeout_ms: a_short_wall,
    ),
    from,
  )
}

fn draw_run(from: Seed, named: OpId) -> #(Option(OpId), Seed) {
  let #(which, from) = between(from, 0, 2)

  case which {
    0 -> #(None, from)
    1 -> #(Some(named), from)
    _other -> #(Some(walked_other()), from)
  }
}

fn draw_event(from: Seed, _goal: goalstate.Goal) -> #(goalloop.Event, Seed) {
  let #(which, from) = between(from, 0, 8)

  case which {
    0 -> #(goalloop.Level, from)
    1 -> {
      let #(harness, from) = between(from, 0, 1)

      #(
        goalloop.PrimaryStarted(
          operation: walked_woken(),
          origin: case harness {
            0 -> goalloop.Foreign
            _opened -> goalloop.Harness
          },
        ),
        from,
      )
    }
    2 -> #(goalloop.PrimaryEnded(operation: walked_woken()), from)
    3 -> #(goalloop.AdvisorEnded(operation: walked_review()), from)
    4 -> #(goalloop.Aborted(operation: walked_woken()), from)
    5 -> #(goalloop.Answered(answer: goalloop.Continued(text: "on")), from)

    // A result for the phase the walk draws, and one for a deadline it
    // never drew. The second is the stale report — a check the loop stopped
    // waiting for, reporting after the fact — and it must move nothing.
    6 -> #(goalloop.Checked(deadline_ms: 4000, result: walked_check()), from)
    7 -> #(goalloop.Checked(deadline_ms: 99_000, result: walked_check()), from)
    _completed -> #(
      goalloop.Answered(answer: goalloop.Completed(text: "done")),
      from,
    )
  }
}

fn walked_check() -> goalstate.CheckResult {
  goalstate.CheckResult(
    command: "make check",
    ending: goalstate.Exited(status: 1),
    output: "one test failed",
    ran_at_ms: 4900,
  )
}

// --- the generator ----------------------------------------------------------

// A seeded SplitMix64, the shape `core`'s own property support uses, so
// a failing property reproduces from its seed alone.
type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

fn seed(n: Int) -> Seed {
  Seed(state: int.bitwise_and(n, mask_64))
}

fn next(from: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(from.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))

  #(z, Seed(state:))
}

fn between(from: Seed, low: Int, high: Int) -> #(Int, Seed) {
  let #(drawn, later) = next(from)
  let span = high - low + 1

  #(low + drawn % span, later)
}
