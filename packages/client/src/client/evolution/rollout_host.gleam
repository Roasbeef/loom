//// Production rollout assembly uses the ordinary runtime and real tool effects.
////
//// The caller opens a fresh workspace fixture and native session with the
//// supplied gateway, and returns its runtime plus a witnessed retirement
//// capability. No direct-answer provider invocation substitutes for coding.
//// A small weft actor reserves worst-case provider usage before every actual
//// request; it is local to this evaluation and shares no default session cost.
//// Conservative reservations use the whole context window, so a trial can
//// refuse before exhausting the billed budget. Such a trial is inconclusive.
////
//// The reservation is a debit, not a sentence. Once the gateway reports how
//// an admitted attempt ended, the guard replaces the worst case with
//// `rollout.attempt_charge` of that settlement: a complete attempt at its
//// measured usage, anything else at the worst case beside whatever it did
//// report. The guard's ledger is the one source of the trial's charge. The
//// step reads it (`charged`) and hands the fold the summed usage records and
//// the worst case of every attempt that was not measured, including every
//// reservation still open when the step reads, so the fold's allowance after
//// the step is the guard's remaining allowance by construction. Nothing is
//// re-derived from the transcript: a request that settles outside a turn, a
//// response the runtime never committed and an attempt that never settles are
//// all charged once, here. The session's own usage ledger is read once more,
//// as a tripwire only (`cross_check`): spend the guard never admitted stops
//// the comparison, never joins its charge. The bookkeeping is the pure
//// `Ledger`; the actor only serialises it.

import broker/internal/call
import client/evolution/prompt
import client/evolution/record
import client/evolution/retirement
import client/evolution/rollout
import client/evolution/trace
import core/accounting
import core/clock.{type Clock}
import core/entry
import core/message
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import provider/gateway
import provider/model
import provider/pricing
import provider/profile as provider_profile
import runtime/api
import storage/storage
import weft/actor

/// The production caller retains native teardown until its result proves exit.
pub type Running {
  Running(
    /// The ordinary production runtime, with jailed tools enabled.
    runtime: api.Runtime,
    /// Native fresh workspace retained for scoring after the runtime closes.
    workspace: String,
    /// Drain the runtime and prove executor/helper retirement.
    retire: retirement.Task,
    /// Remove the private root after retirement and independent scoring.
    cleanup: fn() -> Result(Nil, String),
  )
}

