//// Tests for the pure relay core: one unit test per row of the semantics
//// the direct relay defined, and property tests over seeded random event
//// sequences for the invariants that hold in every order.
////
//// The generator follows `machine`'s property tests: a SplitMix-style draw
//// threaded explicitly, so a failing sequence reproduces from its seed.

import broker/dispatch
import broker/exec
import broker/execution.{
  type Core, type Effect, type Event, CallerDown, CancelRequested,
  DeadlineReached, Deliver, Draining, EnterDraining, ExecExited, ExecFailed,
  ExecOutput, GraceExpired, HelperDown, SendCancel, Settle, Streaming,
}
import broker/framing
import gleam/bit_array
import gleam/int
import gleam/list

// --- fixtures -------------------------------------------------------------

fn chunk(
  stream: framing.OutputStream,
  text: String,
  truncated truncated: Bool,
) -> dispatch.Chunk {
  let data = bit_array.from_string(text)
  dispatch.Chunk(
    stream:,
    data:,
    total_bytes: bit_array.byte_size(data),
    truncated:,
  )
}

fn result(code: Int) -> exec.ExecResult {
  exec.ExecResult(
    code:,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: ["bwrap"],
    degraded: False,
    wall_ms: 1,
    timed_out: False,
    cancelled: False,
  )
}

fn feed(events: List(Event)) -> #(Core, List(Effect)) {
  feed_from(execution.new(), events)
}

fn feed_from(core: Core, events: List(Event)) -> #(Core, List(Effect)) {
  let #(core, collected) =
    list.fold(events, #(core, []), fn(state, event) {
      let #(core, collected) = state
      let #(core, effects) = execution.step(core, event)
      #(core, list.append(collected, effects))
    })
  #(core, collected)
}

fn lost(cause: exec.LossCause) -> dispatch.Terminal {
  dispatch.Failed(failure: exec.ExecutionLost(cause:))
}

// --- the rows of the semantics --------------------------------------------

pub fn output_while_open_is_delivered_and_counted_test() {
  let out = chunk(framing.Stdout, "hello", truncated: False)
  let err = chunk(framing.Stderr, "no", truncated: True)
  let #(core, effects) = feed([ExecOutput(out), ExecOutput(err)])
  assert effects == [Deliver(out), Deliver(err)]
  assert core.output.stdout_bytes == 5
  assert core.output.stderr_bytes == 2
  assert core.output.chunks == 2
  assert core.output.truncated == execution.Truncated
  assert core.settled == execution.Open
}

pub fn an_exit_settles_completed_exactly_once_test() {
  let #(core, effects) = feed([ExecExited(result(0)), ExecExited(result(1))])
  assert effects == [Settle(dispatch.Completed(result: result(0)))]
  assert core.settled == execution.Settling(dispatch.Completed(result(0)))
}

pub fn a_failure_settles_failed_exactly_once_test() {
  let #(_core, effects) =
    feed([ExecFailed(exec.SendFailed), ExecFailed(exec.NotReady)])
  assert effects == [Settle(dispatch.Failed(failure: exec.SendFailed))]
}

pub fn settled_is_absorbing_test() {
  let #(core, _effects) = feed([ExecExited(result(0))])
  let after = [
    ExecOutput(chunk(framing.Stdout, "late", truncated: False)),
    ExecExited(result(2)),
    ExecFailed(exec.SendFailed),
    CancelRequested,
    CallerDown,
    HelperDown,
    DeadlineReached,
    GraceExpired,
  ]
  list.each(after, fn(event) {
    assert execution.step(core, event) == #(core, [])
  })
}

pub fn caller_death_while_streaming_cancels_and_drains_test() {
  let #(core, effects) = feed([CallerDown])
  assert effects == [SendCancel, EnterDraining]
  assert core.mode == Draining
  assert core.cancel == execution.Asked(execution.CallerGone)
}

pub fn caller_death_while_draining_does_nothing_test() {
  let #(core, _effects) = feed([DeadlineReached])
  let #(_core, effects) = feed_from(core, [CallerDown])
  assert effects == []
}

pub fn the_wall_deadline_cancels_and_drains_test() {
  let #(core, effects) = feed([DeadlineReached])
  assert effects == [SendCancel, EnterDraining]
  assert core.mode == Draining
  assert core.cancel == execution.Asked(execution.WallDeadline)
}

pub fn the_first_cancel_cause_is_the_one_kept_test() {
  let #(core, _effects) = feed([CancelRequested, DeadlineReached, CallerDown])
  assert core.cancel == execution.Asked(execution.ByBroker)
}

pub fn grace_expiry_after_draining_escalates_test() {
  let #(_core, effects) = feed([DeadlineReached, GraceExpired])
  assert effects
    == [
      SendCancel,
      EnterDraining,
      Settle(dispatch.Failed(failure: exec.CancelEscalated)),
    ]
}

