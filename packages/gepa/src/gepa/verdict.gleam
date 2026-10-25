//// The words a search decides in: what a comparison may conclude, what a
//// settled step did with its child, and the one rule that turns the first
//// into the second.
////
//// The vocabulary lives apart from the state machine so that a host which
//// only reads dispositions (a report, a front renderer) and the host's own
//// statistical judge can depend on this module and nothing else. The
//// `Acceptance` is deliberately four words rather than a full statistical
//// verdict: the search needs to know whether the candidate was shown
//// better, shown worse, not shown either, or not measured at all, and
//// nothing more. A host that decides with a richer rule (an effect size,
//// an interval, a power calculation) keeps those numbers in its own log
//// and hands the search the word they reduce to.
////
//// `dispose` is the search's one decision about a child, stated once:
//// only `Improved` joins the pool as a ranked member; `Inconclusive` joins
//// as a Pareto member that is never ranked above its parent; `Harmed` and
//// `Incomplete` stay out. `consistent` is the same rule read backwards, so
//// a replayed log cannot claim a disposition its acceptance does not earn.

import gleam/option.{type Option, None, Some}

/// What a comparison of a candidate against a baseline concluded.
pub type Acceptance {
  /// The candidate was shown better than the baseline.
  Improved

  /// The candidate was shown worse than the baseline.
  Harmed

  /// Neither: the data did not separate them, or could not have.
  Inconclusive

  /// The comparison could not be made: a measurement is missing.
  Incomplete
}

/// What a settled step did with its child.
pub type Disposition {
  /// Improved over its parent, and the pool's best by the same rule.
  Incumbent

  /// Improved over its parent; in the pool, ranked below the incumbent.
  Joined

  /// Neither improved nor harmed: a Pareto member, never ranked above its
  /// parent.
  ParetoOnly

  /// Harmed against its parent: discarded.
  Discarded

  /// The validate stage could not reach a conclusion: discarded, and the
  /// budget decides whether to go on.
  Unsettled

  /// The candidate could not be built, or the reflector's answer was
  /// refused.
  Refused

  /// Below its parent on the minibatch: never paid for.
  ScreenedOut

  /// The confirm stage found the best improved over the seed.
  Confirmed

  /// The confirm stage did not.
  Unconfirmed
}

/// Where a judgement's measurements came from, which decides what the
/// judgement may settle.
pub type Basis {
  /// The tune minibatch: a spend filter, never a claim.
  OnMinibatch

  /// The validate split: the only acceptance.
  OnValidate

  /// The confirm run, seed and best together.
  OnConfirm
}

/// The disposition a validate acceptance earns. `against_incumbent` is the
/// acceptance against the pool's best when the parent is not it, and the
/// two counts are the tasks the child and the incumbent lead on a front
/// that includes both.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.dispose(verdict.Harmed, None, 0, 0) == verdict.Discarded
/// assert verdict.dispose(verdict.Improved, None, 5, 3) == verdict.Incumbent
/// ```
///
pub fn dispose(
  against_parent: Acceptance,
  against_incumbent: Option(Acceptance),
  child_led: Int,
  incumbent_led: Int,
) -> Disposition {
  case against_parent {
    Improved ->
      // The incumbent changes only when the child is not shown worse than
      // it and leads more tasks; otherwise the child joins below it.
      case not_worse(against_incumbent) && child_led > incumbent_led {
        True -> Incumbent
        False -> Joined
      }
    Inconclusive -> ParetoOnly
    Harmed -> Discarded
    Incomplete -> Unsettled
  }
}

/// Whether the child stands against the incumbent: no comparison (the
/// parent is the incumbent) counts as standing, since the parent verdict
/// already decided; `Harmed` or `Incomplete` do not.
fn not_worse(against_incumbent: Option(Acceptance)) -> Bool {
  case against_incumbent {
    None | Some(Improved) | Some(Inconclusive) -> True
    Some(Harmed) | Some(Incomplete) -> False
  }
}

