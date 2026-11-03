//// A ticket's stage: a pure function of ticket facts, shipped on the wire as
//// a string so that no client reimplements it.
////
//// The first matching row wins, so the order of the rows is the meaning. An
//// ended ticket comes first, because a stale question on a merged ticket asks
//// nothing of anyone. Then the rows that need a person, most urgent first: an
//// input that never reached the worker, an open question, a review. Then the
//// worker's own distress, which a person's later message clears. Last the
//// states that need nobody: waiting for a session, idle, working.
////
//// A review row stands only while the work is still. A worker is at work when
//// its assignment is running and it has not reported `waiting`, `blocked`,
//// `failed` or `dropped` since a person last spoke: a resumed assignment
//// starts with no report, so it reads `working` while it changes work that a
//// person was told to review. A worker at rest, an ended assignment and a
//// pending one leave the review row in force.
////
//// | row | stage | condition |
//// | --- | --- | --- |
//// | 1 | `ended/<outcome>` | the ticket ended |
//// | 2 | `person/delivery` | an input failed to reach the worker |
//// | 3 | `person/answer` | an open question for a person |
//// | 4 | `person/review` | awaiting review, or a pull request open on a ready or published ticket, unless a running assignment's worker is at work |
//// | 5 | `person/blocked`, `person/failed` | the latest report says so and no person has spoken since |
//// | 6 | `person/check` | the check failed at the head and nobody is handling it: no worker is at work, none was sent back to it and no session is on its way |
//// | 7 | `queued` | never assigned, the assignment is pending, or a session is wanted |
//// | 8 | `idle` | the latest report is `waiting` and no person has spoken since, or the latest assignment ended |
//// | 9 | `working` | otherwise |
////
//// Row 6 is its own stage because the two rows that could have held it say
//// something else. `person/review` stands on a readiness that a failed check
//// never reaches (`InProgress`), and a review is the question of whether to
//// publish work that passed or was never checked. `person/blocked` is the
//// worker's own report. A failed check that a worker is fixing reads
//// `working`, since somebody is handling it; one that is not being handled
//// must not read `idle`, which the board draws as needing nobody.

import gleam/option.{type Option, None, Some}
import gleam/string
import project/model.{
  type Demand, type Heard, type Outcome, type Question, type Report, Abandoned,
  Asking, Blocked, Closed, Failed, Merged, PersonHeard, Satisfied,
  StoppedByPerson, Waiting, Wanting,
}

/// Whether any input to the worker failed to arrive.
pub type Delivery {
  /// Every input arrived.
  DeliveryClear

  /// At least one input did not arrive.
  DeliveryFailed
}

/// Where the ticket is in review.
pub type ReviewFact {
  /// Not in review.
  NotInReview

  /// A person has to look; no check ran.
  InReview

  /// A ready or published ticket whose pull request is open.
  PullRequestOpen
}

/// Whether the check failed at the head, and who is handling it.
pub type CheckFact {
  /// No failed check stands at the head.
  CheckClear

  /// A failed check stands at the head.
  CheckFailing(
    /// Whether the worker was sent back to it.
    handling: model.Handling,
  )
}

/// What the ticket's latest assignment is doing.
pub type AssignmentFact {
  /// No assignment was ever made.
  NeverAssigned

  /// The latest assignment awaits its session.
  LatestPending

  /// The latest assignment's session is running.
  LatestLive

  /// The latest assignment ended.
  LatestEnded
}

/// Everything a stage is computed from.
pub type Facts {
  Facts(
    /// How the ticket ended, if it did.
    outcome: Option(Outcome),
    /// Whether an input failed to arrive.
    delivery: Delivery,
    /// The open question, if any.
    question: Question,
    /// Where the ticket is in review.
    review: ReviewFact,
    /// The worker's latest report, if any.
    latest: Option(Report),
    /// Whether a person has spoken since that report.
    heard: Heard,
    /// What the latest assignment is doing.
    assignment: AssignmentFact,
    /// Whether the ticket awaits a session.
    demand: Demand,
    /// Whether the check failed at the head, and who is handling it.
    check: CheckFact,
  )
}

/// A ticket's stage.
pub type Stage {
  /// The ticket ended.
  StageEnded(
    /// How.
    outcome: Outcome,
  )

  /// An input failed to reach the worker.
  PersonDelivery

  /// A question awaits a person.
  PersonAnswer

  /// A person must review.
  PersonReview

  /// The worker is blocked.
  PersonBlocked

  /// The worker's attempt failed.
  PersonFailed

  /// The check failed at the head and nobody is handling it.
  PersonCheck

  /// The ticket waits for a session.
  Queued

  /// Nothing is running and nothing is wanted.
  Idle

  /// A session is working.
  Working
}

