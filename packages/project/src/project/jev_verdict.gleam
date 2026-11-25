//// What a live verdict over Jev reads out of its trials: who decided each
//// one, how much of the traffic Jev settles, and how its decisions agree with
//// the labels and with the router's own record, at the bar in force and across
//// a sweep of other bars.
////
//// The instrument is the one `project/judge` already is. A person labels
//// recorded triggers, and a candidate decider is run over them three times
//// each. This module does not replace that measurement. It adds what only a
//// decider that can abstain needs reported (docs/design-notes/project-jev-routing.md,
//// section 9), and it performs no I/O: the daemon runs the trials, keeps a
//// `Trial` for each, and hands them here.
////
//// ## Why abstaining is not failing
////
//// Falling back to the model router is intended behaviour. A trial therefore
//// ends one of three ways: Jev decided, Jev abstained (`LowClarity` or
//// `LowProbability`), or the service failed (`Unavailable`, `Invalid` or no
//// key). `health` counts them, and only the service failures count against
//// the service-health bar. The composed decider, Jev's decision where it
//// settled a trigger and the router's elsewhere, is what `judge.judge` gates,
//// so this module reports and never gates.
////
//// ## Flow
////
//// `health` → `sweep` → `silver`
////
//// 1. `health` counts how the trials ended.
//// 2. `sweep` redecides every trial that has answers at each of a list of
////    attach bars and reports coverage and agreement with the labels. The
////    answers were recorded once, so the sweep costs no request.
//// 3. `silver` compares Jev's decision for each trigger with what the router
////    recorded, which needs no new label type, and lists the disagreements.
////
//// ## What the sweep does not cover
////
//// Only the attach bar is swept. The other bars are fixed in `project/jev`
//// and belong to its request-shape version, so changing one is a change of
//// that version and a new run, not a column of this table.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import project/jev.{type Answers, type Decision, type Shape, type Why}
import project/judge.{type Choice, Pass, Take}
import project/model.{type Label, type TicketId, type TriggerId}

/// How one trial ended.
pub type Outcome {
  /// Jev settled the trigger. The decision is never a fallback.
  Decided(Decision)

  /// Jev answered and the answers fall between the bars, or the message is not
  /// clear alone: `LowClarity` or `LowProbability`. The router decides.
  Abstained(Why)

  /// The service gave no usable answer: `Unavailable`, `Invalid` or `NoKey`.
  /// The router decides.
  Failed(Why)
}

/// What one trial of a labelled trigger kept.
pub type Trial {
  Trial(
    /// How the trial ended at the bar the run was made under.
    outcome: Outcome,
    /// The shape the request was built from, rotated for this trial, so the
    /// answers can be decided again under another bar.
    shape: Shape,
    /// The answers, when the service gave any.
    answers: Option(Answers),
    /// The model name the service reported, when it answered.
    model: Option(String),
  )
}

/// What the router recorded for a trigger, as far as a comparison can use it.
pub type Target {
  /// A ticket was opened for it.
  Opened

  /// It was attached to this ticket.
  AttachedTo(TicketId)

  /// It resumed this ticket.
  ResumedOn(TicketId)

  /// It was ignored.
  Ignored

  /// Anything else: the trigger was not decided by a router choice this
  /// comparison can name.
  Elsewhere
}

/// One labelled trigger with its trials and what the router recorded for it.
pub type Entry {
  Entry(
    /// The trigger.
    trigger: TriggerId,
    /// The person's judgement.
    label: Label,
    /// What the router did with it.
    recorded: Target,
    /// One trial per rotation.
    trials: List(Trial),
  )
}

/// How the trials ended, with the total they are a share of.
pub type Health {
  Health(
    /// Trials Jev settled.
    decided: Int,
    /// Trials Jev answered without settling.
    abstained: Int,
    /// Trials the service gave no usable answer for.
    failed: Int,
  )
}

/// Agreement and coverage at one attach bar.
pub type Row {
  Row(
    /// The bar, as a percent.
    percent: Int,
    /// Trials Jev settles at this bar, of every trial.
    decided: Int,
    /// Every trial in the run.
    trials: Int,
    /// Settled trials whose choice matches the label.
    agreeing: Int,
  )
}

