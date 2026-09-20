//// The session goal's durable shape, as pure data.
////
//// A goal is an operator-pinned objective the session keeps working
//// toward across runs (protocol 044). The cell this module encodes —
//// `goal/state` under the reserved `goal/` prefix — is written by
//// exactly one writer, the advisor actor, and read by every observer of
//// the session. The field names are frozen by protocol 044 §1; changing
//// one is a protocol-change proposal, never an edit here.
////
//// ## Why the loop's phase is in the cell and not in the actor's heap
////
//// The cell carries more than the operator's answer to "what am I
//// working on". It carries `phase`: whether a goal feed is open and
//// which advisor run owes the verdict, or which primary run the loop
//// itself opened. An earlier draft kept those in the actor's heap, and
//// every way of losing that heap — a daemon restart, a supervisor
//// restart, a reviewer run that ended without answering — left an
//// Active goal with nothing running and nothing shown to the operator.
//// A restart that reads this cell knows a verdict is owed and by which
//// run, so it can re-offer the feed rather than wait for an occasion
//// that cannot occur. The three counters beside it — `continuations`,
//// `zero_progress`, `unanswered_feeds` — are durable for the same
//// reason: each bounds the loop, and a bound a restart forgets is not a
//// bound.
////
//// ## Why the codec is strict about required fields and lenient about optional ones
////
//// The guard's decoder tolerates an absent field because its writer grew
//// over time and the cost of forgetting is one duplicate block. This
//// cell is the mirror case: it is only ever written whole by its owner,
//// so a payload missing `objective`, `status` or `phase` is a writer
//// disagreeing with this decoder — an error, never a silent default. The
//// fields that may be absent are the counters, the cost and the nullable
//// ones, each of which has a zero value that means "nothing recorded
//// yet": the reviewer's note, the operator's check command and the last
//// check result among them, so a cell written before the check existed
//// decodes as a goal with no check rather than as a refusal. A field that
//// is *present* and mistyped is an error naming the field, whatever its
//// seniority.
////
//// ## What this module deliberately does not do
////
//// No status transitions live here. Which status a bound trips to, when
//// a feed is owed and when the loop rests are `client/goalloop`'s, which
//// is pure for the same reasons this module is and is property-tested
//// because of it. `new` does not validate the objective's length either
//// — the 4,000-character bound is `client/protocol`'s own refusal on the
//// `goal_set` body (`objective_limit`), worded for the operator with both
//// counts, because a codec error naming a bound is not a message the
//// operator ever reads.

import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Why a goal is being held rather than run.
///
/// The cause is carried because the status alone tells the operator
/// nothing actionable: a goal the operator paused, one an abort held, one
/// the harness stopped because two woken runs produced no work, and one
/// it stopped because the reviewer never answered are four different
/// things to do next, and `paused` names all four.
pub type PauseCause {
  /// The operator asked, through `goal_pause`. `goal_resume` continues.
  ByOperator

  /// The operator aborted a run the loop itself opened. Held rather than
  /// cleared: a Ctrl-C on the loop's own run is "not now", not "never".
  ByAbort

  /// Two consecutive woken runs committed no work toward the objective.
  /// A reviewer-primary pair answering `continue` to nothing is a loop
  /// nobody is steering, so the harness stops it rather than spending
  /// the budget's tail on it.
  ByZeroProgress

  /// The reviewer was offered the goal feed and its run ended without a
  /// verdict, repeatedly. A provider that will not answer the goal words
  /// pauses the goal instead of re-feeding it forever.
  ByUnresponsiveReviewer
}

/// Why the harness stopped continuing a goal it was otherwise running.
///
/// Both trip to the same wire word (`budget_limited`) because both are
/// the same thing to the operator's resume, and to different causes
/// because a goal that spent its budget and a goal that took its whole
/// cap of autonomous turns need different answers: a larger budget, or a
/// look at why those turns did not finish it.
pub type LimitCause {
  /// The accounted primary spend reached the required token budget.
  ByTokenBudget

  /// The loop took its cap of continuations since the last run start it
  /// did not open.
  ByContinuationCap
}

/// The state machine's four states, as one word each on the wire, with
/// the two stopped ones carrying their cause.
///
/// Who may move a goal into a state is part of the state's meaning, so it
/// is documented per variant rather than in one table: a reader deciding
/// whether a transition was legal needs the answer where the variant is.
pub type Status {
  /// The loop is running. Set by the operator (`goal_set`, `resume`)
  /// and left by every other transition's exit; only a status the actor
  /// may leave, never one a model may enter.
  Active

  /// Held, for one of four causes. `/goal resume` continues from any of
  /// them.
  Paused(by: PauseCause)

  /// The harness stopped continuing: the token budget, or the
  /// continuation cap. The operator resumes with the budget still
  /// exhausted, or refreshes the goal with a larger one.
  Limited(by: LimitCause)

  /// Terminal. Only the reviewer's `complete` verdict enters it — never
  /// the primary, never the operator — and the reviewer's note is
  /// recorded with it. A new goal starts a fresh cell.
  Complete
}

