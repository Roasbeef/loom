//// The governed guard's ledger against the fold it answers to.
////
//// The guard debits a worst case before every attempt and, since the
//// refund landed (protocol-change/100, the addendum), replaces it with the
//// attempt's charge once the gateway reports how the attempt ended. What
//// makes that safe is that the ledger is the one source of the trial's
//// charge: the step hands the fold `rollout_host.charged`, never a second
//// figure read from the transcript, so this module's centre is a parity
//// property stated as the review that found the earlier divergence asked
//// for it. Over a drawn sequence of attempts that settle complete, errored
//// with usage, with no usage, not at all, outside any turn (a glance or a
//// block summary, which writes no entry), settled but never committed
//// (aborted at the wall), or still open when the step reads, the ledger's
//// remaining allowance equals the allowance the real fold hands the next
//// step after accounting the step the ledger reported. The remaining tests
//// are the falsifiers the addendum names, the reviewer's glance scenario
//// among them.

import broker/token
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/rollout
import client/evolution/rollout_host
import client/evolution/store
import core/accounting
import core/clock
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Pid}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import provider/model
import provider/pricing
import provider/profile
import qcheck
import simplifile

// --- the fixture ------------------------------------------------------------

const api = "anthropic-messages"

const digest = "0000000000000000000000000000000000000000000000000000000000000000"

/// A small target, so a drawn sequence of attempts fits the fold's
/// million-token ceiling at worst case: 3,100 tokens an attempt.
fn target() -> model.ResolvedModel {
  model.ResolvedModel("p", "m", model.ThinkingOff, 1000, 100)
}

/// The reviewer's target: 200k context and 8k output, one worst case of
/// 608,192 tokens, so two do not fit the door's million.
fn large() -> model.ResolvedModel {
  model.ResolvedModel("p", "m", model.ThinkingOff, 200_000, 8192)
}

fn scope() -> record.ModelScope {
  record.ModelScope("p", "m", api)
}

fn card() -> pricing.Pricing {
  pricing.Pricing(input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 1.5)
}

/// The door's own money caps, with a turn and wall budget that never bind.
fn door_allowance() -> rollout.Allowance {
  rollout.Allowance(
    turns: 100,
    tokens: 1_000_000,
    dollars: 2.0,
    output_bytes: 65_536,
    deadline_ms: 10_000,
  )
}

fn priced_with_total(
  input: Int,
  output: Int,
  cache_read: Int,
  cache_write: Int,
  total_tokens: Int,
) -> message.Usage {
  pricing.price(
    message.Usage(
      ..accounting.zero_usage(),
      input:,
      output:,
      cache_read:,
      cache_write:,
      total_tokens:,
    ),
    card(),
  )
}

fn priced(input: Int, output: Int, cache_read: Int, cache_write: Int) {
  priced_with_total(
    input,
    output,
    cache_read,
    cache_write,
    input + output + cache_read + cache_write,
  )
}

/// The fold's reckoning of one usage record, as `accept_step` writes it.
fn used(usage: message.Usage) -> Int {
  int.max(
    usage.total_tokens,
    usage.input + usage.output + usage.cache_read + usage.cache_write,
  )
}

fn complete(usage: message.Usage) -> rollout.Settlement {
  rollout.Settlement(scope(), usage, rollout.Answered(message.Stop))
}

/// A process that outlives the test body, so a reservation can stay open
/// under a pid other than the test's own while the test goes on asking.
fn another_pump() -> Pid {
  process.spawn_unlinked(fn() { process.sleep(5000) })
}

// --- the parity property ----------------------------------------------------

/// How many attempt sequences the parity property draws, and the qcheck
/// seed they come from. The seed is fixed so the gate is deterministic.
const parity_count = 100

const parity_seed = 1_000_100

/// One admitted attempt, as the gateway reports it to the guard. The first
/// four are a turn's own attempts: the runtime commits an assistant entry
/// for the first three and nothing for the fourth. `SideRequest` is a
/// request outside any turn, a glance or a block summary, which settles with
/// usage and writes no entry; `Uncommitted` is a response the pump settled
/// and the runtime never committed, aborted at the wall; `NeverSettles` is
/// an attempt whose settlement has not arrived when the step reads.
type Attempt {
  Complete(usage: message.Usage)
  ErroredWithUsage(usage: message.Usage)
  UsageLess
  Cancelled
  SideRequest(usage: message.Usage)
  Uncommitted(usage: message.Usage)
  NeverSettles
}

