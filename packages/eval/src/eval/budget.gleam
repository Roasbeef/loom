//// The run's dollar budget: what one trial could cost, what the run has
//// measurably spent, and the point at which no further trial may start.
////
//// Two budgets are easy to confuse here, and the design keeps them apart
//// (`docs/design-notes/eval-instrument.md` P3). The request guard of a single
//// trial reserves the worst case of every request, `3 * context + output`
//// tokens priced at the card, because a runaway session must be stopped
//// before it spends rather than after. That number is a safety net: with a
//// 200 thousand token window it is hundreds of thousands of tokens per
//// request, so a run-level cap measured against it would refuse the very
//// first request. The run's cap is therefore charged in two steps. A trial is
//// admitted only when the cap, less what earlier trials *measurably* spent
//// and less the worst case of the trials still in flight, still covers one
//// more worst case; when it settles, its reservation is returned and its
//// measured spend is charged instead.
////
//// The account is an actor so that concurrent trials, which finish in any
//// order, cannot interleave a reservation with a settlement. Once a trial has
//// been refused the account stays exhausted, so the stop is a fact of the run
//// rather than a race between a large refused trial and a small later one,
//// and the report can say "budget exhausted after N trials" and mean it. The
//// cells that never ran are then missing from the ledger, and the verdict
//// over them is `Incomplete`, which is the honest reading.
////
//// ## Flow
////
//// - `worst_case_dollars`, `request_allowance_tokens`: what a trial may cost
//// - `start`, `admit`, `settle`, `status`, `stop`: the account
//// - `describe`: the sentence the report carries

import core/message
import eval/plan.{type Budgets}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/pricing.{type Pricing}
import storage/storage
import weft/actor

/// How much a run may spend in total.
pub type Cap {
  /// A ceiling in dollars on measured spend.
  Dollars(limit: Float)

  /// No ceiling: the replay lane spends nothing, so there is nothing to cap.
  Unmetered
}

/// The answer to a request to start one more trial.
pub type Admission {
  /// The trial may start. Its worst case is reserved until it settles.
  Admitted

  /// The remaining budget cannot cover one more trial's worst case, so this
  /// trial and every later one is refused.
  Exhausted(
    /// How many trials had been admitted when the first refusal came.
    after_trials: Int,
  )
}

/// A snapshot of the account.
pub type Status {
  Status(
    /// Dollars measured across settled trials.
    spent: Float,
    /// Trials admitted so far, settled or not.
    admitted: Int,
    /// The number of admitted trials at the first refusal, or `None` while
    /// the account has never refused.
    exhausted_after: Option(Int),
  )
}

/// The handle on a running account.
pub opaque type Account {
  Account(subject: Subject(Message))
}

type Message {
  Admit(worst_case: Float, reply: Subject(Admission))
  Settle(worst_case: Float, measured: Float, reply: Subject(Nil))
  Report(reply: Subject(Status))
  Stop
}

type State {
  State(
    cap: Cap,
    spent: Float,
    reserved: Float,
    admitted: Int,
    exhausted_after: Option(Int),
  )
}

/// How long a caller waits on the account. It answers from memory, so a miss
/// means the actor is gone and the caller should fail rather than guess.
const wait_ms = 5000

/// The dollars one trial could spend if every request it was allowed used the
/// whole context window three times over (the uncached, cache-read and
/// cache-write buckets) and the longest output. This is the quantity the
/// request guard reserves, multiplied by the plan's request ceiling.
///
/// ## Examples
///
/// ```gleam
/// // 1 request of context 1_000_000 and output 0 at $1 per million on
/// // each of the three input buckets is $3.
/// let card = pricing.Pricing(1.0, 1.0, 1.0, 1.0)
/// assert budget.worst_case_dollars(1, card, context: 1_000_000, output: 0) == 3.0
/// ```
///
pub fn worst_case_dollars(
  requests: Int,
  card: Pricing,
  context context: Int,
  output output: Int,
) -> Float {
  let worst_request =
    message.Usage(
      ..storage.empty_usage(),
      input: context,
      output:,
      cache_read: context,
      cache_write: context,
    )

  int.to_float(requests) *. pricing.price(worst_request, card).cost.total
}

/// The tokens the request guard may reserve across one whole trial:
/// `max_requests_per_trial * (3 * context + output)`.
///
/// ## Examples
///
/// ```gleam
/// // The default plan allows 40 requests: 40 * (3 * 100_000 + 4096).
/// assert budget.request_allowance_tokens(40, context: 100_000, output: 4096) == 12_163_840
/// ```
///
pub fn request_allowance_tokens(
  requests: Int,
  context context: Int,
  output output: Int,
) -> Int {
  requests * { 3 * context + output }
}

