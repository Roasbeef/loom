//// The session goal, as the terminal reads it: one board decoded from the
//// `goal_get` snapshot, one status panel, and one row beside the composer.
////
//// The goal is a state machine the harness owns and the operator steers
//// (protocol 044). The terminal holds none of it. It reads the board the
//// server renders, so every status word, every cause and the sentence
//// explaining the pair come from the single writer that can be right about
//// them; this module decides only what an operator sees.
////
//// Two properties shape the code. The first is that the board is data this
//// terminal did not write, so the decoder is total and carries its own
//// bounds — the server's objective is unbounded today, and a board that
//// outgrew a screen is a disagreement to refuse rather than a screenful to
//// paint. The second is that a status word alone is not actionable: four
//// different pauses and two different limits share two words, so the cause
//// is modelled beside the status rather than parsed out of prose. The
//// server also sends `because`, a ready-made sentence for the pair, and the
//// panel prints that rather than re-deriving it here, because a second
//// wording of the same fact is a wording that will drift.

import core/json
import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/live_jobs
import tui/text_hygiene

/// How many bytes of board this terminal will accept.
///
/// The server bounds the objective at 4,000 characters, so a board inside
/// the contract fits this several times over; the cap is the terminal's
/// defence against a board that is *outside* it, and refusing here keeps a
/// pathological cell out of the wrapping cache rather than letting it reach
/// the screen.
pub const board_limit = 48_000

/// How many bytes of objective text one board may carry.
///
/// `client/protocol` bounds the objective at 4,000 characters, which is
/// four times that many bytes at worst, so this cap refuses only a board
/// that is already outside the contract.
pub const objective_limit = 16_384

/// How much of the objective the one-line composer row shows before it is
/// cut. The panel prints the objective whole; the row is a reminder beside
/// a prompt the operator is writing, and a paragraph there would take the
/// band the conversation is paying for.
pub const row_objective_limit = 72

/// Why a goal is held rather than run.
///
/// The four causes are four different things for the operator to do next,
/// which is why `paused` alone is not enough to draw: a goal they paused
/// resumes, and a goal the harness stopped because two woken runs produced
/// nothing wants a look at the work before it resumes.
pub type PauseCause {
  /// The operator asked, through `/goal pause`.
  ByOperator

  /// The operator aborted a run the goal loop itself opened.
  ByAbort

  /// Two consecutive goal-woken runs committed no work.
  ByZeroProgress

  /// The reviewer was offered the goal repeatedly and never answered.
  ByUnresponsiveReviewer

  /// A cause word this terminal does not know, kept rather than refused.
  ///
  /// `docs/client-protocol.md` §4.9.26 says a client that does not
  /// recognize a reason word shows `because` instead, which is exactly what
  /// the panel does: the sentence is the server's and stays right when the
  /// vocabulary grows, so a newer harness's fifth pause must not blank a
  /// panel that could have printed it.
  UnknownPause(word: String)
}

/// Why the harness stopped continuing a goal it was otherwise running.
///
/// Both reach the operator as `budget limited`, and they are kept apart
/// because the answers differ: a larger budget, or a look at why eight
/// autonomous turns did not finish the objective.
pub type LimitCause {
  /// The accounted primary spend reached the goal's token budget.
  ByTokenBudget

  /// The loop took its cap of consecutive turns without the operator.
  ByContinuationCap

  /// A cause word this terminal does not know, kept for the reason
  /// `UnknownPause` is kept.
  UnknownLimit(word: String)
}

/// The goal's status, with the cause carried by the two statuses that have
/// one.
///
/// A two-level type rather than a status word and a loose reason string:
/// the pairing is the server's invariant, and checking it once in the
/// decoder means no renderer has to ask whether a `paused` board arrived
/// without its cause.
pub type Status {
  /// The loop is running.
  Active

  /// Held, for one of four causes. `/goal resume` continues from any.
  Paused(by: PauseCause)

  /// The harness stopped continuing: the budget, or the continuation cap.
  Limited(by: LimitCause)

  /// Terminal. Only the reviewer's verdict enters it.
  Complete
}

