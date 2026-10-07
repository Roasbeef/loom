//// One output ordinal joins actual consumption, managed drain and original handle.
//// The helper handle may arrive after both consumer witnesses. Holding the closed
//// state preserves that ordinal until the same original execution can receive it.
//// `new`, `original`, `consumed` and `drop` each return one immutable next state;
//// only the transition to Returned produces Release, so duplicates cannot renew it.

import broker/executor
import gleam/option.{type Option, None, Some}

/// A closed output credit owned by the original Service row.
pub opaque type Join {
  /// Neither a later output nor a replacement execution can replace these facts.
  Waiting(ordinal: Int, execution: Option(executor.ProtocolExecution))

  /// Actual consumer success and AllDelivered are retained while startup finishes.
  Consumed(ordinal: Int)

  /// Release or failure permanently spent this ordinal.
  Returned
}

/// The one physical credit action produced by a state transition.
pub type Action {
  /// The exact ordinal remains held, or was already spent.
  Hold

  /// The exact original execution receives this ordinal once.
  Release(execution: executor.ProtocolExecution, ordinal: Int)

  /// Failure spent the ordinal without returning helper credit.
  Dropped
}

/// Reserves one already checked original output ordinal.
///
/// ## Examples
/// `let credit = new(1)`.
@internal
pub fn new(ordinal: Int) -> Join {
  Waiting(ordinal, None)
}

/// Installs the original execution; an existing handle is never replaced.
///
/// ## Examples
/// `let #(credit, action) = original(credit, execution)`.
@internal
pub fn original(
  credit: Join,
  execution: executor.ProtocolExecution,
) -> #(Join, Action) {
  case credit {
    Waiting(ordinal, None) -> #(Waiting(ordinal, Some(execution)), Hold)
    Waiting(_, Some(_)) | Returned -> #(credit, Hold)
    Consumed(ordinal) -> #(Returned, Release(execution, ordinal))
  }
}

/// Records actual successful consumption after its managed task's AllDelivered.
///
/// ## Examples
/// `let #(credit, action) = consumed(credit)`.
@internal
pub fn consumed(credit: Join) -> #(Join, Action) {
  case credit {
    Waiting(ordinal, Some(execution)) -> #(
      Returned,
      Release(execution, ordinal),
    )
    Waiting(ordinal, None) -> #(Consumed(ordinal), Hold)
    Consumed(_) | Returned -> #(credit, Hold)
  }
}

/// Fencing spends the credit without acknowledging any successful prefix.
///
/// ## Examples
/// `let #(credit, action) = drop(credit)`.
@internal
pub fn drop(credit: Join) -> #(Join, Action) {
  case credit {
    Waiting(..) | Consumed(_) -> #(Returned, Dropped)
    Returned -> #(Returned, Hold)
  }
}
