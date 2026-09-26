//// The session-goal surface: the `/goal` grammar, the palette rows, a total
//// decoder over the board, the status panel, the row beside the composer,
//// the worded refusal an older daemon earns, and the two-token recognition
//// that keeps a goal continuation out of the operator's voice.
////
//// The grammar is the part these tests exist for. `/goal`'s argument is free
//// text, so every rule that reads a word out of it is a rule that can steal
//// one: `clear` is a subcommand only as the whole argument, and a trailing
//// number is a word of the objective rather than a budget. Both are pinned
//// here, because both are silent when they go wrong — an objective read as
//// `clear` unpins a goal, and an objective read as a budget pins work to a
//// spend nobody chose.

import core/json
import core/message
import etui/backend
import etui/buffer
import etui/geometry
import etui/keys
import etui/span
import etui/widgets/paragraph
import etui/widgets/textarea as text_area
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui
import tui/advisor_pending
import tui/command
import tui/connection
import tui/focused_goal_panel
import tui/frame
import tui/goal_view
import tui/inbound
import tui/model as tui_model
import tui/notes_view
import tui/protocol.{type Strand, Strand}
import tui/render
import tui/reviewer_status
import tui/session_channel
import tui/surfaces
import tui/transcript_lines
import tui/workspace
import tui_test/pushed

