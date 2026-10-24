//// One prompt candidate is compared with its base through fresh coding runtimes.
////
//// The native caller supplies production session assembly, isolated fixtures,
//// observed coding work, independent scoring and witnessed teardown. This module
//// owns aggregate admission and evidence, not another agent runner. Each step
//// receives the remaining allowance before it starts. A partial run, missing
//// tool execution, unknown outcome or unconfirmed teardown remains inconclusive.
//// Scripted fixtures prove this lifecycle and cannot produce quality evidence.

import client/evolution/prompt
import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/evolution/trace
import client/mcp
import core/clock.{type Clock}
import core/json
import core/message
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/model
import provider/profile.{type Profile}

/// A task and criterion admitted independently of the proposed prompt.
pub type Task {
  Task(
    /// Versioned task identifier.
    id: String,
    /// Coding work given to each isolated trial.
    prompt: String,
    /// Native independent scoring criterion, never the model's success claim.
    criteria: String,
    /// Immutable fixture identity consumed by the native production opener.
    fixture: String,
  )
}

/// Aggregate budget for the whole baseline and candidate comparison.
pub type Limits {
  Limits(
    /// Number of fresh runtime trials, at most twenty.
    trials: Int,
    /// Total model turns, at most one hundred.
    turns: Int,
    /// Total input, output and cache tokens, at most one million.
    tokens: Int,
    /// Total priced usage in dollars.
    dollars: Float,
    /// Retained output bytes, at most 64 KiB.
    output_bytes: Int,
    /// Absolute comparison wall budget, at most fifteen minutes.
    wall_ms: Int,
  )
}

/// Remaining budget that the runtime enforces before its next real effect.
pub type Allowance {
  Allowance(
    /// Remaining aggregate turns.
    turns: Int,
    /// Remaining aggregate tokens.
    tokens: Int,
    /// Remaining aggregate dollars.
    dollars: Float,
    /// Remaining retained output bytes.
    output_bytes: Int,
    /// Absolute deadline, including fixture scoring and close.
    deadline_ms: Int,
  )
}

/// One isolated trial; exact targeting prevents fallback from changing the test.
pub type TrialRequest {
  TrialRequest(
    /// Always `ForResolved`, with no fallback chain.
    target: model.RequestTarget,
    /// Actual adapter API required for this comparison.
    api: String,
    /// Base has no profile; candidate has exactly its immutable overlay.
    profile: Option(Profile),
    /// Independent versioned task and fixture.
    task: Task,
    /// Initial native admission before runtime or tools are opened.
    allowance: Allowance,
  )
}

/// The settled coding operation continues or has completed its model work.
pub type Progress {
  /// Another model turn may be admitted after accounting this one.
  Continue

  /// Model work is settled; the independent scorer can inspect the fixture.
  Finished

  /// Native failure or interruption retains its partial observations.
  Interrupted(reason: String)
}

/// Conservative spend retained when an admitted attempt has no complete usage.
pub type Unreported {
  Unreported(
    /// Worst-case token debit, separate from observed provider usage.
    tokens: Int,
    /// Worst-case priced debit, separate from observed provider cost.
    dollars: Float,
  )
}

/// One settled coding step with actual native turn and tool execution counts.
pub type Step {
  Step(
    /// Actual identity, checked against the exact trial target.
    target: record.ModelScope,
    /// Actual adopted candidate, checked against the trial's profile.
    profile_id: Option(String),
    /// Native ledger observation for this settled coding step.
    usage: message.Usage,
    /// Native counted provider turns, including failed dispatched attempts.
    turns: Int,
    /// Native counted completed tool executions, excluding model claims.
    tool_executions: Int,
    /// Bounded answer/report text retained as diagnostic evidence.
    output: String,
    /// Whether the coding operation has settled.
    progress: Progress,
    /// Native fingerprints of actual composed prompt/tool descriptions for attempts.
    composition_digests: List(String),
    /// Unknown charges which later trial arms must never refund.
    unreported: Unreported,
  )
}

/// An isolated runtime and its native capabilities, owned until `close` proves exit.
pub type Trial {
  Trial(
    /// Advance real coding work under the supplied remaining aggregate budget.
    step: fn(Allowance) -> Result(Step, String),
    /// Independently evaluate the fixture after close proves native retirement.
    score: fn(String) -> Result(trace.Outcome, String),
    /// Cancel remaining work and prove native retirement.
    close: retirement.Task,
    /// Remove the isolated fixture only after retirement and independent scoring.
    cleanup: fn() -> Result(Nil, String),
  )
}

