//// The row every estimator in `evalstat` consumes, and the one ruling about
//// it that the rest of the package rests on: what counts as a failure.
////
//// A `Trial` is one attempt at one task by one arm. The instrument writes
//// them; this package only reads them, so the type is plain data with no
//// behaviour beyond classification. The classification is the point. An
//// evaluation that requeues timed-out trials, or that leaves a refused task
//// out of the denominator, quietly removes the hardest tasks from the
//// measurement and reports a pass rate for the tasks the agent found easy.
//// `standing` is therefore the single place the question "is this row a
//// pass, a failure, or not evidence at all" is answered, and every
//// estimator asks it rather than inspecting `Outcome` itself.
////
//// Only `Infrastructure` is excluded, because it is the one outcome that
//// says nothing about the arm: the harness, the jail or the provider broke
//// before the arm could succeed or fail. Those rows are counted separately
//// so a report can say how much of the plan never produced evidence.

/// How a trial ended. The order is the order a reader should think about
/// them in: a pass, then the three ways the arm itself failed, then the one
/// way the measurement failed.
pub type Outcome {
  /// The hidden verifier accepted the arm's work.
  Passed

  /// The arm finished and the verifier rejected the result.
  VerifierFailed

  /// The arm ran out of wall-clock or turn budget. A failure of the arm:
  /// an agent that cannot finish inside the budget has not solved the task.
  AgentTimeout

  /// The arm declined the task. A failure of the arm on this task, whatever
  /// the merit of the refusal, because the task was not done.
  SafetyRefusal

  /// The measurement itself broke: a crashed helper, a lost jail, a provider
  /// outage. Says nothing about the arm, so it is excluded from every rate
  /// and counted on its own.
  Infrastructure
}

/// What one trial spent. Every field is a plain total so the caller can
/// turn it into the higher-is-better scores `dominance` compares.
pub type Cost {
  Cost(
    /// Input plus output tokens billed for the trial.
    tokens: Int,
    /// Measured spend in dollars.
    dollars: Float,
    /// Model turns taken.
    turns: Int,
    /// Tool calls that returned an error to the model.
    tool_errors: Int,
    /// Wall-clock from admission to the verifier's answer.
    wall_ms: Int,
  )
}

/// One attempt at one task by one arm.
pub type Trial {
  Trial(
    /// The task id. Pairing between arms is by `(task, index)`.
    task: String,
    /// The arm id this row belongs to.
    arm: String,
    /// Which of the task's `K` trials this is, from zero. The plan fixes
    /// `K`, and the same index on two arms is one paired observation.
    index: Int,
    /// The verifier's reward in `[0, 1]`. Carried for reporting; the
    /// decision rule reads `outcome`, not `reward`.
    reward: Float,
    /// Secondary scores, all oriented higher-is-better by the caller.
    scores: List(#(String, Float)),
    /// How the trial ended.
    outcome: Outcome,
    /// What it cost.
    cost: Cost,
  )
}

/// A counted trial's binary result.
pub type Fate {
  /// The verifier accepted.
  Pass

  /// Anything the arm did that the verifier did not accept, timeouts and
  /// refusals included.
  Fail
}

/// Whether a row is evidence about its arm.
pub type Standing {
  /// The row enters `n` with this fate.
  Counted(Fate)

  /// The row is an `Infrastructure` outcome: left out of `n`, counted on
  /// its own.
  Excluded
}

/// Classifies an outcome. This is the one place the failure ruling lives:
/// `AgentTimeout` and `SafetyRefusal` are failures, `Infrastructure` alone
/// is excluded.
///
/// ## Examples
///
/// ```gleam
/// assert trial.standing(trial.AgentTimeout) == trial.Counted(trial.Fail)
/// ```
///
/// ```gleam
/// assert trial.standing(trial.Infrastructure) == trial.Excluded
/// ```
pub fn standing(outcome: Outcome) -> Standing {
  case outcome {
    Passed -> Counted(Pass)
    VerifierFailed -> Counted(Fail)
    AgentTimeout -> Counted(Fail)
    SafetyRefusal -> Counted(Fail)
    Infrastructure -> Excluded
  }
}

/// A fate as the indicator the estimators sum: one for a pass, zero for a
/// failure.
///
/// ## Examples
///
/// ```gleam
/// assert trial.indicator(trial.Pass) == 1.0
/// ```
pub fn indicator(fate: Fate) -> Float {
  case fate {
    Pass -> 1.0
    Fail -> 0.0
  }
}