/// Where the loop stands between messages: nothing owed, a verdict owed
/// by a named advisor run, or a named primary run the loop itself opened.
///
/// This is the field that makes the loop level-triggered. Every
/// evaluation compares the phase against what the store actually shows
/// running, so a missed notification is corrected by the next evaluation
/// instead of stranding the goal: an `AwaitingVerdict` whose advisor run
/// is no longer open is a feed that was never answered, and a
/// `Continuing` whose primary run is no longer open is a woken run whose
/// end the actor can act on even when the cast that announced it was
/// lost.
pub type Phase {
  /// Nothing is owed in either direction. The occasion for a goal feed
  /// is an Active goal in this phase with an idle primary.
  Idle

  /// The operator's check is running in a jailed process and its result
  /// is owed to this loop before the reviewer is fed.
  ///
  /// `deadline_ms` is the wall-clock instant past which the result will
  /// not be waited for. It is durable because the wait must survive the
  /// actor: the task is linked to the actor, so an actor that dies takes
  /// an in-flight check with it, and what a replacement reads is this
  /// phase. A deadline already passed is therefore not an error but the
  /// repair — the next evaluation records "the check did not finish" as
  /// the evidence and feeds the reviewer with it, which is why a check
  /// can no more strand the loop than a feed can.
  Checking(deadline_ms: Int)

  /// A check has been recorded and the feed it was run for has not gone
  /// out yet.
  ///
  /// It exists so the check runs once per feed rather than in a loop with
  /// it: without a phase between the two, the evaluation that found an
  /// Idle goal with a check configured would start another check every
  /// time it read the same level. It is unreachable on a goal with no
  /// check configured.
  ReadyToFeed

  /// A goal feed is open on the advisor and one `continue` or `complete`
  /// is owed. `feed` is the advisor run the feed opened, so the loop can
  /// tell the verdict it is waiting for from a stale one, and can see
  /// that the run ended without answering.
  AwaitingVerdict(feed: OpId)

  /// The loop woke the primary with a continuation and that run is
  /// working. `woken` is the run, which is what makes "a goal-woken run"
  /// precise rather than inferred: the abort notice keys on it.
  ///
  /// `since_seq` is where the primary's branch stood when the wake went
  /// out, and it is what the zero-progress predicate measures from. The
  /// feed cursor cannot serve: a mid-run feed advances it, so a working run
  /// whose last step happened to trip `feed_every_steps` was measured over
  /// the handful of entries after that feed and read as having done
  /// nothing. Two of those paused a goal that was working.
  Continuing(woken: OpId, since_seq: Int)
}

/// How a check run ended, which is the fact the reviewer weighs.
///
/// Two variants rather than an exit status and a nullable reason, because
/// the two are different evidence: a status is what the operator's command
/// said about the work, and a check that never finished says nothing about
/// the work at all. A reviewer shown `exit 1` should weigh it against
/// `complete`; a reviewer shown "the check did not finish" should weigh the
/// transcript instead, and collapsing the pair into a status would hand it
/// a number nobody produced.
pub type CheckEnding {
  /// The command ran to its own exit with this status. Zero is a pass.
  Exited(status: Int)

  /// The command produced no status. `reason` is the harness's own words
  /// for why — the deadline passed, the task died, the sandbox refused the
  /// command — and it is what the feed shows in the status's place.
  DidNotFinish(reason: String)
}

/// What one run of the operator's check produced.
///
/// The command is recorded beside the result rather than read from the
/// goal's own `check` field at render time, because the two can disagree:
/// an operator who changes the check while a run is in flight would
/// otherwise see the old run's output labelled with the new command, and so
/// would the reviewer.
pub type CheckResult {
  CheckResult(
    /// The command as it was run.
    command: String,
    /// How it ended.
    ending: CheckEnding,
    /// A bounded tail of what it printed, already clipped by the runner.
    /// Untrusted data: it is process output, so it reaches a model only
    /// inside a frame that has been made safe against its own tokens.
    output: String,
    /// When the run was recorded. Milliseconds since the epoch.
    ran_at_ms: Int,
  )
}