/// A trigger on which Jev and the router recorded different decisions.
pub type Disagreement {
  Disagreement(
    /// The trigger.
    trigger: TriggerId,
    /// What Jev decided, in a word and the ticket it named.
    jev: String,
    /// What the router recorded, in the same words.
    router: String,
  )
}

/// Jev compared with the router's record.
pub type Silver {
  Silver(
    /// Triggers both decided.
    compared: Int,
    /// Of those, the ones on which they chose the same.
    agreeing: Int,
    /// The ones on which they did not, at most `max_listed`.
    disagreements: List(Disagreement),
  )
}

/// The most disagreements a report lists.
pub const max_listed = 20

/// The attach bars the sweep tries, as percents. The default bar is 80.
pub const sweep_percents = [55, 60, 65, 70, 75, 80, 85, 90, 95, 100]

/// The service-health bar: `Unavailable` plus `Invalid` must be under this
/// share of trials, in basis points, for Jev to be switched on by default.
pub const failure_bar_points = 500

/// Whether a choice matches a label.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.agrees(judge.Take, model.ShouldAccept)
/// ```
pub fn agrees(choice: Choice, label: Label) -> Bool {
  case choice, label {
    Take, model.ShouldAccept | Pass, model.ShouldNotAccept -> True
    Take, model.ShouldNotAccept | Pass, model.ShouldAccept -> False
  }
}

/// The choice a settled decision amounts to: work is taken on, a decline is
/// not. A fallback settles nothing and has no choice.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.choice_of(jev.New(None)) == Some(judge.Take)
/// ```
pub fn choice_of(decision: Decision) -> Option(Choice) {
  case decision {
    jev.Attach(_) | jev.Resume(_) | jev.New(_) -> Some(Take)
    jev.Decline(_) -> Some(Pass)
    jev.Fallback(_) -> None
  }
}

/// The outcome a decision and the answers it came from make.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.outcome_of(jev.Fallback(jev.LowClarity)) == Abstained(jev.LowClarity)
/// ```
pub fn outcome_of(decision: Decision) -> Outcome {
  case decision {
    jev.Fallback(why) -> Abstained(why)
    settled -> Decided(settled)
  }
}

/// How every trial of every entry ended.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.health([]) == Health(0, 0, 0)
/// ```
pub fn health(entries: List(Entry)) -> Health {
  let trials = list.flat_map(entries, fn(entry) { entry.trials })
  Health(
    decided: list.count(trials, fn(trial) { is_decided(trial.outcome) }),
    abstained: list.count(trials, fn(trial) {
      case trial.outcome {
        Abstained(_) -> True
        Decided(_) | Failed(_) -> False
      }
    }),
    failed: list.count(trials, fn(trial) {
      case trial.outcome {
        Failed(_) -> True
        Decided(_) | Abstained(_) -> False
      }
    }),
  )
}

fn is_decided(outcome: Outcome) -> Bool {
  case outcome {
    Decided(_) -> True
    Abstained(_) | Failed(_) -> False
  }
}

/// A share of `whole` in basis points, rounded down, and 0 of nothing.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.points(1, 4) == 2500
/// assert jev_verdict.points(1, 0) == 0
/// ```
pub fn points(part: Int, whole: Int) -> Int {
  case whole > 0 {
    True -> part * 10_000 / whole
    False -> 0
  }
}

/// Whether the service-health bar holds: failures are under 5 percent of
/// trials.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.service_healthy(jev_verdict.Health(95, 0, 4))
/// ```
pub fn service_healthy(counted: Health) -> Bool {
  let total = counted.decided + counted.abstained + counted.failed
  points(counted.failed, total) < failure_bar_points
}

/// Coverage and agreement at each attach bar. A trial with no answers, because
/// the service failed, settles nothing at any bar and stays in the total.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.sweep([], [80]) == [jev_verdict.Row(80, 0, 0, 0)]
/// ```
pub fn sweep(entries: List(Entry), percents: List(Int)) -> List(Row) {
  let total =
    list.fold(entries, 0, fn(sum, entry) { sum + list.length(entry.trials) })
  list.filter_map(percents, fn(percent) {
    use bars <- result.try(jev.bars(percent))
    let settled =
      list.flat_map(entries, fn(entry) {
        list.filter_map(entry.trials, fn(trial) { settled_at(trial, bars) })
        |> list.map(fn(choice) { agrees(choice, entry.label) })
      })
    Ok(Row(
      percent:,
      decided: list.length(settled),
      trials: total,
      agreeing: list.count(settled, fn(agreeing) { agreeing }),
    ))
  })
}

