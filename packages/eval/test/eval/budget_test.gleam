import eval/budget
import gleam/option.{None, Some}
import provider/pricing

pub fn worst_case_prices_three_input_buckets_and_the_output_test() {
  let card = pricing.Pricing(1.0, 2.0, 1.0, 1.0)

  // Context 1,000,000 is billed once as input, once as cache read and once as
  // cache write at $1 each, and 500,000 output at $2 per million is $1.
  assert budget.worst_case_dollars(2, card, context: 1_000_000, output: 500_000)
    == 8.0
}

pub fn request_allowance_is_requests_times_three_context_plus_output_test() {
  assert budget.request_allowance_tokens(40, context: 100_000, output: 4096)
    == 12_163_840
}

pub fn an_in_flight_worst_case_counts_against_the_next_admission_test() {
  let assert Ok(account) = budget.start(budget.Dollars(1.5))

  assert budget.admit(account, 1.0) == budget.Admitted
  assert budget.admit(account, 1.0) == budget.Exhausted(after_trials: 1)
}

pub fn measured_spend_not_the_worst_case_decides_the_next_admission_test() {
  let assert Ok(account) = budget.start(budget.Dollars(2.5))

  let assert budget.Admitted = budget.admit(account, 1.0)
  budget.settle(account, 1.0, measured: 0.25)

  // 2.5 less 0.25 measured leaves room for a worst case of 1.0, twice.
  assert budget.admit(account, 1.0) == budget.Admitted
  assert budget.admit(account, 1.0) == budget.Admitted
  assert budget.status(account).admitted == 3
  assert budget.status(account).spent == 0.25
}

pub fn the_first_refusal_is_permanent_test() {
  let assert Ok(account) = budget.start(budget.Dollars(1.0))

  let assert budget.Admitted = budget.admit(account, 1.0)
  budget.settle(account, 1.0, measured: 0.9)

  // A tiny trial would fit in the 0.1 left, but the account already refused
  // nothing; ask for something too big, then something small.
  assert budget.admit(account, 0.5) == budget.Exhausted(after_trials: 1)
  assert budget.admit(account, 0.01) == budget.Exhausted(after_trials: 1)
}

pub fn an_unmetered_account_never_refuses_test() {
  let assert Ok(account) = budget.start(budget.Unmetered)

  assert budget.admit(account, 1_000_000.0) == budget.Admitted
  assert budget.admit(account, 1_000_000.0) == budget.Admitted
  assert budget.describe(budget.status(account)) == None
}

pub fn the_stop_is_described_in_the_reports_words_test() {
  let stopped = budget.Status(spent: 2.0, admitted: 3, exhausted_after: Some(3))

  assert budget.describe(stopped) == Some("budget exhausted after 3 trials")
}
