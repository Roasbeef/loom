//// One prompt candidate is compared with its base through fresh coding runtimes.
////
//// The native caller supplies production session assembly, isolated fixtures,
//// observed coding work, independent scoring and witnessed teardown. This module
//// owns aggregate admission and evidence, not another agent runner. Each step
//// receives the remaining allowance before it starts. A partial run, missing
//// tool execution, unknown outcome or unconfirmed teardown remains inconclusive.
//// Scripted fixtures prove this lifecycle and cannot produce quality evidence.
////
//// A trial is graded, not merely marked: the independent verifier answers a
//// `Grade` whose reward decides pass or fail at `pass_threshold`, and whose
//// side information is kept for an optimizer. The paired fold runs
//// `Limits.samples` independent samples of every task through each arm under
//// the same aggregate budget, so a retained observation carries one report
//// per (task, sample, arm) and the verdict sees every one of them.
////
//// ## Flow
////
//// `evaluate` → `validate` → `run_trial` → `open_trial` → `drive` → `accept_step` → `score` → `admit_grade` → `retain_trial` → `verdict` → `observation`
////
//// 1. `evaluate` checks the request with `validate`, reads the candidate's
////    profile, and folds `run_trial` over every task, sample and arm.
//// 2. `run_trial` admits one trial against the trial count and `allowance`,
////    and `open_trial` opens the runtime through the caller's callbacks.
//// 3. `drive` and `accept_step` step the coding operation, debiting usage
////    and checking identity until it finishes, stops or exhausts `within`.
//// 4. After `retirement.perform`, `score` asks the verifier for a `Grade`
////    and `admit_grade` checks every member (`grade_defect`, `clip_bytes`).
//// 5. `retain_trial` writes the trial's report (`grade_json`), and after the
////    fold `verdict` and `observation` produce the durable evidence.

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
import gleam/string
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
    /// Independent samples of every task per arm, one to five. Each sample
    /// is a fresh runtime and a trial of its own, debited from the same
    /// aggregate budget as the rest.
    samples: Int,
  )
}

/// A trial passes when its grade's reward reaches this value. The exact-byte
/// verifier answers only `1.0` or `0.0`, so the threshold is the whole rule
/// until a program verifier with a scoring policy of its own exists.
pub const pass_threshold = 1.0

/// Which independent verifier graded a trial, and what it observed doing so.
pub type VerifierRun {
  /// The exact-byte comparison of the task's admitted expected files, run in
  /// the host after witnessed retirement.
  ExpectedFiles

  /// A hidden program run in a fresh jail after retirement, with the argv
  /// that was cleared, its exit status and its wall time in milliseconds.
  ProgramRun(argv: List(String), exit_status: Int, wall_ms: Int)
}

