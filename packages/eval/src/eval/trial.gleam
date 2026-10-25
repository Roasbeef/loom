//// One trial: a fresh jailed session for one arm on one task, from the
//// starting tree to a ledger row.
////
//// This is the instrument's side of the shared trial recipe. The governed
//// evolution path and this module both build a session from
//// `serve.trial_settings`, open it with `serve.open_instance` and retire it
//// with `serve.retire_instance`; what differs is who decides the model, the
//// budget and the grade. Here the arm decides the model and the profiles
//// (`eval/arm_settings`), the plan decides the budget, and the task decides
//// the grade.
////
//// The order of the phases is the guarantee, and each step exists because
//// skipping it has a failure it prevents.
////
//// - The tree is materialised first, with its cold start timed apart.
//// - The agent runs under a per-trial request ceiling enforced by a guard on
////   the gateway, and under the plan's wall-clock budget. Running out of the
////   budget is `AgentTimeout`, a failure of the arm that is never retried.
//// - Everything the ledger needs from the session is read before it closes,
////   since the store goes with the session.
//// - The session is then retired and the retirement is *confirmed* before the
////   workspace is touched. A grader that ran while the agent could still write
////   would be grading a moving target.
//// - The workspace is copied to `frozen/` and the grader sees only the copy.
////
//// A fault in the instrument rather than the arm (the session would not
//// open, retirement could not be confirmed, the tree could not be built, the
//// grader itself broke) is an `Infra` row. `eval/run` retries those up to
//// the ledger's limit; nothing here retries.
////
//// The trial's session tag is a digest of plan, task, arm, index and attempt.
//// The governed path mints its tag from production entropy so that no two
//// trials share a session id. The instrument needs no entropy for that,
//// because every attempt has a root of its own under the run directory, and
//// it does need a tag that does not change between runs, so a replayed trial
//// is the same session as its recording.
////
//// ## Flow
////
//// - `default_seams`, `refuse_program`: the effects a trial performs
//// - `worst_case`: what the budget reserves for a trial
//// - `running_row`, `infra_row`: the rows written around an attempt
//// - `run_one`: one attempt, from materialisation to a row
//// - `grade_expected`: the in-process grader for exact files
//// - `is_refusal`: the provider adapters' refusal messages, recognised

import client/catalog
import client/evolution/prompt
import client/evolution/rollout
import client/internal/ffi_os
import client/mcp
import client/secrets.{type Runner}
import client/serve.{type Instance, type Settings}
import core/clock
import core/entry
import core/message
import eval/arm.{type Arm}
import eval/arm_settings
import eval/atif
import eval/budget
import eval/ledger.{type Row, Row}
import eval/materialise
import eval/plan.{type Budgets, type RowKey, RowKey}
import eval/repos.{type Repos}
import eval/task.{type Task, ExpectedFiles, Program}
import eval/wire
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway
import provider/http.{type Transport}
import provider/model
import provider/pricing
import runtime/api
import simplifile
import storage/storage
import telemetry/log
import weft/actor

/// Where a trial's model responses come from.
pub type Lane {
  /// The gateway the base settings carry, talking to a real provider.
  Live

  /// A gateway rebuilt over a transport the lane supplies per trial: a
  /// recording or a replaying tape. The catalogue and secrets are the arm's
  /// settings'; only the wire changes.
  Taped(
    /// Builds the transport for the cell and trial root given.
    open: fn(RowKey, String) -> Result(Tape, String),
  )

  /// A live lane that also records its traffic: the wire is wrapped by a
  /// recording transport the lane supplies, and the spend is real, so the
  /// budget treats it exactly as it treats `Live`.
  Recording(
    /// Builds the recording transport for the cell and trial root given.
    open: fn(RowKey, String) -> Result(Tape, String),
  )
}

/// A trial's transport and the way to ask what it found.
pub type Tape {
  Tape(
    /// The transport every provider request of the trial goes through.
    transport: Transport,
    /// Findings to report after the trial, such as replay divergences. Empty
    /// means the lane saw nothing wrong.
    findings: fn() -> List(String),
  )
}

/// A function that grades a frozen workspace: the task, the directory holding
/// the frozen copy, a directory it may write its own evidence into, and the
/// pristine build `materialise` prepared before the agent ran, when the task
/// has one.
pub type Grader =
  fn(Task, String, String, Option(String)) -> Result(rollout.Grade, String)