/// Reported totals are usually the bucket sum, as every adapter here writes
/// them, and sometimes not, as a proxy might: the ledger must charge the
/// fold's reckoning either way.
fn usage() -> qcheck.Generator(message.Usage) {
  let buckets =
    qcheck.tuple4(
      qcheck.bounded_int(1, 300),
      qcheck.bounded_int(1, 100),
      qcheck.bounded_int(0, 300),
      qcheck.bounded_int(0, 300),
    )
  qcheck.from_weighted_generators(
    #(
      3,
      qcheck.map(buckets, fn(b) {
        let #(input, output, cache_read, cache_write) = b
        priced(input, output, cache_read, cache_write)
      }),
    ),
    [
      #(
        1,
        qcheck.map2(buckets, qcheck.bounded_int(1, 2000), fn(b, total) {
          let #(input, output, cache_read, cache_write) = b
          priced_with_total(input, output, cache_read, cache_write, total)
        }),
      ),
    ],
  )
}

fn attempt() -> qcheck.Generator(Attempt) {
  qcheck.from_weighted_generators(#(4, qcheck.map(usage(), Complete)), [
    #(2, qcheck.map(usage(), ErroredWithUsage)),
    #(1, qcheck.constant(UsageLess)),
    #(1, qcheck.constant(Cancelled)),
    #(2, qcheck.map(usage(), SideRequest)),
    #(1, qcheck.map(usage(), Uncommitted)),
    #(1, qcheck.constant(NeverSettles)),
  ])
}

fn sequence() -> qcheck.Generator(List(Attempt)) {
  qcheck.generic_list(attempt(), qcheck.bounded_int(1, 8))
}

/// How the gateway reports the attempt to the guard. A side request and an
/// uncommitted response are, to the guard, ordinary settled responses: the
/// difference is only that the transcript never shows them, which is why
/// the transcript is not consulted.
fn settlement(attempt: Attempt) -> rollout.Settlement {
  case attempt {
    Complete(usage:) | SideRequest(usage:) | Uncommitted(usage:) ->
      complete(usage)
    ErroredWithUsage(usage:) ->
      rollout.Settlement(scope(), usage, rollout.Answered(message.Errored))
    UsageLess ->
      rollout.Settlement(
        scope(),
        accounting.zero_usage(),
        rollout.Answered(message.Stop),
      )
    Cancelled | NeverSettles ->
      rollout.Settlement(scope(), accounting.zero_usage(), rollout.Unanswered)
  }
}

/// Admits and settles the attempts in order. A settling attempt runs under
/// the test's own pid, which its settlement frees for the next; one that
/// never settles runs under a pump of its own and stays open.
fn drive(
  ledger: rollout_host.Ledger,
  attempts: List(Attempt),
) -> Result(rollout_host.Ledger, String) {
  list.try_fold(attempts, ledger, fn(ledger, attempt) {
    let pump = case attempt {
      NeverSettles -> another_pump()
      Complete(_)
      | ErroredWithUsage(_)
      | UsageLess
      | Cancelled
      | SideRequest(_)
      | Uncommitted(_) -> process.self()
    }
    let #(admitted, ledger) =
      rollout_host.reserve(ledger, pump, scope(), digest, 1)
    use _ <- result.try(admitted)

    // An open reservation is left open; everything else settles once.
    case attempt {
      NeverSettles -> Ok(ledger)
      Complete(_)
      | ErroredWithUsage(_)
      | UsageLess
      | Cancelled
      | SideRequest(_)
      | Uncommitted(_) -> rollout_host.settle(ledger, pump, settlement(attempt))
    }
  })
}

fn opened() -> #(store.Store, String) {
  let root =
    "build/test_db/evolution-rollout-host-"
    <> bit_array.base16_encode(token.production_entropy()(12))
  let assert Ok(catalogue) =
    store.open(
      root,
      store.Owner,
      record_test.candidate().identity,
      clock.fixed(1),
    )
    as "native catalogue opens"
  #(catalogue, root)
}

