//// The goal loop's transitions, as a pure function of the goal and what
//// the session was observed to be doing.
////
//// ## Why this is a level read rather than a set of edges
////
//// The first draft of the loop was edge-triggered. Each occasion — the
//// primary's run end, the reviewer's verdict, the operator's resume —
//// did the whole transition where it arrived, and the loop's phase lived
//// in the actor's heap. The design's own premise is that an idle primary
//// has no next occasion, and that premise is what makes a missed edge
//// unrecoverable: the goal stays Active with nothing running, the panel
//// shows it working, and nothing will ever start it again. There were
//// five ways to miss one. A daemon or supervisor restart forgot that a
//// verdict was owed, so the reviewer's answer was refused as answering
//// no open feed. A reviewer run that ended without a verdict — a
//// provider refusal, a rate limit — closed the feed and waited for an
//// occasion that could not occur. A failed send of the feed logged a
//// line and returned. A stretch with nothing new in it produced no
//// frame, so `/goal resume` on an already-reviewed idle primary flipped
//// the status and started nothing.
////
//// So the loop is written the other way round. The durable cell carries
//// the phase (`goalstate.Phase`), every message is an occasion to read
//// the level rather than to apply an edge, and `next_action` answers one
//// question: given this goal and what is actually running, what should
//// happen now? A lost notification costs one evaluation's delay, because
//// the next evaluation reads the same level and reaches the same answer.
//// The actor's periodic tick is what makes "the next evaluation" a
//// promise rather than a hope.
////
//// ## Why the transitions are pure
////
//// The states this loop can be in are the product of four statuses,
//// five phases, three counters and what two strands are running, and
//// the failure that matters is a combination nobody enumerated — an
//// Active goal, an idle primary, an idle reviewer and nothing to do. A
//// property test can walk that space in a second; an actor test cannot
//// walk it at all. Everything here is therefore a function of its
//// arguments: no store, no clock, no process. The actor gathers the
//// facts, calls `next_action`, performs the action and stores the goal.
////
//// ## What the caller still owns
////
//// Two things, and both are named where they matter. The accounting is
//// already in the goal by the time `next_action` sees it — the actor
//// recomputes `tokens_used` from the ledger before it asks, because the
//// sum is a fact about the session rather than a decision about the
//// goal. And an action that opens a run reports an operation the caller
//// could not have known in advance, so `next_action` leaves the phase
//// `Idle` for `FeedReviewer` and `WakePrimary`, and the caller narrows
//// it with `feed_opened` or `primary_woken` once the send says which run
//// it opened. A crash in that window costs one redundant evaluation,
//// never a stranded goal: the level read finds an idle phase with a busy
//// strand and waits.
////
//// `RunCheck` is the third of those. The phase it comes with already
//// records the deadline the caller must run the check under, so nothing
//// has to be reported back to make the loop recoverable — the caller runs
//// the command off its own process and casts the result as `Checked`, and
//// a result that never arrives is repaired by the deadline the cell
//// already carries.

import client/advisorslice
import client/goalstate.{
  type Goal, type LimitCause, Active, ByAbort, ByContinuationCap, ByOperator,
  ByTokenBudget, ByUnresponsiveReviewer, ByZeroProgress, Complete, Continuing,
  Goal, Idle, Limited, Paused,
}
import core/entry.{type Entry}
import core/ids.{type OpId}
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// --- the bounds ------------------------------------------------------------

/// How many goal continuations the harness allows since the last run
/// start on the primary the loop did not open.
///
/// The loop's own backstop, beside the goal's required token budget. A
/// count rather than a clock because a count survives daemon restarts
/// the way a wall-clock total does not, and a constant rather than
/// configuration because a budget the operator sets generously still
/// deserves a bound the operator cannot configure away (protocol 044
/// §4). It counts *since the operator, a schedule or another layer last
/// arrived with work of their own*, which is what a `PrimaryStarted` whose
/// `Origin` is `Foreign` resets — without that reset the cap is a lifetime
/// cap, and `/goal resume` after a trip trips again at once.
pub const continuation_cap = 8

/// How many consecutive zero-progress continuations the harness allows
/// before the goal is paused.
///
/// A woken run that committed no tool result and no operator turn did no
/// work toward anything. Two in a row means a reviewer-primary pair
/// answering `continue` to work that produces nothing, and nobody is
/// steering that; the goal pauses rather than burning the budget's tail
/// on it.
pub const zero_progress_limit = 2

/// How many consecutive goal feeds may go unanswered before the goal is
/// paused.
///
/// A level-triggered loop re-offers a feed whose reviewer run ended
/// without a verdict, which is the right answer to one rate-limited
/// review and the wrong answer to a provider that will never answer the
/// goal words: without a bound the loop would re-feed forever and bill
/// the operator for it. Three is enough to ride out a transient refusal
/// and short enough that a misconfigured reviewer is reported rather
/// than paid for.
pub const unanswered_feed_limit = 3