/// The effects a trial performs, as values, so a test can observe their order
/// or make one fail. `default_seams` is the production set.
pub type Seams {
  Seams(
    /// Runs host commands: tree materialisation and the workspace copy.
    runner: Runner,
    /// Opens the session.
    open: fn(Settings) -> Result(Instance, String),
    /// Retires the session and proves its processes are gone.
    retire: fn(Instance) -> Result(Nil, String),
    /// Grades the frozen workspace.
    grade: Grader,
  )
}

/// Everything a trial needs that does not vary by cell.
pub type Context {
  Context(
    /// The session settings every arm starts from.
    base: Settings,
    /// Where model responses come from.
    lane: Lane,
    /// The plan's ceilings.
    budgets: Budgets,
    /// The plan id, which rows carry and the session tag hashes.
    plan_id: String,
    /// The effects.
    seams: Seams,
    /// Where each repository a git task names is cloned on this machine.
    repos: Repos,
    /// What the host sandbox probe reported, recorded in each scored row's
    /// jail. `unprobed` when no probe ran.
    selftest: String,
  )
}

/// The `selftest` text of a run that opened no jail and so probed nothing.
pub const unprobed = "unprobed: run `make selftest`"

/// The production seams, given a grader for `Program` verifiers. Exact-file
/// verifiers are always graded in this process by `grade_expected`.
///
/// ## Examples
///
/// ```gleam
/// // trial.default_seams(refuse_program)
/// ```
///
pub fn default_seams(program: Grader) -> Seams {
  Seams(
    runner: secrets.host_runner(),
    open: fn(settings) { serve.open_instance(settings, log.discard()) },
    retire: serve.retire_instance,
    grade: fn(task, frozen, out, pristine) {
      case task.verifier {
        ExpectedFiles(expected:) -> grade_expected(expected, frozen)
        Program(..) -> program(task, frozen, out, pristine)
      }
    },
  )
}

/// A `Program` grader for a build that has no jailed verifier: it refuses by
/// name, so the trial becomes an `Infra` row rather than a guessed grade.
///
/// ## Examples
///
/// ```gleam
/// // trial.refuse_program(task, "/frozen", "/out", None) == Error("program verifier not built")
/// ```
///
pub fn refuse_program(
  _task: Task,
  _frozen: String,
  _out: String,
  _pristine: Option(String),
) -> Result(rollout.Grade, String) {
  Error("program verifier not built")
}

/// The worst case, in dollars, of one trial of `arm`: the plan's request
/// ceiling times the priced `3 * context + output` of the arm's main model.
/// A live lane needs a pricing card; a taped lane costs nothing.
///
/// ## Examples
///
/// ```gleam
/// // trial.worst_case(ctx, arm) == Ok(1.2)
/// ```
///
pub fn worst_case(ctx: Context, arm: Arm) -> Result(Float, String) {
  // Only a live lane spends money; a taped lane has nothing to reserve.
  case ctx.lane {
    Taped(..) -> Ok(0.0)

    Live | Recording(..) -> {
      use settings <- result.try(arm_settings.to_settings(arm, ctx.base))
      use target <- result.try(main_target(settings.gateway))
      use card <- result.try(
        gateway.card_for(settings.gateway, target.provider)
        |> result.map_error(fn(_) {
          "a live run needs a pricing card for " <> target.provider
        }),
      )

      Ok(budget.worst_case_dollars(
        ctx.budgets.max_requests_per_trial,
        card,
        context: target.context_window,
        output: target.max_output_tokens,
      ))
    }
  }
}

/// The row written before a trial starts, so a crash leaves a visible
/// half-finished attempt.
///
/// ## Examples
///
/// ```gleam
/// // trial.running_row("plan", key, 1).state == ledger.Running
/// ```
///
pub fn running_row(plan_id: String, key: RowKey, attempt: Int) -> Row {
  Row(..blank_row(plan_id, key, attempt), state: ledger.Running, outcome: None)
}

/// The row for an attempt that failed for a reason that is not the arm's.
///
/// ## Examples
///
/// ```gleam
/// // trial.infra_row("plan", key, 1, "open failed").side_info == "open failed"
/// ```
///
pub fn infra_row(
  plan_id: String,
  key: RowKey,
  attempt: Int,
  reason: String,
) -> Row {
  Row(
    ..blank_row(plan_id, key, attempt),
    state: ledger.Infra,
    outcome: Some(ledger.Infrastructure),
    side_info: tail(reason),
  )
}