fn model() {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn painted(model) {
  let model = tui.update(backend.Resize(120, 30), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(buffer)
}

fn roster(main: Option(String), advisor: Option(String)) -> List(Strand) {
  [
    Strand(id: "main", name: Some("main"), live_phase: main),
    Strand(id: "advisor", name: Some("advisor"), live_phase: advisor),
  ]
}

fn with_roster(strands: List(Strand)) -> tui_model.Model {
  tui_model.Model(..model(), strands:)
}

// One `goal_get` board, as `client/goal_pending` renders a pinned goal.
fn wire(status: String, reason: json.JsonValue) -> json.JsonValue {
  json.Object([
    #("status", json.String(status)),
    #("reason", reason),
    #("because", json.String("the goal is running")),
    #("objective", json.String("get the branch green")),
    #("token_budget", json.Int(400_000)),
    #("tokens_used", json.Int(51_200)),
    #("cost_used", json.Float(0.42)),
    #("continuations", json.Int(3)),
    #("created_ms", json.Int(1_000_000)),
    #("updated_ms", json.Int(1_060_000)),
    #("reviewer_note", json.Null),
    #("observed_at_ms", json.Int(1_120_000)),
  ])
}

// A field added to a board that does not carry it, which is how the check
// fixtures are built: `replacing` only rewrites a field the fixture already
// has, and the fixture is deliberately the board a server with no check
// writes.
fn with_field(
  board: json.JsonValue,
  name: String,
  value: json.JsonValue,
) -> json.JsonValue {
  case board {
    json.Object(fields) -> json.Object(list.append(fields, [#(name, value)]))

    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> board
  }
}

fn replacing(
  board: json.JsonValue,
  name: String,
  value: json.JsonValue,
) -> json.JsonValue {
  case board {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) {
          case field.0 == name {
            True -> #(name, value)
            False -> field
          }
        }),
      )

    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> board
  }
}

fn pinned(status: goal_view.Status) -> goal_view.Board {
  noted(status, None)
}

fn noted(status: goal_view.Status, note: Option(String)) -> goal_view.Board {
  goal_view.Pinned(
    status:,
    because: "you paused it",
    objective: "get the branch green",
    token_budget: 400_000,
    tokens_used: 51_200,
    cost_used: 0.42,
    continuations: 3,
    created_ms: 1_000_000,
    updated_ms: 1_060_000,
    reviewer_note: note,
    check: None,
    last_check: None,
    observed_at_ms: 1_120_000,
  )
}

// --- the grammar ------------------------------------------------------------

/// Bare `/goal` asks for the panel, and the three subcommands are
/// subcommands only as the entire argument.
///
/// `/goal clear the failing test` is the case the rule exists for: reading
/// its first word as the subcommand would unpin a goal the operator was
/// trying to pin.
pub fn the_subcommands_are_only_the_whole_argument_test() {
  assert command.parse("/goal") == command.GoalStatus
  assert command.parse("  /goal  ") == command.GoalStatus
  assert command.parse("/goal clear") == command.GoalClear
  assert command.parse("/goal pause") == command.GoalPause
  assert command.parse("/goal resume") == command.GoalResume

  assert command.parse("/goal clear the failing test")
    == command.GoalSet(
      objective: "clear the failing test",
      token_budget: command.default_goal_budget,
    )
  assert command.parse("/goal pause the migration until review")
    == command.GoalSet(
      objective: "pause the migration until review",
      token_budget: command.default_goal_budget,
    )
}

/// `check` is the one subcommand that takes an argument, so it is a
/// whole-argument *prefix* rather than the whole argument: bare `/goal check`
/// clears the check and `/goal check <command>` pins it.
///
/// The cost is an objective that begins with the word "check", and the escape
/// is the flag the operator is already offered: `--budget` puts the objective
/// past the first position. Both are asserted here, because the ambiguity is
/// the one thing about this grammar a reader would otherwise have to guess.
pub fn the_check_subcommand_takes_the_rest_as_its_command_test() {
  assert command.parse("/goal check") == command.GoalCheck(command: None)
  assert command.parse("/goal check   ") == command.GoalCheck(command: None)
  assert command.parse("/goal check make check")
    == command.GoalCheck(command: Some("make check"))
  assert command.parse("/goal check go test ./... 2>&1 | tail -40")
    == command.GoalCheck(command: Some("go test ./... 2>&1 | tail -40"))

  // An objective that begins with the word is read as the subcommand, and
  // `--budget` is how the operator says they meant the objective.
  assert command.parse("/goal check the logs")
    == command.GoalCheck(command: Some("the logs"))
  assert command.parse("/goal --budget 1000 check the logs")
    == command.GoalSet(objective: "check the logs", token_budget: 1000)
}

/// The command's own bound is refused here with the count, because the
/// operator who pasted a script wants to know before the round trip — and the
/// two bounds are different numbers, so the objective's count would send them
/// looking at the wrong text.
pub fn an_oversized_check_command_is_refused_with_its_count_test() {
  assert command.check_limit == 1000

  let oversized = string.repeat("x", command.check_limit + 1)
  assert command.parse("/goal check " <> oversized)
    == command.GoalCheckTooLong(count: command.check_limit + 1)

  let allowed = string.repeat("x", command.check_limit)
  assert command.parse("/goal check " <> allowed)
    == command.GoalCheck(command: Some(allowed))
}

/// A trailing number belongs to the objective. The budget is carried by
/// `--budget` in the first position and nowhere else, so an objective may
/// end in any number without an escape form.
pub fn a_trailing_number_stays_part_of_the_objective_test() {
  assert command.parse("/goal fix issue 468")
    == command.GoalSet(
      objective: "fix issue 468",
      token_budget: command.default_goal_budget,
    )
  assert command.parse("/goal land the migration in 3 steps 200000")
    == command.GoalSet(
      objective: "land the migration in 3 steps 200000",
      token_budget: command.default_goal_budget,
    )
}

/// The explicit flag sets the budget and keeps the objective verbatim,
/// including its own trailing number.
pub fn the_budget_flag_owns_the_budget_test() {
  assert command.parse("/goal --budget 50000 fix issue 468")
    == command.GoalSet(objective: "fix issue 468", token_budget: 50_000)
  assert command.parse("/goal --budget 200_000 get the branch green")
    == command.GoalSet(objective: "get the branch green", token_budget: 200_000)
}

/// The equals form says the same thing as the spaced one, and is accepted
/// rather than read as objective text: a `/goal --budget=200000 land it` that
/// pinned the flag as the objective under the default budget was the silent
/// failure the operator had no way to see.
pub fn the_budget_flag_accepts_the_equals_form_test() {
  assert command.parse("/goal --budget=50000 fix issue 468")
    == command.GoalSet(objective: "fix issue 468", token_budget: 50_000)
  assert command.parse("/goal --budget=200_000 get the branch green")
    == command.GoalSet(objective: "get the branch green", token_budget: 200_000)

  // And its bad arguments are refused the same way, with the word shown back.
  assert command.parse("/goal --budget=soon get the branch green")
    == command.GoalBudgetInvalid("soon")
  assert command.parse("/goal --budget=0 get the branch green")
    == command.GoalBudgetInvalid("0")
}

/// A `/goal` with no budget pins the documented default rather than being
/// refused, and the flag's bad arguments are refused rather than defaulted.
pub fn a_missing_budget_defaults_and_a_bad_one_refuses_test() {
  assert command.default_goal_budget == 200_000

  let assert command.GoalSet(token_budget: budget, ..) =
    command.parse("/goal get the branch green")
    as "a bare objective pins the default budget"
  assert budget == command.default_goal_budget

  assert command.parse("/goal --budget soon get the branch green")
    == command.GoalBudgetInvalid("soon")
  assert command.parse("/goal --budget 0 get the branch green")
    == command.GoalBudgetInvalid("0")
  assert command.parse("/goal --budget -5 get the branch green")
    == command.GoalBudgetInvalid("-5")
  // The flag with nothing after it names itself; the flag with a budget and
  // no objective is missing the objective, which is `/goal`'s own argument.
  assert command.parse("/goal --budget")
    == command.MissingArgument("goal --budget")
  assert command.parse("/goal --budget 50000")
    == command.MissingArgument("goal")

  // A rejected budget with no objective after it names the budget, not the
  // objective. Reporting only the missing objective sent the operator
  // looking for the wrong mistake: their budget word is the thing that will
  // still be wrong the second time.
  assert command.parse("/goal --budget soon")
    == command.GoalBudgetInvalid("soon")
}

/// An objective longer than the wire accepts is refused here, with the count
/// the operator needs, rather than sent and refused there.
///
/// The bound is the server's own (`client/protocol.objective_limit`), and it
/// was enforced in neither place: a pasted document was accepted by the
/// server, written to the cell, and then refused by the very terminal that
/// asked for it, so the operator had a goal they could pin and never see.
pub fn an_oversized_objective_is_refused_before_it_is_sent_test() {
  assert command.objective_limit == 4000

  let allowed = string.repeat("a", command.objective_limit)
  assert command.parse("/goal " <> allowed)
    == command.GoalSet(
      objective: allowed,
      token_budget: command.default_goal_budget,
    )

  let oversized = string.repeat("a", command.objective_limit + 1)
  assert command.parse("/goal " <> oversized)
    == command.GoalObjectiveTooLong(count: command.objective_limit + 1)

  // The flagged form is held to the same bound, because one rule that two
  // call sites share is a rule neither can forget.
  assert command.parse("/goal --budget 50000 " <> oversized)
    == command.GoalObjectiveTooLong(count: command.objective_limit + 1)
}

/// The palette offers `/goal` with room for its argument, and past the space
/// offers the vocabulary that is a subcommand on its own.
pub fn the_palette_offers_goal_and_its_words_test() {
  let assert [row] =
    list.filter(command.suggestions("/goa"), fn(suggestion) {
      suggestion.command == "/goal"
    })
    as "the palette completes /goal"
  assert !row.takes_argument
    as "bare /goal is complete; typing a following space opens its actions"

  let words =
    list.map(command.suggestions("/goal "), fn(suggestion) {
      suggestion.command
    })
  assert words
    == [
      "/goal check", "/goal clear", "/goal pause", "/goal resume",
      "/goal --budget",
    ]

  // `check` takes an argument of its own, so the palette offers it as a row
  // the operator continues typing after.
  let assert [check_row] =
    list.filter(command.suggestions("/goal ch"), fn(row) {
      row.command == "/goal check"
    })
    as "the palette completes /goal check"
  assert check_row.takes_argument

  assert list.map(command.suggestions("/goal cl"), fn(row) { row.command })
    == ["/goal clear"]

  // An objective is not a subcommand, so the palette stops offering rows as
  // soon as the text stops being one of the words.
  assert command.suggestions("/goal clear the failing test") == []
  assert command.suggestions("/goal get the branch green") == []
}

/// Enter on the exact palette row executes the bare status command, while a
/// typed space keeps the subcommand palette and its argument completion.
pub fn the_palette_enter_path_opens_bare_goal_and_keeps_subcommands_test() {
  let board = pinned(goal_view.Paused(by: goal_view.ByOperator))
  let base = tui_model.Model(..model(), goal: Some(board))
  let typed =
    ["/", "g", "o", "a", "l"]
    |> list.fold(base, fn(model, key) {
      tui.update(backend.KeyPress(key), model)
    })
  let opened = tui.update(backend.KeyPress("enter"), typed)
  let assert tui_model.GoalInspector(panel) = opened.overlay
  assert focused_goal_panel.board(panel) == Some(board)
  assert text_area.value(opened.input) == ""

  let actions =
    ["/", "g", "o", "a", "l", " "]
    |> list.fold(base, fn(model, key) {
      tui.update(backend.KeyPress(key), model)
    })
    |> tui.update(backend.KeyPress("enter"), _)
  assert text_area.value(actions.input) == "/goal check "
  assert actions.overlay == tui_model.NoOverlay
}

/// `/help` documents the grammar it parses, including where the budget goes.
pub fn the_help_text_documents_the_goal_grammar_test() {
  let text = command.help_text()
  assert string.contains(text, "/goal             show the session goal")
  assert string.contains(text, "--budget")
  assert string.contains(text, "/goal clear|pause|resume")
  assert string.contains(text, "/goal check [command]")
}

// --- the decoder is total ---------------------------------------------------

/// Every status and cause the server can send decodes to its own variant,
/// and the absent cell decodes to the one board that claims nothing else.
pub fn every_status_and_cause_decodes_test() {
  assert goal_view.decode(
      json.Object([
        #("status", json.String("none")),
        #("observed_at_ms", json.Int(1_120_000)),
      ]),
    )
    == Ok(goal_view.NoGoal(observed_at_ms: 1_120_000))

  let assert Ok(goal_view.Pinned(
    status: active,
    objective:,
    tokens_used:,
    continuations:,
    ..,
  )) = goal_view.decode(wire("active", json.Null))
    as "a pinned board decodes to the pinned variant"
  assert active == goal_view.Active
  assert objective == "get the branch green"
  assert tokens_used == 51_200
  assert continuations == 3

  let assert Ok(goal_view.Pinned(status: complete, ..)) =
    goal_view.decode(wire("complete", json.Null))
    as "a complete goal is still a pinned cell"
  assert complete == goal_view.Complete

  assert paused_by("operator") == goal_view.Paused(by: goal_view.ByOperator)
  assert paused_by("aborted") == goal_view.Paused(by: goal_view.ByAbort)
  assert paused_by("zero_progress")
    == goal_view.Paused(by: goal_view.ByZeroProgress)
  assert paused_by("reviewer_unresponsive")
    == goal_view.Paused(by: goal_view.ByUnresponsiveReviewer)

  assert limited_by("token_budget")
    == goal_view.Limited(by: goal_view.ByTokenBudget)
  assert limited_by("continuation_cap")
    == goal_view.Limited(by: goal_view.ByContinuationCap)
}

fn paused_by(cause: String) -> goal_view.Status {
  let assert Ok(goal_view.Pinned(status:, ..)) =
    goal_view.decode(wire("paused", json.String(cause)))
    as "a paused board names its cause"
  status
}

fn limited_by(cause: String) -> goal_view.Status {
  let assert Ok(goal_view.Pinned(status:, ..)) =
    goal_view.decode(wire("budget_limited", json.String(cause)))
    as "a limited board names its cause"
  status
}

/// A board is data, not a promise. An unknown word, a cause that belongs to
/// the other status, a missing cause and impossible accounting are all
/// refusals naming what was rejected, and none of them is a crash.
pub fn malformed_boards_are_refused_rather_than_trusted_test() {
  let assert Error(_) = goal_view.decode(json.String("not a board"))
    as "a board must be an object"
  let assert Error(_) = goal_view.decode(wire("wedged", json.Null))
    as "an unknown status word is refused rather than drawn"
  let assert Error(_) = goal_view.decode(wire("paused", json.Null))
    as "a stopped goal must say why"
  let assert Error(_) =
    goal_view.decode(wire("active", json.String("operator")))
    as "a running goal carries no cause"
  let assert Error(_) =
    goal_view.decode(replacing(
      wire("active", json.Null),
      "token_budget",
      json.Int(0),
    ))
    as "the wire requires a positive budget"
  let assert Error(_) =
    goal_view.decode(replacing(
      wire("active", json.Null),
      "continuations",
      json.Int(-1),
    ))
    as "a negative count is not a count"
  let assert Error(_) =
    goal_view.decode(replacing(
      wire("active", json.Null),
      "objective",
      json.String(""),
    ))
    as "an objective nobody wrote is a corrupt board"
  let assert Error(_) =
    goal_view.decode(replacing(
      wire("active", json.Null),
      "objective",
      json.String(string.repeat("x", 20_000)),
    ))
    as "an objective past this terminal's own cap is refused"
  let assert Error(_) =
    goal_view.decode(replacing(wire("active", json.Null), "because", json.Null))
    as "the server's sentence is required rather than re-derived"
}

/// A cause word this terminal does not know keeps the board rather than
/// refusing it: the server's own sentence is on the board, and a newer
/// harness's fifth pause must not blank a panel that could have printed it
/// (`docs/client-protocol.md` §4.9.26).
pub fn an_unknown_cause_word_is_kept_and_shown_as_the_server_spelled_it_test() {
  assert paused_by("because i said so")
    == goal_view.Paused(by: goal_view.UnknownPause("because i said so"))
  assert limited_by("wall_clock")
    == goal_view.Limited(by: goal_view.UnknownLimit("wall_clock"))

  assert goal_view.cause_word(
      goal_view.Paused(by: goal_view.UnknownPause("wedged")),
    )
    == Some("wedged")
  assert goal_view.status_word(
      goal_view.Limited(by: goal_view.UnknownLimit("wall_clock")),
    )
    == "budget limited"
}

// The active board with a check pinned. Written out rather than derived from
// `pinned` with a record update, because a value typed as the sum cannot be
// updated into one variant — and spelling the literal keeps the check
// fixtures readable beside the field they are about.
fn checked(
  check: Option(String),
  last: Option(goal_view.CheckRun),
) -> goal_view.Board {
  goal_view.Pinned(
    status: goal_view.Active,
    because: "the goal is running",
    objective: "get the branch green",
    token_budget: 400_000,
    tokens_used: 51_200,
    cost_used: 0.42,
    continuations: 3,
    created_ms: 1_000_000,
    updated_ms: 1_060_000,
    reviewer_note: None,
    check:,
    last_check: last,
    observed_at_ms: 1_120_000,
  )
}

// --- the panel and the row --------------------------------------------------

/// The absent cell says so in one line, and says how to pin one.
pub fn an_absent_goal_is_one_line_test() {
  let assert [line] = goal_view.lines(goal_view.NoGoal(observed_at_ms: 1000))
  assert string.contains(line, "no goal is pinned")
  assert string.contains(line, "/goal <objective>")
  assert goal_view.row(goal_view.NoGoal(observed_at_ms: 1000)) == []
}

/// A pinned goal's panel carries the status, the server's sentence for it,
/// the objective, the spend against the budget, the continuations and the
/// two ages.
pub fn the_panel_carries_the_status_and_the_accounting_test() {
  let assert Ok(board) = goal_view.decode(wire("active", json.Null))
    as "the fixture board decodes"
  let assert [status, objective, spend, ages] = goal_view.lines(board)
  assert string.contains(status, "Goal: active")
  assert string.contains(status, "the goal is running")
  assert string.contains(objective, "get the branch green")
  assert string.contains(spend, "51200 of 400000 tokens")
  assert string.contains(spend, "$0.42")
  assert string.contains(spend, "3 continuations")
  assert string.contains(ages, "pinned 2m 0s ago")
  assert string.contains(ages, "last change 1m 0s ago")
}

/// Each status draws its own word, and each stopped one draws its cause:
/// `paused` alone names four different situations and `budget limited` two.
pub fn every_status_draws_its_word_and_its_cause_test() {
  assert goal_view.status_word(goal_view.Active) == "active"
  assert goal_view.status_word(goal_view.Complete) == "complete"
  assert goal_view.status_word(goal_view.Paused(by: goal_view.ByOperator))
    == "paused"
  assert goal_view.status_word(goal_view.Limited(by: goal_view.ByTokenBudget))
    == "budget limited"

  assert goal_view.cause_word(goal_view.Active) == None
  assert goal_view.cause_word(goal_view.Complete) == None
  assert goal_view.cause_word(goal_view.Paused(by: goal_view.ByZeroProgress))
    == Some("no progress")
  assert goal_view.cause_word(goal_view.Paused(by: goal_view.ByAbort))
    == Some("aborted")
  assert goal_view.cause_word(goal_view.Paused(
      by: goal_view.ByUnresponsiveReviewer,
    ))
    == Some("reviewer silent")
  assert goal_view.cause_word(goal_view.Limited(by: goal_view.ByContinuationCap))
    == Some("continuation cap")

  let assert [row] =
    goal_view.row(pinned(goal_view.Limited(by: goal_view.ByTokenBudget)))
  assert string.contains(row, "goal budget limited (token budget)")
  assert string.contains(row, "51200/400000 tokens")
}

/// A pinned check is drawn with what it last did, and the run names its own
/// command — so an operator who has just changed the check reads what
/// actually ran rather than what is pinned now.
pub fn the_panel_draws_the_check_and_its_last_run_test() {
  let failing =
    checked(
      Some("make check"),
      Some(goal_view.CheckRun(
        command: "make check",
        status: Some(1),
        not_finished: None,
        output: "FAIL client\nsecond line",
        ran_at_ms: 1_100_000,
      )),
    )

  let assert [_status, _objective, _spend, _ages, check, last, output] =
    goal_view.lines(failing)
    as "a checked goal draws three more lines"
  assert string.contains(check, "check: make check")
  assert string.contains(last, "failed (exit status 1)")
  assert string.contains(output, "FAIL client")

  // Captured output is one line whatever the command printed: a panel row is
  // one line, and the reviewer is the reader that gets the whole tail.
  assert !string.contains(output, "\n")
}

/// Output too long for the row shows its end rather than its beginning.
///
/// The head of this field is the `stdout:` labelling the capture writes and
/// then the opening of a build log, so an operator reading the first two
/// hundred characters read neither the failure nor anything else.
pub fn long_check_output_shows_its_tail_test() {
  let long =
    checked(
      Some("make check"),
      Some(goal_view.CheckRun(
        command: "make check",
        status: Some(1),
        not_finished: None,
        output: "stdout:\ncompiling "
          <> string.repeat("a", goal_view.check_output_limit)
          <> "\nFAIL client",
        ran_at_ms: 1_100_000,
      )),
    )

  let assert [_status, _objective, _spend, _ages, _check, _last, output] =
    goal_view.lines(long)
    as "a checked goal draws three more lines"

  assert string.contains(output, "FAIL client")
    as "the end of the log is what the row keeps"
  assert string.contains(output, "compiling") == False
    as "the labelling and the opening of the log are what the row drops"
}

/// A check with no run yet says so rather than drawing an empty result, and a
/// goal with no check draws neither line.
pub fn an_unrun_check_says_so_and_no_check_draws_nothing_test() {
  let unrun = checked(Some("make check"), None)
  let assert [_status, _objective, _spend, _ages, check] =
    goal_view.lines(unrun)
    as "a pinned but unrun check draws one line"
  assert string.contains(check, "not run yet")

  let assert [_status, _objective, _spend, _ages] =
    goal_view.lines(pinned(goal_view.Active))
    as "a goal with no check draws no check lines"
}

/// A run that produced no status says so in the server's words rather than
/// printing a number nobody produced, and a passing one is named as passing
/// rather than as a shell convention the reader has to know.
pub fn a_check_result_without_a_status_is_worded_test() {
  let unfinished =
    checked(
      Some("make check"),
      Some(goal_view.CheckRun(
        command: "make check",
        status: None,
        not_finished: Some("the check did not finish in time"),
        output: "",
        ran_at_ms: 1_100_000,
      )),
    )
  let assert [_status, _objective, _spend, _ages, _check, last] =
    goal_view.lines(unfinished)
    as "an unfinished run draws no output line"
  assert string.contains(last, "no result — the check did not finish in time")

  let passed =
    checked(
      Some("make check"),
      Some(goal_view.CheckRun(
        command: "make check",
        status: Some(0),
        not_finished: None,
        output: "",
        ran_at_ms: 1_100_000,
      )),
    )
  let assert [_status, _objective, _spend, _ages, _check, run] =
    goal_view.lines(passed)
    as "a passing run draws its own line"
  assert string.contains(run, "passed (exit status 0)")
}

/// The board's check fields are read the way every other field is: a result
/// carrying both a status and a reason, or neither, is a server disagreeing
/// with this decoder and is refused rather than resolved in favour of one.
pub fn a_malformed_check_result_is_refused_test() {
  let both =
    json.Object([
      #("command", json.String("make check")),
      #("status", json.Int(0)),
      #("not_finished", json.String("also this")),
      #("output", json.String("")),
      #("ran_at_ms", json.Int(1000)),
    ])
  let assert Error(reason) =
    goal_view.decode(with_field(wire("active", json.Null), "last_check", both))
    as "a result with two endings must not decode"
  assert string.contains(reason, "status or a reason")

  // An absent `last_check` is no run, which is every board written before the
  // check existed.
  let assert Ok(goal_view.Pinned(last_check: None, check: None, ..)) =
    goal_view.decode(wire("active", json.Null))
    as "a board with no check fields decodes as no check"
}

/// The reviewer's note is drawn only when it wrote one, and model-written
/// text never reaches the terminal raw.
pub fn the_reviewer_note_is_drawn_when_present_and_sanitized_test() {
  let reviewed = noted(goal_view.Complete, Some("bell\u{0007}and\nnewline"))
  let assert [_, _, _, _, note] = goal_view.lines(reviewed)
  assert string.contains(note, "reviewer:")
  assert !string.contains(note, "\u{0007}")

  // A complete goal keeps its row: the cell is still occupied and the
  // operator has a verdict to read and a goal to clear.
  let assert [row] = goal_view.row(pinned(goal_view.Complete))
  assert string.contains(row, "goal complete")
}

/// The row draws beside the composer, where a standing objective belongs:
/// it is context for the prompt about to be written.
pub fn a_pinned_goal_is_drawn_beside_the_composer_test() {
  let observed =
    tui_model.Model(
      ..with_roster(roster(None, None)),
      goal: Some(pinned(goal_view.Active)),
    )
  let text = painted(observed)
  assert string.contains(text, "goal active")
  assert string.contains(text, "get the branch green")
}

/// The dedicated card names accounting as consumption and exposes only the
/// status-valid action. A token ratio is evidence of spend, not completion.
pub fn the_goal_card_labels_consumption_and_status_actions_test() {
  let area = geometry.rect_new(0, 0, 80, 20)
  let active =
    focused_goal_panel.new(
      Some(pinned(goal_view.Active)),
      "Last server observation",
    )
  let text =
    focused_goal_panel.render(
      buffer.buffer_new(area),
      area,
      active,
      focused_goal_panel.Ready,
    )
    |> frame.buffer_to_text
  assert string.contains(text, "Budget consumption")
  assert string.contains(text, "51200 of 400000 tokens consumed")
  assert !string.contains(text, "completion")
  assert string.contains(text, "p pause")
  assert !string.contains(text, "c continue")

  let paused =
    focused_goal_panel.new(
      Some(pinned(goal_view.Paused(by: goal_view.ByOperator))),
      "Last server observation",
    )
  let assert focused_goal_panel.Resume =
    focused_goal_panel.update(
      keys.Char("c"),
      paused,
      area,
      focused_goal_panel.Ready,
    )
  let assert focused_goal_panel.Continue(_) =
    focused_goal_panel.update(
      keys.Char("p"),
      paused,
      area,
      focused_goal_panel.Ready,
    )
  let assert focused_goal_panel.Continue(_) =
    focused_goal_panel.update(
      keys.Char("c"),
      paused,
      area,
      focused_goal_panel.Pending,
    )
}

/// A wide card owns the complete body area even though its visible frame is
/// inset. Transcript cells in the two outer gutters must not survive it.
pub fn the_wide_goal_card_clears_its_outer_gutters_test() {
  let area = geometry.rect_new(0, 0, 80, 20)
  let transcript = list.repeat(span.line_plain("XXXXXXXXXXXXXXXX"), 20)
  let base = paragraph.render_styled(buffer.buffer_new(area), area, transcript)
  let panel =
    focused_goal_panel.new(
      Some(pinned(goal_view.Active)),
      "Last server observation",
    )
  let rendered =
    focused_goal_panel.render(base, area, panel, focused_goal_panel.Ready)
    |> frame.buffer_to_text
  assert !string.contains(rendered, "X")
    as "the inset card left transcript glyphs in its owned gutters"
}

/// Paging at the smallest review size reaches the last check output instead
/// of leaving the first headings as the only reachable rows.
pub fn the_small_goal_card_pages_through_the_actual_viewport_test() {
  let marker = "LAST-GOAL-OUTPUT-MARKER"
  let board =
    goal_view.Pinned(
      status: goal_view.Complete,
      because: "the reviewer marked the goal complete",
      objective: "first objective line\nsecond objective line\nthird objective line",
      token_budget: 400_000,
      tokens_used: 51_200,
      cost_used: 0.42,
      continuations: 3,
      created_ms: 1_000_000,
      updated_ms: 1_060_000,
      reviewer_note: Some("reviewer feedback after the check"),
      check: Some("make check"),
      last_check: Some(goal_view.CheckRun(
        command: "make check",
        status: Some(1),
        not_finished: None,
        output: string.repeat("prior output ", 20) <> marker,
        ran_at_ms: 1_100_000,
      )),
      observed_at_ms: 1_120_000,
    )
  let area = geometry.rect_new(0, 0, 40, 12)
  let panel = focused_goal_panel.new(Some(board), "Last server observation")
  let #(pages, paged) =
    int.range(0, 40, #([], panel), fn(acc, _) {
      let #(pages, state) = acc
      let text =
        focused_goal_panel.render(
          buffer.buffer_new(area),
          area,
          state,
          focused_goal_panel.Ready,
        )
        |> frame.buffer_to_text
      let assert focused_goal_panel.Continue(next) =
        focused_goal_panel.update(
          keys.PageDown,
          state,
          area,
          focused_goal_panel.Ready,
        )
      #([text, ..pages], next)
    })
  assert list.any(pages, fn(page) { string.contains(page, marker) })
    as "the check tail must be reachable at 40x12"

  let stale = focused_goal_panel.unavailable(paged, "conversation disconnected")
  let first =
    focused_goal_panel.render(
      buffer.buffer_new(area),
      area,
      stale,
      focused_goal_panel.Ready,
    )
    |> frame.buffer_to_text
  assert string.contains(first, "Observation not refreshed")
    as "a retained board must label its stale observation before its long body"
}

/// The real 40x12 application layout shows substantive goal content on its
/// first frame; the header and observation metadata cannot consume the body.
pub fn the_real_small_layout_starts_with_status_and_objective_test() {
  let board = pinned(goal_view.Active)
  let opened =
    tui_model.Model(
      ..model(),
      goal: Some(board),
      overlay: tui_model.GoalInspector(focused_goal_panel.new(
        Some(board),
        "Illustrative observation",
      )),
    )
  let resized = tui.update(backend.Resize(40, 12), opened)
  let #(rendered, _) = render.view(resized, geometry.rect_new(0, 0, 40, 12))
  let text = frame.buffer_to_text(rendered)
  assert string.contains(text, "active")
  assert string.contains(text, "get the branch green")
}

/// Reviewer and goal status bands may consume the normal body at 40x12. The
/// inspector borrows those bands while leaving the actual editor visible.
pub fn the_busy_small_layout_keeps_goal_content_and_editor_test() {
  let board = pinned(goal_view.Active)
  let reviewers = [
    reviewer_status.Row("sub:first", "op-1", "Review layout", "running", ""),
    reviewer_status.Row("sub:second", "op-2", "Review paging", "running", ""),
  ]
  let opened =
    tui_model.Model(
      ..model(),
      input: text_area.state_from_string("draft remains editable"),
      goal: Some(board),
      reviewer_rows: reviewers,
      overlay: tui_model.GoalInspector(focused_goal_panel.new(
        Some(board),
        "Illustrative observation",
      )),
    )
  let resized = tui.update(backend.Resize(40, 12), opened)
  let #(rendered, _) = render.view(resized, geometry.rect_new(0, 0, 40, 12))
  let text = frame.buffer_to_text(rendered)
  assert string.contains(text, "active")
  assert string.contains(text, "get the branch green")
  assert string.contains(text, "draft remains editable")
}

/// Panel actions use the ordinary mutation lane without consuming text the
/// operator was composing underneath the inspector.
pub fn pausing_from_the_goal_card_retains_the_composer_draft_test() {
  let drafted =
    ["d", "r", "a", "f", "t"]
    |> list.fold(pushed.attached(), fn(model, key) {
      tui.update(backend.KeyPress(key), model)
    })
  let panel =
    focused_goal_panel.new(
      Some(pinned(goal_view.Active)),
      "Last server observation",
    )
  let opened =
    tui_model.Model(
      ..drafted,
      goal: Some(pinned(goal_view.Active)),
      overlay: tui_model.GoalInspector(panel),
    )
  let sent = tui.update(backend.KeyPress("p"), opened)
  assert text_area.value(sent.input) == "draft"
  assert sent.goal_request != None
  let assert tui_model.GoalInspector(_) = sent.overlay
}

// --- the read edges ---------------------------------------------------------

/// The goal reads on the nudge panel's three edges and on one more: the
/// primary *starting* a run, which is what a goal continuation is.
pub fn the_goal_reads_on_the_nudge_edges_and_on_a_run_start_test() {
  let idle = with_roster(roster(None, None))
  let running = with_roster(roster(Some("assistant"), None))
  let reviewing = with_roster(roster(None, Some("assistant")))

  assert surfaces.goal_action(running, idle) == surfaces.ReadGoal
  assert surfaces.goal_action(reviewing, idle) == surfaces.ReadGoal
  assert surfaces.goal_action(with_roster([]), idle) == surfaces.ReadGoal
  assert surfaces.goal_action(idle, running) == surfaces.ReadGoal

  // A goal is pinned until the operator unpins it, so an unrelated
  // transition asks for nothing and nothing clears the board.
  assert surfaces.goal_action(idle, idle) == surfaces.HoldGoal
  assert surfaces.goal_action(running, running) == surfaces.HoldGoal

  // A different session owns a different goal even when both primaries run.
  let other = tui_model.Model(..running, session: "other session")
  assert surfaces.goal_action(running, other) == surfaces.ReadGoal
}

/// A lifecycle-driven goal read is background observation. Sending it must
/// not replace the operator-facing outcome already occupying the footer;
/// an explicit `/goal` still reports its own send while awaiting the board.
pub fn an_automatic_goal_read_preserves_the_footer_notice_test() {
  let base = pushed.attached()
  let prior = tui_model.Model(..base, notice: "copied 2 lines")
  let automatic =
    inbound.apply_channel_update(
      prior,
      session_channel.Submission(session_channel.Sent("goal_get", 500)),
    )
  assert automatic.notice == prior.notice

  let explicit =
    inbound.apply_channel_update(
      tui_model.Model(..prior, goal_report: tui_model.ReportGoal),
      session_channel.Submission(session_channel.Sent("goal_get", 501)),
    )
  assert explicit.notice == "goal_get sent"
}

// --- the command lane -------------------------------------------------------

/// `goal_get` is a read and every mutation is answered with the fresh board,
/// so all five names have to be in the lane tables the compiler cannot
/// check. An unlisted read defaults to the mutation lane and holds the
/// composer for the life of the attachment.
pub fn the_read_takes_the_read_lane_and_a_mutation_answers_with_a_board_test() {
  let model = pushed.attached()
  let assert Some(channel) = model.channel
    as "fixture has a synchronized channel"

  let #(channel, disposition) =
    session_channel.submit(channel, protocol.goal_get(999), now: 0)
  let assert session_channel.Sent("goal_get", read_id) = disposition
    as "the goal read is issued once with the lane's request id"
  assert session_channel.mutation_available(channel)
    as "an auxiliary read never holds the composer's own lane"

  let #(channel, updates) =
    session_channel.receive(
      channel,
      pushed.reply(read_id, "snapshot", snapshot()),
      now: 0,
    )
  let assert [
    session_channel.Auxiliary(protocol.GoalSnapshot(goal_view.Pinned(
      status:,
      ..,
    ))),
  ] = updates
    as "a successful read never becomes an answer to no command"
  assert status == goal_view.Active

  let #(channel, disposition) =
    session_channel.submit(
      channel,
      protocol.goal_set(1000, "get the branch green", 400_000),
      now: 0,
    )
  let assert session_channel.Sent("goal_set", set_id) = disposition
    as "a goal mutation is issued on the mutation lane"
  let #(channel, updates) =
    session_channel.receive(
      channel,
      pushed.reply(set_id, "snapshot", snapshot()),
      now: 0,
    )
  let assert [session_channel.Auxiliary(protocol.GoalSnapshot(_))] = updates
    as "a mutation is answered with the fresh board, not a bare committed"
  assert session_channel.ready_for_read(channel)
}

fn snapshot() -> json.JsonValue {
  json.Object([
    #("mode", json.String("goal")),
    #("board", wire("active", json.Null)),
  ])
}

// --- the model's own answers ------------------------------------------------

// A model whose lane has one outstanding goal command of the given name,
// with the terminal's own bookkeeping pointing at it. `queue_owner` is the
// empty string for a fixture that never adopted a cut, which is what
// `goal_awaiting` has to match for a board to be accepted.
fn outstanding(frame: String, name: String) -> #(tui_model.Model, Int) {
  let model = pushed.attached()
  let assert Some(channel) = model.channel as "fixture has a channel"
  let #(channel, disposition) = session_channel.submit(channel, frame, now: 0)
  let assert session_channel.Sent(sent, id) = disposition
    as "the goal command is issued once"
  assert sent == name

  #(
    tui_model.Model(
      ..model,
      channel: Some(channel),
      goal_awaiting: Some(""),
      goal_request: Some(id),
      goal_report: tui_model.ReportGoal,
    ),
    id,
  )
}