/// The guard's ledger: the allowance one trial opened with, every admitted
/// attempt's worst case while it is open, and what each settled attempt is
/// charged. `remaining` is derived from these rather than kept, so it cannot
/// drift from `charged`, which is the same arithmetic read the other way.
/// It is pure so the parity property can run it beside the fold without a
/// process, and opaque so its one invariant, that every open reservation is
/// settled at most once, is enforced by `reserve` and `settle` alone.
pub opaque type Ledger {
  Ledger(
    /// The exact scope every admitted attempt must name.
    scope: record.ModelScope,
    /// The exact target, for the worst case and the output ceiling.
    target: model.ResolvedModel,
    /// The rate card the gateway prices this target on.
    card: pricing.Pricing,
    /// The allowance the fold handed the trial at open.
    opened: rollout.Allowance,
    /// Admitted attempts, which is the turn count the fold reads.
    attempts: Int,
    /// The newest composition digests, newest first, at most a hundred.
    digests: List(String),
    /// Pumps whose admitted attempt the gateway has not yet reported, each
    /// with the worst case reserved for it at its pinned output ceiling.
    open: List(#(Pid, rollout.Charge)),
    /// The field-wise sum of every settled attempt's reported usage, whatever
    /// its stop reason: the records the fold reckons its measured tokens and
    /// dollars from.
    reported: message.Usage,
    /// The summed reservations of settled attempts that were not measured,
    /// charged beside their reports.
    unknown: rollout.Charge,
    /// Retained output bytes charged for measured attempts, four a token.
    measured_output_bytes: Int,
  )
}

/// What the step charges the fold, read from the ledger at the moment the
/// step settles: the turn count, the composition digests, the summed usage
/// records and the worst case of every attempt that is not measured, which
/// counts a reservation still open when the step reads.
pub type Charged {
  Charged(
    /// Admitted attempts.
    turns: Int,
    /// Composition digests, oldest first.
    digests: List(String),
    /// Every settled attempt's reported usage, summed field-wise.
    usage: message.Usage,
    /// The worst case of each unmeasured attempt, settled or still open.
    unreported: rollout.Unreported,
  )
}

/// The reservation actor holds the ledger and the clock and nothing else:
/// no runtime, no secrets and no large effect closures.
type Reservation {
  Reservation(ledger: Ledger, clock: Clock)
}

/// All messages and state precede handlers so the lifetime is visible together.
type Message {
  /// The request guard asks, from the pump that will run the attempt.
  Admit(
    pump: Pid,
    target: record.ModelScope,
    digest: String,
    reply: Subject(Result(Int, String)),
  )

  /// The gateway reports how the attempt a pump ran ended.
  Settled(pump: Pid, settlement: rollout.Settlement)

  /// The step reads what the trial is charged so far.
  Count(reply: Subject(Charged))

  Stop
}

/// Native admission capability and its retained retirement witness identity.
type Guard {
  Guard(pid: Pid, requests: Subject(Message))
}

/// Builds real coding callbacks from the native session opener and fixture scorer.
/// The opener must honor the supplied guarded gateway and exact profile override,
/// and the scorer must grade the isolated fixture independently of model text.
///
/// ## Examples
///
/// ```gleam
/// // rollout_host.callbacks(gateway, clock, fresh_session, fixture_check)
/// ```
pub fn callbacks(
  base: gateway.Gateway,
  clock: Clock,
  open: fn(rollout.TrialRequest, gateway.Gateway) -> Result(Running, String),
  score: fn(rollout.Task, String) -> Result(rollout.Grade, String),
) -> rollout.Callbacks {
  rollout.Callbacks(mode: rollout.LiveProduction, clock:, open: fn(request) {
    // Extract and validate resolved model target.
    use target <- result.try(case request.target {
      model.ForResolved(target) -> Ok(target)
      model.ForRole(..) -> Error("a rollout must use one exact resolved target")
    })

    use card <- result.try(
      gateway.card_for(base, target.provider)
      |> result.map_error(fn(_) {
        "a live rollout requires a native pricing card"
      }),
    )
    use guard <- result.try(start_guard(request, target, card, clock))

    // The guard closure and the settlement observer both run in the pump
    // that owns the attempt, so the pump's pid is the key that pairs a
    // settlement with the reservation it releases. The gateway reports the
    // settlement before it delivers the terminal, so the credit lands before
    // any request the answer provokes can ask for admission.
    let guarded =
      gateway.with_request_guard(base, fn(actual, api_name, provider_request) {
        use output <- result.try(
          call.try_call(guard.requests, waiting: 5000, sending: Admit(
            process.self(),
            record.ModelScope(actual.provider, actual.model_id, api_name),
            prompt.fingerprint(provider_request.system, provider_request.tools),
            _,
          ))
          |> result.map_error(fn(_) {
            "the rollout admission owner is unavailable"
          })
          |> result.flatten,
        )
        Ok(
          model.ProviderRequest(
            ..provider_request,
            target: model.ForResolved(actual),
            max_output_tokens: Some(output),
          ),
        )
      })
      |> gateway.with_attempt_settled(fn(settled) {
        process.send(
          guard.requests,
          Settled(process.self(), settlement_of_attempt(settled)),
        )
      })

    // Wrap optional prompt profile in singleton list for profile middleware.
    let profiles = case request.profile {
      None -> []
      Some(profile) -> [profile]
    }

    use guarded <- result.try(
      gateway.with_profiles(guarded, profiles, prompt.fingerprint, fn(_) {
        Ok(Nil)
      }),
    )

    // Attempt to open trial execution runtime with guarded client.
    case open(request, guarded) {
      Error(reason) -> {
        let _retired = stop_guard(guard)
        Error(reason)
      }
      Ok(running) -> {
        let runtime = running.runtime
        let workspace = running.workspace
        let retire = running.retire
        let task = request.task
        Ok(rollout.Trial(
          step: fn(allowance) { run(runtime, request, guard, clock, allowance) },
          score: fn(criteria) {
            case criteria == task.criteria {
              True -> score(task, workspace)
              False -> Error("the fixed independent criterion changed")
            }
          },
          close: retirement.sequence(
            retire,
            retirement.repeat(fn() { stop_guard(guard) }),
          ),
          cleanup: running.cleanup,
        ))
      }
    }
  })
}

/// Starts the background token reservation actor guarding rollout quota.
fn start_guard(
  request: rollout.TrialRequest,
  target: model.ResolvedModel,
  card: pricing.Pricing,
  clock: Clock,
) -> Result(Guard, String) {
  let state =
    Reservation(
      ledger: open_ledger(request.allowance, target, request.api, card),
      clock:,
    )
  actor.new(state)
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Guard(started.pid, started.data) })
  |> result.map_error(string.inspect)
}