/// Compute the stage. Exhaustive: the last row matches everything.
///
/// ## Examples
///
/// ```gleam
/// let facts = stage.Facts(
///   outcome: option.None,
///   delivery: stage.DeliveryClear,
///   question: model.NoQuestion,
///   review: stage.NotInReview,
///   latest: option.None,
///   heard: model.Silent,
///   assignment: stage.NeverAssigned,
///   demand: model.Satisfied,
///   check: stage.CheckClear,
/// )
/// assert stage.of(facts) == stage.Queued
/// ```
pub fn of(facts: Facts) -> Stage {
  case facts.outcome {
    Some(outcome) -> StageEnded(outcome)
    None -> open_stage(facts)
  }
}

/// The rows for a ticket that has not ended.
fn open_stage(facts: Facts) -> Stage {
  case facts.delivery, facts.question, facts.review {
    DeliveryFailed, _, _ -> PersonDelivery
    DeliveryClear, Asking(_), _ -> PersonAnswer
    DeliveryClear, model.NoQuestion, InReview -> review_stage(facts)
    DeliveryClear, model.NoQuestion, PullRequestOpen -> review_stage(facts)
    DeliveryClear, model.NoQuestion, NotInReview -> distress_stage(facts)
  }
}

/// Row 4: a person is asked to review unless the worker is still changing the
/// work, in which case the ticket is working and the review waits for it.
fn review_stage(facts: Facts) -> Stage {
  case worker_at_work(facts) {
    AtWork -> Working
    AtRest -> PersonReview
  }
}

/// Whether the work under review can still change.
type Activity {
  /// A running assignment's worker has not come to rest.
  AtWork

  /// No assignment is running, or its worker has reported that it waits.
  AtRest
}

/// A worker is at work when its assignment is running and either a person has
/// spoken since its latest report, which the worker is handling, or it has
/// reported nothing yet or only progress. A resumed assignment begins with no
/// report, so it is at work from its first moment.
fn worker_at_work(facts: Facts) -> Activity {
  case facts.assignment, facts.heard, facts.latest {
    LatestLive, PersonHeard, _ -> AtWork
    LatestLive, model.Silent, None -> AtWork
    LatestLive, model.Silent, Some(model.Progress) -> AtWork
    LatestLive, model.Silent, Some(Waiting(_)) -> AtRest
    LatestLive, model.Silent, Some(Blocked) -> AtRest
    LatestLive, model.Silent, Some(Failed) -> AtRest
    LatestLive, model.Silent, Some(model.Dropped) -> AtRest
    NeverAssigned, _, _ -> AtRest
    LatestPending, _, _ -> AtRest
    LatestEnded, _, _ -> AtRest
  }
}

/// Rows 5 to 9: the worker's own report, then the failed check, then the
/// states needing nobody.
fn distress_stage(facts: Facts) -> Stage {
  case facts.heard {
    PersonHeard -> check_stage(facts)
    model.Silent ->
      case facts.latest {
        Some(Blocked) -> PersonBlocked
        Some(Failed) -> PersonFailed
        Some(model.Progress) -> check_stage(facts)
        Some(Waiting(_)) -> check_stage(facts)
        Some(model.Dropped) -> check_stage(facts)
        None -> check_stage(facts)
      }
  }
}

/// Row 6: a failed check at the head. A session on its way is somebody
/// handling it, a worker at work is, and a worker that was sent back to it is
/// until its first report. Otherwise a person is.
fn check_stage(facts: Facts) -> Stage {
  case facts.check {
    CheckClear -> quiet_stage(facts)
    CheckFailing(handling) ->
      case facts.assignment, facts.demand {
        LatestPending, _ -> Queued
        LatestLive, Wanting(_) -> Queued
        LatestEnded, Wanting(_) -> Queued
        NeverAssigned, _ -> PersonCheck
        LatestLive, Satisfied -> live_check_stage(facts, handling)
        LatestEnded, Satisfied -> PersonCheck
      }
  }
}

/// A live worker handles a failed check while it is at work or has just been
/// sent back to it.
fn live_check_stage(facts: Facts, handling: model.Handling) -> Stage {
  case worker_at_work(facts), handling {
    AtWork, _ -> Working
    AtRest, model.WorkerTold -> Working
    AtRest, model.PersonNeeded -> PersonCheck
  }
}