/// One session goal: the operator's objective, the loop's phase, and the
/// accounting and counters that bound it. Frozen by protocol 044 §1.
pub type Goal {
  Goal(
    /// The operator-pinned objective text. Untrusted data: it reaches
    /// models only inside a frame, and its length bound is enforced by the
    /// `goal_set` decoder in `client/protocol`, not here.
    objective: String,
    /// Where the goal is in the state machine above.
    status: Status,
    /// Where the loop is between messages.
    phase: Phase,
    /// The required positive token budget. v1 has no unbounded goals, so
    /// there is no optional variant to carry.
    token_budget: Int,
    /// The accounted token total, summed by the one code path that adds:
    /// the ledger scan past `accounted_through_seq`.
    tokens_used: Int,
    /// The newest usage row the total covers. The accounting's durable
    /// claim, because the usage hook is at-most-once and non-replayable.
    accounted_through_seq: Int,
    /// The summed dollar cost of accounted rows, recorded for display
    /// and never for gating.
    cost_used: Float,
    /// Goal continuations since the last run start on the primary the
    /// loop did not open. Reset there, so the cap bounds one autonomous
    /// stretch rather than the goal's whole life.
    continuations: Int,
    /// Consecutive woken runs that committed no work toward the
    /// objective.
    zero_progress: Int,
    /// Consecutive goal feeds whose reviewer run ended without a
    /// verdict. Bounds the re-feed, so a provider that never answers
    /// pauses the goal instead of looping.
    unanswered_feeds: Int,
    /// When the goal was pinned. Milliseconds since the epoch.
    created_ms: Int,
    /// When the goal last moved. Milliseconds since the epoch, and
    /// never before `created_ms`.
    updated_ms: Int,
    /// The text the reviewer sent with its terminal verdict. `None`
    /// until a `complete` lands.
    reviewer_note: Option(String),
    /// The operator's check command, or `None` when they pinned none.
    ///
    /// Operator-authored and therefore not model-influenced text — but it
    /// still runs through the capability-checked jail an ordinary tool
    /// command does, because Rule Zero is about where code runs rather than
    /// about who wrote it (protocol 044 §8).
    check: Option(String),
    /// What the last run of the check produced, or `None` when none has
    /// run under this goal yet. Recorded for the feed frame the reviewer
    /// reads and for the operator's panel.
    last_check: Option(CheckResult),
  )
}

// Every decode error is prefixed with where it came from, so an operator
// holding a refused cell can find the decoder that refused it.
const decode_where = "client/goalstate.decode"

/// A fresh goal: active, idle, with zeroed counters and no reviewer note.
///
/// Total and unvalidated by design. The objective's non-empty and
/// 4,000-character bounds are the `goal_set` decoder's refusal — a
/// message worded for the operator with the actual and maximum counts —
/// and the budget's positivity is re-checked by `decode` on every read,
/// which is where a bad value would actually be caught.
///
/// `accounted_from` is where the accounting starts, and it is an argument
/// rather than a zero because zero is wrong on every session that has
/// already spent anything: the sum is "every usage row past this cursor
/// attributed to the primary", so a goal pinned with the cursor at zero
/// charges the whole session's prior spend to the budget the operator just
/// set and trips it before the loop runs once. The caller passes the
/// ledger's newest seq at pin time; a caller with no ledger to read passes
/// zero and means it.
///
/// ## Examples
///
/// ```gleam
/// let goal =
///   goalstate.new(
///     "land the migration",
///     400_000,
///     1_726_000_000_000,
///     accounted_from: 0,
///   )
///
/// assert goalstate.status_of(goal) == goalstate.Active
/// assert goal.phase == goalstate.Idle
/// assert goalstate.tokens_used_of(goal) == 0
/// ```
///
pub fn new(
  objective: String,
  token_budget: Int,
  now: Int,
  accounted_from accounted_from: Int,
) -> Goal {
  Goal(
    objective:,
    status: Active,
    phase: Idle,
    token_budget:,
    tokens_used: 0,
    accounted_through_seq: accounted_from,
    cost_used: 0.0,
    continuations: 0,
    zero_progress: 0,
    unanswered_feeds: 0,
    created_ms: now,
    updated_ms: now,
    reviewer_note: None,
    check: None,
    last_check: None,
  )
}

// The three read accessors below exist because `Goal` is a plain record
// a caller could reach into, but the tests and the actor should say what
// they want rather than spell the field list to get it. They are the
// fields a test asserts on most; the rest are read directly.

/// The goal's status.
///
/// ## Examples
///
/// ```gleam
/// assert goalstate.status_of(goalstate.new("x", 100, 0, accounted_from: 0))
///   == goalstate.Active
/// ```
///
pub fn status_of(goal: Goal) -> Status {
  goal.status
}

/// The goal's accounted token total.
///
/// ## Examples
///
/// ```gleam
/// assert goalstate.tokens_used_of(
///   goalstate.new("x", 100, 0, accounted_from: 0),
/// )
///   == 0
/// ```
///
pub fn tokens_used_of(goal: Goal) -> Int {
  goal.tokens_used
}

/// The reviewer's note, if one has arrived.
///
/// ## Examples
///
/// ```gleam
/// assert goalstate.reviewer_note_of(goalstate.new("x", 100, 0, accounted_from: 0))
///   == option.None
/// ```
///
pub fn reviewer_note_of(goal: Goal) -> Option(String) {
  goal.reviewer_note
}