fn candidate() -> record.Candidate {
  record.identified(
    record.Candidate(
      ..record_test.candidate(),
      kind: record.Prompt,
      scope: record.ExactModel(scope()),
      files: [
        #(
          "prompt.json",
          "{\"version\":1,\"provider\":\"p\",\"model\":\"m\",\"api\":\"anthropic-messages\",\"system\":\"Parity.\",\"task\":\"Check the fixture.\",\"descriptions\":{\"code_mode\":\"Verify the result.\"}}",
        ),
      ],
      test_entry: None,
    ),
  )
}

fn task() -> rollout.Task {
  rollout.Task(
    "repair-v1",
    "Repair fixture source and run its tests.",
    "fixture-test-v1",
    "fixture-source-v1",
  )
}

/// What the step reads from the guard, as `rollout_host.run` builds it.
fn step_from(
  ledger: rollout_host.Ledger,
  request: rollout.TrialRequest,
  progress: rollout.Progress,
) -> rollout.Step {
  let charged = rollout_host.charged(ledger)
  rollout.Step(
    target: scope(),
    profile_id: option.map(request.profile, fn(profile) {
      profile.fields(profile).0
    }),
    usage: charged.usage,
    turns: charged.turns,
    tool_executions: 1,
    output: "",
    progress:,
    composition_digests: charged.digests,
    unreported: charged.unreported,
  )
}

/// Runs the attempts through a guard ledger opened on the allowance the real
/// fold hands the first trial's first step, reports that step from the ledger
/// as `rollout_host.run` would, and returns the ledger's remaining allowance
/// beside the allowance the fold hands the next step. The catalogue the fold
/// needs is opened under `build/test_db` and removed before anything is
/// asserted, so a failing case leaves no database behind.
fn guard_and_fold(
  target: model.ResolvedModel,
  attempts: List(Attempt),
) -> #(rollout.Allowance, rollout.Allowance) {
  let #(catalogue, root) = opened()
  let proposed = candidate()
  let assert Ok(_) = store.propose(catalogue, proposed) as "candidate retained"
  let remaining = process.new_subject()
  let allowances = process.new_subject()
  let limits = rollout.Limits(2, 100, 1_000_000, 10.0, 65_536, 900_000, 1)
  let callbacks =
    rollout.Callbacks(
      clock: clock.fixed(1),
      mode: rollout.ScriptedLifecycle,
      open: fn(request) {
        Ok(rollout.Trial(
          step: fn(allowance) {
            // The fresh allowance opens the step that carries the attempts;
            // every later step, on either arm, reports the allowance it was
            // handed and finishes.
            case allowance.turns == limits.turns {
              True -> {
                let driven =
                  drive(
                    rollout_host.open_ledger(allowance, target, api, card()),
                    attempts,
                  )
                process.send(remaining, driven)
                let ledger =
                  result.lazy_unwrap(driven, fn() {
                    rollout_host.open_ledger(allowance, target, api, card())
                  })
                Ok(step_from(ledger, request, rollout.Continue))
              }
              False -> {
                process.send(allowances, allowance)
                let empty =
                  rollout_host.open_ledger(allowance, target, api, card())
                Ok(
                  rollout.Step(
                    ..step_from(empty, request, rollout.Finished),
                    turns: 1,
                    composition_digests: [digest],
                  ),
                )
              }
            }
          },
          score: fn(_) { Ok(rollout.Grade(1.0, [], "", rollout.ExpectedFiles)) },
          close: retirement.repeat(fn() { Ok(Nil) }),
          cleanup: fn() { Ok(Nil) },
        ))
      },
    )
  let evaluated =
    rollout.evaluate(
      catalogue,
      proposed.id,
      target,
      api,
      [task()],
      limits,
      callbacks,
    )
  let _removed = simplifile.delete(root)
  let assert Ok(_) = evaluated as "the scripted comparison runs to evidence"
  let assert Ok(Ok(ledger)) = process.receive(remaining, 1000)
    as "the allowance admits and settles every attempt"
  let assert Ok(fold) = process.receive(allowances, 1000)
    as "the fold continues to a second step after accounting the attempts"
  #(rollout_host.remaining(ledger), fold)
}