fn deliver(
  model: tui_model.Model,
  message: connection.Message,
) -> tui_model.Model {
  process.send(model.inbox, message)
  tui.update(backend.Tick, model)
}

/// The operator's own `/goal` is answered with the block in the transcript,
/// because the status is several lines and the band beside the composer
/// holds one. The board also becomes the row, which stays after the block
/// has scrolled away.
pub fn the_operators_question_is_answered_in_the_transcript_test() {
  let #(model, id) = outstanding(protocol.goal_get(99), "goal_get")
  let model =
    tui_model.Model(
      ..model,
      overlay: tui_model.GoalInspector(focused_goal_panel.new(
        None,
        "Reading current goal",
      )),
    )
  let answered = deliver(model, pushed.reply(id, "snapshot", snapshot()))

  let text = painted(answered)
  assert string.contains(text, "Session goal")
  assert string.contains(text, "Status")
  assert string.contains(text, "active")
  assert string.contains(text, "51200 of 400000 tokens")
  assert string.contains(text, "goal active")
  let assert tui_model.GoalInspector(panel) = answered.overlay
  assert focused_goal_panel.board(panel) == answered.goal
  assert answered.goal_report == tui_model.HoldGoalReport
    as "one question is answered once"
}

/// A daemon with no advisor routed — or one predating goals — refuses every
/// goal command. The operator reads why, rather than watching a panel that
/// never appears.
pub fn an_older_daemon_refusing_the_read_is_worded_in_the_transcript_test() {
  let #(model, id) = outstanding(protocol.goal_get(99), "goal_get")
  let refused =
    deliver(
      model,
      pushed.reply(
        id,
        "error",
        json.Object([
          #("code", json.String("code_unsupported")),
          #("message", json.String("this server has no advisor routed")),
        ]),
      ),
    )

  let text = painted(refused)
  assert string.contains(text, "/goal is unavailable on this session")
  assert refused.goal == None as "a refusal is never a positive empty board"
}