/// One observation of the session's goal.
///
/// Two variants rather than one record of options: "no goal is pinned" is a
/// real state with nothing else to say about it, and a `Pinned` board whose
/// every field might be absent would make each renderer re-decide what a
/// half-present goal means.
pub type Board {
  /// No goal is pinned. The stamp is the server's clock at the read.
  NoGoal(
    /// The server's clock when the cell was observed.
    observed_at_ms: Int,
  )

  /// A goal exists, whatever its status.
  Pinned(
    /// The status and, for the two stopped ones, its cause.
    status: Status,
    /// The server's own sentence for this status and cause. Printed rather
    /// than re-derived: one wording, in the one place that owns it.
    because: String,
    /// The operator's objective text. Untrusted display data, sanitized on
    /// the way to the screen.
    objective: String,
    /// The primary tokens the goal may spend, as the operator pinned it.
    token_budget: Int,
    /// The accounted primary spend. A checkpoint the server recomputes, so
    /// it can move backward on a restart without anything being wrong.
    tokens_used: Int,
    /// The accounted cost of that spend.
    cost_used: Float,
    /// How many consecutive turns the loop has taken without the operator.
    continuations: Int,
    /// The server's clock when the goal was pinned.
    created_ms: Int,
    /// The server's clock at the goal's last transition.
    updated_ms: Int,
    /// The reviewer's note on what remains, when it wrote one.
    reviewer_note: Option(String),
    /// The command the harness runs before each review, when the operator
    /// pinned one. Untrusted display data, sanitized on the way to the
    /// screen the way the objective is.
    check: Option(String),
    /// What the last run of that command produced, when one has run.
    last_check: Option(CheckRun),
    /// The server's clock when the cell was observed. Ages are differences
    /// within this one clock domain, never against a terminal clock.
    observed_at_ms: Int,
  )
}

/// One run of the operator's check, as the panel reads it.
///
/// The status is modelled as an option rather than as a number with a
/// sentinel because a run that was stopped has no exit status at all, and a
/// terminal that printed `-1` would be inventing the command's verdict on the
/// work. `not_finished` is the server's own words for that case.
pub type CheckRun {
  CheckRun(
    /// The command as it was run, which may differ from the pinned one when
    /// the operator has just changed it.
    command: String,
    /// The exit status, when the run produced one.
    status: Option(Int),
    /// Why there is no status, when there is none.
    not_finished: Option(String),
    /// The captured tail, already bounded server-side.
    output: String,
    /// The server's clock when the run was recorded.
    ran_at_ms: Int,
  )
}

/// How much of a check's captured output the panel prints.
///
/// The server bounds the tail already; this is the terminal's own bound on
/// what it will paint into a panel the operator asked for, and it is smaller
/// because a panel is a summary — the reviewer reads the whole tail, and an
/// operator who wants the rest runs the command.
pub const check_output_limit = 240

/// Validates one goal observation without trusting the server's bounds.
///
/// Every refusal is an `Error` naming what was rejected; nothing here can
/// crash a terminal on a malformed board. An unknown status word, and a
/// cause that does not belong to its status, are refusals rather than
/// guesses: a board this terminal cannot name is one it must not describe
/// to the operator, and the refusal reaches them as a worded row.
///
/// ## Examples
///
/// ```gleam
/// // goal_view.decode(board)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > board_limit,
    Error("oversized goal observation"),
  )
  use fields <- result.try(object(value))
  use word <- result.try(text(fields, "status"))
  use observed <- result.try(number(fields, "observed_at_ms"))

  case word {
    // The absent cell, and the only board that carries nothing else.
    "none" -> Ok(NoGoal(observed_at_ms: observed))

    _ -> pinned(fields, word, observed)
  }
}