/// Native provenance distinguishes measured behavior from fixture mechanics.
pub type Mode {
  /// Real providers, tools and isolated production runtimes.
  LiveProduction

  /// Deterministic fixtures; evidence cannot authorize measured quality.
  ScriptedLifecycle
}

/// Caller-owned assembly avoids a client/serve import cycle.
pub type Callbacks {
  Callbacks(
    /// Open a fresh fixture and production runtime for each call.
    open: fn(TrialRequest) -> Result(Trial, String),
    /// Native execution source, never selected by candidate content.
    mode: Mode,
    /// Wall clock used for aggregate admission.
    clock: Clock,
  )
}

/// Aggregate counters and partial trial reports remain owned after a failure.
type State {
  State(
    limits: Limits,
    started: Int,
    clock: Clock,
    trials: Int,
    turns: Int,
    tokens: Int,
    dollars: Float,
    unreported_tokens: Int,
    unreported_dollars: Float,
    output_bytes: Int,
    tools: Int,
    reports: List(json.JsonValue),
    stop: Option(String),
    cleanup: Option(#(String, retirement.Task)),
    trial_start: #(Int, Int, Float, Int, Int, Float),
    trial_started: Int,
    composition_digests: List(String),
    output: String,
    outcome: trace.Outcome,
  )
}

/// Evaluates one immutable candidate beside its unchanged base and persists both.
/// Limits, task bytes, actual target, trial outcomes and partial counters bind
/// the evidence digest. Passing criteria is shown separately from cost.
///
/// ## Examples
///
/// ```gleam
/// // rollout.evaluate(catalogue, candidate_id, exact, api, tasks, limits, native)
/// ```
pub fn evaluate(
  catalogue: store.Store,
  candidate_id: record.CandidateId,
  target: model.ResolvedModel,
  api: String,
  tasks: List(Task),
  limits: Limits,
  callbacks: Callbacks,
) -> Result(record.Evidence, store.Refusal) {
  use Nil <- result.try(
    validate(tasks, limits) |> result.map_error(store.Bounds),
  )
  use candidate <- result.try(store.read_candidate(catalogue, candidate_id))
  use profile <- result.try(
    prompt.candidate_profile(candidate) |> result.map_error(store.Bounds),
  )
  let #(_, provider, model_id, profile_api, _, _, _) = profile.fields(profile)

  // Verify that candidate profile matches rollout target coordinates.
  use Nil <- result.try(
    case
      provider == target.provider
      && model_id == target.model_id
      && profile_api == api
    {
      True -> Ok(Nil)
      False ->
        Error(store.Bounds(
          "rollout target differs from candidate's exact scope",
        ))
    },
  )

  // Initialize rollout state and execute paired trials.
  let #(started, clock) = clock.read(callbacks.clock)
  let state =
    State(
      limits:,
      started:,
      clock:,
      trials: 0,
      turns: 0,
      tokens: 0,
      dollars: 0.0,
      unreported_tokens: 0,
      unreported_dollars: 0.0,
      output_bytes: 0,
      tools: 0,
      reports: [],
      stop: None,
      cleanup: None,
      trial_start: #(0, 0, 0.0, 0, 0, 0.0),
      trial_started: started,
      composition_digests: [],
      output: "",
      outcome: trace.Unmarked,
    )
  let state =
    list.fold(tasks, state, fn(state, task) {
      let state = run_trial(state, callbacks, target, api, task, None)
      run_trial(state, callbacks, target, api, task, Some(profile))
    })

  // Record retained evaluation evidence and clean up.
  let verdict = verdict(state, callbacks.mode, list.length(tasks) * 2)
  let observation =
    observation(state, callbacks.mode, tasks, candidate_id, target, api)
  let retained =
    store.record_evidence(
      catalogue,
      candidate_id,
      record.IndependentRollout,
      verdict,
      json.to_string(observation),
    )

  // Check if unconfirmed cleanup needs to be surfaced.
  case state.cleanup {
    None -> retained
    Some(#(reason, close)) -> {
      // Combine recorded reason with cleanup diagnostic.
      let reason = case retained {
        Ok(evidence) ->
          reason
          <> "; inconclusive evidence_id="
          <> record.evidence_string(evidence.id)
        Error(error) ->
          reason
          <> "; partial evidence did not commit: "
          <> bounded(store.describe(error))
      }

      Error(store.CleanupUnconfirmed(reason, close))
    }
  }
}

/// Validates task collection bounds and trial limits ceilings.
fn validate(tasks: List(Task), limits: Limits) -> Result(Nil, String) {
  let task_bytes =
    tasks |> list.map(task_json) |> json.Array |> json.to_string |> bytes

  // Verify tasks are non-empty and within budget limits.
  case
    tasks != []
    && list.length(tasks) <= 10
    && task_bytes <= 8192
    && list.all(tasks, fn(task) {
      task.id != ""
      && task.prompt != ""
      && task.criteria != ""
      && task.fixture != ""
    })
    && limits.trials > 0
    && limits.trials <= 20
    && limits.turns > 0
    && limits.turns <= 100
    && limits.tokens > 0
    && limits.tokens <= 1_000_000
    && limits.dollars >. 0.0
    && limits.output_bytes > 0
    && limits.output_bytes <= 65_536
    && limits.wall_ms > 0
    && limits.wall_ms <= 900_000
  {
    True -> Ok(Nil)
    False -> Error("invalid rollout tasks or aggregate budget")
  }
}

// Each arm retires native execution before independent fixture scoring begins.
/// Runs a single trial arm against the target model and records progress.
fn run_trial(
  state: State,
  callbacks: Callbacks,
  target: model.ResolvedModel,
  api: String,
  task: Task,
  profile: Option(Profile),
) -> State {
  // Check whether execution is stopped or budget limit is met.
  case state.stop, state.trials >= state.limits.trials {
    Some(_), _ -> state
    None, True -> State(..state, stop: Some("aggregate trial budget exhausted"))
    None, False -> {
      let #(trial_started, clock) = clock.read(state.clock)
      let state = State(..state, clock:)
      let #(allowance, state) = allowance(state)

      // Verify trial allowance availability before opening trial.
      case allowance {
        Error(reason) -> State(..state, stop: Some(reason))
        Ok(allowance) ->
          open_trial(
            State(
              ..state,
              trials: state.trials + 1,
              trial_started:,
              composition_digests: [],
              tools: 0,
              trial_start: #(
                state.turns,
                state.tokens,
                state.dollars,
                state.output_bytes,
                state.unreported_tokens,
                state.unreported_dollars,
              ),
              output: "",
              outcome: trace.Unmarked,
            ),
            callbacks,
            TrialRequest(
              target: model.ForResolved(target),
              api:,
              profile:,
              task:,
              allowance:,
            ),
          )
      }
    }
  }
}