/// The status as its wire word. The four words of protocol 044 §1; the
/// cause of a stopped status rides `encode_reason` beside it.
///
/// ## Examples
///
/// ```gleam
/// assert goalstate.encode_status(goalstate.Active) == "active"
/// ```
///
/// ```gleam
/// assert goalstate.encode_status(
///   goalstate.Limited(by: goalstate.ByTokenBudget)) == "budget_limited"
/// ```
///
pub fn encode_status(status: Status) -> String {
  case status {
    Active -> "active"
    Paused(..) -> "paused"
    Limited(..) -> "budget_limited"
    Complete -> "complete"
  }
}

/// The cause of a stopped status as its wire word, or nothing for the
/// two statuses that have no cause to carry.
///
/// ## Examples
///
/// ```gleam
/// assert goalstate.encode_reason(goalstate.Paused(by: goalstate.ByAbort))
///   == option.Some("aborted")
/// ```
///
/// ```gleam
/// assert goalstate.encode_reason(goalstate.Active) == option.None
/// ```
///
pub fn encode_reason(status: Status) -> Option(String) {
  case status {
    Active | Complete -> None

    Paused(by: ByOperator) -> Some("operator")
    Paused(by: ByAbort) -> Some("aborted")
    Paused(by: ByZeroProgress) -> Some("zero_progress")
    Paused(by: ByUnresponsiveReviewer) -> Some("reviewer_unresponsive")

    Limited(by: ByTokenBudget) -> Some("token_budget")
    Limited(by: ByContinuationCap) -> Some("continuation_cap")
  }
}

/// A status word and its reason word as one status. Total: an unknown
/// word, or a reason that does not belong to its status, is an `Error`
/// naming what was accepted.
///
/// The pairing is checked rather than defaulted because the pair is the
/// whole point: a `paused` with no cause would tell the operator the
/// harness is holding their goal and refuse to say why, which is the
/// state this field exists to remove.
///
/// ## Examples
///
/// ```gleam
/// assert goalstate.decode_status("complete", option.None)
///   == Ok(goalstate.Complete)
/// ```
///
/// ```gleam
/// assert goalstate.decode_status("paused", option.Some("aborted"))
///   == Ok(goalstate.Paused(by: goalstate.ByAbort))
/// ```
///
pub fn decode_status(
  word: String,
  reason: Option(String),
) -> Result(Status, String) {
  case word {
    "active" -> causeless(Active, reason)
    "complete" -> causeless(Complete, reason)
    "paused" -> result.map(pause_cause(reason), Paused)
    "budget_limited" -> result.map(limit_cause(reason), Limited)

    _ ->
      Error(
        decode_where
        <> ": status must be one of \"active\", \"paused\", "
        <> "\"budget_limited\" or \"complete\", got "
        <> json.to_string(json.String(word)),
      )
  }
}

// A status that carries no cause, refusing a reason that came with it: a
// present reason on `active` is a writer that thinks the status means
// something it does not.
fn causeless(status: Status, reason: Option(String)) -> Result(Status, String) {
  case reason {
    None -> Ok(status)

    Some(word) ->
      Error(
        decode_where
        <> ": "
        <> encode_status(status)
        <> " carries no reason, got "
        <> json.to_string(json.String(word)),
      )
  }
}

fn pause_cause(reason: Option(String)) -> Result(PauseCause, String) {
  case reason {
    Some("operator") -> Ok(ByOperator)
    Some("aborted") -> Ok(ByAbort)
    Some("zero_progress") -> Ok(ByZeroProgress)
    Some("reviewer_unresponsive") -> Ok(ByUnresponsiveReviewer)

    Some(word) -> Error(bad_reason("paused", word))
    None -> Error(missing_reason("paused"))
  }
}

fn limit_cause(reason: Option(String)) -> Result(LimitCause, String) {
  case reason {
    Some("token_budget") -> Ok(ByTokenBudget)
    Some("continuation_cap") -> Ok(ByContinuationCap)

    Some(word) -> Error(bad_reason("budget_limited", word))
    None -> Error(missing_reason("budget_limited"))
  }
}

fn bad_reason(status: String, word: String) -> String {
  decode_where
  <> ": "
  <> json.to_string(json.String(word))
  <> " is not a reason a "
  <> status
  <> " goal can carry"
}

fn missing_reason(status: String) -> String {
  decode_where <> ": a " <> status <> " goal must carry a reason"
}