/// Runs one attempt at one cell under `root` and answers its final row. Never
/// raises: any fault becomes an `Infra` row.
///
/// ## Examples
///
/// ```gleam
/// // let row = trial.run_one(ctx, task, arm, key, 1, "/runs/p/t/a/0/attempt-1")
/// // row.state == ledger.Scored
/// ```
///
pub fn run_one(
  ctx: Context,
  task: Task,
  arm: Arm,
  key: RowKey,
  attempt: Int,
  root: String,
) -> Row {
  let blank = blank_row(ctx.plan_id, key, attempt)

  // A fault inside the attempt becomes an `Infra` row here, so `run_one` never raises.
  case attempt_trial(ctx, task, arm, blank, root) {
    Ok(row) -> row
    Error(reason) -> infra_row(ctx.plan_id, key, attempt, reason)
  }
}

/// Grades exact expected files: reward one when every file is a regular file
/// holding exactly the expected bytes, zero otherwise, with the first
/// differing path as the only diagnostic. A symbolic link or special file
/// never matches. This mirrors `client/evolution/fixture.score`, whose
/// signature takes the governed task set and so cannot be called on a frozen
/// directory; the comparison is the same.
///
/// ## Examples
///
/// ```gleam
/// // trial.grade_expected([#("a.txt", "x\n")], "/frozen")
/// // == Ok(rollout.Grade(1.0, [], "", rollout.ExpectedFiles))
/// ```
///
pub fn grade_expected(
  expected: List(#(String, String)),
  frozen: String,
) -> Result(rollout.Grade, String) {
  use differing <- result.map(first_difference(expected, frozen))

  // One differing file fails the whole criterion; the first in the task's order is the diagnostic.
  case differing {
    Some(path) ->
      rollout.Grade(
        0.0,
        [],
        "expected file differs: " <> path,
        rollout.ExpectedFiles,
      )
    None -> rollout.Grade(1.0, [], "", rollout.ExpectedFiles)
  }
}

/// The first expected path, in the task's order, that does not match.
fn first_difference(
  expected: List(#(String, String)),
  frozen: String,
) -> Result(Option(String), String) {
  // An empty list has no difference to report.
  case expected {
    [] -> Ok(None)
    [#(path, content), ..rest] -> {
      use matches <- result.try(file_matches(frozen, path, content))

      // A matching file moves on; the first mismatch ends the search.
      case matches {
        True -> first_difference(rest, frozen)
        False -> Ok(Some(path))
      }
    }
  }
}

/// Walks the path one component at a time so no component may be a link, then
/// compares sizes before reading, so a huge file is refused without being read.
fn file_matches(
  frozen: String,
  relative: String,
  expected: String,
) -> Result(Bool, String) {
  use regular <- result.try(regular_path(frozen, string.split(relative, "/")))

  // A path that is not a regular file never matches.
  case regular {
    False -> Ok(False)
    True -> {
      let target = frozen <> "/" <> relative
      let wanted = bit_array.from_string(expected)
      let size = bit_array.byte_size(wanted)

      // A size mismatch decides without reading the file.
      case simplifile.file_info(target) {
        Error(error) -> Error(simplifile.describe_error(error))
        Ok(info) if info.size != size -> Ok(False)
        Ok(_) ->
          simplifile.read_bits(target)
          |> result.map(fn(found) { found == wanted })
          |> result.map_error(simplifile.describe_error)
      }
    }
  }
}

/// Whether a relative path reaches a regular file through real directories only.
fn regular_path(root: String, pieces: List(String)) -> Result(Bool, String) {
  // An empty path names nothing; otherwise the first component is examined and the rest follow.
  case pieces {
    [] -> Ok(False)
    [name, ..rest] -> {
      let path = root <> "/" <> name

      // `link_info` does not follow links, so a symbolic link is seen as a link and never as a file.
      case simplifile.link_info(path) {
        Error(simplifile.Enoent) -> Ok(False)
        Error(error) -> Error(simplifile.describe_error(error))
        Ok(info) ->
          case rest, simplifile.file_info_type(info) {
            [], simplifile.File -> Ok(True)
            [_, ..], simplifile.Directory -> regular_path(path, rest)
            _, _ -> Ok(False)
          }
      }
    }
  }
}

// --- the guard --------------------------------------------------------------

type GuardMessage {
  Admit(reply: Subject(Result(Nil, String)))
  Observe(served: ledger.Served)
  Snapshot(reply: Subject(Seen))
  Stop
}

type Seen {
  Seen(attempts: Int, refused: Int, served: List(ledger.Served))
}

type GuardState {
  GuardState(ceiling: Int, seen: Seen)
}

/// The per-trial request guard: counts provider requests, refuses past the
/// plan's ceiling, and collects what each request was served by.
type Guard {
  Guard(subject: Subject(GuardMessage))
}

const guard_wait_ms = 5000

/// Starts a request guard with the plan's ceiling.
fn start_guard(ceiling: Int) -> Result(Guard, String) {
  actor.new(GuardState(ceiling:, seen: Seen(0, 0, [])))
  |> actor.on_message(guard_handle)
  |> actor.start
  |> result.map(fn(started) { Guard(started.data) })
  |> result.replace_error("the request guard did not start")
}

/// Handles one message to the request guard.
fn guard_handle(
  state: GuardState,
  message: GuardMessage,
) -> actor.Next(GuardState, GuardMessage) {
  // One arm per message the guard can receive; only `Admit` can refuse.
  case message {
    Stop -> actor.stop()

    Snapshot(reply:) -> {
      process.send(reply, state.seen)
      actor.continue(state)
    }

    Observe(served:) -> {
      let held = state.seen.served

      // A model already seen adds nothing to the record.
      case list.contains(held, served) {
        True -> actor.continue(state)
        False ->
          actor.continue(
            GuardState(
              ..state,
              seen: Seen(..state.seen, served: list.append(held, [served])),
            ),
          )
      }
    }

    Admit(reply:) ->
      case state.seen.attempts < state.ceiling {
        True -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            GuardState(
              ..state,
              seen: Seen(..state.seen, attempts: state.seen.attempts + 1),
            ),
          )
        }
        False -> {
          process.send(
            reply,
            Error("the per-trial request ceiling was reached"),
          )
          actor.continue(
            GuardState(
              ..state,
              seen: Seen(..state.seen, refused: state.seen.refused + 1),
            ),
          )
        }
      }
  }
}