/// Processes messages to the rollout reservation actor.
fn handle(
  state: Reservation,
  message: Message,
) -> actor.Next(Reservation, Message) {
  // Match incoming request message variant.
  case message {
    Stop -> actor.stop()
    Count(reply) -> {
      process.send(reply, charged(state.ledger))
      actor.continue(state)
    }
    Admit(pump, target, digest, reply) -> {
      let #(now, clock) = clock.read(state.clock)
      let #(allowed, ledger) = reserve(state.ledger, pump, target, digest, now)
      process.send(reply, allowed)
      actor.continue(Reservation(ledger:, clock:))
    }

    // A settlement the ledger refuses, because no reservation is open for
    // that pump or it was already credited, changes nothing: the worst case
    // already debited stands, which is the conservative side of the error.
    Settled(pump, settlement) -> {
      let ledger =
        settle(state.ledger, pump, settlement)
        |> result.unwrap(state.ledger)
      actor.continue(Reservation(..state, ledger:))
    }
  }
}

/// Opens the ledger a trial's guard keeps, holding the allowance the fold
/// handed the trial and nothing reserved yet.
///
/// ## Examples
///
/// ```gleam
/// // rollout_host.open_ledger(request.allowance, target, request.api, card)
/// ```
pub fn open_ledger(
  allowance: rollout.Allowance,
  target: model.ResolvedModel,
  api: String,
  card: pricing.Pricing,
) -> Ledger {
  Ledger(
    scope: record.ModelScope(target.provider, target.model_id, api),
    target:,
    card:,
    opened: allowance,
    attempts: 0,
    digests: [],
    open: [],
    reported: accounting.zero_usage(),
    unknown: rollout.Charge(0, 0.0, 0, rollout.WorstCase),
    measured_output_bytes: 0,
  )
}

/// What the ledger has left: the opened allowance less `charged`, reckoned
/// exactly as `rollout.accept_step` reckons a step, so the fold's allowance
/// after it accounts the step this ledger reports is this value.
///
/// ## Examples
///
/// ```gleam
/// // rollout_host.remaining(ledger).tokens
/// ```
pub fn remaining(ledger: Ledger) -> rollout.Allowance {
  let Charged(turns:, usage:, unreported:, ..) = charged(ledger)
  let opened = ledger.opened
  let used =
    int.max(
      usage.total_tokens,
      usage.input + usage.output + usage.cache_read + usage.cache_write,
    )
  rollout.Allowance(
    ..opened,
    turns: opened.turns - turns,
    tokens: opened.tokens - used - unreported.tokens,
    dollars: opened.dollars -. usage.cost.total -. unreported.dollars,
    output_bytes: opened.output_bytes
      - ledger.measured_output_bytes
      - unmeasured(ledger).output_bytes,
  )
}