/// A mutation's confirmation waits for the board that commits it.
///
/// The line used to be printed on the way out, which made every refusal read
/// as a contradiction: "goal pinned · budget 200000 tokens" followed by the
/// sentence saying this server has no advisor to judge one. The committed
/// board is what the server answers a mutation with, so that is where the
/// line belongs.
pub fn a_mutation_is_confirmed_only_once_it_commits_test() {
  let #(sent, id) = outstanding(protocol.goal_clear(99), "goal_clear")
  let waiting =
    tui_model.Model(
      ..sent,
      goal_report: tui_model.ConfirmGoal(line: "the session goal is cleared"),
    )

  assert !string.contains(painted(waiting), "the session goal is cleared")
    as "nothing is claimed before the server has answered"

  let committed = deliver(waiting, pushed.reply(id, "snapshot", snapshot()))
  assert string.contains(painted(committed), "the session goal is cleared")
  assert committed.goal_report == tui_model.HoldGoalReport
    as "one mutation is confirmed once"
}

/// The same mutation refused prints the refusal and never the confirmation.
pub fn a_refused_mutation_is_not_confirmed_test() {
  let #(sent, id) = outstanding(protocol.goal_pause(99), "goal_pause")
  let waiting =
    tui_model.Model(
      ..sent,
      goal_report: tui_model.ConfirmGoal(line: "the session goal is held"),
    )

  let refused =
    deliver(
      waiting,
      pushed.reply(
        id,
        "error",
        json.Object([
          #("code", json.String("code_unsupported")),
          #("message", json.String("this server has no advisor routed")),
        ]),
      ),
    )

  let text = painted(refused)
  assert string.contains(text, "/goal is unavailable on this session")
  assert !string.contains(text, "the session goal is held")
    as "a refused mutation must not also read as a success"
}