/// The two allowances agree exactly on turns, tokens and the deadline, and
/// on dollars to rounding, because the two sides sum in a different order.
/// Output bytes are the one component the fold charges by retained text
/// rather than by attempt, so the guard may only be the tighter of the two.
fn agree(guard: rollout.Allowance, fold: rollout.Allowance) -> Nil {
  assert guard.turns == fold.turns
  assert guard.tokens == fold.tokens
  assert float.absolute_value(guard.dollars -. fold.dollars) <. 1.0e-9
  assert guard.output_bytes <= fold.output_bytes
  assert guard.deadline_ms == fold.deadline_ms
}

pub fn the_guard_and_the_fold_agree_after_any_attempt_sequence_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(parity_count)
  |> qcheck.with_seed(qcheck.seed(parity_seed))
  |> qcheck.run(sequence(), fn(attempts) {
    let #(guard, fold) = guard_and_fold(target(), attempts)
    agree(guard, fold)
  })
}

// --- the falsifiers ---------------------------------------------------------

pub fn two_side_requests_on_a_large_window_target_are_charged_once_test() {
  // The reviewer's scenario: a glance and a block summary settle through the
  // guarded gateway with usage and no transcript entry, beside the turn's
  // own attempt. Before the fix the guard credited them measured while the
  // fold charged each its 608,192-token worst case, putting the fold past
  // the million-token cap on a trial the guard had admitted.
  let glance = priced(1800, 40, 0, 0)
  let summary = priced(2400, 60, 0, 0)
  let turn = priced(2000, 500, 0, 0)
  let #(guard, fold) =
    guard_and_fold(large(), [
      SideRequest(glance),
      SideRequest(summary),
      Complete(turn),
    ])
  agree(guard, fold)
  assert guard.tokens == 1_000_000 - used(glance) - used(summary) - used(turn)
  assert guard.turns == 97
}

pub fn a_large_window_target_runs_three_attempts_inside_the_door_caps_test() {
  // Before the refund the second attempt against this target was refused
  // whatever the first one used.
  let pump = process.self()
  let ledger = rollout_host.open_ledger(door_allowance(), large(), api, card())
  let small = priced(2000, 500, 0, 0)

  // Each attempt is admitted at the full output ceiling and settles to its
  // measured usage, so the third admission finds the whole cap less two
  // small charges, and the open third is charged its worst case.
  let ledger =
    list.fold([small, small], ledger, fn(ledger, usage) {
      let #(admitted, ledger) =
        rollout_host.reserve(ledger, pump, scope(), digest, 1)
      assert admitted == Ok(8192)
      let assert Ok(ledger) = rollout_host.settle(ledger, pump, complete(usage))
      ledger
    })
  let #(third, ledger) = rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert third == Ok(8192)
  let remaining = rollout_host.remaining(ledger)
  let worst = rollout.worst_case(large(), card())
  assert remaining.tokens == 1_000_000 - 2 * used(small) - worst.tokens
  assert remaining.turns == 97
  assert float.absolute_value(
      remaining.dollars -. { 2.0 -. 2.0 *. small.cost.total -. worst.dollars },
    )
    <. 1.0e-9
}

pub fn an_unsettled_attempt_keeps_its_whole_reservation_test() {
  let ledger = rollout_host.open_ledger(door_allowance(), large(), api, card())
  let #(first, ledger) =
    rollout_host.reserve(ledger, process.self(), scope(), digest, 1)
  assert first == Ok(8192)

  // Nothing settled, so the second attempt from another pump meets the
  // pre-refund arithmetic: two worst cases do not fit a million tokens.
  let #(second, ledger) =
    rollout_host.reserve(ledger, another_pump(), scope(), digest, 1)
  assert second
    == Error(
      "exact rollout target or aggregate reservation budget refused request",
    )
  let worst = rollout.worst_case(large(), card())
  assert rollout_host.remaining(ledger).tokens == 1_000_000 - worst.tokens
  let charged = rollout_host.charged(ledger)
  assert charged.turns == 1 && charged.digests == [digest, digest]
}