/// An independent verifier's grade of one retired trial workspace.
pub type Grade {
  Grade(
    /// Scalar reward from `0.0` through `1.0`; `passed` compares it with
    /// `pass_threshold`. Anything outside that range is refused at scoring.
    reward: Float,
    /// Named sub-scores, in the shape of a verifier's reward map. Empty for
    /// the exact-byte verifier.
    scores: List(#(String, Float)),
    /// Bounded diagnostic prose for an optimizer, such as the first differing
    /// path. Never the expected bytes, which stay in the host.
    side_info: String,
    /// The verifier that produced this grade.
    verifier: VerifierRun,
  )
}

/// Whether a grade's reward reaches `pass_threshold`.
///
/// ## Examples
///
/// ```gleam
/// rollout.passed(rollout.Grade(1.0, [], "", rollout.ExpectedFiles))
/// // -> True
/// ```
pub fn passed(grade: Grade) -> Bool {
  grade.reward >=. pass_threshold
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
    /// Independently grade the fixture after close proves native retirement.
    score: fn(String) -> Result(Grade, String),
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

/// One retained trial report, with the two facts the verdict reads kept
/// typed beside the JSON so the decision never parses its own evidence.
type Retained {
  Retained(
    profile: Option(String),
    grade: Option(Grade),
    report: json.JsonValue,
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
    reports: List(Retained),
    stop: Option(String),
    cleanup: Option(#(String, retirement.Task)),
    trial_start: #(Int, Int, Float, Int, Int, Float),
    trial_started: Int,
    composition_digests: List(String),
    output: String,
    sample: Int,
    grade: Option(Grade),
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
      sample: 0,
      grade: None,
    )

  // Every sample of a task runs its base arm and then its candidate arm, so
  // the pair that the verdict compares is adjacent in the budget's order and
  // a budget that runs out leaves whole pairs behind rather than one arm of
  // every sample.
  let samples =
    list.index_map(list.repeat(Nil, limits.samples), fn(_, index) { index + 1 })
  let state =
    list.fold(tasks, state, fn(state, task) {
      list.fold(samples, state, fn(state, sample) {
        let state = run_trial(state, callbacks, target, api, task, sample, None)
        run_trial(state, callbacks, target, api, task, sample, Some(profile))
      })
    })

  // Record retained evaluation evidence and clean up.
  let expected = list.length(tasks) * 2 * limits.samples
  let verdict = verdict(state, callbacks.mode, expected)
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
  let needed = list.length(tasks) * 2 * limits.samples

  // A comparison whose trial budget cannot hold every (task, sample, arm)
  // would spend the whole budget and end Inconclusive by construction, so it
  // is refused before any trial opens, naming the product the caller must
  // either fund or shrink.
  use Nil <- result.try(case needed <= limits.trials {
    True -> Ok(Nil)
    False ->
      Error(
        "rollout needs "
        <> int.to_string(needed)
        <> " trials (tasks x 2 arms x "
        <> int.to_string(limits.samples)
        <> " samples) but the trial budget admits "
        <> int.to_string(limits.trials),
      )
  })

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
    && limits.samples > 0
    && limits.samples <= 5
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
  sample: Int,
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
              sample:,
              grade: None,
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

/// Asks the independent verifier for the finished trial's grade.
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
        Ok(grade) -> admit_grade(state, grade)
      }
  }
}

/// Retained side information per report, in bytes after scrubbing.
const max_side_info_bytes = 1024

/// Named scores a grade may carry, and the byte length of one name.
const max_scores = 8

const max_score_name_bytes = 32

/// Entries and total bytes of a program verifier's retained argv.
const max_argv_entries = 8

const max_argv_bytes = 512

// Every member of a grade is checked before it is retained, because the
// grade is written into evidence only after the whole budget is spent: a
// duplicate score name would make the canonical JSON unparseable and a large
// member would push the observation past the store's 64 KiB evidence
// ceiling, and either loses all evidence of a paid comparison. A defect
// stops the fold with a named reason, so the verdict is Inconclusive and the
// partial observation still commits.
//
// Worst-case size at 20 trials, for the record. The members this shape added
// cost per report at most 1,024 bytes of side information, 8 scores of a
// 32-byte name and a float (about 450 bytes), a 512-byte argv and the
// verifier's fixed fields, so about 2 KiB per report and about 40 KiB over
// 20 trials: the new members alone cannot be what breaks the 64 KiB
// evidence ceiling. The exact-byte verifier contributes under 300 bytes per
// report. Known issue, separate from this shape and not fixed here: the
// pre-existing `output` excerpt is bounded in graphemes (1,024, up to 4 KiB
// of UTF-8 before JSON escaping), so 20 reports of it alone could reach 80
// KiB; a program verifier's wide answers add to that, not to the grade.
/// Retains a grade whose members are all in bounds, side information clipped.
fn admit_grade(state: State, grade: Grade) -> State {
  case grade_defect(grade) {
    Error(reason) -> State(..state, stop: Some(reason))
    Ok(Nil) ->
      State(
        ..state,
        grade: Some(
          Grade(
            ..grade,
            side_info: clip_bytes(bounded(grade.side_info), max_side_info_bytes),
          ),
        ),
      )
  }
}

/// The first bound a grade violates, named, or `Ok` when every member fits.
fn grade_defect(grade: Grade) -> Result(Nil, String) {
  let names = list.map(grade.scores, fn(score) { score.0 })

  // Only a program run carries an argv to bound; the exact-byte verifier
  // contributes nothing here.
  let #(argv_entries, argv_bytes) = case grade.verifier {
    ExpectedFiles -> #([], 0)
    ProgramRun(argv:, ..) -> #(
      argv,
      list.fold(argv, 0, fn(total, entry) { total + bytes(entry) }),
    )
  }

  // The table is read in order, so the reason names the first defect found.
  let defects = [
    #(
      grade.reward <. 0.0 || grade.reward >. 1.0,
      "independent grade is out of range",
    ),
    #(
      list.drop(grade.scores, max_scores) != [],
      "independent grade carries more than 8 scores",
    ),
    #(
      list.any(names, fn(name) {
        name == "" || bytes(name) > max_score_name_bytes
      }),
      "independent grade score name is empty or over 32 bytes",
    ),
    #(list.unique(names) != names, "independent grade score names repeat"),
    #(
      list.any(grade.scores, fn(score) { score.1 <. 0.0 || score.1 >. 1.0 }),
      "independent grade score is out of range",
    ),
    #(
      list.drop(argv_entries, max_argv_entries) != [],
      "independent verifier argv has more than 8 entries",
    ),
    #(
      argv_bytes > max_argv_bytes,
      "independent verifier argv exceeds 512 bytes",
    ),
  ]

  // The first true row is the defect reported; no row true is admission.
  case list.find(defects, fn(defect) { defect.0 }) {
    Ok(#(_, reason)) -> Error(reason)
    Error(Nil) -> Ok(Nil)
  }
}