/// An automatic refresh is silent. An older daemon refuses one at every idle
/// boundary, and a row apiece would be a scrolling complaint about a feature
/// the session does not have.
pub fn an_automatic_refresh_refused_draws_nothing_test() {
  let #(asked, id) = outstanding(protocol.goal_get(99), "goal_get")
  let automatic =
    tui_model.Model(
      ..asked,
      goal: Some(pinned(goal_view.Active)),
      goal_report: tui_model.HoldGoalReport,
    )
  let refused =
    deliver(
      automatic,
      pushed.reply(
        id,
        "error",
        json.Object([
          #("code", json.String("code_unsupported")),
          #("message", json.String("this server has no advisor routed")),
        ]),
      ),
    )

  assert !string.contains(painted(refused), "/goal is unavailable")
  assert refused.goal == None
}

// --- the refusal ------------------------------------------------------------

/// An older daemon, or one with no advisor routed, refuses every goal
/// command. The operator is told in words: a panel that silently fails to
/// appear looks exactly like a session with no goal.
pub fn an_unsupported_goal_command_is_worded_test() {
  let text =
    goal_view.refusal(
      "unsupported",
      "this server has no advisor routed, so there is no reviewer to judge a goal",
    )
  assert string.contains(text, "/goal is unavailable on this session")
  assert string.contains(text, "no advisor routed")
  assert string.contains(text, "routed advisor")

  let other = goal_view.refusal("bad_request", "token_budget must be positive")
  assert string.contains(other, "bad_request")
  assert string.contains(other, "token_budget must be positive")
}