/// The guard's present counts.
fn snapshot(guard: Guard) -> Seen {
  actor.call(guard.subject, waiting: guard_wait_ms, sending: Snapshot)
}

// --- the trial ----------------------------------------------------------------

// What the session showed before it closed.
type Metrics {
  Metrics(
    usage: message.Usage,
    turns: Int,
    tool_calls: Int,
    tool_errors: Int,
    compactions: Int,
    answered: Int,
    last_error: Option(String),
    refusal: Option(String),
    models: List(ledger.Served),
  )
}

// Whether the agent's run reached a terminal result inside the wall budget.
type Settling {
  Settled
  TimedOut
}

// How the agent's run ended.
type Driven {
  Driven(settling: Settling, agent_ms: Int, metrics: Metrics)
}

/// One attempt from materialisation to a row, with an error meaning the instrument, not the arm, failed.
fn attempt_trial(
  ctx: Context,
  task: Task,
  arm: Arm,
  blank: Row,
  root: String,
) -> Result(Row, String) {
  use prepared <- result.try(
    materialise.run(ctx.seams.runner, ctx.repos, task, root)
    |> result.map_error(fn(reason) { "materialise failed: " <> reason }),
  )
  use settings <- result.try(arm_settings.to_settings(arm, ctx.base))
  use profiles <- result.try(arm_settings.profiles(arm, ctx.base))
  use guard <- result.try(start_guard(ctx.budgets.max_requests_per_trial))

  let attempted =
    with_session(
      ctx,
      task,
      arm,
      blank,
      root,
      prepared,
      settings,
      profiles,
      guard,
    )
  process.send(guard.subject, Stop)

  attempted
}