/// Encodes the goal as its stored `goal/state` cell payload: one object
/// with every field always present, the two nullable ones null when
/// absent. Always-present-sometimes-null rather than sometimes-absent,
/// so a goal with no note cannot be confused with a payload an older
/// writer left the field out of.
///
/// ## Examples
///
/// ```gleam
/// // goalstate.decode(goalstate.encode(goal)) == Ok(goal)
/// ```
///
pub fn encode(goal: Goal) -> JsonValue {
  json.Object([
    #("objective", json.String(goal.objective)),
    #("status", json.String(encode_status(goal.status))),
    #("reason", encode_optional(encode_reason(goal.status))),
    #("phase", encode_phase(goal.phase)),
    #("token_budget", json.Int(goal.token_budget)),
    #("tokens_used", json.Int(goal.tokens_used)),
    #("accounted_through_seq", json.Int(goal.accounted_through_seq)),
    #("cost_used", json.Float(goal.cost_used)),
    #("continuations", json.Int(goal.continuations)),
    #("zero_progress", json.Int(goal.zero_progress)),
    #("unanswered_feeds", json.Int(goal.unanswered_feeds)),
    #("created_ms", json.Int(goal.created_ms)),
    #("updated_ms", json.Int(goal.updated_ms)),
    #("reviewer_note", encode_optional(goal.reviewer_note)),
    #("check", encode_optional(goal.check)),
    #("last_check", encode_last_check(goal.last_check)),
  ])
}

/// The last check result as its wire object, or null when none has run.
///
/// The ending is two always-present fields, `status` and `not_finished`,
/// exactly one of which is null. An object of its own rather than a status
/// with a sentinel: there is no exit status that means "no status", and a
/// reviewer shown `-1` would weigh a number the harness invented.
///
/// ## Examples
///
/// ```gleam
/// // goalstate.encode_last_check(option.None) == json.Null
/// ```
///
pub fn encode_last_check(result: Option(CheckResult)) -> JsonValue {
  case result {
    None -> json.Null

    Some(CheckResult(command:, ending:, output:, ran_at_ms:)) -> {
      let #(status, not_finished) = case ending {
        Exited(status:) -> #(json.Int(status), json.Null)
        DidNotFinish(reason:) -> #(json.Null, json.String(reason))
      }

      json.Object([
        #("command", json.String(command)),
        #("status", status),
        #("not_finished", not_finished),
        #("output", json.String(output)),
        #("ran_at_ms", json.Int(ran_at_ms)),
      ])
    }
  }
}

/// A stored last-check object as a result. Total: absent and null are both
/// "nothing has run", and a present payload that is not a well-formed
/// result is an `Error` naming the field.
///
/// A result carrying both a status and a not-finished reason, or neither, is
/// refused rather than resolved in favour of one. Either shape is a writer
/// that disagrees with this decoder about what the pair means, and picking
/// a winner would show the reviewer evidence nobody produced.
///
/// ## Examples
///
/// ```gleam
/// // goalstate.decode_last_check(json.Null) == Ok(option.None)
/// ```
///
pub fn decode_last_check(
  payload: JsonValue,
) -> Result(Option(CheckResult), String) {
  case payload {
    json.Null -> Ok(None)

    _present -> {
      use fields <- result.try(object_fields(payload))
      use command <- result.try(required_string(fields, "command"))
      use ending <- result.try(decode_ending(fields))
      use output <- result.try(check_output(fields))
      use ran_at_ms <- result.try(required_ms(fields, "ran_at_ms"))

      Ok(Some(CheckResult(command:, ending:, output:, ran_at_ms:)))
    }
  }
}

// The ending, read from the pair of always-present-sometimes-null fields.
// Exactly one of the two carries a value; both and neither are refusals,
// for the reason `decode_last_check` states.
fn decode_ending(
  fields: List(#(String, JsonValue)),
) -> Result(CheckEnding, String) {
  use status <- result.try(optional_status(fields))
  use reason <- result.try(optional_text(fields, "not_finished"))

  case status, reason {
    Some(code), None -> Ok(Exited(status: code))
    None, Some(words) -> Ok(DidNotFinish(reason: words))

    Some(_both), Some(_of_them) | None, None ->
      Error(
        decode_where
        <> ": a check result carries exactly one of status and not_finished",
      )
  }
}

// The exit status, absent or null when the run produced none. Any integer
// is accepted: a jailed process that was signalled reports 128 plus the
// signal, and a helper's own failure code is not this decoder's to bound.
fn optional_status(
  fields: List(#(String, JsonValue)),
) -> Result(Option(Int), String) {
  case list.key_find(fields, "status") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(value:)) -> Ok(Some(value))

    Ok(other) -> Error(field_error("status", "an integer or null", other))
  }
}