// --- the continuation frame -------------------------------------------------

/// A continuation lands on the primary's own branch as a user message, so
/// without recognition it would be drawn as though the operator had typed
/// it. Recognized, it is the system voice.
pub fn a_goal_continuation_draws_in_the_system_voice_test() {
  let assert Some(payload) =
    transcript_lines.advisor_payload(continuation("keep going"))
    as "both frame tokens are present"
  assert payload == transcript_lines.Continuation("keep going")

  let assert [line] =
    transcript_lines.advisor_lines(payload, notes_view.Excerpt)
  assert line.speaker == tui_model.System
  assert string.contains(line.text, "goal continuation")

  assert transcript_lines.advisor_lines(payload, notes_view.Complete)
    == [
      tui_model.Line(tui_model.System, "goal continuation"),
      tui_model.Line(tui_model.ToolDetail, "keep going"),
    ]
}

/// The header alone is not a frame. A model that quoted its own continuation
/// header must not be able to promote its output into the system voice, and
/// an operator pasting one back to ask about it keeps their own voice.
pub fn a_quoted_continuation_header_is_not_a_frame_test() {
  assert transcript_lines.advisor_payload(user_message(
      transcript_lines.continuation_header <> "\nwhy did this fire?",
    ))
    == None
  assert transcript_lines.advisor_payload(user_message(
      "what does this mean\n" <> transcript_lines.continuation_header,
    ))
    == None
  assert transcript_lines.advisor_payload(user_message(
      "keep going\n" <> transcript_lines.continuation_footer,
    ))
    == None
}

