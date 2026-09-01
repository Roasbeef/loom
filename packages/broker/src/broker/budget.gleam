//// Pooled per-execution budgets (design §6.5).
////
//// Broker-side limits are pooled per execution, not per call: one token
//// backs many in-flight effects, so the budget is aggregate — a cap on
//// outstanding effects and one wall-clock deadline for everything under
//// the token. This closes the amplification hole: 10,000 polite parallel
//// reads or 50 spawned test runs share one ledger and are refused past
//// the cap, however politely they ask.
////
//// Pure accounting; the broker owns one ledger per live execution
//// (keyed `{op_id, step_id}`, the identity a token is valid for) and
//// calls `reserve` before dispatching any effect and `settle` when one
//// completes, is aborted, or is reclaimed after a relay crash.
////
//// **This keying is a decision, not an accident**: `docs/adr/005-budget-
//// pooling-granularity.md` records why it stays `{op_id, step_id}` — one
//// ledger per *batch*, never one per call — against the concrete case
//// that put it in question (`grep`'s `max_outstanding: 1` contradicting
//// its own `Concurrent` declaration, issue #50). Read it before adding
//// anything that threads a new identity through this key or stacks a
//// further cap on top of it (issue #23). The threading that already
//// exists, `codemode/identity`, keeps this keying: it derives its build
//// and run phases from one opaque `ExecIdentity` rather than letting a
//// caller assemble either, so an execution resolves to one ledger — or
//// two where its hermetic build is deliberately accounted apart — and
//// never to one per call (issue #22). Two `code_mode` programs in one
//// batch are one batch and share this key on purpose; the per-execution
//// coordinate that tells them apart names their paths and must never
//// become a second axis of it (ADR-005, "Two programs in one batch").

/// The budget attached to one execution's token.
pub type Budget {
  Budget(
    /// Maximum effects in flight at once under this token. Invariant:
    /// positive.
    max_outstanding: Int,
    /// Unix-ms instant after which no further effect may start.
    deadline_ms: Int,
  )
}

/// The running account for one execution.
pub opaque type Ledger {
  /// Invariant: `0 <= outstanding <= budget.max_outstanding`.
  Ledger(budget: Budget, outstanding: Int)
}

/// Why a reservation was refused.
pub type Refusal {
  /// The outstanding-effect cap is already fully used.
  OutstandingCapReached(cap: Int)

  /// The aggregate wall deadline has passed.
  DeadlinePassed(deadline_ms: Int)
}

/// Opens a fresh ledger for a budget.
///
/// ## Examples
///
/// ```gleam
/// let ledger = budget.open(budget.Budget(max_outstanding: 8, deadline_ms: 99))
/// assert budget.outstanding(ledger) == 0
/// ```
///
pub fn open(budget: Budget) -> Ledger {
  Ledger(budget:, outstanding: 0)
}

/// Reserves one effect slot at time `now`. Refused past the deadline or
/// at the cap; otherwise the returned ledger carries the reservation.
///
/// ## Examples
///
/// ```gleam
/// let ledger = budget.open(budget.Budget(max_outstanding: 1, deadline_ms: 10))
/// let assert Ok(ledger) = budget.reserve(ledger, now: 5)
/// assert budget.reserve(ledger, now: 5)
///   == Error(budget.OutstandingCapReached(cap: 1))
/// ```
///
pub fn reserve(ledger: Ledger, now now: Int) -> Result(Ledger, Refusal) {
  case now > ledger.budget.deadline_ms {
    True -> Error(DeadlinePassed(deadline_ms: ledger.budget.deadline_ms))
    False ->
      case ledger.outstanding >= ledger.budget.max_outstanding {
        True -> Error(OutstandingCapReached(cap: ledger.budget.max_outstanding))
        False -> Ok(Ledger(..ledger, outstanding: ledger.outstanding + 1))
      }
  }
}

/// Returns one reserved slot. Settling with nothing outstanding is a
/// no-op rather than an error: settlement can race a crash-driven
/// cleanup, and double-settling must never underflow into free budget.
///
/// ## Examples
///
/// ```gleam
/// let ledger = budget.open(budget.Budget(max_outstanding: 1, deadline_ms: 10))
/// assert budget.settle(ledger) == ledger
/// ```
///
pub fn settle(ledger: Ledger) -> Ledger {
  case ledger.outstanding {
    0 -> ledger
    outstanding -> Ledger(..ledger, outstanding: outstanding - 1)
  }
}

/// How many effects are currently in flight under this ledger.
pub fn outstanding(ledger: Ledger) -> Int {
  ledger.outstanding
}

/// The budget this ledger enforces.
pub fn budget(ledger: Ledger) -> Budget {
  ledger.budget
}