pub fn an_open_reservation_is_charged_its_worst_case_when_the_step_reads_test() {
  // An attempt that has not settled when the step reads is charged the whole
  // worst case on both ledgers, and a settlement that arrives afterwards
  // moves the guard alone, which the fold never sees.
  let opened_with = door_allowance()
  let worst = rollout.worst_case(target(), card())
  let pump = another_pump()
  let ledger = rollout_host.open_ledger(opened_with, target(), api, card())
  let #(admitted, ledger) =
    rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert admitted == Ok(100)
  let charged = rollout_host.charged(ledger)
  assert charged.unreported == rollout.Unreported(worst.tokens, worst.dollars)
  assert charged.usage == accounting.zero_usage()
  assert rollout_host.remaining(ledger).tokens
    == opened_with.tokens - worst.tokens
  let assert Ok(settled) =
    rollout_host.settle(ledger, pump, complete(priced(10, 5, 0, 0)))
  assert rollout_host.charged(settled).unreported == rollout.Unreported(0, 0.0)
}

pub fn an_errored_attempt_is_charged_its_worst_case_beside_its_usage_test() {
  let pump = process.self()
  let opened_with = door_allowance()
  let ledger = rollout_host.open_ledger(opened_with, target(), api, card())
  let reported = priced(50, 20, 0, 0)
  let #(admitted, ledger) =
    rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert admitted == Ok(100)
  let assert Ok(ledger) =
    rollout_host.settle(
      ledger,
      pump,
      rollout.Settlement(scope(), reported, rollout.Answered(message.Errored)),
    )

  // The seventy tokens are real spend and the worst case is the answer to
  // not knowing whether they were the whole of it.
  let worst = rollout.worst_case(target(), card())
  let remaining = rollout_host.remaining(ledger)
  assert remaining.tokens == opened_with.tokens - worst.tokens - used(reported)
  assert float.absolute_value(
      remaining.dollars
      -. { opened_with.dollars -. worst.dollars -. reported.cost.total },
    )
    <. 1.0e-12
}

pub fn a_foreign_or_empty_report_keeps_the_worst_case_test() {
  let pump = process.self()
  let opened_with = door_allowance()
  let worst = rollout.worst_case(target(), card())
  list.each(
    [
      rollout.Settlement(
        record.ModelScope("other", "m", api),
        priced(50, 20, 0, 0),
        rollout.Answered(message.Stop),
      ),
      rollout.Settlement(
        scope(),
        accounting.zero_usage(),
        rollout.Answered(message.Stop),
      ),
      rollout.Settlement(scope(), accounting.zero_usage(), rollout.Unanswered),
    ],
    fn(settlement) {
      let ledger = rollout_host.open_ledger(opened_with, target(), api, card())
      let #(_, ledger) = rollout_host.reserve(ledger, pump, scope(), digest, 1)
      let assert Ok(ledger) = rollout_host.settle(ledger, pump, settlement)
      let charge =
        rollout.attempt_charge(target(), api, settlement, worst, card())
      assert charge.basis == rollout.WorstCase
      assert rollout_host.remaining(ledger).tokens
        == opened_with.tokens - worst.tokens - used(settlement.usage)
    },
  )
}

pub fn measured_tokens_are_the_folds_reckoning_of_the_summed_records_test() {
  // Two reports with inconsistent totals: one claims more than its buckets,
  // the other less. The fold reckons the sum once, so the charge is fifteen
  // tokens rather than the twenty a per-attempt reckoning would give.
  let pump = process.self()
  let opened_with = door_allowance()
  let ledger = rollout_host.open_ledger(opened_with, target(), api, card())
  let ledger =
    list.fold(
      [priced_with_total(5, 0, 0, 0, 10), priced_with_total(10, 0, 0, 0, 5)],
      ledger,
      fn(ledger, usage) {
        let #(_, ledger) =
          rollout_host.reserve(ledger, pump, scope(), digest, 1)
        let assert Ok(ledger) =
          rollout_host.settle(ledger, pump, complete(usage))
        ledger
      },
    )
  assert rollout_host.remaining(ledger).tokens == opened_with.tokens - 15
}