/// The goal feed rides the advisor's branch beside the ordinary feed, and
/// the wrap-up steer rides the existing advice frame, so both are already
/// recognized.
pub fn the_goal_feed_and_the_wrap_up_are_recognized_test() {
  let feed =
    user_message(
      transcript_lines.goal_feed_header
      <> "\nObjective: get the branch green\n"
      <> transcript_lines.goal_feed_footer,
    )
  let assert Some(transcript_lines.GoalFeed(body)) =
    transcript_lines.advisor_payload(feed)
    as "a goal feed is advisor traffic, not an operator turn"
  assert string.contains(body, "get the branch green")

  let wrap_up =
    user_message(
      transcript_lines.advice_header
      <> "\nthe goal's token budget is exhausted; wrap up\n"
      <> transcript_lines.advice_footer,
    )
  let assert Some(transcript_lines.Advice(_)) =
    transcript_lines.advisor_payload(wrap_up)
    as "the budget wrap-up rides the advice frame already recognized"
}

/// The frame literals, spelled as `client/advisorslice` writes them. A drift
/// silently stops the terminal recognizing the server's own messages.
pub fn the_goal_frame_literals_match_the_servers_test() {
  assert transcript_lines.continuation_header == "[goal continuation]"
  assert transcript_lines.continuation_footer
    == "[end goal continuation. Continue the work; do not reply about the frame.]"
  assert transcript_lines.goal_feed_header
    == "[advisor goal feed: the primary stopped with the session's goal still open]"
  assert transcript_lines.goal_feed_footer
    == "[end goal feed. Judge the objective against the evidence above and answer with exactly one advise call: continue, or complete when the objective is actually achieved.]"
  assert advisor_pending.primary_strand == "main"
}

// The continuation frame exactly as `advisorslice` writes it.
fn continuation(body: String) -> message.AgentMessage {
  user_message(
    transcript_lines.continuation_header
    <> "\n"
    <> body
    <> "\n"
    <> transcript_lines.continuation_footer,
  )
}

fn user_message(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 1,
    origin: None,
  )
}