/// How long the operator's check may run before the loop stops waiting for
/// it and feeds the reviewer with "the check did not finish" instead.
///
/// Five minutes, and the number is argued rather than picked. The check is
/// whatever an operator would type to find out whether the work is done, so
/// the useful cases are a test binary, a build, a lint sweep — a few seconds
/// at the fast end and a few minutes at the slow one. A wall shorter than a
/// real `make check` would report "did not finish" on every feed of a
/// perfectly ordinary project, and a reviewer shown that every cycle learns
/// to discount the block, which is worse than pinning no check at all.
/// Against that, the wall is dead time in the loop once per feed, and an
/// operator whose check genuinely takes half an hour is better told it does
/// not fit than made to wait for it on every cycle.
///
/// It bounds two things and deliberately so: the jailed process's own wall
/// limit, so a runaway command is killed by the sandbox rather than merely
/// abandoned by this loop, and the durable `Checking` deadline a restarted
/// actor reads. Both are derived from this number, so they cannot drift.
pub const check_timeout_ms = 300_000

// --- what the caller observed ----------------------------------------------

/// Whether the stretch of primary work the loop is judging committed
/// anything that counts as work toward the objective.
///
/// A two-variant type rather than a `Bool` because the polarity is the
/// whole meaning: `Stalled` is what trips a bound, and a field or
/// argument typed `Bool` makes every reader carry which way round it
/// went.
pub type Progress {
  /// The stretch committed a tool result, or an entry somebody other
  /// than the harness wrote.
  Progressed

  /// The stretch committed nothing but the model's own turns and the
  /// harness's own frames.
  Stalled
}

/// The reviewer's answer to an open goal feed, as the loop reads it.
///
/// `tools/advise` owns the wire vocabulary and carries three more words
/// this loop never sees; this type is the pair that can actually answer a
/// goal feed, so a caller cannot hand the loop a verdict it has no
/// transition for.
pub type Answer {
  /// The objective is not achieved. Wake the primary with this text.
  Continued(text: String)

  /// The objective is achieved. Record this text and stop.
  Completed(text: String)
}

/// Who opened a run that has just started on the primary.
///
/// The continuation cap counts continuations *since somebody else arrived
/// with work of their own*, so the reset turns on this and on nothing else.
/// The goal's phase cannot answer it alone: the harness opens runs for three
/// reasons and only one of them — the goal continuation — is in the phase.
/// A reviewer's nudge wake and a tripped bound's wrap-up are the other two,
/// and reading either as somebody arriving cleared the cap, which let a
/// reviewer that nudged between continuations hold the bound off for as long
/// as it kept nudging.
pub type Origin {
  /// Somebody arrived with work of their own: the operator's prompt, a
  /// schedule, a background job's wake, a sub-agent's result. The cap
  /// counts from here.
  ///
  /// A run the *model* arranged is deliberately foreign too, because
  /// nothing can tell it from the operator's own prompt. Under a primary
  /// that schedules its own wakes the token budget is the binding bound,
  /// which protocol 044 §4 says in as many words.
  Foreign

  /// The harness opened it — a goal continuation, a nudge wake, a bound's
  /// wrap-up. It resets nothing, because the harness arriving with work is
  /// the loop's own behaviour rather than a reason to forgive it.
  Harness
}

/// The occasion that prompted this evaluation.
///
/// Every variant but `Level` is a notification that may be lost, and
/// every one of them is also *derivable* from the level: a run that
/// ended is a run the store no longer shows open. That redundancy is
/// deliberate. The notification makes the loop prompt; the level read
/// makes it correct.
pub type Event {
  /// No occasion in particular — the periodic re-evaluation, the actor's
  /// first read of its cells, or the step after an operator command.
  /// This is the event that repairs a missed notification, so it is the
  /// only one that infers an abandoned feed or a finished woken run from
  /// the store alone.
  Level

  /// A run opened on the primary. The loop cares because a run the
  /// harness did not open is somebody arriving with work of their own,
  /// which is what resets the continuation cap.
  PrimaryStarted(operation: OpId, origin: Origin)

  /// A run on the primary ended.
  PrimaryEnded(operation: OpId)

  /// A run on the advisor ended. When it is the run that owed a verdict,
  /// the feed went unanswered.
  AdvisorEnded(operation: OpId)

  /// The operator aborted a run on the primary.
  Aborted(operation: OpId)

  /// The reviewer answered an open goal feed.
  Answered(answer: Answer)

  /// A check run reported back. `deadline_ms` is the deadline of the
  /// `Checking` phase the run was started for, and it is what tells the
  /// result the loop is waiting for from a late one: the caller cannot
  /// name the run any other way, because a check is a process rather than
  /// an operation the store records.
  ///
  /// A result whose deadline is not the current phase's is ignored, which
  /// is the whole of what "clearing or pausing mid-check leaves nothing
  /// that acts later" rests on. Two checks started at the same instant
  /// would be indistinguishable here; that needs a second check begun in
  /// the same millisecond as the first, after the first has already been
  /// abandoned, and what it costs is one feed carrying the earlier run of
  /// the same command as its evidence.
  Checked(deadline_ms: Int, result: goalstate.CheckResult)
}