/// The choice a trial settles at a bar, or nothing when it does not settle.
fn settled_at(trial: Trial, bars: jev.Bars) -> Result(Choice, Nil) {
  case trial.answers {
    None -> Error(Nil)
    Some(answers) ->
      case choice_of(jev.decide(trial.shape, bars, answers)) {
        Some(choice) -> Ok(choice)
        None -> Error(Nil)
      }
  }
}

/// Jev's decision against the router's record, trigger by trigger. Jev's
/// decision for a trigger is the one most of its settled trials made, the
/// earliest on a tie. A trigger Jev never settled, or that the router did not
/// decide by a choice, is not compared.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.silver([]) == Silver(0, 0, [])
/// ```
pub fn silver(entries: List(Entry)) -> Silver {
  let compared =
    list.filter_map(entries, fn(entry) {
      case entry.recorded, majority(entry.trials) {
        Elsewhere, _ -> Error(Nil)
        _, None -> Error(Nil)
        recorded, Some(decision) -> Ok(#(entry.trigger, decision, recorded))
      }
    })
  let split = list.partition(compared, fn(found) { same(found.1, found.2) })
  Silver(
    compared: list.length(compared),
    agreeing: list.length(split.0),
    disagreements: list.take(
      list.map(split.1, fn(found) {
        Disagreement(
          trigger: found.0,
          jev: decision_words(found.1),
          router: target_words(found.2),
        )
      }),
      max_listed,
    ),
  )
}

/// The decision most settled trials made, by its words.
fn majority(trials: List(Trial)) -> Option(Decision) {
  let settled =
    list.filter_map(trials, fn(trial) {
      case trial.outcome {
        Decided(decision) -> Ok(decision)
        Abstained(_) | Failed(_) -> Error(Nil)
      }
    })
  let counts =
    list.fold(settled, dict.new(), fn(seen, decision) {
      dict.upsert(seen, decision_words(decision), fn(found) {
        option.unwrap(found, 0) + 1
      })
    })
  let best = list.fold(dict.values(counts), 0, int.max)

  // The earliest decision whose words reached the best count.
  list.find(settled, fn(decision) {
    dict.get(counts, decision_words(decision)) == Ok(best)
  })
  |> option.from_result
}

/// Whether a decision and a recorded target are the same choice: the same kind,
/// and the same ticket where a ticket is named. Opening a ticket matches
/// opening one whichever agent Jev chose, since the router chooses none.
fn same(decision: Decision, recorded: Target) -> Bool {
  case decision, recorded {
    jev.New(_), Opened -> True
    jev.Attach(ticket), AttachedTo(other) -> ticket == other
    jev.Resume(ticket), ResumedOn(other) -> ticket == other
    jev.Decline(_), Ignored -> True
    _, _ -> False
  }
}

/// A decision in words and the ticket it names, for the report.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.decision_words(jev.New(None)) == "open"
/// ```
pub fn decision_words(decision: Decision) -> String {
  case decision {
    jev.New(_) -> "open"
    jev.Attach(ticket) -> "attach " <> ticket.value
    jev.Resume(ticket) -> "resume " <> ticket.value
    jev.Decline(_) -> "ignore"
    jev.Fallback(_) -> "fallback"
  }
}

/// A recorded target in the words `decision_words` uses.
///
/// ## Examples
///
/// ```gleam
/// assert jev_verdict.target_words(jev_verdict.Opened) == "open"
/// ```
pub fn target_words(target: Target) -> String {
  case target {
    Opened -> "open"
    AttachedTo(ticket) -> "attach " <> ticket.value
    ResumedOn(ticket) -> "resume " <> ticket.value
    Ignored -> "ignore"
    Elsewhere -> "elsewhere"
  }
}
