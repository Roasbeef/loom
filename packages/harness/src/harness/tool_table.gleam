//// The tool half of `runtime/effects.Effects` which needs only the registry:
//// clearance, the replay and scheduling declarations, and the conversion of a
//// tool's outcome into the result message the runtime commits.
////
//// Everything here is registry-level. Clearance reads a registration's replay
//// declaration and nothing else, and the two declaration questions the
//// machine asks (is replay still safe, may this call run beside others) read
//// two words of a registration. They therefore take the declaration
//// projection (`tool.Declarations`) rather than the registry: `Effects` is a
//// record of closures copied into every process of a session assembly, BEAM
//// drops sharing when it copies, and a closure which held the registry to
//// answer a declaration question put a copy of every tool's executor into each
//// of those heaps.
////
//// Policy composition against a broker happens later, inside a tool's own
//// `clear_call`. A clearance here is not an execution grant.
////
//// ## Flow
////
//// `surface` assembles a `ToolSurface` from the declaration projection and a
//// run function. `clear` decides a planned call, `replay_still_safe` and
//// `execution_mode` answer the machine's declaration questions, and
//// `completed` is the one place a tool's outcome becomes the effect plane's
//// answer. `run_registry` is the whole run for a host with no workspace
//// machinery: a fresh context, `tool.dispatch`, and `finished`.

import core/clock.{type Clock}
import gleam/list
import gleam/option.{None}
import gleam/string
import machine/operation.{type ReplayPolicy}
import runtime/effects
import tools/tool.{type Registry}

/// Assembles the tool surface from a registry's declarations and a `run`
/// function. `recover` is left `None`: a host whose tools run in this VM has
/// nothing to ask about a call the runtime lost.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.surface(tool.declarations(registry), run)
/// ```
///
pub fn surface(
  declared: tool.Declarations,
  run: fn(effects.ToolRun) -> effects.ToolOutcome,
) -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(query) { clear(declared, query) },
    run:,
    replay_still_safe: fn(name) { replay_still_safe(declared, name) },
    execution_mode: fn(name) { execution_mode(declared, name) },
    recover: None,
  )
}

/// Clears one planned call at registry level: active and registered means
/// cleared with the model's arguments and the registration's replay policy;
/// anything else is refused, and the driver stages the reason as the ordinary
/// in-band error result.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.clear(tool.declarations(registry), query)
/// // -> effects.Cleared(effective_arguments: .., replay: ReplayNever)
/// ```
///
pub fn clear(
  declared: tool.Declarations,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  let name = query.call.name

  case list.contains(query.configuration.active_tool_names, name) {
    False ->
      effects.ClearanceRefused(
        reason: "the tool `"
        <> name
        <> "` is not active for this strand. The system prompt lists the "
        <> "session's tools, and a strand may hold fewer; this one can call "
        <> "only: "
        <> string.join(query.configuration.active_tool_names, ", ")
        <> ".",
      )
    True ->
      case tool.declared(declared, name) {
        Ok(declaration) ->
          effects.Cleared(
            effective_arguments: query.call.arguments,
            replay: replay_policy(declaration.replay),
          )
        Error(Nil) ->
          effects.ClearanceRefused(
            reason: "the tool `" <> name <> "` is unavailable",
          )
      }
  }
}

/// Whether the named tool's registration declares safe replay (pi section
/// 4.5: stored and current must both say safe). Unregistered names are never
/// safe.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.replay_still_safe(tool.declarations(registry), "fs_read")
/// //   == True
/// ```
///
pub fn replay_still_safe(declared: tool.Declarations, name: String) -> Bool {
  case tool.declared(declared, name) {
    Ok(declaration) ->
      case declaration.replay {
        tool.Safe -> True
        tool.Never -> False
      }
    Error(Nil) -> False
  }
}

/// The named tool's scheduling constraint, mapped from its registration.
/// Unregistered names report exclusive: the safe direction, and the clearance
/// which follows refuses them anyway.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.execution_mode(tool.declarations(registry), "fs_read")
/// //   == effects.ConcurrentExecution
/// ```
///
pub fn execution_mode(
  declared: tool.Declarations,
  name: String,
) -> effects.ExecutionMode {
  case tool.declared(declared, name) {
    Ok(declaration) ->
      case declaration.execution_mode {
        tool.Exclusive -> effects.ExclusiveExecution
        tool.Concurrent -> effects.ConcurrentExecution
      }
    Error(Nil) -> effects.ExclusiveExecution
  }
}

/// Maps the tool package's replay declaration onto the machine's persisted
/// replay policy.
///
/// ## Examples
///
/// ```gleam
/// assert tool_table.replay_policy(tool.Never) == operation.ReplayNever
/// ```
///
pub fn replay_policy(safety: tool.ReplaySafety) -> ReplayPolicy {
  case safety {
    tool.Never -> operation.ReplayNever
    tool.Safe -> operation.ReplaySafe
  }
}

/// The tool vocabulary's answer as the effect plane's frozen field.
///
/// `runtime/effects`, `machine` and `core` carry `terminate` as a `Bool`; the
/// tool vocabulary names it. This is the only place the two touch, and
/// therefore the only place the polarity is written down.
///
/// ## Examples
///
/// ```gleam
/// assert tool_table.terminates(tool.TerminateRun)
/// ```
///
pub fn terminates(terminate: tool.Terminate) -> Bool {
  case terminate {
    tool.ContinueRun -> False
    tool.TerminateRun -> True
  }
}

/// The one place a tool outcome becomes the effect plane's answer, shared by
/// the executed and the refused-to-run paths so both build the same shape.
/// Always `ToolCompleted`: dispatch is total and a tool failure is an in-band
/// `is_error` result, never a harness fault.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.completed(tool.success("ok"), run, now)
/// ```
///
pub fn completed(
  outcome: tool.ToolOutcome,
  run: effects.ToolRun,
  now: Int,
) -> effects.ToolOutcome {
  effects.ToolCompleted(
    result: tool.to_result_message(
      outcome,
      tool_call_id: run.call.id,
      tool_name: run.call.name,
      timestamp: now,
    ),
    terminate: terminates(outcome.terminate),
  )
}

/// `completed`, stamped with the time from an injected clock.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.finished(tool.failure("no"), run, clock.fixed(at: 0))
/// ```
///
pub fn finished(
  outcome: tool.ToolOutcome,
  run: effects.ToolRun,
  clock: Clock,
) -> effects.ToolOutcome {
  let #(now, _clock) = clock.read(clock)
  completed(outcome, run, now)
}

/// Runs one cleared call through a registry: a fresh context per call from
/// `context`, `tool.dispatch`, and the outcome wrapped as the result message
/// the runtime commits.
///
/// ## Examples
///
/// ```gleam
/// // tool_table.run_registry(registry, context, clock, run)
/// ```
///
pub fn run_registry(
  registry: Registry,
  context: fn(effects.ToolRun) -> tool.Ctx,
  clock: Clock,
  run: effects.ToolRun,
) -> effects.ToolOutcome {
  let outcome =
    tool.dispatch(registry, context(run), run.call.name, run.arguments)
  finished(outcome, run, clock)
}