/// How the woken run the phase names actually ended, as the caller read it
/// from the durable record rather than from a notification.
///
/// It exists because the abort notice is a cast and a cast can be dropped —
/// an actor that restarted between the operator's Ctrl-C and the run's
/// finish never hears it. Without this the level read would find a
/// `Continuing` phase whose run is gone, call it a finished stretch, and
/// wake the primary again within the tick's interval: the operator's abort
/// answered with a continuation. The terminal transaction writes the
/// operation's result atomically with the settlement that clears
/// `current_operation`, so a run the store no longer shows open is a run
/// whose outcome is already durable, which is what makes this readable at
/// exactly the moment it is needed.
pub type Ending {
  /// The run ended on its own terms, or has not ended at all.
  RanItsCourse

  /// The operator's abort ended it.
  Cancelled
}

/// The facts the caller fetched for one evaluation.
///
/// `primary` and `advisor` are what each strand has open *other than the
/// run this event just ended*: the driver resolves a run-end hook before
/// the settlement that clears `current_operation`, so for one commit the
/// store still shows a finished run as open, and the caller disbelieves
/// exactly that one value. Passing the disbelief in rather than
/// reconstructing it here keeps this module free of the store's
/// ordering.
pub type Observed {
  Observed(
    /// The run the primary has open, if any.
    primary: Option(OpId),
    /// The run the advisor has open, if any.
    advisor: Option(OpId),
    /// Whether the stretch since the wake's own seq did work. Read only
    /// when the phase is `Continuing`, which is the only phase that names a
    /// stretch to judge.
    progress: Progress,
    /// How the run the phase names ended, read from its durable terminal
    /// record. `RanItsCourse` for every phase that names no run.
    woken_ending: Ending,
    /// The occasion asking.
    event: Event,
    /// The caller's clock, stamped into `updated_ms` on every move.
    now_ms: Int,
    /// How long the caller will actually let a check run, which is what
    /// the `Checking` deadline is computed from.
    ///
    /// It is injected rather than read from `check_timeout_ms` here because
    /// the wall the process runs under is the caller's — `client/goalcheck`
    /// carries it, and production passes the constant. One number reaches
    /// both, so the deadline a restart reads cannot outlive the process it
    /// was waiting for, and a test can pin a short wall without waiting out
    /// a production one.
    check_timeout_ms: Int,
  )
}

// --- what the caller should do ---------------------------------------------

/// What the loop asks the caller to do about the goal it just moved.
///
/// Five actions, and the whole of the loop's contact with the world is
/// in them. Two of them open a run whose operation the caller must
/// report back through `feed_opened` or `primary_woken`, and one runs a
/// process whose result the caller reports back as `Checked`.
pub type Action {
  /// Nothing. The goal is stopped, something is already running, or the
  /// occasion belongs to somebody else.
  Rest

  /// Send the reviewer a goal feed. A feed is sendable with nothing new
  /// on the branch — the frame says so — because a stretch with no new
  /// entries is exactly what `/goal resume` on an already-reviewed idle
  /// primary finds, and a loop that declined to send there would flip
  /// the status and start nothing.
  FeedReviewer

  /// Wake the idle primary with this continuation text, or steer its run
  /// when one opened between the level read and the send.
  WakePrimary(text: String)

  /// Run the operator's check and report what it did, as `Checked`
  /// against the deadline the goal's `Checking` phase now carries.
  ///
  /// It is the step before a feed rather than a part of it, so the frame
  /// the reviewer reads can carry the result as evidence. It is harness-
  /// opened work on a process of its own: it opens no run, so it can
  /// neither reset the continuation cap nor be mistaken for somebody
  /// arriving with work of their own.
  RunCheck(command: String)

  /// Tell the primary the loop has stopped and why, once. The status is
  /// already `Limited` in the goal this action comes with, and `Limited`
  /// rests, so the one-shot is structural rather than guarded: no later
  /// evaluation can reach this action again until the operator resumes.
  WrapUp(text: String)
}

// --- the transition --------------------------------------------------------