pub fn grace_expiry_while_streaming_is_stale_and_ignored_test() {
  let #(core, effects) = feed([GraceExpired])
  assert effects == []
  assert core.settled == execution.Open
}

pub fn a_deadline_while_draining_is_stale_and_ignored_test() {
  let #(core, _effects) = feed([CallerDown])
  let #(_core, effects) = feed_from(core, [DeadlineReached])
  assert effects == []
}

/// The broker's cancel was already forwarded to the helper by the service,
/// so the core sends nothing and does not leave `Streaming`: today's
/// broker cancel never moved the relay to a draining window.
pub fn a_broker_cancel_is_recorded_and_sends_nothing_test() {
  let #(core, effects) = feed([CancelRequested])
  assert effects == []
  assert core.mode == Streaming
  assert core.cancel == execution.Asked(execution.ByBroker)
}

pub fn a_broker_cancelled_execution_still_settles_on_its_exit_test() {
  let cancelled = exec.ExecResult(..result(143), cancelled: True)
  let #(_core, effects) = feed([CancelRequested, ExecExited(cancelled)])
  assert effects == [Settle(dispatch.Completed(result: cancelled))]
}

/// The relay fix: a helper actor that dies mid-execution settles the
/// caller, in either mode, whatever the deadline was.
pub fn helper_death_while_streaming_settles_lost_test() {
  let #(_core, effects) = feed([HelperDown])
  assert effects == [Settle(lost(exec.HelperActorDown))]
}

pub fn helper_death_while_draining_settles_lost_test() {
  let #(_core, effects) = feed([CallerDown, HelperDown])
  assert effects
    == [SendCancel, EnterDraining, Settle(lost(exec.HelperActorDown))]
}

pub fn helper_death_after_a_terminal_event_changes_nothing_test() {
  let #(_core, effects) = feed([ExecExited(result(0)), HelperDown])
  assert effects == [Settle(dispatch.Completed(result: result(0)))]
}

// --- properties -----------------------------------------------------------

type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(state, int.bitwise_shift_right(state, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  #(int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31)), Seed(state:))
}

fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

// One random event. Output is the commonest so that sequences have chunks
// to order, and chunk text is its index so a reordering is visible.
fn event_from(seed: Seed, index: Int) -> #(Event, Seed) {
  let #(kind, seed) = int_between(seed, 0, 11)
  let #(truncated, seed) = int_between(seed, 0, 3)
  let #(width, seed) = int_between(seed, 0, 6)
  let text = int.to_string(index) <> string_of(width)
  let event = case kind {
    0 | 1 | 2 ->
      ExecOutput(chunk(framing.Stdout, text, truncated: truncated == 0))
    3 | 4 -> ExecOutput(chunk(framing.Stderr, text, truncated: truncated == 0))
    5 -> ExecExited(result(index))
    6 -> ExecFailed(exec.SendFailed)
    7 -> CancelRequested
    8 -> CallerDown
    9 -> HelperDown
    10 -> DeadlineReached
    _ -> GraceExpired
  }
  #(event, seed)
}

// 1 through `last`, inclusive.
fn count_to(last: Int) -> List(Int) {
  count_loop(last, [])
}

fn count_loop(current: Int, collected: List(Int)) -> List(Int) {
  case current < 1 {
    True -> collected
    False -> count_loop(current - 1, [current, ..collected])
  }
}

fn string_of(width: Int) -> String {
  case width {
    0 -> ""
    _ -> "x" <> string_of(width - 1)
  }
}

fn sequence_from(seed_value: Int) -> List(Event) {
  let seed = Seed(state: seed_value)
  let #(length, seed) = int_between(seed, 1, 14)
  let #(events, _seed) =
    count_to(length)
    |> list.fold(#([], seed), fn(state, index) {
      let #(events, seed) = state
      let #(event, seed) = event_from(seed, index)
      #([event, ..events], seed)
    })
  list.reverse(events)
}

// One step's record: the event, the core before it, and what it produced.
type Trace {
  Trace(event: Event, before: Core, effects: List(Effect))
}

fn trace(events: List(Event)) -> List(Trace) {
  let #(_core, reversed) =
    list.fold(events, #(execution.new(), []), fn(state, event) {
      let #(core, traces) = state
      let #(next_core, effects) = execution.step(core, event)
      #(next_core, [Trace(event:, before: core, effects:), ..traces])
    })
  list.reverse(reversed)
}

fn settles(effects: List(Effect)) -> List(dispatch.Terminal) {
  list.filter_map(effects, fn(effect) {
    case effect {
      Settle(terminal:) -> Ok(terminal)
      Deliver(..) | SendCancel | EnterDraining -> Error(Nil)
    }
  })
}

