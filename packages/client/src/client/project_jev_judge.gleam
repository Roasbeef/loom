//// Jev as the candidate of a live verdict: the decider the report measures
//// when `projects.verdict` is asked for `router = "jev"`.
////
//// A live verdict runs a decision function over every labelled trigger three
//// times (`project/judge.live_trials`). For the model router the function
//// opens a scratch session. For Jev it is one request per trial, built from
//// the engine's state as it stood when the run began, so the tickets listed
//// are the run-time list and the report says so. The three trials of a
//// trigger are three rotations of the ticket order, because Jev's documentation
//// says it leans toward the first option of a Choice and identical repeats
//// differ by about one percent, so repeats would test nothing.
////
//// ## The composed decider
////
//// What the project would actually run is Jev's decision where it settles a
//// trigger and the model router's everywhere else. A trial therefore asks Jev
//// first. When Jev settles it, the trial is Jev's decision. When Jev abstains
//// or the service fails, the trial is handed to the router's own decider and
//// carries on from there, with what Jev spent added to what the router spends.
//// `project/judge.judge` gates that composed decision. What each trial kept
//// of Jev's part goes to `project/jev_verdict`, which reports it without
//// gating anything.
////
//// ## Flow
////
//// `judge` → `decide` → `settle`
////
//// 1. `judge` closes over the state and the setting, and returns the
////    `Judge` the fan-out runs.
//// 2. `decide` builds the request for one trigger and trial and sends it.
//// 3. `settle` turns the answer into a choice, or hands the trial to the
////    router.
////
//// The live service is never called from a test: `client/jev.client_with`
//// takes a fake fetch.

import client/jev as transport
import client/project_judge.{
  type Custody, type Decision, type Failure, type Judge, type Spend, Decision,
  Failure, Judge, Spend,
}
import gleam/option.{None, Some}
import jevelin
import project/gate
import project/jev
import project/jev_verdict.{type Trial, Trial}
import project/model.{type Strength}
import project/state.{type State}
import project/tape.{type Frame}

/// What the daemon knows about Jev for a run.
pub type Setting {
  Setting(
    /// The transport, with its key.
    client: transport.Client,
    /// The model or alias each request names.
    model: String,
    /// The attach bar in force, as a percent from 51 to 100.
    percent: Int,
    /// The `use_for` text of each catalogue agent, in catalogue order.
    agents: List(String),
  )
}

/// Whether a finished run's verdict is written to the ledger. A verdict is
/// pinned to the decider that was measured, and the pin in force is the Jev
/// form only when the daemon routes with Jev. A daemon that routes with the
/// model would otherwise record a Jev run under the model's pin and unlock
/// `auto` for a router the run did not measure.
pub type Recording {
  /// The verdict is recorded under the Jev pin.
  Records

  /// The run measures and reports and records nothing.
  MeasuresOnly
}

/// A setting with the router's own decider, which takes every trial Jev leaves.
pub type Setup {
  Setup(setting: Setting, router: Judge, recording: Recording)
}

/// The decider a run measures: Jev first, the router for what Jev leaves. The
/// limits are the router's, since its sessions are the slow part.
///
/// ## Examples
///
/// ```gleam
/// // project_jev_judge.judge(setup, engine).limits == setup.router.limits
/// ```
pub fn judge(setup: Setup, current: State) -> Judge {
  // The setting bounds the percent to what `jev.bars` accepts, so the default
  // answers a case the file cannot produce.
  let bars = case jev.bars(setup.setting.percent) {
    Ok(found) -> found
    Error(Nil) -> jev.default_bars()
  }

  Judge(
    decide: fn(frame, index, custody) {
      decide(setup, current, bars, frame, index, custody)
    },
    limits: setup.router.limits,
  )
}