/// The goal after this occasion, and what the caller should do about it.
///
/// Total in both arguments: every combination of status, phase, event and
/// observation has an answer, and the answer for a state the loop cannot
/// legitimately be in is `Rest` with the goal unchanged. The properties
/// worth knowing, all of them tested in `goalloop_test`:
///
/// - An Active goal in the `Idle` or `ReadyToFeed` phase with an idle
///   primary and an idle reviewer never rests. That combination is the
///   stall the rework exists to remove, so it always answers
///   `FeedReviewer`, `RunCheck` when a check is configured and has not
///   run for this feed, or `WrapUp` when a bound is reached.
/// - A `Checking` phase rests only while its deadline is in the future.
///   At or past it the check is abandoned, recorded as evidence the
///   harness does not have, and the feed goes out — so a check can no
///   more strand the loop than an unanswered feed can.
/// - `Complete` is terminal: no event moves a complete goal.
/// - Only an operator command leaves `Paused` or `Limited`, and those
///   are the caller's, not this function's — every event here rests.
/// - The counters only grow toward their bounds, so no sequence of
///   continuations exceeds `continuation_cap`, and no sequence of
///   unanswered feeds exceeds `unanswered_feed_limit`.
///
/// ## Examples
///
/// ```gleam
/// let goal = goalstate.new("get the branch green", 400_000, 1000, accounted_from: 0)
/// let seen =
///   goalloop.Observed(
///     primary: option.None,
///     advisor: option.None,
///     progress: goalloop.Progressed,
///     woken_ending: goalloop.RanItsCourse,
///     event: goalloop.Level,
///     now_ms: 2000,
///     check_timeout_ms: goalloop.check_timeout_ms,
///   )
///
/// assert goalloop.next_action(goal, seen) == #(goal, goalloop.FeedReviewer)
/// ```
///
pub fn next_action(goal: Goal, observed: Observed) -> #(Goal, Action) {
  case observed.event {
    // The verdict is the one event that carries what the action needs,
    // so it is answered before the level read rather than through it.
    Answered(answer:) -> answer_feed(goal, answer, observed)

    Level
    | PrimaryStarted(..)
    | PrimaryEnded(..)
    | AdvisorEnded(..)
    | Aborted(..)
    | Checked(..) -> decide(record(goal, observed), observed)
  }
}

/// The goal with a sent feed's run recorded, which is what makes the
/// verdict the loop then waits for identifiable and its absence
/// observable.
///
/// ## Examples
///
/// ```gleam
/// // goalloop.feed_opened(goal, review_run, 2000).phase
/// //   == goalstate.AwaitingVerdict(feed: review_run)
/// ```
///
pub fn feed_opened(goal: Goal, feed: OpId, now_ms: Int) -> Goal {
  Goal(..goal, phase: goalstate.AwaitingVerdict(feed:), updated_ms: now_ms)
}

/// The goal after a feed the caller could not deliver at all.
///
/// A refused send counts against the same bound an unanswered feed does,
/// and for the same reason: the reviewer was not reached. Without it a
/// host whose send keeps failing would be re-offered the feed at every
/// periodic evaluation forever, which is a retry with no end rather than
/// a retry. Three failures pause the goal with `reviewer_unresponsive`,
/// where a transient one costs one delayed feed.
///
/// ## Examples
///
/// ```gleam
/// // goalloop.feed_refused(goal, 2000).unanswered_feeds == 1
/// ```
///
pub fn feed_refused(goal: Goal, now_ms: Int) -> Goal {
  unanswered(goal, now_ms)
}

/// The goal with a woken run recorded, which is what makes "a goal-woken
/// run" precise: the abort notice keys on this operation.
///
/// `since_seq` is where the primary's branch stood when the wake went out,
/// and it is the other half of the same precision — the zero-progress
/// predicate measures the stretch from here rather than from the feed
/// cursor, which a mid-run review moves.
///
/// ## Examples
///
/// ```gleam
/// // goalloop.primary_woken(goal, woken_run, 2000, since_seq: 41).phase
/// //   == goalstate.Continuing(woken: woken_run, since_seq: 41)
/// ```
///
pub fn primary_woken(
  goal: Goal,
  woken: OpId,
  now_ms: Int,
  since_seq since_seq: Int,
) -> Goal {
  Goal(..goal, phase: Continuing(woken:, since_seq:), updated_ms: now_ms)
}

/// Whether a stretch of the primary's branch did work toward an
/// objective.
///
/// A tool result is work by construction. An operator turn is work
/// because somebody steered. The harness's own frames are not: the
/// continuation the loop just delivered is a user message on the
/// primary's branch, and an earlier draft counted it, which is why the
/// zero-progress bound could never fire — the frame lands inside the
/// stretch the wake starts, so every woken stretch contained one and every
/// stretch "progressed". The frames are recognized by the two-token
/// discipline `client/advisorslice` owns, so a model cannot promote its
/// own output into work by quoting a header.
///
/// ## Examples
///
/// ```gleam
/// assert goalloop.progress_of([]) == goalloop.Stalled
/// ```
///
pub fn progress_of(entries: List(Entry)) -> Progress {
  case list.any(entries, did_work) {
    True -> Progressed
    False -> Stalled
  }
}