/// What the trial is charged so far, as the step hands it to the fold. An
/// attempt still open when the step reads is charged the reservation it was
/// admitted under, because the fold accounts the step once and a settlement
/// that arrives after the read has nobody left to credit.
///
/// ## Examples
///
/// ```gleam
/// // rollout_host.charged(ledger).unreported
/// ```
pub fn charged(ledger: Ledger) -> Charged {
  let unmeasured = unmeasured(ledger)
  Charged(
    turns: ledger.attempts,
    digests: list.reverse(ledger.digests),
    usage: ledger.reported,
    unreported: rollout.Unreported(unmeasured.tokens, unmeasured.dollars),
  )
}

/// Everything charged at a reservation rather than a measurement: settled
/// attempts that were not measured, and every reservation still open.
fn unmeasured(ledger: Ledger) -> rollout.Charge {
  list.fold(ledger.open, ledger.unknown, fn(sum, open) {
    let #(_, reserved) = open
    rollout.Charge(
      sum.tokens + reserved.tokens,
      sum.dollars +. reserved.dollars,
      sum.output_bytes + reserved.output_bytes,
      rollout.WorstCase,
    )
  })
}

/// Admits one attempt for a pump, or refuses it. The attempt's output
/// ceiling is pinned to the least of the target's own, the tokens the
/// allowance has left over three context windows, and a quarter of the
/// bytes it has left, so a target whose whole ceiling does not fit the
/// door's caps still runs at the ceiling that does; the request guard pins
/// that ceiling on the request, which is what makes charging the clipped
/// reservation sound. The attempt is debited `rollout.reservation` at that
/// ceiling at once, and that is the figure it keeps if it never settles or
/// settles unmeasured. A pump with a reservation still open is refused,
/// because the gateway settles each attempt before the next request from
/// that pump can ask, so a second ask is a pairing the ledger could not
/// settle exactly.
///
/// ## Examples
///
/// ```gleam
/// // let #(Ok(max_output), ledger) = rollout_host.reserve(ledger, pump, scope, digest, now)
/// ```
pub fn reserve(
  ledger: Ledger,
  pump: Pid,
  target: record.ModelScope,
  digest: String,
  now: Int,
) -> #(Result(Int, String), Ledger) {
  let left = remaining(ledger)
  let context = ledger.target.context_window
  let output =
    int.min(
      ledger.target.max_output_tokens,
      int.min(left.tokens - context * 3, left.output_bytes / 4),
    )
  let reserved = rollout.reservation(ledger.target, output, ledger.card)
  let ledger =
    Ledger(..ledger, digests: list.take([digest, ..ledger.digests], 100))

  // Evaluate remaining balance against the reservation at the pinned
  // ceiling; a positive ceiling already fits the tokens and the bytes.
  case
    target == ledger.scope
    && now < left.deadline_ms
    && left.turns > 0
    && output > 0
    && reserved.dollars <=. left.dollars
    && list.key_find(ledger.open, pump) == Error(Nil)
  {
    False -> #(
      Error(
        "exact rollout target or aggregate reservation budget refused request",
      ),
      ledger,
    )
    True -> #(
      Ok(output),
      Ledger(..ledger, attempts: ledger.attempts + 1, open: [
        #(pump, reserved),
        ..ledger.open
      ]),
    )
  }
}

