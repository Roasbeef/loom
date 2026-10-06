//// Production rollout assembly uses the ordinary runtime and real tool effects.
////
//// The caller opens a fresh workspace fixture and native session with the
//// supplied gateway, and returns its runtime plus a witnessed retirement
//// capability. No direct-answer provider invocation substitutes for coding.
//// A small weft actor reserves worst-case provider usage before every actual
//// request; it is local to this evaluation and shares no default session cost.
//// Conservative reservations use the whole context window, so a trial can
//// refuse before exhausting the billed budget. Such a trial is inconclusive.

import broker/internal/call
import client/evolution/prompt
import client/evolution/record
import client/evolution/retirement
import client/evolution/rollout
import client/evolution/trace
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

/// The reservation actor holds no runtime, secrets or large effect closures.
type Reservation {
  Reservation(
    target: record.ModelScope,
    remaining: rollout.Allowance,
    context: Int,
    output: Int,
    card: pricing.Pricing,
    clock: Clock,
    attempts: Int,
    digests: List(String),
  )
}

/// All messages and state precede handlers so the lifetime is visible together.
type Message {
  Admit(
    target: record.ModelScope,
    digest: String,
    reply: Subject(Result(Int, String)),
  )
  Count(reply: Subject(#(Int, List(String))))
  Stop
}

/// Native admission capability and its retained retirement witness identity.
type Guard {
  Guard(pid: Pid, requests: Subject(Message))
}

/// Builds real coding callbacks from the native session opener and fixture scorer.
/// The opener must honor the supplied guarded gateway and exact profile override,
/// and the scorer must inspect the isolated fixture independently of model text.
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
  score: fn(rollout.Task, String) -> Result(trace.Outcome, String),
) -> rollout.Callbacks {
  rollout.Callbacks(mode: rollout.LiveProduction, clock:, open: fn(request) {
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
    let guarded =
      gateway.with_request_guard(base, fn(actual, api_name, provider_request) {
        use output <- result.try(
          call.try_call(guard.requests, waiting: 5000, sending: Admit(
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
    let profiles = case request.profile {
      None -> []
      Some(profile) -> [profile]
    }
    use guarded <- result.try(
      gateway.with_profiles(guarded, profiles, prompt.fingerprint, fn(_) {
        Ok(Nil)
      }),
    )
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
          step: fn(allowance) {
            run(runtime, request, guard, clock, allowance, card)
          },
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

fn start_guard(
  request: rollout.TrialRequest,
  target: model.ResolvedModel,
  card: pricing.Pricing,
  clock: Clock,
) -> Result(Guard, String) {
  let state =
    Reservation(
      target: record.ModelScope(target.provider, target.model_id, request.api),
      remaining: request.allowance,
      context: target.context_window,
      output: target.max_output_tokens,
      card:,
      clock:,
      attempts: 0,
      digests: [],
    )
  actor.new(state)
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Guard(started.pid, started.data) })
  |> result.map_error(string.inspect)
}

fn handle(
  state: Reservation,
  message: Message,
) -> actor.Next(Reservation, Message) {
  case message {
    Stop -> actor.stop()
    Count(reply) -> {
      process.send(reply, #(state.attempts, list.reverse(state.digests)))
      actor.continue(state)
    }
    Admit(target, digest, reply) -> {
      let #(allowed, next) = reserve(state, target, digest)
      process.send(reply, allowed)
      actor.continue(next)
    }
  }
}

fn reserve(
  state: Reservation,
  target: record.ModelScope,
  digest: String,
) -> #(Result(Int, String), Reservation) {
  let #(now, clock) = clock.read(state.clock)
  let state =
    Reservation(
      ..state,
      clock:,
      digests: list.take([digest, ..state.digests], 100),
    )
  let output =
    int.min(
      state.output,
      int.min(
        state.remaining.tokens - state.context * 3,
        state.remaining.output_bytes / 4,
      ),
    )
  let tokens = state.context * 3 + output
  let usage =
    message.Usage(
      ..storage.empty_usage(),
      input: state.context,
      output:,
      cache_read: state.context,
      cache_write: state.context,
    )
  let cost = pricing.price(usage, state.card).cost.total
  case
    target == state.target
    && now < state.remaining.deadline_ms
    && state.remaining.turns > 0
    && output > 0
    && tokens <= state.remaining.tokens
    && cost <=. state.remaining.dollars
  {
    False -> #(
      Error(
        "exact rollout target or aggregate reservation budget refused request",
      ),
      state,
    )
    True -> #(
      Ok(output),
      Reservation(
        ..state,
        attempts: state.attempts + 1,
        remaining: rollout.Allowance(
          ..state.remaining,
          turns: state.remaining.turns - 1,
          tokens: state.remaining.tokens - tokens,
          dollars: state.remaining.dollars -. cost,
          output_bytes: state.remaining.output_bytes - output * 4,
        ),
      ),
    )
  }
}

fn run(
  runtime: api.Runtime,
  request: rollout.TrialRequest,
  guard: Guard,
  clock: Clock,
  allowance: rollout.Allowance,
  card: pricing.Pricing,
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
  let observed_result =
    api.await_result(
      runtime,
      operation,
      within_ms: int.max(allowance.deadline_ms - now, 0),
    )
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
  use Nil <- result.try(case list.length(entries) < 256 {
    True -> Ok(Nil)
    False -> Error("rollout source scan exceeded its bounded inventory")
  })
  use #(turns, composition_digests) <- result.try(
    call.try_call(guard.requests, waiting: 5000, sending: Count)
    |> result.map_error(fn(_) { "rollout attempt count is unavailable" }),
  )
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
    usage: stats.usage,
    turns:,
    tool_executions: tools,
    output:,
    progress:,
    composition_digests:,
    unreported: unreported_debit(turns, target, request.api, entries, card),
  ))
}

/// Retains worst-case spend for attempts without complete exact-target usage.
/// Positive usage on an ordinary settled response releases its reservation;
/// synthetic errors, absent usage and unfinished attempts remain uncertain.
///
/// ## Examples
///
/// `unreported_debit(1, target, api, [], card)` retains one whole reservation.
pub fn unreported_debit(
  attempts: Int,
  target: model.ResolvedModel,
  api: String,
  entries: List(entry.Entry),
  card: pricing.Pricing,
) -> rollout.Unreported {
  let complete =
    list.count(entries, fn(entry) {
      case entry {
        entry.MessageEntry(
          message: message.AssistantMessage(
            provider:,
            model:,
            api: actual_api,
            stop_reason:,
            usage:,
            ..,
          ),
          ..,
        ) ->
          provider == target.provider
          && model == target.model_id
          && actual_api == api
          && stop_reason != message.Errored
          && usage.total_tokens > 0
        entry.MessageEntry(..)
        | entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> False
      }
    })
  let unknown = int.max(attempts - complete, 0)
  let maximum =
    message.Usage(
      ..storage.empty_usage(),
      input: target.context_window,
      output: target.max_output_tokens,
      cache_read: target.context_window,
      cache_write: target.context_window,
    )
  rollout.Unreported(
    unknown * { target.context_window * 3 + target.max_output_tokens },
    int.to_float(unknown) *. pricing.price(maximum, card).cost.total,
  )
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

fn stop_live_guard(guard: Guard) -> Result(Nil, String) {
  let monitor = process.monitor(guard.pid)
  process.send(guard.requests, Stop)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down.reason })
    |> process.selector_receive(5000)
  process.demonitor_process(monitor)
  case stopped {
    Ok(process.Normal) -> Ok(Nil)
    _ -> Error("rollout admission owner retirement is unconfirmed")
  }
}
