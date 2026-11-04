//// The bounded fan-out of a live verdict: many trials of a decision function,
//// run at a fixed concurrency under a wall limit, gathered into samples.
////
//// A live verdict asks the router's model what it would do with each labelled
//// trigger, `judge.live_trials` times. Thirty triggers make ninety model calls,
//// which is real spend, so the run is bounded in three ways. At most
//// `Limits.concurrency` trials are in flight. The whole run has `Limits.wall_ms`
//// and is cut off when it expires. And the first trial that fails ends the run,
//// because a verdict over a partial set of trials is not a verdict and every
//// further call would be spent for nothing.
////
//// This module knows nothing about sessions or models. A `Judge` carries a
//// `decide` function, and `client/project_judge_session` builds the one that
//// opens a scratch session per trial. Keeping them apart lets a test supply a
//// scripted `decide` and still run the same fan-out, limits and accounting.
////
//// ## Flow
////
//// `measure` → `attempt` → `settle` → `assemble`
////
//// 1. `measure` turns each labelled trigger and trial into one job, and runs
////    the jobs as a weft run with a concurrency limit, a wall deadline, and
////    cancellation of the rest on the first failure.
//// 2. `attempt` is one job. It asks the judge for a decision and reports what
////    the trial spent as it ends, so a caller can show a run's cost while it
////    is going and after it has failed.
//// 3. `settle` reads the run's account. Either every trial completed, or the
////    run is incomplete and the answer is a sentence saying why.
//// 4. `assemble` turns the decisions of a complete run into samples in trigger
////    order.

import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/result
import project/judge.{type Choice, type Sample, Sample}
import project/model.{type Label}
import project/tape.{type Frame}
import weft

/// How many trials run at once unless a host says otherwise.
pub const default_concurrency: Int = 4

/// How long a run may take, in milliseconds, unless a host says otherwise.
/// Ninety trials at four in flight and a model that takes ten seconds to answer
/// finish in under four minutes. The limit leaves several times that for a slow
/// provider and cuts off one that has stopped answering.
pub const default_wall_ms: Int = 1_200_000

/// What bounds a run.
pub type Limits {
  Limits(
    /// The most trials in flight at once. Below one it is one.
    concurrency: Int,
    /// The wall time of the whole run, in milliseconds.
    wall_ms: Int,
  )
}

/// What a run has spent on the model: requests sent and tokens billed.
pub type Spend {
  Spend(
    /// Provider requests.
    calls: Int,
    /// Tokens the provider reported, input and output together.
    tokens: Int,
  )
}

/// A trial's end when the model answered no routing: the run completed with no
/// `route` call that names the candidate.
pub type Routing {
  /// The model routed the candidate.
  Routed

  /// The model routed nothing for the candidate, so the project would have
  /// left it unrouted. It counts as declining, and the report counts them.
  Unrouted
}

/// What one trial decided and what it cost.
pub type Decision {
  Decision(
    /// Take the trigger on, or not.
    choice: Choice,
    /// Whether the model routed the candidate at all.
    routing: Routing,
    /// What the trial spent.
    spend: Spend,
  )
}

/// Why a trial produced no decision, with what it had spent by then.
pub type Failure {
  Failure(
    /// A sentence for the owner.
    words: String,
    /// What the trial spent before it failed.
    spend: Spend,
  )
}

/// How a trial hands the run a process it started and must not outlive the
/// trial: its root and a request that it stop. `Ok` means the run holds the
/// process and will ask it to stop if the trial is cancelled, and will not
/// release the trial's slot until it has. `Error` means the run is already
/// ending, and the caller must stop the process itself and start no work in it.
pub type Custody =
  fn(Pid, fn() -> Nil) -> Result(Nil, Nil)

/// The host's way to run a live verdict: how one trial is decided, and what
/// bounds the run.
pub type Judge {
  Judge(
    /// Decides one labelled trigger at a trial index. Each call starts from a
    /// fresh context, so trials do not see each other. A decision that starts
    /// processes hands them over through the custody before it uses them.
    decide: fn(Frame, Int, Custody) -> Result(Decision, Failure),
    /// What bounds the run.
    limits: Limits,
  )
}

/// A complete run.
pub type Measured {
  Measured(
    /// One sample per labelled trigger, in the tape's order, with every trial.
    samples: List(Sample),
    /// The spend of all trials.
    spend: Spend,
    /// How many trials the model left unrouted.
    unrouted: Int,
  )
}

/// No spend.
pub const no_spend: Spend = Spend(calls: 0, tokens: 0)

/// Two spends added.
///
/// ## Examples
///
/// ```gleam
/// assert project_judge.add(Spend(1, 10), Spend(2, 5)) == Spend(3, 15)
/// ```
pub fn add(first: Spend, second: Spend) -> Spend {
  Spend(calls: first.calls + second.calls, tokens: first.tokens + second.tokens)
}