/// Opens the session, runs the agent, retires, freezes and judges, whatever the lane.
fn with_session(
  ctx: Context,
  task: Task,
  arm: Arm,
  blank: Row,
  root: String,
  prepared: materialise.Prepared,
  settings: Settings,
  profiles: List(_),
  guard: Guard,
) -> Result(Row, String) {
  use target <- result.try(main_target(settings.gateway))
  use api_name <- result.try(
    gateway.api_for(settings.gateway, target)
    |> result.replace_error("no provider is registered for the main model"),
  )
  use tape <- result.try(open_lane(
    ctx.lane,
    settings,
    RowKey(blank.task, blank.arm, blank.index),
    root,
  ))
  use guarded <- result.try(guarded_gateway(tape.gateway, profiles, guard))

  let isolated =
    serve.trial_settings(
      settings,
      target,
      api_name,
      profiles,
      root,
      tag_of(ctx.plan_id, blank, arm, task),
      guarded,
      settings.base_policy,
    )
  use instance <- result.try(
    ctx.seams.open(isolated)
    |> result.map_error(fn(reason) { "the session did not open: " <> reason }),
  )

  let driven = drive(ctx, task, instance)

  // Retirement is attempted whether or not the run could be observed, since
  // an open session must not outlive its trial; the observation fault, if
  // any, is reported after the retirement has been tried.
  let retire_started = ffi_os.system_time_ms()
  let retired = ctx.seams.retire(instance)
  let retire_ms = ffi_os.system_time_ms() - retire_started

  use Nil <- result.try(
    retired
    |> result.map_error(fn(reason) { "retirement unconfirmed: " <> reason }),
  )
  use driven <- result.try(driven)
  use frozen <- result.try(freeze(ctx.seams.runner, root))

  let findings = tape.findings()
  let seen = snapshot(guard)
  let card = gateway.card_for(settings.gateway, target.provider)

  finish(
    ctx,
    task,
    blank,
    Evidence(
      root:,
      frozen:,
      pristine: prepared.pristine,
      prepare_ms: prepared.prepare_ms,
      retire_ms:,
      driven:,
      seen:,
      card:,
      findings:,
    ),
  )
}

// Everything `finish` needs to judge a closed, frozen trial.
type Evidence {
  Evidence(
    root: String,
    frozen: String,
    pristine: Option(String),
    prepare_ms: Int,
    retire_ms: Int,
    driven: Driven,
    seen: Seen,
    card: Result(pricing.Pricing, Nil),
    findings: List(String),
  )
}

/// What is left once the session is gone: judge the trial, then keep its
/// trajectory. The export comes last because it can only add to a row that
/// already stands; it must never be the reason a finished trial is lost.
fn finish(
  ctx: Context,
  task: Task,
  blank: Row,
  evidence: Evidence,
) -> Result(Row, String) {
  use judged <- result.map(judge(ctx, task, blank, evidence))

  attach_trajectory(judged, evidence.root)
}

/// Picks the outcome, grades if the arm finished, and writes the row. A
/// timed-out agent is not graded, since the ledger's rule is that a timeout
/// is a failure, not partial credit; a model that refused is not graded
/// either, because its last word was a refusal and the tree is whatever it
/// had written before; a replay that diverged is the lane's finding, not a
/// grade of anything.
fn judge(
  ctx: Context,
  task: Task,
  blank: Row,
  evidence: Evidence,
) -> Result(Row, String) {
  let metrics = evidence.driven.metrics
  let base =
    Row(
      ..blank,
      state: ledger.Scored,
      // Profile attempts are observed only when the arm has profiles; a base
      // arm's served model is read from the answers the session recorded.
      served: case evidence.seen.served {
        [] -> metrics.models
        observed -> observed
      },
      usage: usage_of(metrics, evidence),
      turns: metrics.turns,
      tool_calls: metrics.tool_calls,
      tool_errors: metrics.tool_errors,
      compactions: metrics.compactions,
      timing: ledger.Timing(
        prepare: evidence.prepare_ms,
        agent: evidence.driven.agent_ms,
        verifier: 0,
        retire: evidence.retire_ms,
      ),
      jail: jail_of_host(ctx.selftest),
      artifacts: ledger.Artifacts(
        session_db: "state/session.db",
        workspace: "frozen",
        trajectory: "",
        verifier_stdout: "",
      ),
    )

  // A replay divergence outranks a timeout, which outranks a refusal, which outranks a provider fault, which outranks grading: each earlier arm makes the later ones meaningless. A refusal is the arm's failure, so it must be read before the provider fault that carries the same stop reason.
  case
    evidence.findings,
    evidence.driven.settling,
    metrics.refusal,
    metrics.last_error
  {
    [_, ..], _, _, _ ->
      Ok(
        Row(
          ..base,
          outcome: Some(ledger.VerifierFailed),
          side_info: tail(
            "lane finding: " <> string.join(evidence.findings, "; "),
          ),
        ),
      )

    [], TimedOut, _, _ -> Ok(Row(..base, outcome: Some(ledger.AgentTimeout)))

    [], Settled, Some(refusal), _ ->
      Ok(
        Row(
          ..base,
          outcome: Some(ledger.SafetyRefusal),
          side_info: tail("model refusal: " <> refusal),
        ),
      )

    [], Settled, None, Some(error) if evidence.seen.refused == 0 ->
      Error("the provider failed: " <> error)

    [], Settled, None, _ -> grade(ctx, task, base, evidence)
  }
}