fn did_work(the_entry: Entry) -> Bool {
  case the_entry {
    entry.MessageEntry(message: message.ToolResultMessage(..), ..) -> True

    // A user message counts only when the harness did not write it.
    entry.MessageEntry(message: user, ..) -> operator_turn(user)

    entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> False
  }
}

// An operator turn is a user message that is not one of the harness's
// own frames. `advisorslice` answers `False` for every message that is
// not a user message, so an assistant turn falls out here as it should.
fn operator_turn(user: message.AgentMessage) -> Bool {
  case user {
    message.UserMessage(..) ->
      !advisorslice.is_advice(user)
      && !advisorslice.is_continuation(user)
      && !advisorslice.is_nudges(user)

    message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> False
  }
}

// --- reading the level -----------------------------------------------------

// What the occasion itself changes, before anything is decided from it.
// Each arm is one notification's bookkeeping; `relevel` is the same
// bookkeeping derived from the store, which is what repairs a
// notification that never arrived.
fn record(goal: Goal, observed: Observed) -> Goal {
  case observed.event {
    Level -> relevel(goal, observed)

    PrimaryStarted(operation:, origin:) ->
      started(goal, operation, origin, observed.now_ms)
    PrimaryEnded(operation:) -> ended(goal, operation, observed)
    AdvisorEnded(operation:) -> reviewed(goal, operation, observed)
    Aborted(operation:) -> aborted(goal, operation, observed.now_ms)
    Checked(deadline_ms:, result:) ->
      checked(goal, deadline_ms, result, observed.now_ms)

    // Answered never reaches here: `next_action` routes it to
    // `answer_feed`, which needs the answer's text.
    Answered(..) -> goal
  }
}

// The level read. The two phases that name a run are the two places a
// lost notification hides, and each is detected the same way: the store
// no longer shows that run open.
fn relevel(goal: Goal, observed: Observed) -> Goal {
  case goal.phase {
    Idle | goalstate.ReadyToFeed -> goal

    // A check whose deadline has passed is the third lost notification, and
    // it is repaired here rather than waited on: the task was killed at its
    // own wall, or the actor it would have reported to was replaced, and
    // either way no `Checked` is coming. The reviewer is fed with the
    // absence recorded as the evidence, which is what keeps a check from
    // stranding the loop.
    goalstate.Checking(deadline_ms:) ->
      case observed.now_ms >= deadline_ms {
        True -> check_abandoned(goal, observed)
        False -> goal
      }

    goalstate.AwaitingVerdict(feed:) ->
      case observed.advisor == Some(feed) {
        True -> goal
        False -> unanswered(goal, observed.now_ms)
      }

    Continuing(woken:, ..) ->
      case observed.primary == Some(woken) {
        True -> goal
        False -> woken_finished(goal, observed)
      }
  }
}

// The woken run is over, and how it ended decides what that means. An
// abort is the operator's "not now" about the loop's own run, and it must
// reach the same pause here as it does through the notice: this is the path
// a dropped `Aborted` cast leaves behind, and treating it as an ordinary
// finish is what turned a Ctrl-C into another continuation.
fn woken_finished(goal: Goal, observed: Observed) -> Goal {
  case observed.woken_ending {
    Cancelled -> hold_for_abort(goal, observed.now_ms)
    RanItsCourse -> woken_run_ended(goal, observed)
  }
}

// A run opening on the primary that this loop did not open is somebody
// arriving with work of their own, and that is what the continuation cap
// counts from. Without this reset the cap is a lifetime cap: the count
// only ever rose, so a resume after a trip tripped again on its first
// evaluation.
fn started(goal: Goal, operation: OpId, origin: Origin, now_ms: Int) -> Goal {
  case harness_opened(goal, operation, origin) {
    True -> goal

    False ->
      Goal(..goal, continuations: 0, zero_progress: 0, updated_ms: now_ms)
  }
}

// Whether the run that just opened is one the harness opened itself.
//
// Two answers, and both are needed. `origin` is the caller's record of what
// it woke, which is the only thing that knows about a nudge wake or a
// wrap-up. The phase is the second, because an actor that has just replaced
// a dead one has forgotten its heap and still reads `Continuing(woken)` from
// the cell — without it a restart mid-continuation would read the loop's own
// run as the operator arriving and forgive the cap.
fn harness_opened(goal: Goal, operation: OpId, origin: Origin) -> Bool {
  case origin {
    Harness -> True

    Foreign ->
      case goal.phase {
        Continuing(woken:, ..) -> woken == operation
        Idle
        | goalstate.Checking(..)
        | goalstate.ReadyToFeed
        | goalstate.AwaitingVerdict(..) -> False
      }
  }
}