/// One trial: a request for the trigger under this rotation, and what its
/// answer comes to.
fn decide(
  setup: Setup,
  current: State,
  bars: jev.Bars,
  frame: Frame,
  index: Int,
  custody: Custody,
) -> Result(Decision, Failure) {
  let shape =
    jev.shape(current, strength_of(current, frame), setup.setting.agents)
    |> jev.rotate(index)
  let message =
    jev.Message(text: frame.text, source: jev.source_of(frame.trigger.inputs))
  let asked = fn(trial) {
    hand_over(setup, frame, index, custody, trial, project_judge.no_spend)
  }

  // A request that cannot be built is a defect of ours, and the trial goes to
  // the router like any other the service did not answer.
  case jev.request(shape, message, setup.setting.model) {
    Error(_) -> asked(Trial(jev_verdict.Failed(jev.Invalid), shape, None, None))
    Ok(request) ->
      case transport.evaluate(setup.setting.client, request) {
        Error(why) -> asked(Trial(jev_verdict.Failed(why), shape, None, None))
        Ok(evaluation) ->
          settle(setup, bars, frame, index, custody, shape, evaluation)
      }
  }
}

/// What a service answer comes to for one trial: Jev's choice when it settles
/// the trigger, and the router's when it does not.
fn settle(
  setup: Setup,
  bars: jev.Bars,
  frame: Frame,
  index: Int,
  custody: Custody,
  shape: jev.Shape,
  evaluation: jevelin.Evaluation(jev.Answers),
) -> Result(Decision, Failure) {
  let spent =
    Spend(
      calls: 1,
      tokens: evaluation.usage.input_tokens + evaluation.usage.output_tokens,
    )

  // A model name the ledger would refuse is as unusable as a malformed body.
  case jev.accept(evaluation) {
    Error(why) ->
      hand_over(
        setup,
        frame,
        index,
        custody,
        Trial(jev_verdict.Failed(why), shape, None, None),
        spent,
      )
    Ok(accepted) -> {
      let decision = jev.decide(shape, bars, accepted.answers)
      let trial =
        Trial(
          jev_verdict.outcome_of(decision),
          shape,
          Some(accepted.answers),
          Some(accepted.model),
        )
      chosen(setup, frame, index, custody, trial, spent, decision)
    }
  }
}

/// Jev's choice when its decision settles the trigger, and the router's when it
/// does not.
fn chosen(
  setup: Setup,
  frame: Frame,
  index: Int,
  custody: Custody,
  trial: Trial,
  spent: Spend,
  decision: jev.Decision,
) -> Result(Decision, Failure) {
  // A fallback has no choice of its own, so the router's trial stands in.
  case jev_verdict.choice_of(decision) {
    Some(choice) ->
      Ok(Decision(
        choice:,
        routing: project_judge.Routed,
        spend: spent,
        trial: Some(trial),
      ))
    None -> hand_over(setup, frame, index, custody, trial, spent)
  }
}

/// The router's trial for a trigger Jev did not settle, with what Jev spent
/// added to what the router spends and what Jev kept riding along.
fn hand_over(
  setup: Setup,
  frame: Frame,
  index: Int,
  custody: Custody,
  trial: Trial,
  spent: Spend,
) -> Result(Decision, Failure) {
  case setup.router.decide(frame, index, custody) {
    Ok(routed) ->
      Ok(
        Decision(
          ..routed,
          spend: project_judge.add(spent, routed.spend),
          trial: Some(trial),
        ),
      )
    Error(failure) ->
      Error(Failure(..failure, spend: project_judge.add(spent, failure.spend)))
  }
}

/// The strength the gate admitted the trigger at when it arrived, and inferred
/// for a trigger the engine does not hold, which a rule's tape never has.
fn strength_of(current: State, frame: Frame) -> Strength {
  case state.record(current, frame.trigger.id) {
    Ok(stored) -> admitted(stored.admission)
    Error(_) -> model.Inferred
  }
}

/// The strength of an admission, inferred for one the gate did not admit.
fn admitted(admission: gate.Admission) -> Strength {
  // A trigger the gate withheld has no strength, and inferred is the weaker.
  case admission {
    gate.Admitted(strength, _, _) -> strength
    gate.NotAdmitted(_) -> model.Inferred
  }
}