/// Rows 6 to 8, which need no person.
fn quiet_stage(facts: Facts) -> Stage {
  case facts.assignment, facts.demand {
    NeverAssigned, _ -> Queued
    LatestPending, _ -> Queued
    LatestLive, Wanting(_) -> Queued
    LatestEnded, Wanting(_) -> Queued
    LatestLive, Satisfied -> live_stage(facts)
    LatestEnded, Satisfied -> Idle
  }
}

/// A running session is idle when its latest report is `waiting` and nobody
/// has spoken to it since. A person's answer or message after that report is
/// work the session has been handed, so it reads `working` until the worker
/// reports again. Without that, an answered ticket read `idle` with a worker on
/// it that had been given something to do.
fn live_stage(facts: Facts) -> Stage {
  case facts.latest, facts.heard {
    Some(Waiting(_)), model.Silent -> Idle
    Some(Waiting(_)), PersonHeard -> Working
    Some(_), _ -> Working
    None, _ -> Working
  }
}

/// Whether the stage asks something of a person.
///
/// ## Examples
///
/// ```gleam
/// assert stage.needs_person(stage.PersonAnswer)
/// assert !stage.needs_person(stage.Working)
/// ```
pub fn needs_person(stage: Stage) -> Bool {
  case stage {
    PersonDelivery -> True
    PersonAnswer -> True
    PersonReview -> True
    PersonBlocked -> True
    PersonFailed -> True
    PersonCheck -> True
    StageEnded(_) -> False
    Queued -> False
    Idle -> False
    Working -> False
  }
}

/// The stage as the wire spells it.
///
/// ## Examples
///
/// ```gleam
/// assert stage.to_string(stage.PersonReview) == "person/review"
/// assert stage.to_string(stage.StageEnded(model.Merged)) == "ended/merged"
/// ```
pub fn to_string(stage: Stage) -> String {
  case stage {
    StageEnded(outcome) -> "ended/" <> outcome_string(outcome)
    PersonDelivery -> "person/delivery"
    PersonAnswer -> "person/answer"
    PersonReview -> "person/review"
    PersonBlocked -> "person/blocked"
    PersonFailed -> "person/failed"
    PersonCheck -> "person/check"
    Queued -> "queued"
    Idle -> "idle"
    Working -> "working"
  }
}

/// Read a stage back from its wire spelling.
///
/// ## Examples
///
/// ```gleam
/// assert stage.parse("queued") == Ok(stage.Queued)
/// assert stage.parse("nonsense") == Error(Nil)
/// ```
pub fn parse(text: String) -> Result(Stage, Nil) {
  case text {
    "person/delivery" -> Ok(PersonDelivery)
    "person/answer" -> Ok(PersonAnswer)
    "person/review" -> Ok(PersonReview)
    "person/blocked" -> Ok(PersonBlocked)
    "person/failed" -> Ok(PersonFailed)
    "person/check" -> Ok(PersonCheck)
    "queued" -> Ok(Queued)
    "idle" -> Ok(Idle)
    "working" -> Ok(Working)
    _ -> parse_ended(text)
  }
}

// The `ended/<outcome>` family.
fn parse_ended(text: String) -> Result(Stage, Nil) {
  case string.split_once(text, "/") {
    Ok(#("ended", word)) -> parse_outcome(word) |> map_ended
    _ -> Error(Nil)
  }
}

fn map_ended(outcome: Result(Outcome, Nil)) -> Result(Stage, Nil) {
  case outcome {
    Ok(found) -> Ok(StageEnded(found))
    Error(Nil) -> Error(Nil)
  }
}

/// The word an outcome has on the wire.
///
/// ## Examples
///
/// ```gleam
/// assert stage.outcome_string(model.Merged) == "merged"
/// ```
pub fn outcome_string(outcome: Outcome) -> String {
  case outcome {
    Merged -> "merged"
    Closed -> "closed"
    Abandoned -> "abandoned"
    StoppedByPerson -> "stopped"
  }
}

/// Read an outcome back from its word.
///
/// ## Examples
///
/// ```gleam
/// assert stage.parse_outcome("merged") == Ok(model.Merged)
/// ```
pub fn parse_outcome(word: String) -> Result(Outcome, Nil) {
  case word {
    "merged" -> Ok(Merged)
    "closed" -> Ok(Closed)
    "abandoned" -> Ok(Abandoned)
    "stopped" -> Ok(StoppedByPerson)
    _ -> Error(Nil)
  }
}