fn pinned(
  fields: List(#(String, json.JsonValue)),
  word: String,
  observed: Int,
) -> Result(Board, String) {
  use status <- result.try(status(word, nullable_text(fields, "reason")))
  use because <- result.try(text(fields, "because"))
  use objective <- result.try(text(fields, "objective"))
  use <- bool.guard(
    objective == "" || string.byte_size(objective) > objective_limit,
    Error("goal objective outside this terminal's bounds"),
  )

  // The accounting, which the panel prints as "used of budget": a
  // non-positive budget contradicts the wire's own requirement and negative
  // counters would print as nonsense beside it, so both are refused rather
  // than clamped into a plausible-looking row.
  use budget <- result.try(number(fields, "token_budget"))
  use used <- result.try(number(fields, "tokens_used"))
  use spent <- result.try(cost(fields, "cost_used"))
  use continuations <- result.try(number(fields, "continuations"))
  use <- bool.guard(
    budget <= 0 || used < 0 || continuations < 0,
    Error("inconsistent goal accounting"),
  )

  // The two stamps, in the server's own clock domain, which is the only
  // domain an age on this board may be computed in.
  use created <- result.try(number(fields, "created_ms"))
  use updated <- result.try(number(fields, "updated_ms"))

  use last_check <- result.try(check_run(fields))

  Ok(Pinned(
    status:,
    because:,
    objective:,
    token_budget: budget,
    tokens_used: used,
    cost_used: spent,
    continuations:,
    created_ms: created,
    updated_ms: updated,
    reviewer_note: nullable_text(fields, "reviewer_note"),
    check: nullable_text(fields, "check"),
    last_check:,
    observed_at_ms: observed,
  ))
}

// The last check run, absent on every board written before the check existed
// and on every goal whose check has not run. A present payload that is not a
// well-formed run is a refusal, the discipline this decoder keeps for every
// field it does read: a board this terminal cannot name is one it must not
// describe to the operator.
fn check_run(
  fields: List(#(String, json.JsonValue)),
) -> Result(Option(CheckRun), String) {
  case list.key_find(fields, "last_check") {
    Error(Nil) | Ok(json.Null) -> Ok(None)

    Ok(payload) -> {
      use run <- result.try(object(payload))
      use command <- result.try(text(run, "command"))
      use ran_at_ms <- result.try(number(run, "ran_at_ms"))

      let status = nullable_number(run, "status")
      let not_finished = nullable_text(run, "not_finished")

      // Exactly one of the pair carries a value. Both or neither is a server
      // disagreeing with this decoder about what a result means, and picking
      // a winner would show the operator evidence nobody produced.
      case status, not_finished {
        Some(_code), None | None, Some(_reason) ->
          Ok(
            Some(CheckRun(
              command:,
              status:,
              not_finished:,
              output: nullable_string(run, "output"),
              ran_at_ms:,
            )),
          )

        Some(_both), Some(_of_them) | None, None ->
          Error("a check result must carry a status or a reason, not both")
      }
    }
  }
}

// The status word and its cause word as one status. The pairing is checked
// rather than defaulted: a `paused` board with no cause would tell the
// operator the harness is holding their goal and refuse to say why, and a
// cause belonging to the other status means the two fields disagree.
fn status(word: String, reason: Option(String)) -> Result(Status, String) {
  case word, reason {
    "active", None -> Ok(Active)
    "complete", None -> Ok(Complete)

    "paused", Some(cause) -> Ok(Paused(by: pause_cause(cause)))
    "budget_limited", Some(cause) -> Ok(Limited(by: limit_cause(cause)))

    "active", Some(_) | "complete", Some(_) ->
      Error("a running or complete goal carries no cause: " <> word)

    "paused", None | "budget_limited", None ->
      Error("a stopped goal must name its cause: " <> word)

    _, _ -> Error("unknown goal status: " <> text_hygiene.single_line(word))
  }
}

// A word outside the vocabulary is kept rather than refused, because the
// board's `because` sentence already says what it means and a status word
// this terminal *can* place is worth drawing. An unknown status word is a
// different matter: there is nothing left to place it against.
fn pause_cause(word: String) -> PauseCause {
  case word {
    "operator" -> ByOperator
    "aborted" -> ByAbort
    "zero_progress" -> ByZeroProgress
    "reviewer_unresponsive" -> ByUnresponsiveReviewer
    other -> UnknownPause(word: other)
  }
}

fn limit_cause(word: String) -> LimitCause {
  case word {
    "token_budget" -> ByTokenBudget
    "continuation_cap" -> ByContinuationCap
    other -> UnknownLimit(word: other)
  }
}

/// The status as the word the operator reads.
///
/// ## Examples
///
/// ```gleam
/// assert goal_view.status_word(goal_view.Active) == "active"
/// ```
pub fn status_word(status: Status) -> String {
  case status {
    Active -> "active"
    Paused(..) -> "paused"
    Limited(..) -> "budget limited"
    Complete -> "complete"
  }
}

/// The cause as a short operator-facing word, for the two statuses that
/// carry one.
///
/// The panel prints the server's `because` sentence; this is the short form
/// the one-line row has room for.
///
/// ## Examples
///
/// ```gleam
/// assert goal_view.cause_word(goal_view.Paused(goal_view.ByAbort))
///   == option.Some("aborted")
/// ```
pub fn cause_word(status: Status) -> Option(String) {
  case status {
    Active | Complete -> None

    Paused(by: ByOperator) -> Some("you paused it")
    Paused(by: ByAbort) -> Some("aborted")
    Paused(by: ByZeroProgress) -> Some("no progress")
    Paused(by: ByUnresponsiveReviewer) -> Some("reviewer silent")

    Limited(by: ByTokenBudget) -> Some("token budget")
    Limited(by: ByContinuationCap) -> Some("continuation cap")

    // An unrecognized word is shown as the server spelled it. The panel's
    // `because` line carries the sentence; this is the row's short form and
    // inventing prose for a word this terminal does not know would be
    // guessing at the harness's meaning.
    Paused(by: UnknownPause(word:)) | Limited(by: UnknownLimit(word:)) ->
      Some(text_hygiene.single_line(word))
  }
}

/// Renders the status panel: one block the operator asked for.
///
/// An absent goal is one line, because "nothing is pinned" plus how to pin
/// one is the whole of what there is to say. A pinned goal is a small block
/// — status and why, the objective, the spend against its budget, the
/// continuations, the ages, and the reviewer's note when it wrote one —
/// because those are the facts a decision to resume, refresh or clear
/// rests on.
///
/// ## Examples
///
/// ```gleam
/// // goal_view.lines(goal_view.NoGoal(1000))
/// ```
pub fn lines(board: Board) -> List(String) {
  case board {
    NoGoal(..) -> [
      "Goal: no goal is pinned · /goal <objective> pins one",
    ]

    Pinned(..) ->
      list.append(
        [
          "Goal: "
            <> status_word(board.status)
            <> " · "
            <> text_hygiene.single_line(board.because),
          "  objective: " <> text_hygiene.single_line(board.objective),
          "  spend: "
            <> int.to_string(board.tokens_used)
            <> " of "
            <> int.to_string(board.token_budget)
            <> " tokens · "
            <> money(board.cost_used)
            <> " · "
            <> int.to_string(board.continuations)
            <> " continuations",
          "  pinned "
            <> age(board.created_ms, board.observed_at_ms)
            <> " ago"
            <> " · last change "
            <> age(board.updated_ms, board.observed_at_ms)
            <> " ago",
        ],
        list.append(
          check_lines(board.check, board.last_check),
          note_lines(board.reviewer_note),
        ),
      )
  }
}

// The check and what it last did. Nothing is drawn for a goal with no check,
// because a line saying so on every panel of every goal would be paid for by
// the goals that have none — which is all of them until an operator pins one.
//
// The result is drawn whenever one is recorded, even when the command has
// since changed: the run names its own command, so the operator reads what
// actually ran rather than what is pinned now.
fn check_lines(
  command: Option(String),
  last: Option(CheckRun),
) -> List(String) {
  case command, last {
    None, None -> []

    Some(text), None -> [
      "  check: " <> text_hygiene.single_line(text) <> " (not run yet)",
    ]

    None, Some(run) | Some(_pinned), Some(run) -> [
      "  check: " <> text_hygiene.single_line(run.command),
      "  last run: " <> check_result(run),
      ..check_output(run.output)
    ]
  }
}

// What the run produced, in the operator's terms. A passing check says so in
// as many words, because "exit status 0" alone asks the reader to know a
// shell convention.
fn check_result(run: CheckRun) -> String {
  case run.status, run.not_finished {
    Some(0), _either -> "passed (exit status 0)"
    Some(code), _other -> "failed (exit status " <> int.to_string(code) <> ")"
    None, Some(reason) -> "no result — " <> text_hygiene.single_line(reason)

    // Unreachable: the decoder refuses a run carrying neither. The arm keeps
    // the match total and says what it knows rather than nothing.
    None, None -> "no result"
  }
}

fn check_output(output: String) -> List(String) {
  case output {
    "" -> []
    // One line, because a captured build log is many and a panel row is one.
    // The reviewer is shown the whole tail; the operator is shown that there
    // was output and what its shape is.
    printed -> [
      "  output: "
      <> clipped_to(text_hygiene.single_line(printed), check_output_limit),
    ]
  }
}

// The reviewer's note is the one field that may be absent, and an absent
// note draws nothing rather than a row saying so.
fn note_lines(note: Option(String)) -> List(String) {
  case note {
    None -> []
    Some(text) -> ["  reviewer: " <> text_hygiene.single_line(text)]
  }
}

/// Renders the one row drawn beside the composer while a goal is pinned.
///
/// Every pinned goal draws it, `complete` included: a complete goal still
/// occupies the session's one goal cell, and the row is how the operator
/// learns there is a verdict to read and a cell to clear. Only the absent
/// cell draws nothing, because the band is taken from the conversation and
/// a session with no goal should not pay a row to be told so.
///
/// ## Examples
///
/// ```gleam
/// assert goal_view.row(goal_view.NoGoal(1000)) == []
/// ```
pub fn row(board: Board) -> List(String) {
  case board {
    NoGoal(..) -> []

    Pinned(..) -> [
      "goal "
      <> status_word(board.status)
      <> cause_suffix(board.status)
      <> " · "
      <> int.to_string(board.tokens_used)
      <> "/"
      <> int.to_string(board.token_budget)
      <> " tokens · "
      <> int.to_string(board.continuations)
      <> " continuations · "
      <> clipped(text_hygiene.single_line(board.objective)),
    ]
  }
}

fn cause_suffix(status: Status) -> String {
  case cause_word(status) {
    None -> ""
    Some(word) -> " (" <> word <> ")"
  }
}

// Whether the objective is longer than the row shows is a bounded question,
// so it is answered by dropping the bound rather than by measuring the whole
// objective: the cap is 72 graphemes and an objective may be thousands.
fn clipped(text: String) -> String {
  clipped_to(text, row_objective_limit)
}

// The same bounded question against any cap: whether the text is longer than
// the bound is answered by dropping the bound rather than by measuring text
// that may be thousands of graphemes.
fn clipped_to(text: String, limit: Int) -> String {
  case string.drop_start(text, limit) {
    "" -> text
    _longer -> string.slice(text, 0, limit) <> "…"
  }
}

/// Words a refused goal command for the operator.
///
/// A refusal must reach them as a sentence rather than as a panel that
/// silently fails to appear: the commonest refusal is a daemon with no
/// advisor routed, or one predating goals altogether, and both look
/// identical to an operator watching nothing happen.
///
/// ## Examples
///
/// ```gleam
/// // goal_view.refusal("unsupported", "no advisor is routed")
/// ```
pub fn refusal(code: String, message: String) -> String {
  let reason = text_hygiene.single_line(message)
  case code {
    "unsupported" | "code_unsupported" ->
      "/goal is unavailable on this session: "
      <> reason
      <> " — a goal needs a routed advisor to judge it, and a daemon older"
      <> " than goals knows no goal commands at all"

    _ -> "/goal refused (" <> text_hygiene.single_line(code) <> "): " <> reason
  }
}

// An age within the server's own clock domain. Both stamps come from the
// same board, so this subtracts nothing the terminal measured. A negative
// difference — a stamp ahead of its own observation — floors at zero in
// `live_jobs.duration` rather than printing a negative age.
fn age(stamp: Int, observed: Int) -> String {
  live_jobs.duration(observed - stamp)
}

// The accounted cost, to the cent. The footer formats its own totals the
// same way, privately; repeating four lines here is cheaper than a shared
// module whose only member is this.
fn money(value: Float) -> String {
  let cents = int.max(0, float.round(value *. 100.0))
  "$"
  <> int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}

fn object(
  value: json.JsonValue,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected goal object")
  }
}

fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing goal text: " <> name)
  }
}