/// Settles the attempt a pump had open by `rollout.attempt_charge`: the
/// attempt's reported usage joins the summed records whatever its stop
/// reason, and an attempt that is not measured keeps its own reservation
/// charged beside its report. A pump with no open reservation, which
/// includes one already settled, is refused and the ledger is unchanged.
///
/// ## Examples
///
/// ```gleam
/// // let Ok(ledger) = rollout_host.settle(ledger, pump, settlement)
/// ```
pub fn settle(
  ledger: Ledger,
  pump: Pid,
  settlement: rollout.Settlement,
) -> Result(Ledger, String) {
  // Only a pump with an attempt still open can settle, so a second
  // settlement of one attempt, and one for an attempt never admitted, both
  // find nothing to credit.
  use reserved <- result.try(
    list.key_find(ledger.open, pump)
    |> result.replace_error(
      "no admitted attempt of this request awaits settlement",
    ),
  )

  let charge =
    rollout.attempt_charge(
      ledger.target,
      ledger.scope.api,
      settlement,
      reserved,
      ledger.card,
    )
  let settled =
    Ledger(
      ..ledger,
      open: list.filter(ledger.open, fn(open) { open.0 != pump }),
      reported: accounting.add_usage(ledger.reported, settlement.usage),
    )

  // A measured attempt is charged its record alone; any other keeps its
  // reservation charged on top of that record.
  case charge.basis {
    rollout.Measured ->
      Ok(
        Ledger(
          ..settled,
          measured_output_bytes: settled.measured_output_bytes
            + charge.output_bytes,
        ),
      )
    rollout.WorstCase ->
      Ok(
        Ledger(
          ..settled,
          unknown: rollout.Charge(
            settled.unknown.tokens + reserved.tokens,
            settled.unknown.dollars +. reserved.dollars,
            settled.unknown.output_bytes + reserved.output_bytes,
            rollout.WorstCase,
          ),
        ),
      )
  }
}

/// The tripwire between the guard's ledger and the session's own: every
/// request a trial makes crosses the guarded gateway, so the session's usage
/// ledger can never carry more than the guard charged. More is spend the
/// guard never admitted, and the step refuses rather than letting it ride
/// under a charge that does not include it. Dollars are compared to the
/// rounding the two sums' orders can differ by; tokens are the fold's own
/// reckoning of each sum.
///
/// ## Examples
///
/// ```gleam
/// // rollout_host.cross_check(charged.usage, stats.usage) == Ok(Nil)
/// ```
pub fn cross_check(
  charged: message.Usage,
  session: message.Usage,
) -> Result(Nil, String) {
  let reckon = fn(usage: message.Usage) {
    int.max(
      usage.total_tokens,
      usage.input + usage.output + usage.cache_read + usage.cache_write,
    )
  }

  // Either sum exceeding the guard's is spend that bypassed it.
  case
    reckon(session) > reckon(charged)
    || session.cost.total >. charged.cost.total +. 0.000000001
  {
    True ->
      Error(
        "the session's usage ledger exceeds the admission ledger: spend bypassed the guarded gateway",
      )
    False -> Ok(Nil)
  }
}

/// Reads the gateway's settlement report as the fold's settlement shape.
fn settlement_of_attempt(
  settled: gateway.AttemptSettled,
) -> rollout.Settlement {
  rollout.Settlement(
    scope: record.ModelScope(
      settled.target.provider,
      settled.target.model_id,
      settled.api,
    ),
    usage: settled.usage,
    response: case settled.ending {
      gateway.Responded(stop_reason:) -> rollout.Answered(stop_reason:)
      gateway.Unanswered -> rollout.Unanswered
    },
  )
}