/// The session database, exported as a trajectory beside it.
const trajectory_file = "trajectory.json"

/// Writes `trajectory.json` into the attempt root and records its relative
/// path in the row. The trajectory is evidence about a trial that already
/// has its verdict, so a failure to export is told in `side_info`, ahead of
/// the verifier's diagnostic (a row keeps the end of its text), and the row
/// is otherwise untouched: no outcome changes and the cell is not retried.
fn attach_trajectory(row: Row, root: String) -> Row {
  let exported = {
    use found <- result.try(atif.from_session_db(
      root <> "/" <> row.artifacts.session_db,
    ))

    atif.write(found, root <> "/" <> trajectory_file)
  }

  // A written file is recorded; a failed one is told in the row and the verdict stands.
  case exported {
    Ok(Nil) ->
      Row(
        ..row,
        artifacts: ledger.Artifacts(
          ..row.artifacts,
          trajectory: trajectory_file,
        ),
      )

    Error(reason) ->
      Row(
        ..row,
        side_info: tail(
          "trajectory export failed: " <> reason <> "\n" <> row.side_info,
        ),
      )
  }
}

/// The provider adapters spell a refusal as an errored stop with a fixed
/// message; no stop reason of its own exists in `core/message`. These are
/// those messages, so the runner can tell a model that declined from a
/// provider that failed.
const refusal_messages = [
  "the model refused to complete the request",
  "Responses provider refused the request",
  "provider finishReason: SAFETY",
  "provider finishReason: BLOCKLIST",
  "provider finishReason: PROHIBITED_CONTENT",
  "provider finishReason: SPII",
  "provider finishReason: IMAGE_SAFETY",
  "provider finishReason: IMAGE_PROHIBITED_CONTENT",
]

/// Whether an errored assistant message's text is a provider-reported
/// refusal rather than a fault. `core/message.StopReason` has no refusal
/// variant: the Messages adapter maps `refusal` to `Errored` with a fixed
/// message, the Responses adapter overrides a refused turn to `Errored`, and
/// the Gemini adapter does the same for its safety finish reasons. Matching
/// those messages is the only signal the stored answer carries.
///
/// ## Examples
///
/// ```gleam
/// assert trial.is_refusal("the model refused to complete the request")
/// assert !trial.is_refusal("connection reset")
/// ```
///
pub fn is_refusal(error_message: String) -> Bool {
  list.contains(refusal_messages, error_message)
}

/// The refusal text of an errored message, if it is one.
fn refusal_of(error_message: String) -> Option(String) {
  case is_refusal(error_message) {
    True -> Some(error_message)
    False -> None
  }
}

/// Runs the grader over the frozen copy and adds its result to the row.
fn grade(
  ctx: Context,
  task: Task,
  base: Row,
  evidence: Evidence,
) -> Result(Row, String) {
  let started = ffi_os.system_time_ms()
  use graded <- result.try(
    ctx.seams.grade(
      task,
      evidence.frozen,
      evidence.root <> "/verifier",
      evidence.pristine,
    )
    |> result.map_error(fn(reason) { "grading failed: " <> reason }),
  )
  let verifier_ms = ffi_os.system_time_ms() - started

  Ok(
    Row(
      ..base,
      outcome: Some(case rollout.passed(graded) {
        True -> ledger.Passed
        False -> ledger.VerifierFailed
      }),
      reward: graded.reward,
      scores: graded.scores,
      side_info: tail(graded.side_info),
      timing: ledger.Timing(..base.timing, verifier: verifier_ms),
    ),
  )
}

/// The row's usage, priced at the model's card when it has one.
fn usage_of(metrics: Metrics, evidence: Evidence) -> ledger.Usage {
  // An unpriced model keeps the cost the session itself recorded.
  let priced = case evidence.card {
    Ok(card) -> pricing.price(metrics.usage, card).cost.total
    Error(Nil) -> metrics.usage.cost.total
  }

  // Each request that settled with a positive token count accounts for one
  // guard admission; fewer means some request reported nothing, so the
  // figures are a floor.
  let completeness = case metrics.answered >= evidence.seen.attempts {
    True -> ledger.Complete
    False -> ledger.LowerBound
  }

  ledger.Usage(
    input: metrics.usage.input,
    output: metrics.usage.output,
    cache_read: metrics.usage.cache_read,
    cache_write: metrics.usage.cache_write,
    dollars: priced,
    completeness:,
  )
}