// A nullable field is always present and sometimes `null`, the cell's own
// discipline. An absent field is read as null for the same reason: this
// terminal must not refuse a board over a field that carries no goal state.
fn nullable_text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Some(value)
    Ok(_) | Error(Nil) -> None
  }
}

// A nullable integer: the check's exit status, which a stopped run has none
// of. Absent and null are the same answer, and a present value of the wrong
// type reads as absent for the reason `nullable_text` gives — this terminal
// must not refuse a board over a field that carries no goal state.
fn nullable_number(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(Int) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Some(value)
    Ok(_other) | Error(Nil) -> None
  }
}

// A string that may be absent and means the empty string when it is: a check
// that printed nothing and a board that carried no output field are the same
// thing to draw.
fn nullable_string(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> String {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> value
    Ok(_other) | Error(Nil) -> ""
  }
}

fn number(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error("invalid goal number: " <> name)
  }
}

// The one float on the board. A whole-numbered cost may arrive as an
// integer, so both are accepted rather than refusing a zero cost.
fn cost(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(Float, String) {
  case list.key_find(fields, name) {
    Ok(json.Float(value)) -> Ok(value)
    Ok(json.Int(value)) -> Ok(int.to_float(value))
    _ -> Error("invalid goal cost: " <> name)
  }
}