// A run ending on the primary matters to the loop only when it is the
// run the loop opened: that is the stretch the zero-progress predicate
// is about.
fn ended(goal: Goal, operation: OpId, observed: Observed) -> Goal {
  case goal.phase {
    Continuing(woken:, ..) if woken == operation ->
      woken_finished(goal, observed)

    Idle
    | goalstate.Checking(..)
    | goalstate.ReadyToFeed
    | goalstate.AwaitingVerdict(..)
    | Continuing(..) -> goal
  }
}

// The woken run is over. Its stretch either did work, which clears the
// count, or it did not, which moves the goal one step toward the pause.
fn woken_run_ended(goal: Goal, observed: Observed) -> Goal {
  let returned = Goal(..goal, phase: Idle, updated_ms: observed.now_ms)

  case observed.progress {
    Progressed -> Goal(..returned, zero_progress: 0)
    Stalled -> stalled(returned)
  }
}

fn stalled(goal: Goal) -> Goal {
  let counted = Goal(..goal, zero_progress: goal.zero_progress + 1)

  case counted.zero_progress >= zero_progress_limit, counted.status {
    True, Active -> Goal(..counted, status: Paused(by: ByZeroProgress))

    // A goal the operator or a bound already stopped is not paused
    // again, and a complete one is terminal; the count is kept either
    // way, because a resume should not start from a clean slate the
    // evidence does not support.
    True, Paused(..) | True, Limited(..) | True, Complete | False, _ -> counted
  }
}

// The reviewer's run ended. When it is the run that owed a verdict, the
// feed was abandoned: the phase returns to idle so the next evaluation
// offers it again, bounded so a provider that never answers pauses the
// goal rather than being paid to refuse it forever.
fn reviewed(goal: Goal, operation: OpId, observed: Observed) -> Goal {
  case goal.phase {
    goalstate.AwaitingVerdict(feed:) if feed == operation ->
      unanswered(goal, observed.now_ms)

    Idle
    | goalstate.Checking(..)
    | goalstate.ReadyToFeed
    | goalstate.AwaitingVerdict(..)
    | Continuing(..) -> goal
  }
}

/// What a check that produced no status is recorded as.
///
/// A named function because two readers depend on the words: the frame the
/// reviewer reads, which must say plainly that the harness has no evidence
/// rather than imply a failure, and the test that proves an abandoned check
/// still feeds.
///
/// ## Examples
///
/// ```gleam
/// // goalloop.check_did_not_finish(300_000) names the wall in seconds
/// ```
///
pub fn check_did_not_finish(timeout_ms: Int) -> String {
  "the check did not finish inside the "
  <> int.to_string(timeout_ms / 1000)
  <> " seconds the harness allows it"
}

// A `Checking` phase past its deadline. The result is recorded as the
// absence it is, against the command the goal currently carries — the phase
// does not name the command, and a goal whose check was changed mid-run has
// already had its phase reset by that command, so this arm cannot be reached
// with the wrong one.
fn check_abandoned(goal: Goal, observed: Observed) -> Goal {
  let result =
    goalstate.CheckResult(
      command: option.unwrap(goal.check, ""),
      ending: goalstate.DidNotFinish(reason: check_did_not_finish(
        observed.check_timeout_ms,
      )),
      output: "",
      ran_at_ms: observed.now_ms,
    )

  Goal(
    ..goal,
    phase: goalstate.ReadyToFeed,
    last_check: Some(result),
    updated_ms: observed.now_ms,
  )
}

// A check run that reported back. It counts only against the phase it was
// started for: a result for any other deadline is a run this loop stopped
// waiting for, and recording it would show the reviewer evidence about a
// stretch of work that has since moved on.
fn checked(
  goal: Goal,
  deadline_ms: Int,
  result: goalstate.CheckResult,
  now_ms: Int,
) -> Goal {
  case goal.phase == goalstate.Checking(deadline_ms:) {
    True ->
      Goal(
        ..goal,
        phase: goalstate.ReadyToFeed,
        last_check: Some(result),
        updated_ms: now_ms,
      )

    False -> goal
  }
}

fn unanswered(goal: Goal, now_ms: Int) -> Goal {
  let counted =
    Goal(
      ..goal,
      phase: Idle,
      unanswered_feeds: goal.unanswered_feeds + 1,
      updated_ms: now_ms,
    )

  case counted.unanswered_feeds >= unanswered_feed_limit, counted.status {
    True, Active -> Goal(..counted, status: Paused(by: ByUnresponsiveReviewer))

    True, Paused(..) | True, Limited(..) | True, Complete | False, _ -> counted
  }
}

// The operator's abort, gated on the loop's own run. An abort of a run
// somebody else opened is the operator changing their mind about their
// own work, not about the goal, and the phase is what makes the
// difference readable rather than inferred.
fn aborted(goal: Goal, operation: OpId, now_ms: Int) -> Goal {
  case goal.phase {
    Continuing(woken:, ..) if woken == operation -> hold_for_abort(goal, now_ms)

    Idle
    | goalstate.Checking(..)
    | goalstate.ReadyToFeed
    | goalstate.AwaitingVerdict(..)
    | Continuing(..) -> goal
  }
}