/// Opens runtime environment for a trial and handles execution lifecycle.
fn open_trial(
  state: State,
  callbacks: Callbacks,
  request: TrialRequest,
) -> State {
  // Attempt to open isolated trial runtime.
  let state = case callbacks.open(request) {
    Error(reason) ->
      State(
        ..state,
        stop: Some("isolated runtime open failed: " <> bounded(reason)),
      )
    Ok(trial) -> {
      let state = drive(state, trial, request)

      // Perform runtime retirement cleanup.
      case retirement.perform(trial.close) {
        Ok(Nil) -> {
          // Score trial outcome if trial did not halt early.
          let state = case state.stop {
            None -> score(state, trial, request)
            Some(_) -> state
          }

          // Execute private fixture cleanup task.
          case trial.cleanup() {
            Ok(Nil) -> state
            Error(reason) ->
              State(
                ..state,
                stop: Some(
                  "private fixture cleanup failed: " <> bounded(reason),
                ),
                cleanup: Some(#(
                  bounded(reason),
                  retirement.repeat(trial.cleanup),
                )),
              )
          }
        }
        Error(failed) -> {
          State(
            ..state,
            stop: Some(
              "runtime retirement unconfirmed: " <> bounded(failed.reason),
            ),
            cleanup: Some(#(
              bounded(failed.reason),
              retirement.sequence(
                failed.retry,
                retirement.repeat(trial.cleanup),
              ),
            )),
          )
        }
      }
    }
  }

  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)

  // Check whether cumulative wall clock budget has expired.
  let state = case now >= state.started + state.limits.wall_ms {
    True -> State(..state, stop: Some("aggregate wall budget exhausted"))
    False -> state
  }

  retain_trial(state, request, now)
}

/// Steps trial execution loop until finished or interrupted.
fn drive(state: State, trial: Trial, request: TrialRequest) -> State {
  let #(available, state) = allowance(state)

  // Check remaining allowance before stepping trial.
  case available {
    Error(reason) -> State(..state, stop: Some(reason))
    Ok(available) -> {
      case trial.step(available) {
        Error(reason) ->
          State(..state, stop: Some("trial failed: " <> bounded(reason)))
        Ok(step) -> accept_step(state, trial, request, step)
      }
    }
  }
}