/// Runs `trials` decisions for each labelled frame under the judge's limits.
/// `progress` is told each trial's spend as the trial ends, whether it
/// completed or failed, from the trial's own process. `Error` is a sentence
/// saying why the run is incomplete, and a run that is incomplete has no
/// samples to measure.
///
/// ## Examples
///
/// ```gleam
/// // project_judge.measure(judge.labelled_frames(found, labels), judge, 3, fn(_) { Nil })
/// ```
pub fn measure(
  work: List(#(Frame, Label)),
  judge: Judge,
  trials: Int,
  progress: fn(Spend) -> Nil,
) -> Result(Measured, String) {
  let count = int.max(1, trials)
  let jobs =
    list.flat_map(work, fn(entry) {
      list.repeat(Nil, count)
      |> list.index_map(fn(_, index) {
        // A managed task: the trial's session outlives the worker that opened
        // it, so the run holds the session's root as an owner and does not
        // call the trial over until the session has stopped, whether the trial
        // ended or was cancelled.
        weft.managed(fn(ledger) {
          attempt(judge, entry.0, index, progress, fn(owner, cancel) {
            case weft.adopt(ledger, owner:, cancel:) {
              weft.Adopted -> Ok(Nil)
              weft.Refused -> Error(Nil)
            }
          })
        })
      })
    })

  // The first failure cancels the rest: a verdict needs every trial, so a
  // failed one makes the calls still to come a cost with nothing to buy.
  let outcomes =
    weft.new_prepared(jobs)
    |> weft.limit(judge.limits.concurrency)
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.deadline(judge.limits.wall_ms)
    |> weft.start

  settle(work, count, judge.limits, outcomes)
}

/// One job: a decision, and a report of what it spent whichever way it ended.
fn attempt(
  judge: Judge,
  frame: Frame,
  index: Int,
  progress: fn(Spend) -> Nil,
  custody: Custody,
) -> Result(Decision, Failure) {
  let decided = judge.decide(frame, index, custody)

  // The report comes from the trial's own process, before its slot is given
  // up, so a run that fails still shows the spend of the trials that ended.
  case decided {
    Ok(decision) -> progress(decision.spend)
    Error(failure) -> progress(failure.spend)
  }

  decided
}

/// Reads the run's account. The outcomes come in job order, which is trigger
/// order and then trial order, so a complete run is cut into one group of
/// `count` per trigger.
fn settle(
  work: List(#(Frame, Label)),
  count: Int,
  limits: Limits,
  outcomes: List(weft.Outcome(Decision, Failure)),
) -> Result(Measured, String) {
  let total = list.length(work) * count
  let decided =
    list.filter_map(outcomes, fn(outcome) {
      case outcome {
        weft.Completed(value:, ..) -> Ok(value)
        weft.Failed(..)
        | weft.Crashed(..)
        | weft.Abandoned(..)
        | weft.NeverStarted(..)
        | weft.DrainProofLost(..)
        | weft.CancellationUnconfirmed(..) -> Error(Nil)
      }
    })
  let finished = list.length(decided)

  // A trial's own failure is the reason when there is one. Without a failure,
  // a run short of its trials was cut off by its wall limit, and one that has
  // all of them is complete.
  case first_failure(outcomes), finished == total {
    Ok(words), _ ->
      Error(
        words
        <> " The run stopped with "
        <> progress_words(finished, total)
        <> " and records no verdict.",
      )
    Error(Nil), False ->
      Error(
        "The wall limit of "
        <> int.to_string(limits.wall_ms / 1000)
        <> " seconds ran out with "
        <> progress_words(finished, total)
        <> ". The run records no verdict.",
      )
    Error(Nil), True -> Ok(assemble(work, count, decided))
  }
}

/// The sentence of the first trial that failed, in job order, else of the first
/// that crashed or could not be confirmed stopped. A trial's own words come
/// first because they say what went wrong, and a session that did not stop
/// cleanly is usually a result of the failure that cancelled it.
fn first_failure(
  outcomes: List(weft.Outcome(Decision, Failure)),
) -> Result(String, Nil) {
  let own =
    list.find_map(outcomes, fn(outcome) {
      case outcome {
        weft.Failed(error:, ..) -> Ok(error.words)
        _ -> Error(Nil)
      }
    })
  use <- result.lazy_or(own)

  list.find_map(outcomes, fn(outcome) {
    case outcome {
      weft.Crashed(..) -> Ok("A trial stopped without an answer.")
      weft.DrainProofLost(..) | weft.CancellationUnconfirmed(..) ->
        Ok("A trial could not be confirmed stopped.")
      weft.Completed(..)
      | weft.Failed(..)
      | weft.Abandoned(..)
      | weft.NeverStarted(..) -> Error(Nil)
    }
  })
}

fn progress_words(finished: Int, total: Int) -> String {
  int.to_string(finished) <> " of " <> int.to_string(total) <> " trials done"
}

/// The samples of a complete run, with its spend and unrouted count.
fn assemble(
  work: List(#(Frame, Label)),
  count: Int,
  decided: List(Decision),
) -> Measured {
  let samples =
    list.zip(work, list.sized_chunk(decided, count))
    |> list.map(fn(entry) {
      let #(#(frame, label), trials) = entry
      Sample(
        trigger: frame.trigger.id,
        label:,
        recorded: judge.recorded_choice(frame),
        candidate: list.map(trials, fn(decision) { decision.choice }),
      )
    })
  Measured(
    samples:,
    spend: list.fold(decided, no_spend, fn(total, decision) {
      add(total, decision.spend)
    }),
    unrouted: list.count(decided, fn(decision) { decision.routing == Unrouted }),
  )
}