/// Executes a coding task step in the runtime environment and measures resource metrics.
fn run(
  runtime: api.Runtime,
  request: rollout.TrialRequest,
  guard: Guard,
  clock: Clock,
  allowance: rollout.Allowance,
) -> Result(rollout.Step, String) {
  let #(now, _) = clock.read(clock)
  use operation <- result.try(
    api.prompt(runtime, [
      message.UserMessage(
        content: [message.UserText(request.task.prompt, None)],
        timestamp: now,
        origin: None,
      ),
    ])
    |> result.map_error(fn(_) {
      "the real coding operation could not be admitted"
    }),
  )

  // Await operation settlement and summarize the resulting progress.
  let observed_result =
    api.await_result(
      runtime,
      operation,
      within_ms: int.max(allowance.deadline_ms - now, 0),
    )

  // Categorize result outcome into trial progress state.
  let progress = case observed_result {
    Error(Nil) ->
      rollout.Interrupted(
        "the real coding operation did not settle within its wall budget",
      )
    Ok(operation.RunLastResult(outcome: operation.RunCompleted(..), ..)) ->
      rollout.Finished
    Ok(operation.RunLastResult(outcome: operation.RunFailed(error), ..)) ->
      rollout.Interrupted("coding operation failed: " <> error.code)
    Ok(operation.RunLastResult(outcome: operation.RunAborted, ..)) ->
      rollout.Interrupted("coding operation was cancelled")
    Ok(operation.CompactionLastResult(..))
    | Ok(operation.NavigationLastResult(..)) ->
      rollout.Interrupted("trial did not settle a coding operation")
  }

  use stats <- result.try(
    storage.stats(runtime.session.store)
    |> result.map_error(fn(_) { "rollout ledger observation failed" }),
  )
  use entries <- result.try(
    storage.scan_entries(
      runtime.session.store,
      storage.entry_scan() |> storage.entry_limit(256),
    )
    |> result.map_error(fn(_) { "rollout source observation failed" }),
  )

  // Ensure entry count does not overflow maximum scan limits.
  use Nil <- result.try(case list.length(entries) < 256 {
    True -> Ok(Nil)
    False -> Error("rollout source scan exceeded its bounded inventory")
  })

  // The guard is the one source of the step's charge. A live trial is one
  // step, since this function never answers `Continue`, so the ledger's
  // cumulative figures are the step's figures; a reservation still open at
  // this read is charged its worst case and a settlement arriving after it
  // credits nothing the fold will ever see.
  use Charged(turns:, digests: composition_digests, usage:, unreported:) <- result.try(
    call.try_call(guard.requests, waiting: 5000, sending: Count)
    |> result.map_error(fn(_) { "rollout attempt count is unavailable" }),
  )
  use Nil <- result.try(cross_check(usage, stats.usage))

  // Aggregate tool executions and assistant scrubbed output.
  let tools =
    list.count(entries, fn(entry) {
      case entry {
        entry.MessageEntry(
          message: message.ToolResultMessage(is_error: False, ..),
          ..,
        ) -> True
        _ -> False
      }
    })
  let output =
    entries
    |> list.flat_map(fn(entry) {
      case entry {
        entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
          list.filter_map(content, fn(block) {
            case block {
              message.AssistantText(text:, ..) ->
                Ok(trace.scrub_excerpt(text, 1024))
              message.AssistantThinking(..) | message.AssistantToolCall(..) ->
                Error(Nil)
            }
          })
        entry.MessageEntry(..)
        | entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> []
      }
    })
    |> string.join("\n")

  // Confirm exact model target remains resolved.
  use target <- result.try(case request.target {
    model.ForResolved(target) -> Ok(target)
    model.ForRole(..) -> Error("rollout exact identity disappeared")
  })

  Ok(rollout.Step(
    target: record.ModelScope(target.provider, target.model_id, request.api),
    profile_id: case request.profile {
      None -> None
      Some(profile) -> Some(provider_profile_id(profile))
    },
    usage:,
    turns:,
    tool_executions: tools,
    output:,
    progress:,
    composition_digests:,
    unreported:,
  ))
}

fn provider_profile_id(profile: provider_profile.Profile) -> String {
  provider_profile.fields(profile).0
}

fn stop_guard(guard: Guard) -> Result(Nil, String) {
  case process.is_alive(guard.pid) {
    False -> Ok(Nil)
    True -> stop_live_guard(guard)
  }
}

/// Stops an active guard actor process and verifies clean termination.
fn stop_live_guard(guard: Guard) -> Result(Nil, String) {
  let monitor = process.monitor(guard.pid)
  process.send(guard.requests, Stop)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down.reason })
    |> process.selector_receive(5000)
  process.demonitor_process(monitor)

  // Verify whether the guard stopped under normal conditions.
  case stopped {
    Ok(process.Normal) -> Ok(Nil)
    _ -> Error("rollout admission owner retirement is unconfirmed")
  }
}