/// Whether a settling disposition is one `dispose` gives its acceptance, on
/// the basis the acceptance was reached on. A screen can only screen out;
/// a confirm can only confirm or not.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.consistent(verdict.Improved, verdict.OnValidate, verdict.Joined)
/// assert !verdict.consistent(verdict.Improved, verdict.OnValidate, verdict.ParetoOnly)
/// ```
///
pub fn consistent(
  found: Acceptance,
  basis: Basis,
  disposition: Disposition,
) -> Bool {
  case found, basis, disposition {
    Incomplete, OnMinibatch, ScreenedOut -> True
    Improved, OnValidate, Incumbent | Improved, OnValidate, Joined -> True
    Inconclusive, OnValidate, ParetoOnly -> True
    Harmed, OnValidate, Discarded -> True
    Incomplete, OnValidate, Unsettled -> True
    Improved, OnConfirm, Confirmed -> True
    Harmed, OnConfirm, Unconfirmed
    | Inconclusive, OnConfirm, Unconfirmed
    | Incomplete, OnConfirm, Unconfirmed
    -> True
    _, _, _ -> False
  }
}

/// The disposition a confirm acceptance earns: only `Improved` confirms.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.confirm(verdict.Inconclusive) == verdict.Unconfirmed
/// ```
///
pub fn confirm(found: Acceptance) -> Disposition {
  case found {
    Improved -> Confirmed
    Harmed | Inconclusive | Incomplete -> Unconfirmed
  }
}

/// The spelling of an acceptance, as the log and a report print it.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.acceptance_name(verdict.Inconclusive) == "inconclusive"
/// ```
///
pub fn acceptance_name(found: Acceptance) -> String {
  case found {
    Improved -> "improved"
    Harmed -> "harmed"
    Inconclusive -> "inconclusive"
    Incomplete -> "incomplete"
  }
}

/// Parses an acceptance's spelling.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.parse_acceptance("harmed") == Ok(verdict.Harmed)
/// ```
///
pub fn parse_acceptance(name: String) -> Result(Acceptance, String) {
  case name {
    "improved" -> Ok(Improved)
    "harmed" -> Ok(Harmed)
    "inconclusive" -> Ok(Inconclusive)
    "incomplete" -> Ok(Incomplete)
    other -> Error("unknown acceptance \"" <> other <> "\"")
  }
}

/// The spelling of a disposition, as the log and a front print it.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.disposition_name(verdict.ParetoOnly) == "pareto_only"
/// ```
///
pub fn disposition_name(disposition: Disposition) -> String {
  case disposition {
    Incumbent -> "incumbent"
    Joined -> "joined"
    ParetoOnly -> "pareto_only"
    Discarded -> "harmed"
    Unsettled -> "unsettled"
    Refused -> "refused"
    ScreenedOut -> "screened_out"
    Confirmed -> "confirmed"
    Unconfirmed -> "unconfirmed"
  }
}

/// Parses a disposition's spelling.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.parse_disposition("harmed") == Ok(verdict.Discarded)
/// ```
///
pub fn parse_disposition(name: String) -> Result(Disposition, String) {
  case name {
    "incumbent" -> Ok(Incumbent)
    "joined" -> Ok(Joined)
    "pareto_only" -> Ok(ParetoOnly)
    "harmed" -> Ok(Discarded)
    "unsettled" -> Ok(Unsettled)
    "refused" -> Ok(Refused)
    "screened_out" -> Ok(ScreenedOut)
    "confirmed" -> Ok(Confirmed)
    "unconfirmed" -> Ok(Unconfirmed)
    other -> Error("unknown disposition \"" <> other <> "\"")
  }
}

/// The spelling of a basis.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.basis_name(verdict.OnValidate) == "validate"
/// ```
///
pub fn basis_name(basis: Basis) -> String {
  case basis {
    OnMinibatch -> "minibatch"
    OnValidate -> "validate"
    OnConfirm -> "confirm"
  }
}

/// Parses a basis's spelling.
///
/// ## Examples
///
/// ```gleam
/// assert verdict.parse_basis("confirm") == Ok(verdict.OnConfirm)
/// ```
///
pub fn parse_basis(name: String) -> Result(Basis, String) {
  case name {
    "minibatch" -> Ok(OnMinibatch)
    "validate" -> Ok(OnValidate)
    "confirm" -> Ok(OnConfirm)
    other -> Error("unknown basis \"" <> other <> "\"")
  }
}