// --- running the agent -------------------------------------------------------

/// Prompts the session and waits for a terminal result under the wall budget.
fn drive(
  ctx: Context,
  task: Task,
  instance: Instance,
) -> Result(Driven, String) {
  let runtime = instance.runtime
  let started = ffi_os.system_time_ms()

  use operation <- result.try(
    api.prompt(runtime, [
      message.UserMessage(
        content: [message.UserText(task.prompt, None)],
        timestamp: started,
        origin: None,
      ),
    ])
    |> result.map_error(fn(_) { "the prompt was not admitted" }),
  )

  // The wall budget bounds the wait; a run that does not settle in time is the
  // arm's failure, and it is the retirement that stops it.
  let awaited =
    api.await_result(
      runtime,
      operation,
      within_ms: ctx.budgets.wall_ms_per_trial,
    )
  let agent_ms = ffi_os.system_time_ms() - started

  use metrics <- result.map(observe(instance))

  Driven(
    settling: case awaited {
      Ok(_) -> Settled
      Error(Nil) -> TimedOut
    },
    agent_ms:,
    metrics:,
  )
}

/// Reads usage and counts from the session's store before it closes.
fn observe(instance: Instance) -> Result(Metrics, String) {
  let store = instance.runtime.session.store

  use stats <- result.try(
    storage.stats(store)
    |> result.map_error(fn(_) { "the ledger of the session could not be read" }),
  )
  use entries <- result.try(
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_limit(8192),
    )
    |> result.map_error(fn(_) { "the entries of the session could not be read" }),
  )

  Ok(tally(stats.usage, entries))
}

/// Folds the store's entries into counts.
fn tally(usage: message.Usage, entries: List(entry.Entry)) -> Metrics {
  let empty = Metrics(usage, 0, 0, 0, 0, 0, None, None, [])

  list.fold(entries, empty, fn(seen, each) {
    case each {
      entry.CompactionEntry(..) ->
        Metrics(..seen, compactions: seen.compactions + 1)

      entry.MessageEntry(message: message.AssistantMessage(..) as assistant, ..) ->
        count_assistant(seen, assistant)

      entry.MessageEntry(
        message: message.ToolResultMessage(is_error: True, ..),
        ..,
      ) -> Metrics(..seen, tool_errors: seen.tool_errors + 1)

      entry.MessageEntry(..)
      | entry.BranchSummaryEntry(..)
      | entry.CustomEntry(..) -> seen
    }
  })
}

/// Counts one assistant answer: a turn, its tool calls, its model, and how it ended.
fn count_assistant(seen: Metrics, assistant: message.AgentMessage) -> Metrics {
  // Only assistant answers, tool errors and compactions carry counts.
  case assistant {
    message.AssistantMessage(
      content:,
      usage:,
      stop_reason:,
      error_message:,
      provider:,
      model:,
      api:,
      ..,
    ) -> {
      let calls =
        list.count(content, fn(block) {
          case block {
            message.AssistantToolCall(..) -> True
            message.AssistantText(..) | message.AssistantThinking(..) -> False
          }
        })

      // A response with no reported tokens is not accounted for, which the completeness mark records.
      let settled = case usage.total_tokens > 0 {
        True -> 1
        False -> 0
      }

      // The last assistant message decides: an earlier failed request that a
      // retry recovered from is not the way the run ended.
      let ended = case stop_reason {
        message.Errored -> Some(option.unwrap(error_message, "errored"))
        message.Pending
        | message.Stop
        | message.Length
        | message.ToolUse
        | message.Aborted
        | message.Deferred -> None
      }

      Metrics(
        ..seen,
        turns: seen.turns + 1,
        tool_calls: seen.tool_calls + calls,
        answered: seen.answered + settled,
        models: list.unique(
          list.append(seen.models, [
            ledger.Served(provider, model, api, None, ""),
          ]),
        ),
        last_error: ended,
        refusal: option.then(ended, refusal_of),
      )
    }
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> seen
  }
}

// --- wiring ------------------------------------------------------------------

// The gateway a lane gives a trial, and the findings it will report.
type Wired {
  Wired(gateway: gateway.Gateway, findings: fn() -> List(String))
}