fn hold_for_abort(goal: Goal, now_ms: Int) -> Goal {
  case goal.status {
    Active ->
      Goal(..goal, status: Paused(by: ByAbort), phase: Idle, updated_ms: now_ms)

    Paused(..) | Limited(..) | Complete -> goal
  }
}

// --- deciding --------------------------------------------------------------

// Three of the four statuses rest: `Complete` is terminal, and `Paused`
// and `Limited` are left by an operator command, which the caller
// applies before it asks this function anything.
fn decide(goal: Goal, observed: Observed) -> #(Goal, Action) {
  case goal.status {
    Paused(..) | Limited(..) | Complete -> #(goal, Rest)
    Active -> running(goal, observed)
  }
}

// A bound reached stops the loop wherever it stands, including inside a
// run. The budget is checked before the phase because a primary that
// crossed its budget mid-run should be told to stop soon rather than at
// an idle boundary it may be an hour from reaching.
fn running(goal: Goal, observed: Observed) -> #(Goal, Action) {
  case bound(goal) {
    Some(cause) -> stop(goal, cause, observed.now_ms)
    None -> await(goal, observed)
  }
}

// What the level says to do with a goal that is running and inside its
// bounds. The two phases that name a run have already been relevelled,
// so a phase that still names one names a run that is genuinely open.
fn await(goal: Goal, observed: Observed) -> #(Goal, Action) {
  case goal.phase {
    goalstate.AwaitingVerdict(..) | Continuing(..) -> #(goal, Rest)

    // A check inside its deadline is work in flight, and the loop waits for
    // it the way it waits for a review. `relevel` has already turned a
    // deadline that passed into `ReadyToFeed`, so this arm rests only while
    // there is genuinely something to wait for.
    goalstate.Checking(..) -> #(goal, Rest)

    Idle | goalstate.ReadyToFeed -> offer(goal, observed)
  }
}

// The occasion: an Active goal, nothing owed, and neither strand busy.
// This is the one arm that must never rest, because resting here is the
// stall — an idle primary has no next occasion to be woken at.
fn offer(goal: Goal, observed: Observed) -> #(Goal, Action) {
  case observed.primary, observed.advisor {
    // The primary is working. The feed's occasion is its run end, which
    // the loop will be told about and would find at the next level read
    // regardless.
    Some(_working), _either -> #(goal, Rest)

    // The reviewer is mid-review. The feed coalesces with it: the cursor
    // stays put, so the next evaluation offers the same stretch as one
    // larger slice.
    None, Some(_reviewing) -> #(goal, Rest)

    None, None -> checked_or_fed(goal, observed)
  }
}

// The feed, or the check that precedes it. An operator who pinned a check
// wants the reviewer to see its result, so the check is run first and the
// phase records that one is owed; a goal with no check feeds directly, which
// is every goal before this feature and every goal after it whose operator
// pinned no command.
//
// `ReadyToFeed` is what keeps the pair from looping: the check moves the
// phase, and the evaluation that reads the moved phase feeds rather than
// checking again.
fn checked_or_fed(goal: Goal, observed: Observed) -> #(Goal, Action) {
  case goal.phase, goal.check {
    goalstate.Idle, Some(command) -> #(
      Goal(
        ..goal,
        phase: goalstate.Checking(
          deadline_ms: observed.now_ms + observed.check_timeout_ms,
        ),
        updated_ms: observed.now_ms,
      ),
      RunCheck(command:),
    )

    // Either the check has already run for this feed, or there is none to
    // run. Both feed, and both carry whatever the cell's last result is —
    // which for a goal with no check is nothing.
    goalstate.ReadyToFeed, _either | goalstate.Idle, None -> #(
      goal,
      FeedReviewer,
    )

    // Unreachable: `await` reaches this function from the two phases above
    // and from no other. The arm keeps the match total without a catch-all,
    // and resting is the answer that cannot act on a phase this function
    // does not understand.
    goalstate.Checking(..), _any
    | goalstate.AwaitingVerdict(..), _other
    | Continuing(..), _third
    -> #(goal, Rest)
  }
}

// --- answering a feed ------------------------------------------------------