// The captured tail, which may legitimately be empty: a command that
// printed nothing and exited zero is the commonest passing check there is.
fn check_output(fields: List(#(String, JsonValue))) -> Result(String, String) {
  case list.key_find(fields, "output") {
    Error(Nil) | Ok(json.Null) -> Ok("")
    Ok(json.String(value:)) -> Ok(value)

    Ok(other) -> Error(field_error("output", "a string or null", other))
  }
}

// Null is what "nothing recorded" looks like in a field that never
// moves.
fn encode_optional(text: Option(String)) -> JsonValue {
  case text {
    None -> json.Null
    Some(value) -> json.String(value)
  }
}

/// The phase as its wire object: a state word, the operation it names and
/// the seq it measures from, each null in the states that name none.
///
/// An object rather than sibling fields on the goal, because the word and
/// what rides with it are one fact: a phase word with somebody else's
/// operation beside it is not a state this loop can be in, and keeping the
/// pair in one value is what lets the decoder refuse that.
///
/// ## Examples
///
/// ```gleam
/// // goalstate.encode_phase(goalstate.Idle)
/// //   == json.Object([#("state", json.String("idle")),
/// //                   #("operation", json.Null),
/// //                   #("since_seq", json.Null)])
/// ```
///
pub fn encode_phase(phase: Phase) -> JsonValue {
  let #(word, operation, since, deadline) = case phase {
    Idle -> #("idle", None, None, None)
    Checking(deadline_ms:) -> #("checking", None, None, Some(deadline_ms))
    ReadyToFeed -> #("ready_to_feed", None, None, None)
    AwaitingVerdict(feed:) -> #("awaiting_verdict", Some(feed), None, None)
    Continuing(woken:, since_seq:) -> #(
      "continuing",
      Some(woken),
      Some(since_seq),
      None,
    )
  }

  json.Object([
    #("state", json.String(word)),
    #("operation", encode_optional(option.map(operation, ids.op_id_to_string))),
    #("since_seq", encode_optional_int(since)),
    #("deadline_ms", encode_optional_int(deadline)),
  ])
}

fn encode_optional_int(value: Option(Int)) -> JsonValue {
  case value {
    None -> json.Null
    Some(number) -> json.Int(number)
  }
}

/// A stored phase object as a phase. Total: an unknown word, a missing
/// operation where one is required, or an unparseable one is an `Error`
/// naming the field.
///
/// ## Examples
///
/// ```gleam
/// // goalstate.decode_phase(goalstate.encode_phase(goalstate.Idle))
/// //   == Ok(goalstate.Idle)
/// ```
///
pub fn decode_phase(payload: JsonValue) -> Result(Phase, String) {
  use fields <- result.try(object_fields(payload))
  use word <- result.try(required_string(fields, "state"))
  use operation <- result.try(optional_operation(fields))
  use since <- result.try(optional_since_seq(fields))
  use deadline <- result.try(optional_deadline(fields))

  case word, operation {
    "idle", None -> Ok(Idle)
    "ready_to_feed", None -> Ok(ReadyToFeed)

    // An absent deadline on a `checking` phase reads as one already passed,
    // which the next evaluation turns into "the check did not finish" and a
    // feed. That is the safe direction, the same reasoning `since_seq`
    // takes: a check whose deadline cannot be read costs the reviewer one
    // feed with no evidence, where refusing the cell would lose the goal.
    "checking", None -> Ok(Checking(deadline_ms: option.unwrap(deadline, 0)))

    "awaiting_verdict", Some(feed) -> Ok(AwaitingVerdict(feed:))

    // An absent `since_seq` on a `continuing` phase reads as zero, which
    // measures the woken stretch from the start of the branch. That is the
    // safe direction: a wider stretch can only read as *more* progress, and
    // reading progress where there was none costs one continuation, where
    // reading none where there was some pauses a working goal.
    "continuing", Some(woken) ->
      Ok(Continuing(woken:, since_seq: option.unwrap(since, 0)))

    // A state word that needs an operation and has none, or the reverse.
    // Either is a writer disagreeing with this decoder about what the
    // phase means, and the caller reads a refused cell as no goal.
    "idle", Some(_named)
    | "ready_to_feed", Some(_other)
    | "checking", Some(_third)
    | "awaiting_verdict", None
    | "continuing", None
    ->
      Error(
        decode_where
        <> ": phase state "
        <> json.to_string(json.String(word))
        <> " does not match the operation beside it",
      )

    _unknown, _any ->
      Error(
        decode_where
        <> ": phase state must be one of \"idle\", \"checking\", "
        <> "\"ready_to_feed\", \"awaiting_verdict\" or \"continuing\", got "
        <> json.to_string(json.String(word)),
      )
  }
}

// The instant a check in flight stops being waited for: absent or null
// outside the checking state, a non-negative integer inside it. A present
// value of the wrong type is an error rather than an absence, the
// discipline every field in this codec keeps.
fn optional_deadline(
  fields: List(#(String, JsonValue)),
) -> Result(Option(Int), String) {
  case list.key_find(fields, "deadline_ms") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(value:)) if value >= 0 -> Ok(Some(value))

    Ok(other) ->
      Error(field_error("deadline_ms", "a non-negative integer or null", other))
  }
}

// The seq a woken stretch is measured from: absent or null outside the
// continuing state, a non-negative integer inside it. A present value of
// the wrong type is an error rather than an absence, the discipline every
// field in this codec keeps.
fn optional_since_seq(
  fields: List(#(String, JsonValue)),
) -> Result(Option(Int), String) {
  case list.key_find(fields, "since_seq") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(value:)) if value >= 0 -> Ok(Some(value))

    Ok(other) ->
      Error(field_error("since_seq", "a non-negative integer or null", other))
  }
}