/// Gives the trial the gateway its lane calls for.
fn open_lane(
  lane: Lane,
  settings: Settings,
  key: RowKey,
  root: String,
) -> Result(Wired, String) {
  // A live lane uses the gateway the settings carry; a taped lane swaps only the wire.
  case lane {
    Live -> Ok(Wired(gateway: settings.gateway, findings: fn() { [] }))

    Taped(open:) | Recording(open:) -> {
      use tape <- result.map(open(key, root))

      Wired(
        gateway: catalog_gateway(settings, tape.transport),
        findings: tape.findings,
      )
    }
  }
}

/// Puts the request guard and the arm's profiles on the gateway.
fn guarded_gateway(
  wired: gateway.Gateway,
  profiles: List(_),
  guard: Guard,
) -> Result(gateway.Gateway, String) {
  let admitting =
    gateway.with_request_guard(wired, fn(_actual, _api, request) {
      use Nil <- result.map(
        actor.call(guard.subject, waiting: guard_wait_ms, sending: Admit)
        |> result.map_error(string.inspect),
      )

      request
    })

  gateway.with_profiles(admitting, profiles, prompt.fingerprint, fn(attempt) {
    process.send(
      guard.subject,
      Observe(ledger.Served(
        provider: attempt.target.provider,
        model: attempt.target.model_id,
        api: attempt.api,
        profile: attempt.profile_id,
        digest: attempt.digest,
      )),
    )

    Ok(Nil)
  })
}

/// The model the main role routes to.
fn main_target(routed: gateway.Gateway) -> Result(model.ResolvedModel, String) {
  gateway.resolve(routed, model.Main)
  |> result.replace_error("the arm routes no main model")
}

/// Rebuilds a gateway over a lane's transport from the settings' catalogue.
fn catalog_gateway(
  settings: Settings,
  transport: Transport,
) -> gateway.Gateway {
  catalog.gateway(
    settings.catalog,
    transport:,
    secrets: settings.secrets,
    clock: clock.from_function(ffi_os.system_time_ms),
  )
}

// --- the workspace, the row ---------------------------------------------------

/// The copy is a separate directory so that the verifier, which may write, can
/// never alter the evidence, and so that the live directory is not reachable
/// from anything that grades.
fn freeze(runner: Runner, root: String) -> Result(String, String) {
  let frozen = root <> "/frozen"
  let live = serve.trial_workspace(root)
  let command =
    "mkdir -p "
    <> shell_quote(frozen)
    <> " && cp -a "
    <> shell_quote(live <> "/.")
    <> " "
    <> shell_quote(frozen <> "/")

  use capture <- result.try(runner(["bash", "-c", command], 600_000))

  // Only a zero status leaves a complete copy to grade.
  case capture.status {
    0 -> Ok(frozen)
    status ->
      Error(
        "freezing the workspace exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// Quotes one word for `bash -c`.
fn shell_quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

/// The session tag: a digest of the cell and attempt, so it is stable across runs.
fn tag_of(plan_id: String, blank: Row, arm: Arm, task: Task) -> String {
  let identity =
    string.join(
      [
        plan_id,
        task.id,
        arm.id,
        int.to_string(blank.index),
        int.to_string(blank.attempt),
      ],
      "/",
    )

  string.slice(mcp.sha256_hex(identity), 0, 16)
}

/// The sandbox family the host provides, read from its platform.
fn jail_of_host(selftest: String) -> ledger.Jail {
  let #(_family, name) = ffi_os.platform()

  // The platform name decides which sandbox family the row records.
  case string.contains(string.lowercase(name), "darwin") {
    True -> ledger.Jail(ledger.Seatbelt, selftest)
    False -> ledger.Jail(ledger.BwrapUserns, selftest)
  }
}

/// A row with nothing yet recorded.
fn blank_row(plan_id: String, key: RowKey, attempt: Int) -> Row {
  Row(
    plan: plan_id,
    task: key.task,
    arm: key.arm,
    index: key.index,
    attempt:,
    state: ledger.Scored,
    outcome: None,
    reward: 0.0,
    scores: [],
    side_info: "",
    served: [],
    usage: ledger.Usage(0, 0, 0, 0, 0.0, ledger.Complete),
    turns: 0,
    tool_calls: 0,
    tool_errors: 0,
    compactions: 0,
    timing: ledger.Timing(0, 0, 0, 0),
    jail: jail_of_host(unprobed),
    artifacts: ledger.Artifacts("", "", "", ""),
  )
}

/// A row keeps the end of its diagnostic: a verifier's verdict is at the bottom.
fn tail(text: String) -> String {
  case wire.bytes(text) <= ledger.max_side_info_bytes {
    True -> text
    False -> string.slice(text, string.length(text) - 2000, 2000)
  }
}