// A verdict acts only against the level it was asked for. A verdict
// arriving against any other is a stale answer — the feed was closed by
// a run that ended, or the operator moved the goal while the reviewer
// judged — and acting on one would wake a primary toward a goal the cell
// no longer records.
//
// A stale verdict is nonetheless still an occasion, so it falls through
// to the level read rather than resting. That is deliberate and is what
// makes the no-stall invariant unconditional: if the stale arm rested,
// an Active goal with an idle primary, an idle reviewer and nothing owed
// would have one event that left it stopped with nothing scheduled —
// the exact shape the rework removes — and the only thing preventing it
// would be the caller's own refusal, one module away from the invariant.
fn answer_feed(
  goal: Goal,
  answer: Answer,
  observed: Observed,
) -> #(Goal, Action) {
  case goal.phase, goal.status {
    goalstate.AwaitingVerdict(..), Active -> settle(goal, answer, observed)

    Idle, _any
    | goalstate.Checking(..), _second
    | goalstate.ReadyToFeed, _third
    | Continuing(..), _other
    | goalstate.AwaitingVerdict(..), Paused(..)
    | goalstate.AwaitingVerdict(..), Limited(..)
    | goalstate.AwaitingVerdict(..), Complete
    -> decide(goal, observed)
  }
}

fn settle(goal: Goal, answer: Answer, observed: Observed) -> #(Goal, Action) {
  // The feed was answered, whichever word answered it, so the
  // unanswered count starts again from zero.
  let answered =
    Goal(..goal, phase: Idle, unanswered_feeds: 0, updated_ms: observed.now_ms)

  case answer {
    Completed(text:) -> #(
      Goal(..answered, status: Complete, reviewer_note: Some(text)),
      Rest,
    )

    Continued(text:) -> continue_work(answered, text, observed.now_ms)
  }
}

// A `continue` the bounds allow. The count rises before the wake rather
// than after it, so a crash between the cell write and the send costs
// one continuation of headroom rather than an uncounted turn.
fn continue_work(goal: Goal, text: String, now_ms: Int) -> #(Goal, Action) {
  case bound(goal) {
    Some(cause) -> stop(goal, cause, now_ms)

    None -> #(
      Goal(..goal, continuations: goal.continuations + 1),
      WakePrimary(text:),
    )
  }
}

// --- the bounds, read ------------------------------------------------------

// The two bounds a running goal is held to, in the order protocol 044 §4
// states them. The zero-progress predicate is not here: it is measured
// on a stretch of work, so it moves the status where the stretch ends
// rather than being re-derived on every evaluation.
fn bound(goal: Goal) -> Option(LimitCause) {
  case
    goal.tokens_used >= goal.token_budget,
    goal.continuations >= continuation_cap
  {
    True, _either -> Some(ByTokenBudget)
    False, True -> Some(ByContinuationCap)
    False, False -> None
  }
}

fn stop(goal: Goal, cause: LimitCause, now_ms: Int) -> #(Goal, Action) {
  #(
    Goal(..goal, status: Limited(by: cause), phase: Idle, updated_ms: now_ms),
    WrapUp(text: wrap_up_text(cause)),
  )
}

/// What the primary is told when a bound stops the loop, worded per
/// cause.
///
/// One wording per cause because the two are different instructions: a
/// goal that spent its tokens has no more room to work in, and a goal
/// that took its autonomous turns has room but has stopped being
/// steered. An earlier draft told the primary its token budget was
/// exhausted whichever bound had tripped, which is a false statement
/// half the time.
///
/// ## Examples
///
/// ```gleam
/// // goalloop.wrap_up_text(goalstate.ByContinuationCap)
/// //   mentions the autonomous turns rather than the token budget
/// ```
///
pub fn wrap_up_text(cause: LimitCause) -> String {
  case cause {
    ByTokenBudget ->
      "the session goal's token budget is exhausted; wrap up the current "
      <> "step, summarize what you did and name what remains"

    ByContinuationCap ->
      "the session goal has taken all the consecutive turns the harness "
      <> "allows without the operator; wrap up the current step, summarize "
      <> "what you did and name what remains"
  }
}

/// Why the operator is told a goal stopped, worded per status.
///
/// The panel and every refusal read this, so the wording lives once:
/// four pauses and two limits that the status word `paused` and
/// `budget_limited` cannot tell apart on their own.
///
/// ## Examples
///
/// ```gleam
/// // goalloop.stopped_because(goalstate.Paused(by: goalstate.ByAbort))
/// //   == "you aborted the run the goal loop had started"
/// ```
///
pub fn stopped_because(status: goalstate.Status) -> String {
  case status {
    Active -> "the goal is running"
    Complete -> "the reviewer judged the objective achieved"

    Paused(by: ByOperator) -> "you paused it"
    Paused(by: ByAbort) -> "you aborted the run the goal loop had started"
    Paused(by: ByZeroProgress) ->
      "two goal-woken runs in a row produced no work toward the objective"
    Paused(by: ByUnresponsiveReviewer) ->
      "the reviewer was offered the goal repeatedly and never answered"

    Limited(by: ByTokenBudget) -> "the goal's token budget is exhausted"
    Limited(by: ByContinuationCap) ->
      "the goal took all "
      <> int.to_string(continuation_cap)
      <> " consecutive turns the harness allows without you"
  }
}