// The phase's operation, absent or null in the idle state and a UUID in
// the other two. A present value that will not parse is an error rather
// than an absence: the loop would otherwise read a corrupt phase as idle
// and re-feed a goal whose verdict is genuinely owed.
fn optional_operation(
  fields: List(#(String, JsonValue)),
) -> Result(Option(OpId), String) {
  case list.key_find(fields, "operation") {
    Error(Nil) | Ok(json.Null) -> Ok(None)

    Ok(json.String(value:)) ->
      case ids.parse_op_id(value) {
        Ok(operation) -> Ok(Some(operation))

        Error(_corrupt) ->
          Error(
            decode_where
            <> ": phase operation is not an operation id, got "
            <> json.to_string(json.String(value)),
          )
      }

    Ok(other) ->
      Error(field_error("operation", "an operation id or null", other))
  }
}

/// Decodes a stored goal. Total: every malformed payload is an `Error`
/// naming the field that broke, never a crash and never a half-read goal.
///
/// Required fields (`objective`, `status`, `phase`, `token_budget`,
/// `created_ms`, `updated_ms`) must be present — this cell is written
/// whole by one owner, so an absent required field is a writer/decoder
/// disagreement rather than an older writer. The counters and the two
/// nullable fields may be absent. A present field of the wrong type is an
/// error naming it, whichever side of the split it sits on.
///
/// ## Examples
///
/// ```gleam
/// let goal =
///   goalstate.new("make the race test pass", 400_000, 1000, accounted_from: 0)
///
/// assert goalstate.decode(goalstate.encode(goal)) == Ok(goal)
/// ```
///
/// ```gleam
/// // goalstate.decode(json.String("x")) -> Error("client/goalstate.decode: …")
/// ```
///
pub fn decode(payload: JsonValue) -> Result(Goal, String) {
  use fields <- result.try(object_fields(payload))
  use objective <- result.try(required_string(fields, "objective"))
  use status <- result.try(decode_stored_status(fields))
  use phase <- result.try(required_phase(fields))
  use budget <- result.try(required_budget(fields))
  use created <- result.try(required_ms(fields, "created_ms"))
  use updated <- result.try(required_ms(fields, "updated_ms"))
  use counts <- result.try(decode_counters(fields))
  use cost_used <- result.try(optional_cost(fields))
  use reviewer_note <- result.try(optional_text(fields, "reviewer_note"))
  use check <- result.try(optional_text(fields, "check"))
  use last_check <- result.try(optional_last_check(fields))

  // A negative age is always wrong: `updated_ms` is stamped by the same
  // writer as `created_ms`, so the pair can only move forward.
  use _ <- result.try(check_updated_after(created, updated))

  Ok(Goal(
    objective:,
    status:,
    phase:,
    token_budget: budget,
    tokens_used: counts.tokens_used,
    accounted_through_seq: counts.accounted_through_seq,
    cost_used:,
    continuations: counts.continuations,
    zero_progress: counts.zero_progress,
    unanswered_feeds: counts.unanswered_feeds,
    created_ms: created,
    updated_ms: updated,
    reviewer_note:,
    check:,
    last_check:,
  ))
}

// The last check result, absent on every cell written before the check
// existed and on every goal whose check has not run yet. Both read as
// nothing recorded, which is what makes a cell with none decode as "no
// check" rather than as a refusal (protocol 044 §8).
fn optional_last_check(
  fields: List(#(String, JsonValue)),
) -> Result(Option(CheckResult), String) {
  case list.key_find(fields, "last_check") {
    Error(Nil) -> Ok(None)
    Ok(payload) -> decode_last_check(payload)
  }
}

// The five counted fields, decoded together because they share one rule:
// absent means zero, and negative is a writer this decoder does not
// trust. A record rather than a tuple so the caller names them.
type Counters {
  Counters(
    tokens_used: Int,
    accounted_through_seq: Int,
    continuations: Int,
    zero_progress: Int,
    unanswered_feeds: Int,
  )
}

fn decode_counters(
  fields: List(#(String, JsonValue)),
) -> Result(Counters, String) {
  use tokens_used <- result.try(counter(fields, "tokens_used"))
  use through <- result.try(counter(fields, "accounted_through_seq"))
  use continuations <- result.try(counter(fields, "continuations"))
  use zero_progress <- result.try(counter(fields, "zero_progress"))
  use unanswered_feeds <- result.try(counter(fields, "unanswered_feeds"))

  Ok(Counters(
    tokens_used:,
    accounted_through_seq: through,
    continuations:,
    zero_progress:,
    unanswered_feeds:,
  ))
}

// The status and its reason read together, because the pair is what
// `decode_status` checks.
fn decode_stored_status(
  fields: List(#(String, JsonValue)),
) -> Result(Status, String) {
  use word <- result.try(required_string(fields, "status"))
  use reason <- result.try(optional_text(fields, "reason"))

  decode_status(word, reason)
}

fn required_phase(fields: List(#(String, JsonValue))) -> Result(Phase, String) {
  case list.key_find(fields, "phase") {
    Ok(payload) -> decode_phase(payload)
    Error(Nil) -> Error(decode_where <> ": phase is required")
  }
}

// A non-object is a writer that stored something else under the key.
// Unlike the guard's decoder there is no `Null` case: this cell's
// absence is never handed here — an absent cell is no goal, read before
// the payload reaches this module — so `Null` is as wrong as a string.
fn object_fields(
  payload: JsonValue,
) -> Result(List(#(String, JsonValue)), String) {
  case payload {
    json.Object(fields:) -> Ok(fields)

    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null ->
      Error(
        decode_where
        <> ": the payload must be an object, got "
        <> json.to_string(payload),
      )
  }
}

// A required string. Absence is an error, not a default, because every
// field this serves has no meaningful empty value: an objective nobody
// wrote and a status word nobody chose are both corrupt cells.
fn required_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(value:)) if value != "" -> Ok(value)

    // The empty string is present and typed right, but it names
    // nothing: an objective nobody wrote is a corrupt cell, and the
    // status has the same refusal one arm below.
    Ok(json.String(_)) ->
      Error(decode_where <> ": " <> key <> " must not be empty")

    Error(Nil) -> Error(decode_where <> ": " <> key <> " is required")
    Ok(other) -> Error(field_error(key, "a non-empty string", other))
  }
}

// The budget, required and positive. v1 has no unbounded goals, so zero
// is as wrong as a negative number and the refusal says so once.
fn required_budget(fields: List(#(String, JsonValue))) -> Result(Int, String) {
  case list.key_find(fields, "token_budget") {
    Ok(json.Int(value:)) if value > 0 -> Ok(value)
    Ok(json.Int(value:)) ->
      Error(
        decode_where
        <> ": token_budget must be a positive integer, got "
        <> int.to_string(value),
      )
    Error(Nil) -> Error(decode_where <> ": token_budget is required")
    Ok(other) -> Error(field_error("token_budget", "a positive integer", other))
  }
}

// A required millisecond timestamp, which the pair `check_updated_after`
// then orders. Zero is allowed: a caller may pin a goal before any clock
// it trusts.
fn required_ms(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(value:)) if value >= 0 -> Ok(value)
    Ok(json.Int(value:)) ->
      Error(
        decode_where
        <> ": "
        <> key
        <> " must not be negative, got "
        <> int.to_string(value),
      )
    Error(Nil) -> Error(decode_where <> ": " <> key <> " is required")
    Ok(other) -> Error(field_error(key, "a non-negative integer", other))
  }
}

// One counter: absent is zero, because a writer that never wrote one has
// recorded nothing yet, and negative is refused because every one of
// these counts something that only grows. A negative `tokens_used` would
// make remaining-budget arithmetic lie; a negative bound count would be a
// budget already spent before any continuation ran.
fn counter(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(0)
    Ok(json.Int(value:)) if value >= 0 -> Ok(value)

    Ok(json.Int(value:)) ->
      Error(
        decode_where
        <> ": "
        <> key
        <> " must not be negative, got "
        <> int.to_string(value),
      )

    Ok(other) -> Error(field_error(key, "a non-negative integer", other))
  }
}

// The cost, optional and a number either way on the wire: `0` and `0.0`
// are the same recorded cost, the same tolerance `core/codec` gives the
// usage row's own cost fields.
fn optional_cost(fields: List(#(String, JsonValue))) -> Result(Float, String) {
  case list.key_find(fields, "cost_used") {
    Error(Nil) -> Ok(0.0)
    Ok(json.Float(value:)) -> Ok(value)
    Ok(json.Int(value:)) -> Ok(int.to_float(value))
    Ok(other) -> Error(field_error("cost_used", "a number", other))
  }
}

// A nullable string: the reviewer's note, which every goal predates, and
// the status reason, which two of the four statuses do not carry. Null is
// present and means `None`, the same value absence takes.
fn optional_text(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.Null) -> Ok(None)
    Ok(json.String(value:)) -> Ok(Some(value))
    Ok(other) -> Error(field_error(key, "a string or null", other))
  }
}

fn check_updated_after(created: Int, updated: Int) -> Result(Nil, String) {
  case updated >= created {
    True -> Ok(Nil)
    False ->
      Error(
        decode_where
        <> ": updated_ms "
        <> int.to_string(updated)
        <> " is before created_ms "
        <> int.to_string(created),
      )
  }
}

fn field_error(key: String, expected: String, got: JsonValue) -> String {
  decode_where
  <> ": "
  <> key
  <> " must be "
  <> expected
  <> ", got "
  <> json.to_string(got)
}