/// The cap a plan's budgets declare. A plan whose lane is replay never calls
/// this: it starts the account `Unmetered`.
///
/// ## Examples
///
/// ```gleam
/// // budget.cap_of(budgets) == budget.Dollars(budgets.max_dollars)
/// ```
///
pub fn cap_of(budgets: Budgets) -> Cap {
  Dollars(budgets.max_dollars)
}

/// Starts an account under `cap`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(account) = budget.start(budget.Dollars(5.0))
/// assert budget.admit(account, 1.0) == budget.Admitted
/// ```
///
pub fn start(cap: Cap) -> Result(Account, String) {
  actor.new(State(
    cap:,
    spent: 0.0,
    reserved: 0.0,
    admitted: 0,
    exhausted_after: None,
  ))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Account(started.data) })
  |> result.replace_error("the budget account did not start")
}

/// Asks to start one trial whose worst case is `worst_case` dollars. An
/// admission reserves that amount until `settle` returns it; a refusal is
/// permanent.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(account) = budget.start(budget.Dollars(1.5))
/// assert budget.admit(account, 1.0) == budget.Admitted
/// assert budget.admit(account, 1.0) == budget.Exhausted(after_trials: 1)
/// ```
///
pub fn admit(account: Account, worst_case: Float) -> Admission {
  actor.call(account.subject, waiting: wait_ms, sending: Admit(worst_case, _))
}

/// Returns a trial's reservation and charges what it measurably spent.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(account) = budget.start(budget.Dollars(1.5))
/// let assert budget.Admitted = budget.admit(account, 1.0)
/// budget.settle(account, 1.0, measured: 0.25)
/// assert budget.status(account).spent == 0.25
/// ```
///
pub fn settle(
  account: Account,
  worst_case: Float,
  measured measured: Float,
) -> Nil {
  actor.call(account.subject, waiting: wait_ms, sending: Settle(
    worst_case,
    measured,
    _,
  ))
}

/// The account's present figures.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(account) = budget.start(budget.Unmetered)
/// assert budget.status(account).admitted == 0
/// ```
///
pub fn status(account: Account) -> Status {
  actor.call(account.subject, waiting: wait_ms, sending: Report)
}

/// Stops the account's process.
///
/// ## Examples
///
/// ```gleam
/// // budget.stop(account)
/// ```
///
pub fn stop(account: Account) -> Nil {
  process.send(account.subject, Stop)
}

/// The sentence a report carries when the account ever refused, and nothing
/// when it did not.
///
/// ## Examples
///
/// ```gleam
/// let stopped = budget.Status(spent: 2.0, admitted: 3, exhausted_after: Some(3))
/// assert budget.describe(stopped) == Some("budget exhausted after 3 trials")
/// ```
///
pub fn describe(status: Status) -> Option(String) {
  case status.exhausted_after {
    None -> None
    Some(count) ->
      Some("budget exhausted after " <> int.to_string(count) <> " trials")
  }
}

/// Handles one message to the account.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  // Only `Admit` decides; the other messages keep the books or end the actor.
  case message {
    Stop -> actor.stop()

    Report(reply:) -> {
      process.send(
        reply,
        Status(
          spent: state.spent,
          admitted: state.admitted,
          exhausted_after: state.exhausted_after,
        ),
      )
      actor.continue(state)
    }

    Settle(worst_case:, measured:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          spent: state.spent +. measured,
          reserved: float.max(state.reserved -. worst_case, 0.0),
        ),
      )
    }

    Admit(worst_case:, reply:) -> {
      let #(answer, next) = decide(state, worst_case)
      process.send(reply, answer)
      actor.continue(next)
    }
  }
}

/// A trial is admitted when what is left of the cap, after measured spend and
/// the worst cases still in flight, covers its own worst case. Once the first
/// refusal has been recorded every later one repeats it, whatever the size of
/// the trial asking.
fn decide(state: State, worst_case: Float) -> #(Admission, State) {
  // A recorded refusal outranks everything: the stop is a fact of the run, not a race between a large refused trial and a small later one.
  case state.exhausted_after, state.cap {
    Some(count), _ -> #(Exhausted(count), state)

    None, Unmetered -> #(Admitted, admit_one(state, worst_case))

    None, Dollars(limit:) -> {
      let remaining = limit -. state.spent -. state.reserved

      // Admission needs what is left of the cap, after measured spend and in-flight reservations, to cover this trial's worst case.
      case remaining >=. worst_case {
        True -> #(Admitted, admit_one(state, worst_case))
        False -> #(
          Exhausted(state.admitted),
          State(..state, exhausted_after: Some(state.admitted)),
        )
      }
    }
  }
}

/// Records one admission: counts the trial and reserves its worst case.
fn admit_one(state: State, worst_case: Float) -> State {
  State(
    ..state,
    admitted: state.admitted + 1,
    reserved: state.reserved +. worst_case,
  )
}
