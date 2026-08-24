import broker/budget
import gleam/int

fn small() -> budget.Budget {
  budget.Budget(max_outstanding: 2, deadline_ms: 1000)
}

pub fn open_starts_empty_test() {
  assert budget.outstanding(budget.open(small())) == 0
}

pub fn reserve_counts_up_test() {
  let assert Ok(ledger) = budget.reserve(budget.open(small()), now: 0)
  assert budget.outstanding(ledger) == 1
}

pub fn reserve_at_cap_refused_test() {
  let assert Ok(ledger) = budget.reserve(budget.open(small()), now: 0)
  let assert Ok(ledger) = budget.reserve(ledger, now: 0)
  assert budget.reserve(ledger, now: 0)
    == Error(budget.OutstandingCapReached(cap: 2))
}

pub fn reserve_past_deadline_refused_test() {
  assert budget.reserve(budget.open(small()), now: 1001)
    == Error(budget.DeadlinePassed(deadline_ms: 1000))
}

pub fn reserve_at_deadline_allowed_test() {
  let assert Ok(_) = budget.reserve(budget.open(small()), now: 1000)
}

pub fn settle_frees_a_slot_test() {
  let assert Ok(ledger) = budget.reserve(budget.open(small()), now: 0)
  let assert Ok(ledger) = budget.reserve(ledger, now: 0)
  let ledger = budget.settle(ledger)
  let assert Ok(ledger) = budget.reserve(ledger, now: 0)
  assert budget.outstanding(ledger) == 2
}

pub fn settle_never_underflows_test() {
  let ledger = budget.open(small())
  let ledger = budget.settle(ledger)
  let ledger = budget.settle(ledger)
  assert budget.outstanding(ledger) == 0
}

pub fn budget_accessor_test() {
  assert budget.budget(budget.open(small())) == small()
}

// The 10k-parallel amplification scenario (design §6.5): ten thousand
// polite reservation attempts against one pooled ledger; exactly the
// cap gets through, everything else is refused, and nothing crashes.
pub fn ten_thousand_requests_capped_test() {
  let cap = 64
  let ledger = budget.open(budget.Budget(max_outstanding: cap, deadline_ms: 10))
  let #(_ledger, granted, refused) =
    int.range(
      from: 0,
      to: 10_000,
      with: #(ledger, 0, 0),
      run: fn(acc, _attempt) {
        let #(ledger, granted, refused) = acc
        case budget.reserve(ledger, now: 5) {
          Ok(ledger) -> #(ledger, granted + 1, refused)
          Error(budget.OutstandingCapReached(cap: _)) -> #(
            ledger,
            granted,
            refused + 1,
          )
          Error(budget.DeadlinePassed(deadline_ms: _)) ->
            panic as "deadline refusal before the deadline"
        }
      },
    )
  assert granted == cap
  assert refused == 10_000 - cap
}

// Settling under churn: interleaved reserve/settle holds the invariant
// that outstanding never exceeds the cap.
pub fn churn_never_exceeds_cap_test() {
  let cap = 8
  let ledger = budget.open(budget.Budget(max_outstanding: cap, deadline_ms: 10))
  let final =
    int.range(from: 1, to: 1001, with: ledger, run: fn(ledger, attempt) {
      let ledger = case budget.reserve(ledger, now: 1) {
        Ok(reserved) -> reserved
        Error(_) -> ledger
      }
      assert budget.outstanding(ledger) <= cap
      case attempt % 3 {
        0 -> budget.settle(ledger)
        _ -> ledger
      }
    })
  assert budget.outstanding(final) <= cap
}