/// Records resource consumption and checks output bounds for completed trial step.
fn accept_step(
  state: State,
  trial: Trial,
  request: TrialRequest,
  step: Step,
) -> State {
  // Verify model target matches requested model scope.
  let target_matches = case request.target {
    model.ForResolved(target) ->
      step.target
      == record.ModelScope(target.provider, target.model_id, request.api)
    model.ForRole(..) -> False
  }

  let expected =
    option.map(request.profile, fn(profile) { profile.fields(profile).0 })
  let used =
    int.max(
      step.usage.total_tokens,
      step.usage.input
        + step.usage.output
        + step.usage.cache_read
        + step.usage.cache_write,
    )
  let state =
    State(
      ..state,
      turns: state.turns + step.turns,
      tokens: state.tokens + used,
      dollars: state.dollars +. step.usage.cost.total,
      unreported_tokens: state.unreported_tokens + step.unreported.tokens,
      unreported_dollars: state.unreported_dollars +. step.unreported.dollars,
      output_bytes: state.output_bytes + bytes(step.output),
      tools: state.tools + step.tool_executions,
      output: bounded(step.output),
      composition_digests: list.append(
        state.composition_digests,
        step.composition_digests,
      ),
    )

  // Validate step metrics stay within native limits and admission bounds.
  case
    !target_matches
    || step.profile_id != expected
    || step.turns <= 0
    || step.composition_digests == []
    || list.length(state.composition_digests) > 100
    || !list.all(step.composition_digests, fn(digest) { bytes(digest) == 64 })
    || used < 0
    || step.usage.cost.total <. 0.0
    || step.tool_executions < 0
    || step.unreported.tokens < 0
    || !{ step.unreported.dollars >=. 0.0 }
  {
    True ->
      State(
        ..state,
        stop: Some("actual trial identity or usage violated native admission"),
      )
    False -> {
      let #(now, clock) = clock.read(state.clock)
      let state = State(..state, clock:)

      // Evaluate step progress and loop or terminate trial.
      case within(state, now), step.progress {
        False, _ ->
          State(..state, stop: Some("aggregate rollout budget exhausted"))
        True, Continue -> drive(state, trial, request)
        True, Finished -> state
        True, Interrupted(reason) -> State(..state, stop: Some(bounded(reason)))
      }
    }
  }
}

/// Evaluates criteria scoring function on finished trial.
fn score(state: State, trial: Trial, request: TrialRequest) -> State {
  case state.tools > 0 {
    False ->
      State(..state, stop: Some("trial did not execute a real coding tool"))
    True ->
      case trial.score(request.task.criteria) {
        Error(reason) ->
          State(
            ..state,
            stop: Some("independent scoring failed: " <> bounded(reason)),
          )
        Ok(trace.Unmarked) ->
          State(..state, stop: Some("independent task outcome is absent"))
        Ok(outcome) -> State(..state, outcome:)
      }
  }
}

/// Adds report entry for completed trial to state history.
fn retain_trial(state: State, request: TrialRequest, now: Int) -> State {
  let report =
    json.Object([
      #("task", json.String(request.task.id)),
      #("profile", case request.profile {
        None -> json.Null
        Some(profile) -> json.String(profile.fields(profile).0)
      }),
      #(
        "outcome",
        json.String(case state.outcome {
          trace.Succeeded -> "succeeded"
          trace.Failed -> "failed"
          trace.Unmarked -> "unmarked"
        }),
      ),
      #("tools", json.Int(state.tools)),
      #(
        "composition_digests",
        json.Array(list.map(state.composition_digests, json.String)),
      ),
      #("output", json.String(state.output)),
      #("turns", json.Int(state.turns - state.trial_start.0)),
      #("tokens", json.Int(state.tokens - state.trial_start.1)),
      #("dollars", json.Float(state.dollars -. state.trial_start.2)),
      #("output_bytes", json.Int(state.output_bytes - state.trial_start.3)),
      #(
        "unreported_tokens",
        json.Int(state.unreported_tokens - state.trial_start.4),
      ),
      #(
        "unreported_dollars",
        json.Float(state.unreported_dollars -. state.trial_start.5),
      ),
      #("elapsed_ms", json.Int(now - state.trial_started)),
      #("partial_reason", case state.stop {
        None -> json.Null
        Some(reason) -> json.String(reason)
      }),
    ])
  State(..state, reports: [report, ..state.reports])
}

