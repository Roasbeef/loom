//// The trial ledger: an append-only file of JSON lines, one per attempt at
//// one cell of a plan, and the reconciliation that holds it to the plan.
////
//// Rows are appended and never rewritten. A trial that hit an infrastructure
//// fault is followed by a row with the next attempt number, up to three, so
//// the history of a flaky run is in the file rather than in someone's
//// memory. A row of state `Running` is written first and superseded by the
//// scored or infrastructure row of the same attempt, so a crash leaves a
//// visible half-finished trial instead of a missing one.
////
//// `reconcile` is the other half of the contract. It takes the plan, which
//// is the denominator, and the rows, which are only what happened, and
//// returns the latest attempt per cell or refuses. A cell with no finished
//// row is an error naming that cell, never a smaller sample: dropping the
//// trials that failed is the easiest way for a comparison to flatter itself.

import core/json.{type JsonValue}
import eval/plan.{type Plan, type RowKey, RowKey}
import eval/wire
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One attempt at one trial.
pub type Row {
  Row(
    /// The plan this row belongs to.
    plan: String,
    /// The task id.
    task: String,
    /// The arm id.
    arm: String,
    /// The trial index within the cell.
    index: Int,
    /// Which attempt at this trial, from 1 to `max_attempts`.
    attempt: Int,
    /// Whether the attempt is finished, and how.
    state: RowState,
    /// The graded outcome. `None` exactly while the row is `Running`;
    /// `Infrastructure` exactly when the state is `Infra`.
    outcome: Option(Outcome),
    /// The reduced reward in zero to one.
    reward: Float,
    /// Named sub-scores, for example `f2p` and `p2p`.
    scores: List(#(String, Float)),
    /// A tail of verifier output, at most 8 KiB.
    side_info: String,
    /// The models the trial was actually served by.
    served: List(Served),
    /// What the trial spent.
    usage: Usage,
    /// Model turns taken.
    turns: Int,
    /// Tool calls made.
    tool_calls: Int,
    /// Tool calls that returned an error.
    tool_errors: Int,
    /// Compactions performed.
    compactions: Int,
    /// Where the time went.
    timing: Timing,
    /// The sandbox the trial ran in.
    jail: Jail,
    /// Where the evidence of the trial was kept.
    artifacts: Artifacts,
  )
}

/// Where an attempt stands.
pub type RowState {
  /// Finished and graded; terminal for its cell.
  Scored

  /// Failed for a reason that is not the agent's; retried while attempts
  /// remain.
  Infra

  /// Started and not yet finished.
  Running
}

/// The five ways a trial can end, matching the statistics package's variants.
pub type Outcome {
  /// The verifier accepted the result.
  Passed

  /// The verifier ran and rejected the result.
  VerifierFailed

  /// The agent ran out of time. Terminal, and counted against the arm.
  AgentTimeout

  /// The model refused on safety grounds.
  SafetyRefusal

  /// The harness, jail or network failed.
  Infrastructure
}

/// One model that served the trial.
pub type Served {
  Served(
    /// The provider name.
    provider: String,
    /// The model identifier.
    model: String,
    /// The wire API name.
    api: String,
    /// The profile applied, if any.
    profile: Option(String),
    /// The composition digest of the request prelude.
    digest: String,
  )
}

/// Token and money accounting for a trial.
pub type Usage {
  Usage(
    /// Input tokens.
    input: Int,
    /// Output tokens.
    output: Int,
    /// Tokens read from the provider's cache.
    cache_read: Int,
    /// Tokens written to the provider's cache.
    cache_write: Int,
    /// Dollars spent.
    dollars: Float,
    /// Whether every request was accounted for.
    completeness: Completeness,
  )
}

/// Whether usage covers every request.
pub type Completeness {
  /// Every request reported usage.
  Complete

  /// Some request did not, so the figures are a floor.
  LowerBound
}

/// Wall-clock milliseconds by phase.
pub type Timing {
  Timing(
    /// Host-side preparation: the trial's cold start.
    prepare: Int,
    /// The agent session.
    agent: Int,
    /// The verifier run.
    verifier: Int,
    /// Retiring the session.
    retire: Int,
  )
}

/// The sandbox a trial ran in.
pub type Jail {
  Jail(
    /// Which enforcement the host provided.
    posture: JailPosture,
    /// A one-line summary of the self-test.
    selftest: String,
  )
}

/// The kind of sandbox.
pub type JailPosture {
  /// Linux user namespaces through bubblewrap.
  BwrapUserns

  /// The macOS sandbox.
  Seatbelt

  /// No sandbox: the trial is not comparable with jailed ones.
  NoJail
}

/// Paths to the evidence of a trial, relative to its directory.
pub type Artifacts {
  Artifacts(
    /// The copied session database.
    session_db: String,
    /// The frozen agent workspace.
    workspace: String,
    /// The ATIF trajectory.
    trajectory: String,
    /// The verifier's standard output.
    verifier_stdout: String,
  )
}

/// The most attempts one trial may have.
pub const max_attempts = 3

/// The ledger row version.
pub const version = 2

/// The most bytes of verifier tail a row may carry.
pub const max_side_info_bytes = 8192

/// Encodes one row as a single line of canonical JSON, without the newline.
///
/// ## Examples
///
/// ```gleam
/// // ledger.decode_line(ledger.encode_line(row)) == Ok(row)
/// ```
///
pub fn encode_line(row: Row) -> String {
  row
  |> to_json
  |> json.to_string
}

/// The canonical JSON value of a row.
///
/// ## Examples
///
/// ```gleam
/// // ledger.to_json(row) is an object with "v": 2
/// ```
///
pub fn to_json(row: Row) -> JsonValue {
  json.canonical(
    json.Object([
      #("v", json.Int(version)),
      #("plan", json.String(row.plan)),
      #("task", json.String(row.task)),
      #("arm", json.String(row.arm)),
      #("index", json.Int(row.index)),
      #("attempt", json.Int(row.attempt)),
      #("state", json.String(state_name(row.state))),
      #("outcome", outcome_json(row.outcome)),
      #("reward", json.Float(row.reward)),
      #("scores", scores_json(row.scores)),
      #("side_info", json.String(row.side_info)),
      #("served", json.Array(list.map(row.served, served_json))),
      #("usage", usage_json(row.usage)),
      #("turns", json.Int(row.turns)),
      #("tool_calls", json.Int(row.tool_calls)),
      #("tool_errors", json.Int(row.tool_errors)),
      #("compactions", json.Int(row.compactions)),
      #("timing_ms", timing_json(row.timing)),
      #("jail", jail_json(row.jail)),
      #("artifacts", artifacts_json(row.artifacts)),
    ]),
  )
}

/// Decodes one row from a JSON value. Total, and strict about the
/// relationship between state and outcome so a hand-edited row cannot claim
/// a pass while still running.
///
/// ## Examples
///
/// ```gleam
/// // ledger.decode(ledger.to_json(row)) == Ok(row)
/// ```
///
pub fn decode(value: JsonValue) -> Result(Row, String) {
  use fields <- result.try(wire.object(value, row_keys))
  use v <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(require(v == version, "unsupported row version"))
  use plan <- result.try(wire.text(fields, "plan"))
  use task <- result.try(wire.text(fields, "task"))
  use arm <- result.try(wire.text(fields, "arm"))
  use index <- result.try(wire.int_between(fields, "index", 0, 999_999))
  use attempt <- result.try(wire.int_between(fields, "attempt", 1, max_attempts))
  use state <- result.try(
    wire.text(fields, "state") |> result.try(decode_state),
  )
  use outcome <- result.try(
    wire.required(fields, "outcome") |> result.try(decode_outcome),
  )
  use Nil <- result.try(state_matches_outcome(state, outcome))
  use reward <- result.try(wire.number(fields, "reward"))
  use Nil <- result.try(reward_matches_outcome(reward, outcome))
  use scores <- result.try(
    wire.required(fields, "scores") |> result.try(decode_scores),
  )
  use side_info <- result.try(wire.text(fields, "side_info"))
  use Nil <- result.try(require(
    wire.bytes(side_info) <= max_side_info_bytes,
    "side_info may hold at most 8 KiB",
  ))
  use served <- result.try(wire.list_of(fields, "served", decode_served))
  use usage <- result.try(
    wire.required(fields, "usage") |> result.try(decode_usage),
  )
  use turns <- result.try(count(fields, "turns"))
  use tool_calls <- result.try(count(fields, "tool_calls"))
  use tool_errors <- result.try(count(fields, "tool_errors"))
  use compactions <- result.try(count(fields, "compactions"))
  use timing <- result.try(
    wire.required(fields, "timing_ms") |> result.try(decode_timing),
  )
  use jail <- result.try(
    wire.required(fields, "jail") |> result.try(decode_jail),
  )
  use artifacts <- result.try(
    wire.required(fields, "artifacts") |> result.try(decode_artifacts),
  )

  Ok(Row(
    plan:,
    task:,
    arm:,
    index:,
    attempt:,
    state:,
    outcome:,
    reward:,
    scores:,
    side_info:,
    served:,
    usage:,
    turns:,
    tool_calls:,
    tool_errors:,
    compactions:,
    timing:,
    jail:,
    artifacts:,
  ))
}

/// Parses one line of the ledger.
///
/// ## Examples
///
/// ```gleam
/// // ledger.decode_line("{\"v\":2,…}") == Ok(row)
/// ```
///
pub fn decode_line(line: String) -> Result(Row, String) {
  use value <- result.try(
    json.parse(line) |> result.replace_error("not valid JSON"),
  )

  decode(value)
}

/// Parses a whole ledger. Blank lines are skipped, since a trailing newline
/// is the normal end of an append-only file, but they still count toward the
/// line numbers, so the first bad line is reported at the number an editor
/// shows.
///
/// ## Examples
///
/// ```gleam
/// // ledger.parse("not json") == Error("line 1: not valid JSON")
/// ```
///
pub fn parse(text: String) -> Result(List(Row), String) {
  text
  |> string.split("\n")
  |> list.index_map(fn(line, position) { #(position + 1, line) })
  |> list.filter(fn(numbered) { string.trim(numbered.1) != "" })
  |> list.try_map(fn(numbered) {
    decode_line(numbered.1)
    |> result.map_error(fn(reason) {
      "line " <> int.to_string(numbered.0) <> ": " <> reason
    })
  })
}

/// Holds a ledger to its plan. Every row must belong to the plan and name one
/// of its cells. For every cell the plan owes, the rows in file order must
/// form a legal attempt sequence (see `check_sequence`), and the last row must
/// finish the cell: `Scored`, or `Infra` with every attempt spent. Anything
/// else is `plan row missing: <key>`; a sequence that rerolls a scored cell is
/// `cell rerolled: <key>`. The rows come back in plan order.
///
/// ## Examples
///
/// ```gleam
/// // ledger.reconcile(plan, []) == Error("plan row missing: t/a/0")
/// ```
///
pub fn reconcile(plan: Plan, rows: List(Row)) -> Result(List(Row), String) {
  let owed = plan.rows(plan)
  let known = dict.from_list(list.map(owed, fn(key) { #(key, Nil) }))

  use by_cell <- result.try(group_by_cell(plan, known, rows))

  list.try_map(owed, fn(key) {
    let missing = Error("plan row missing: " <> plan.key_to_string(key))

    // A cell with no rows, or whose last row has not finished it, still owes
    // a result; a legal sequence is checked first so a reroll is reported as
    // one even when the rerolled row happens to finish the cell.
    case dict.get(by_cell, key) {
      Error(Nil) -> missing
      Ok(history) -> {
        use last <- result.try(check_sequence(key, history))

        // The last row of a legal history finishes the cell only if it is
        // scored or the attempts are spent.
        case finished(last) {
          True -> Ok(last)
          False -> missing
        }
      }
    }
  })
}

/// Groups the rows by cell, each cell's rows in file order, refusing strays.
fn group_by_cell(
  plan: Plan,
  known: dict.Dict(RowKey, Nil),
  rows: List(Row),
) -> Result(dict.Dict(RowKey, List(Row)), String) {
  use reversed <- result.map(
    list.try_fold(rows, dict.new(), fn(grouped, row) {
      let key = RowKey(task: row.task, arm: row.arm, index: row.index)

      // A row counts only when it belongs to this plan and names a cell the
      // plan owes; the plan, not the file, decides what the experiment is.
      case row.plan == plan.id, dict.has_key(known, key) {
        True, True -> {
          let held = result.unwrap(dict.get(grouped, key), [])
          Ok(dict.insert(grouped, key, [row, ..held]))
        }
        False, _ -> Error("row from another plan: " <> plan.key_to_string(key))
        True, False ->
          Error("row outside the plan: " <> plan.key_to_string(key))
      }
    }),
  )

  dict.map_values(reversed, fn(_, history) { list.reverse(history) })
}

/// Where a cell's attempt history stands: the attempt it is on and the state
/// of the last row written for that attempt, if any.
type Cursor {
  Cursor(attempt: Int, last: Option(RowState))
}

/// Checks one cell's rows, in file order, against the only legal history:
/// attempts start at 1; within an attempt an optional `Running` row is
/// followed by at most one finished row; attempt k+1 may begin only directly
/// after an `Infra` row at attempt k; and nothing may follow a `Scored` row.
/// A scored trial that could be rerun and re-appended would let a comparison
/// keep only the draws it liked. Returns the last row.
fn check_sequence(key: RowKey, history: List(Row)) -> Result(Row, String) {
  let start = Cursor(attempt: 1, last: None)
  let label = plan.key_to_string(key)

  use #(_, last) <- result.try(
    list.try_fold(history, #(start, None), fn(state, row) {
      let #(cursor, _) = state

      // The cursor's last state decides what may legally come next. A
      // scored row ends the cell for good; an infra row opens the next
      // attempt only; a running row must be superseded within its attempt.
      case cursor.last, row.attempt - cursor.attempt {
        Some(Scored), _ -> Error("cell rerolled: " <> label)
        None, 0 -> Ok(#(Cursor(cursor.attempt, Some(row.state)), Some(row)))
        Some(Running), 0 if row.state != Running ->
          Ok(#(Cursor(cursor.attempt, Some(row.state)), Some(row)))
        Some(Infra), 1 -> Ok(#(Cursor(row.attempt, Some(row.state)), Some(row)))
        Some(Running), _ | Some(Infra), _ | None, _ ->
          Error("attempt sequence broken: " <> label)
      }
    }),
  )

  option.to_result(last, "plan row missing: " <> label)
}

/// Whether a cell's last row ends it.
fn finished(row: Row) -> Bool {
  case row.state {
    Scored -> True
    Infra -> row.attempt >= max_attempts
    Running -> False
  }
}

const row_keys = [
  "v", "plan", "task", "arm", "index", "attempt", "state", "outcome", "reward",
  "scores", "side_info", "served", "usage", "turns", "tool_calls", "tool_errors",
  "compactions", "timing_ms", "jail", "artifacts",
]

fn require(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn count(fields: wire.Fields, key: String) -> Result(Int, String) {
  wire.int_between(fields, key, 0, 1_000_000_000_000)
}

/// The wire spelling of a row state.
fn state_name(state: RowState) -> String {
  case state {
    Scored -> "scored"
    Infra -> "infra"
    Running -> "running"
  }
}

/// Parses a row state's wire spelling; an unknown spelling is refused.
fn decode_state(name: String) -> Result(RowState, String) {
  case name {
    "scored" -> Ok(Scored)
    "infra" -> Ok(Infra)
    "running" -> Ok(Running)
    other -> Error("unknown state \"" <> other <> "\"")
  }
}

/// Encodes the optional outcome: `null` while the row is running, otherwise the outcome's wire name.
fn outcome_json(outcome: Option(Outcome)) -> JsonValue {
  case outcome {
    None -> json.Null
    Some(Passed) -> json.String("passed")
    Some(VerifierFailed) -> json.String("verifier_failed")
    Some(AgentTimeout) -> json.String("agent_timeout")
    Some(SafetyRefusal) -> json.String("safety_refusal")
    Some(Infrastructure) -> json.String("infrastructure")
  }
}

/// Decodes the outcome field; `null` and the five outcome names are the only accepted values.
fn decode_outcome(value: JsonValue) -> Result(Option(Outcome), String) {
  case value {
    json.Null -> Ok(None)
    json.String("passed") -> Ok(Some(Passed))
    json.String("verifier_failed") -> Ok(Some(VerifierFailed))
    json.String("agent_timeout") -> Ok(Some(AgentTimeout))
    json.String("safety_refusal") -> Ok(Some(SafetyRefusal))
    json.String("infrastructure") -> Ok(Some(Infrastructure))
    json.String(other) -> Error("unknown outcome \"" <> other <> "\"")
    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..) -> Error("outcome must be a string or null")
  }
}

/// The three states and the outcome they admit: running has none, infra is
/// exactly infrastructure, scored is any of the four graded outcomes.
fn state_matches_outcome(
  state: RowState,
  outcome: Option(Outcome),
) -> Result(Nil, String) {
  case state, outcome {
    Running, None -> Ok(Nil)
    Infra, Some(Infrastructure) -> Ok(Nil)
    Scored, Some(Passed)
    | Scored, Some(VerifierFailed)
    | Scored, Some(AgentTimeout)
    | Scored, Some(SafetyRefusal)
    -> Ok(Nil)
    Running, Some(_) -> Error("a running row has no outcome yet")
    Infra, Some(_) | Infra, None ->
      Error("an infra row's outcome must be infrastructure")
    Scored, Some(Infrastructure) | Scored, None ->
      Error("a scored row needs a graded outcome")
  }
}

/// A row's reward and its outcome must not contradict each other, because one
/// consumer reads the outcome and another the reward. The reward lies in zero
/// to one; the grader decides the outcome, so a `Passed` row needs some
/// credit (above zero) and every other row, including one still running,
/// must fall short of full credit (below one).
fn reward_matches_outcome(
  reward: Float,
  outcome: Option(Outcome),
) -> Result(Nil, String) {
  case outcome, reward >. 0.0, reward <. 1.0 {
    _, _, _ if reward >. 1.0 -> Error("reward must be at most 1")
    Some(Passed), False, _ -> Error("a passed row needs a reward above 0")
    Some(Passed), True, _ -> Ok(Nil)
    _, _, False -> Error("a row that did not pass needs a reward below 1")
    _, _, True -> Ok(Nil)
  }
}

fn scores_json(scores: List(#(String, Float))) -> JsonValue {
  json.Object(list.map(scores, fn(score) { #(score.0, json.Float(score.1)) }))
}

/// Decodes the named sub-scores, each a non-negative number.
fn decode_scores(value: JsonValue) -> Result(List(#(String, Float)), String) {
  case value {
    json.Object(fields:) ->
      list.try_map(fields, fn(field) {
        wire.number([field], field.0)
        |> result.map(fn(number) { #(field.0, number) })
      })
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("scores must be an object")
  }
}

/// Encodes one served model, with a null profile when none was applied.
fn served_json(served: Served) -> JsonValue {
  json.Object([
    #("provider", json.String(served.provider)),
    #("model", json.String(served.model)),
    #("api", json.String(served.api)),
    #("profile", case served.profile {
      Some(profile) -> json.String(profile)
      None -> json.Null
    }),
    #("digest", json.String(served.digest)),
  ])
}

/// Decodes one served model entry.
fn decode_served(value: JsonValue) -> Result(Served, String) {
  use fields <- result.try(
    wire.object(value, ["provider", "model", "api", "profile", "digest"]),
  )
  use provider <- result.try(wire.text(fields, "provider"))
  use model <- result.try(wire.text(fields, "model"))
  use api <- result.try(wire.text(fields, "api"))
  use digest <- result.try(wire.text(fields, "digest"))
  use profile <- result.try(
    wire.required(fields, "profile") |> result.try(decode_profile),
  )

  Ok(Served(provider:, model:, api:, profile:, digest:))
}

/// Decodes the optional profile name: a string or `null`.
fn decode_profile(value: JsonValue) -> Result(Option(String), String) {
  case value {
    json.Null -> Ok(None)
    json.String(profile) -> Ok(Some(profile))
    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..) -> Error("profile must be a string or null")
  }
}

/// Encodes token and dollar accounting, with its completeness flag.
fn usage_json(usage: Usage) -> JsonValue {
  json.Object([
    #("input", json.Int(usage.input)),
    #("output", json.Int(usage.output)),
    #("cache_read", json.Int(usage.cache_read)),
    #("cache_write", json.Int(usage.cache_write)),
    #("dollars", json.Float(usage.dollars)),
    #("completeness", case usage.completeness {
      Complete -> json.String("complete")
      LowerBound -> json.String("lower_bound")
    }),
  ])
}

/// Decodes usage accounting; counts are non-negative integers and dollars a non-negative number.
fn decode_usage(value: JsonValue) -> Result(Usage, String) {
  use fields <- result.try(
    wire.object(value, [
      "input", "output", "cache_read", "cache_write", "dollars", "completeness",
    ]),
  )
  use input <- result.try(count(fields, "input"))
  use output <- result.try(count(fields, "output"))
  use cache_read <- result.try(count(fields, "cache_read"))
  use cache_write <- result.try(count(fields, "cache_write"))
  use dollars <- result.try(wire.number(fields, "dollars"))
  use completeness <- result.try(
    wire.text(fields, "completeness") |> result.try(decode_completeness),
  )

  Ok(Usage(input:, output:, cache_read:, cache_write:, dollars:, completeness:))
}

/// Parses the usage completeness spelling.
fn decode_completeness(name: String) -> Result(Completeness, String) {
  case name {
    "complete" -> Ok(Complete)
    "lower_bound" -> Ok(LowerBound)
    other -> Error("unknown completeness \"" <> other <> "\"")
  }
}

/// Encodes the per-phase wall-clock milliseconds.
fn timing_json(timing: Timing) -> JsonValue {
  json.Object([
    #("prepare", json.Int(timing.prepare)),
    #("agent", json.Int(timing.agent)),
    #("verifier", json.Int(timing.verifier)),
    #("retire", json.Int(timing.retire)),
  ])
}

/// Decodes the per-phase wall-clock milliseconds as non-negative integers.
fn decode_timing(value: JsonValue) -> Result(Timing, String) {
  use fields <- result.try(
    wire.object(value, ["prepare", "agent", "verifier", "retire"]),
  )
  use prepare <- result.try(count(fields, "prepare"))
  use agent <- result.try(count(fields, "agent"))
  use verifier <- result.try(count(fields, "verifier"))
  use retire <- result.try(count(fields, "retire"))

  Ok(Timing(prepare:, agent:, verifier:, retire:))
}

fn jail_json(jail: Jail) -> JsonValue {
  json.Object([
    #("posture", json.String(posture_name(jail.posture))),
    #("selftest", json.String(jail.selftest)),
  ])
}

/// The wire spelling of a jail posture.
fn posture_name(posture: JailPosture) -> String {
  case posture {
    BwrapUserns -> "bwrap-userns"
    Seatbelt -> "seatbelt"
    NoJail -> "none"
  }
}

/// Decodes the jail record: its posture and a one-line self-test summary.
fn decode_jail(value: JsonValue) -> Result(Jail, String) {
  use fields <- result.try(wire.object(value, ["posture", "selftest"]))
  use name <- result.try(wire.text(fields, "posture"))
  use selftest <- result.try(wire.text(fields, "selftest"))

  // The wire spelling picks the posture; an unknown spelling is refused so a
  // new sandbox kind cannot be read as having none.
  use posture <- result.try(case name {
    "bwrap-userns" -> Ok(BwrapUserns)
    "seatbelt" -> Ok(Seatbelt)
    "none" -> Ok(NoJail)
    other -> Error("unknown jail posture \"" <> other <> "\"")
  })

  Ok(Jail(posture:, selftest:))
}

/// Encodes the paths of a trial's evidence files.
fn artifacts_json(artifacts: Artifacts) -> JsonValue {
  json.Object([
    #("session_db", json.String(artifacts.session_db)),
    #("workspace", json.String(artifacts.workspace)),
    #("trajectory", json.String(artifacts.trajectory)),
    #("verifier_stdout", json.String(artifacts.verifier_stdout)),
  ])
}

/// Decodes the paths of a trial's evidence files.
fn decode_artifacts(value: JsonValue) -> Result(Artifacts, String) {
  use fields <- result.try(
    wire.object(value, [
      "session_db", "workspace", "trajectory", "verifier_stdout",
    ]),
  )
  use session_db <- result.try(artifact_path(fields, "session_db"))
  use workspace <- result.try(artifact_path(fields, "workspace"))
  use trajectory <- result.try(artifact_path(fields, "trajectory"))
  use verifier_stdout <- result.try(artifact_path(fields, "verifier_stdout"))

  Ok(Artifacts(session_db:, workspace:, trajectory:, verifier_stdout:))
}

/// An artifact path is empty (the file does not exist yet, as in a `Running`
/// row) or a safe relative path. A later report opens these, so a row must
/// not be able to point it outside the trial's directory.
fn artifact_path(fields: wire.Fields, key: String) -> Result(String, String) {
  use path <- result.try(wire.text(fields, key))

  // Empty is the one value that is not a path: nothing was written yet.
  case path == "" || wire.safe_path(path) {
    True -> Ok(path)
    False -> Error("\"" <> key <> "\" must be a safe relative path")
  }
}