fn for_each_sequence(check: fn(List(Event), List(Trace)) -> Nil) -> Nil {
  list.each(count_to(600), fn(seed_value) {
    let events = sequence_from(seed_value)
    check(events, trace(events))
  })
}

/// Over every generated sequence, no more than one `Settle` is produced.
pub fn at_most_one_settle_per_sequence_test() {
  for_each_sequence(fn(_events, traces) {
    let all = list.flat_map(traces, fn(step) { step.effects })
    assert list.length(settles(all)) <= 1
  })
}

/// A terminal exec event, a helper death, or a grace expiry that follows a
/// drain always yields exactly one `Settle` in its own step, unless an
/// earlier step already settled, in which case it yields none and the
/// sequence still has exactly one.
pub fn terminal_events_always_settle_test() {
  for_each_sequence(fn(_events, traces) {
    let all = list.flat_map(traces, fn(step) { step.effects })
    let terminal_anywhere =
      list.any(traces, fn(step) { is_terminal(step.event, step.before) })
    case terminal_anywhere {
      True -> {
        assert list.length(settles(all)) == 1
      }
      False -> Nil
    }
    list.each(traces, fn(step) {
      case is_terminal(step.event, step.before), step.before.settled {
        True, execution.Open -> {
          assert list.length(settles(step.effects)) == 1
        }
        True, execution.Settling(_) | False, _ -> Nil
      }
    })
  })
}

fn is_terminal(event: Event, before: Core) -> Bool {
  case event, before.mode {
    ExecExited(_), _ | ExecFailed(_), _ | HelperDown, _ -> True
    GraceExpired, Draining -> True
    GraceExpired, Streaming -> False
    ExecOutput(_), _
    | CancelRequested, _
    | CallerDown, _
    | DeadlineReached, _
    -> False
  }
}

/// After the step that settles, every later step produces nothing, and
/// `Settle` is the last effect of its own step.
pub fn nothing_is_produced_after_settle_test() {
  for_each_sequence(fn(_events, traces) {
    list.each(traces, fn(step) {
      case step.before.settled {
        execution.Settling(_) -> {
          assert step.effects == []
        }
        execution.Open ->
          case list.reverse(step.effects) {
            [Settle(_), ..rest] -> {
              assert settles(rest) == []
            }
            [] | [Deliver(..), ..] | [SendCancel, ..] | [EnterDraining, ..] -> {
              assert settles(step.effects) == []
            }
          }
      }
    })
  })
}

/// The chunks delivered are exactly the chunks input before settlement,
/// in input order.
pub fn deliveries_follow_input_order_test() {
  for_each_sequence(fn(_events, traces) {
    let expected =
      list.filter_map(traces, fn(step) {
        case step.event, step.before.settled {
          ExecOutput(chunk:), execution.Open -> Ok(Deliver(chunk:))
          ExecOutput(..), execution.Settling(_)
          | ExecExited(..), _
          | ExecFailed(..), _
          | CancelRequested, _
          | CallerDown, _
          | HelperDown, _
          | DeadlineReached, _
          | GraceExpired, _
          -> Error(Nil)
        }
      })
    let delivered =
      list.flat_map(traces, fn(step) { step.effects })
      |> list.filter(fn(effect) {
        case effect {
          Deliver(..) -> True
          SendCancel | EnterDraining | Settle(..) -> False
        }
      })
    assert delivered == expected
  })
}

/// The counters equal the sums over the delivered chunks.
pub fn counters_equal_the_sum_of_delivered_chunks_test() {
  for_each_sequence(fn(events, _traces) {
    let #(core, effects) = feed(events)
    let delivered =
      list.filter_map(effects, fn(effect) {
        case effect {
          Deliver(chunk:) -> Ok(chunk)
          SendCancel | EnterDraining | Settle(..) -> Error(Nil)
        }
      })
    let sum = fn(stream: framing.OutputStream) {
      list.filter(delivered, fn(chunk) { chunk.stream == stream })
      |> list.fold(0, fn(total, chunk) {
        total + bit_array.byte_size(chunk.data)
      })
    }
    assert core.output.stdout_bytes == sum(framing.Stdout)
    assert core.output.stderr_bytes == sum(framing.Stderr)
    assert core.output.chunks == list.length(delivered)
    let any_truncated = list.any(delivered, fn(chunk) { chunk.truncated })
    assert core.output.truncated
      == case any_truncated {
        True -> execution.Truncated
        False -> execution.Whole
      }
  })
}

/// A cancel is sent at most once: draining is entered once and the
/// service is asked to cancel only on that entry.
pub fn cancel_is_sent_at_most_once_test() {
  for_each_sequence(fn(_events, traces) {
    let all = list.flat_map(traces, fn(step) { step.effects })
    assert list.count(all, fn(effect) { effect == SendCancel }) <= 1
    assert list.count(all, fn(effect) { effect == EnterDraining }) <= 1
  })
}