pub fn an_attempt_settles_exactly_once_and_only_after_admission_test() {
  let pump = process.self()
  let ledger = rollout_host.open_ledger(door_allowance(), target(), api, card())
  let usage = priced(10, 5, 0, 0)

  // Before any admission there is nothing to settle.
  assert result.is_error(rollout_host.settle(ledger, pump, complete(usage)))
  let #(_, ledger) = rollout_host.reserve(ledger, pump, scope(), digest, 1)
  let assert Ok(settled) = rollout_host.settle(ledger, pump, complete(usage))

  // A second settlement of the same attempt is refused and credits nothing,
  // and a pump that was never admitted is refused the same way.
  assert result.is_error(rollout_host.settle(settled, pump, complete(usage)))
  assert result.is_error(rollout_host.settle(
    settled,
    another_pump(),
    complete(usage),
  ))
  assert rollout_host.remaining(settled).tokens
    == door_allowance().tokens - used(usage)
}

pub fn a_pump_with_an_open_reservation_is_not_admitted_again_test() {
  let pump = process.self()
  let ledger = rollout_host.open_ledger(door_allowance(), target(), api, card())
  let #(first, ledger) = rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert first == Ok(100)
  let #(second, ledger) = rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert result.is_error(second)

  // Settling the open attempt readmits the pump, and the third admission
  // is the second attempt.
  let assert Ok(ledger) =
    rollout_host.settle(ledger, pump, complete(priced(10, 5, 0, 0)))
  let #(third, ledger) = rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert third == Ok(100)
  assert rollout_host.charged(ledger).turns == 2
}

pub fn a_target_whose_output_ceiling_exceeds_the_byte_cap_is_admitted_clipped_test() {
  // The reviewer's first case: 100k context and 32k output. Four bytes a
  // token puts the whole ceiling at twice the door's 65,536-byte cap, so the
  // ceiling is pinned to 16,384 and the attempt runs rather than being
  // refused before any spend.
  let wide = model.ResolvedModel("p", "m", model.ThinkingOff, 100_000, 32_768)
  let pump = another_pump()
  let ledger = rollout_host.open_ledger(door_allowance(), wide, api, card())
  let #(admitted, ledger) =
    rollout_host.reserve(ledger, pump, scope(), digest, 1)
  assert admitted == Ok(16_384)

  // Open, the attempt is charged the clipped reservation, not the target's
  // whole worst case; settled unmeasured, it keeps that same figure.
  let clipped = rollout.reservation(wide, 16_384, card())
  assert clipped.tokens == 300_000 + 16_384
  assert rollout_host.charged(ledger).unreported
    == rollout.Unreported(clipped.tokens, clipped.dollars)
  assert rollout_host.remaining(ledger).output_bytes == 0
  let assert Ok(settled) =
    rollout_host.settle(
      ledger,
      pump,
      rollout.Settlement(scope(), accounting.zero_usage(), rollout.Unanswered),
    )
  assert rollout_host.charged(settled).unreported
    == rollout.Unreported(clipped.tokens, clipped.dollars)
  assert rollout_host.remaining(settled).tokens
    == door_allowance().tokens - clipped.tokens
}

pub fn a_target_at_the_token_margin_is_admitted_with_its_output_clipped_test() {
  // The reviewer's second case: 330k context and 16k output. Three windows
  // are 990,000 tokens, so the door's million leaves 10,000 for output and
  // the ceiling is pinned there.
  let margin = model.ResolvedModel("p", "m", model.ThinkingOff, 330_000, 16_384)
  let ledger = rollout_host.open_ledger(door_allowance(), margin, api, card())
  let #(admitted, ledger) =
    rollout_host.reserve(ledger, process.self(), scope(), digest, 1)
  assert admitted == Ok(10_000)
  assert rollout_host.remaining(ledger).tokens == 0
  assert rollout_host.charged(ledger).unreported.tokens == 1_000_000
}

pub fn session_spend_the_guard_never_admitted_trips_the_step_test() {
  // The session's usage ledger can only ever carry what crossed the guarded
  // gateway. A record the guard did not charge is spend that bypassed it,
  // and the step refuses rather than account the trial short.
  let charged = priced(100, 20, 0, 0)
  assert rollout_host.cross_check(charged, charged) == Ok(Nil)
  assert rollout_host.cross_check(charged, priced(90, 20, 0, 0)) == Ok(Nil)
  assert result.is_error(rollout_host.cross_check(
    charged,
    priced(101, 20, 0, 0),
  ))
  assert result.is_error(rollout_host.cross_check(
    charged,
    message.Usage(
      ..charged,
      cost: message.UsageCost(..charged.cost, total: charged.cost.total +. 0.01),
    ),
  ))
}