/// Checks if cumulative resource usage remains strictly within limits.
fn within(state: State, now: Int) -> Bool {
  state.turns <= state.limits.turns
  && state.tokens + state.unreported_tokens <= state.limits.tokens
  && state.dollars +. state.unreported_dollars <=. state.limits.dollars
  && state.output_bytes <= state.limits.output_bytes
  && now < state.started + state.limits.wall_ms
}

/// Calculates remaining resource allowance for subsequent trial runs.
fn allowance(state: State) -> #(Result(Allowance, String), State) {
  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)
  let left =
    Allowance(
      turns: state.limits.turns - state.turns,
      tokens: state.limits.tokens - state.tokens - state.unreported_tokens,
      dollars: state.limits.dollars -. state.dollars -. state.unreported_dollars,
      output_bytes: state.limits.output_bytes - state.output_bytes,
      deadline_ms: state.started + state.limits.wall_ms,
    )

  // Determine if positive allowance remains across all budget metrics.
  let result = case
    state.trials <= state.limits.trials
    && left.turns > 0
    && left.tokens > 0
    && left.dollars >. 0.0
    && left.output_bytes > 0
    && now < left.deadline_ms
  {
    True -> Ok(left)
    False -> Error("aggregate rollout budget exhausted")
  }

  #(result, state)
}

/// Evaluates candidate trial reports to determine overall rollout verdict.
fn verdict(state: State, mode: Mode, expected: Int) -> record.Verdict {
  case mode, state.stop, list.length(state.reports) == expected {
    ScriptedLifecycle, _, _ ->
      record.Inconclusive(
        "scripted lifecycle evidence does not measure model quality",
      )
    LiveProduction, Some(reason), _ -> record.Inconclusive(reason)
    LiveProduction, None, False ->
      record.Inconclusive("paired task set is incomplete")
    LiveProduction, None, True ->
      case list.any(state.reports, candidate_failed) {
        True -> record.Failed
        False -> record.Passed
      }
  }
}

// Only candidate-arm failures decide adoption; baseline failures remain evidence.
/// Checks if report indicates candidate arm failure.
fn candidate_failed(report: json.JsonValue) -> Bool {
  case report {
    json.Object(fields) ->
      list.key_find(fields, "outcome") == Ok(json.String("failed"))
      && list.key_find(fields, "profile") != Ok(json.Null)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> False
  }
}

/// Constructs detailed observation JSON report for the rollout evaluation.
fn observation(
  state: State,
  mode: Mode,
  tasks: List(Task),
  candidate: record.CandidateId,
  target: model.ResolvedModel,
  api: String,
) -> json.JsonValue {
  let task_set = json.Array(list.map(tasks, task_json))
  json.Object([
    #("version", json.Int(1)),
    #("candidate", json.String(record.id_string(candidate))),
    #(
      "mode",
      json.String(case mode {
        LiveProduction -> "live-production"
        ScriptedLifecycle -> "scripted-lifecycle"
      }),
    ),
    #("provider", json.String(target.provider)),
    #("model", json.String(target.model_id)),
    #("api", json.String(api)),
    #("task_set_digest", json.String(mcp.sha256_hex(json.to_string(task_set)))),
    #("tasks", task_set),
    #(
      "limits",
      json.Object([
        #("trials", json.Int(state.limits.trials)),
        #("turns", json.Int(state.limits.turns)),
        #("tokens", json.Int(state.limits.tokens)),
        #("dollars", json.Float(state.limits.dollars)),
        #("output_bytes", json.Int(state.limits.output_bytes)),
        #("wall_ms", json.Int(state.limits.wall_ms)),
      ]),
    ),
    #(
      "used",
      json.Object([
        #("trials", json.Int(state.trials)),
        #("turns", json.Int(state.turns)),
        #("tokens", json.Int(state.tokens)),
        #("dollars", json.Float(state.dollars)),
        #("output_bytes", json.Int(state.output_bytes)),
      ]),
    ),
    #("partial_reason", case state.stop {
      None -> json.Null
      Some(reason) -> json.String(reason)
    }),
    #(
      "unreported",
      json.Object([
        #("tokens", json.Int(state.unreported_tokens)),
        #("dollars", json.Float(state.unreported_dollars)),
      ]),
    ),
    #("trials", json.Array(list.reverse(state.reports))),
  ])
}

/// Serializes a task specification into JSON format.
fn task_json(task: Task) -> json.JsonValue {
  json.Object([
    #("id", json.String(task.id)),
    #("prompt", json.String(task.prompt)),
    #("criteria", json.String(task.criteria)),
    #("fixture", json.String(task.fixture)),
  ])
}

fn bytes(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

fn bounded(text: String) -> String {
  trace.scrub_excerpt(text, 1024)
}