/// Keeps the longest prefix of whole graphemes that fits in `limit` bytes.
fn clip_bytes(text: String, limit: Int) -> String {
  let #(kept, _) =
    list.fold_until(string.to_graphemes(text), #([], 0), fn(acc, grapheme) {
      let size = acc.1 + bytes(grapheme)

      // A grapheme that would cross the limit ends the prefix before it.
      case size > limit {
        True -> list.Stop(acc)
        False -> list.Continue(#([grapheme, ..acc.0], size))
      }
    })
  kept |> list.reverse |> string.concat
}

/// Adds report entry for completed trial to state history.
fn retain_trial(state: State, request: TrialRequest, now: Int) -> State {
  let profile = option.map(request.profile, fn(p) { profile.fields(p).0 })

  // `outcome` stays beside `grade` as its three-word projection, so a reader
  // of older observations and a reader of these see the same word in the
  // same place; `grade` and `sample` are the members this shape added.
  let report =
    json.Object([
      #("task", json.String(request.task.id)),
      #("profile", case profile {
        None -> json.Null
        Some(id) -> json.String(id)
      }),
      #("outcome", json.String(outcome_word(state.grade))),
      #("grade", case state.grade {
        None -> json.Null
        Some(grade) -> grade_json(grade)
      }),
      #("sample", json.Int(state.sample)),
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
  let retained = Retained(profile:, grade: state.grade, report:)
  State(..state, reports: [retained, ..state.reports])
}

/// Projects a grade onto the operator-outcome vocabulary of `trace.Outcome`.
fn outcome_word(grade: Option(Grade)) -> String {
  case option.map(grade, passed) {
    None -> outcome_name(trace.Unmarked)
    Some(True) -> outcome_name(trace.Succeeded)
    Some(False) -> outcome_name(trace.Failed)
  }
}

/// The wire word of each operator outcome, as `trace` and the trace door spell it.
fn outcome_name(outcome: trace.Outcome) -> String {
  case outcome {
    trace.Succeeded -> "succeeded"
    trace.Failed -> "failed"
    trace.Unmarked -> "unmarked"
  }
}

/// Encodes a grade with its verifier for the retained observation.
fn grade_json(grade: Grade) -> json.JsonValue {
  json.Object([
    #("reward", json.Float(grade.reward)),
    #(
      "scores",
      json.Object(
        list.map(grade.scores, fn(score) { #(score.0, json.Float(score.1)) }),
      ),
    ),
    #("side_info", json.String(grade.side_info)),
    #("verifier", verifier_json(grade.verifier)),
  ])
}

/// Encodes which verifier ran, with a program run's argv, exit and wall time.
fn verifier_json(verifier: VerifierRun) -> json.JsonValue {
  case verifier {
    ExpectedFiles -> json.Object([#("kind", json.String("expected-files"))])
    ProgramRun(argv:, exit_status:, wall_ms:) ->
      json.Object([
        #("kind", json.String("program")),
        #("argv", json.Array(list.map(argv, json.String))),
        #("exit_status", json.Int(exit_status)),
        #("wall_ms", json.Int(wall_ms)),
      ])
  }
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
// A candidate arm that was never graded cannot have passed.
/// Checks if a retained report is a candidate arm whose grade did not pass.
fn candidate_failed(retained: Retained) -> Bool {
  case retained.profile, option.map(retained.grade, passed) {
    None, _ -> False
    Some(_), None -> True
    Some(_), Some(reached) -> !reached
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
        #("samples", json.Int(state.limits.samples)),
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
    #(
      "trials",
      json.Array(state.reports |> list.reverse |> list.map(fn(r) { r.report })),
    ),
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
