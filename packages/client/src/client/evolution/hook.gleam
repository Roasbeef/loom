//// Promoted hooks preserve every native predecessor while generation custody
//// serializes a complete before-tool, tool and after-tool sequence.
////
//// A generic invocation already enters the generation owner itself. Its outer
//// runtime wrapper therefore delegates directly, avoiding owner re-entry.
//// Promoted hooks join future events. The native session_start event belongs
//// to session boot and is not replayed during activation or recovery.

import client/evolution/live
import client/extension/hooks
import core/clock
import core/codec
import core/json
import core/message.{type AgentMessage}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/effects

/// Composes the promoted tool hook phases over the existing runtime slots.
///
/// Each closure retains only its predecessor slot. Native clearance remains
/// unchanged; the promoted gate runs immediately before dispatch inside the
/// same captured generation as the settled-result transform.
///
/// ## Examples
///
/// ```gleam
/// // hook.wire(built, generation_owner)
/// ```
///
pub fn wire(built: effects.Effects, owner: live.Live) -> effects.Effects {
  let run = built.tools.run
  let context = built.hooks.context
  let started = built.hooks.run_start
  let ended = built.hooks.run_end
  let compact = built.hooks.compaction_note
  let usage = built.hooks.usage
  let time = built.clock
  effects.Effects(
    ..built,
    tools: effects.ToolSurface(..built.tools, run: fn(request: effects.ToolRun) {
      case request.call.name {
        "evolution_invoke"
        | "evolution_propose"
        | "evolution_test"
        | "evolution_inspect"
        | "evolution_catalogue" -> run(request)
        _native ->
          live.run(
            owner,
            fn(generation) { run_with(generation, request, run) },
            120_000,
          )
      }
    }),
    hooks: effects.Hooks(
      ..built.hooks,
      run_start: fn(operation) {
        let baseline = started(operation)
        let #(now, _) = clock.read(time)
        let encoded =
          live.fold(
            owner,
            fn(generation) {
              let added = case generation {
                Some(active) ->
                  case active.hooks {
                    Some(bus) ->
                      hooks.run_start_injections(bus, operation, "main", now)
                    None -> []
                  }
                None -> []
              }
              json.Array(list.map(
                list.append(baseline, added),
                codec.encode_message,
              ))
            },
            json.Array(list.map(baseline, codec.encode_message)),
            60_000,
          )
        decode_messages(encoded, baseline)
      },
      run_end: fn(operation) {
        let answer = ended(operation)
        live.notice(owner, fn(generation) {
          notify(generation, hooks.AgentEnd(operation))
        })
        answer
      },
      usage: fn(operation, row) {
        usage(operation, row)
        live.notice(owner, fn(generation) {
          notify(generation, hooks.Usage(operation, row))
        })
      },
      compaction_note: fn(operation, cue) {
        let baseline = compact(operation, cue)
        let encoded =
          live.fold(
            owner,
            fn(generation) {
              let added = case generation {
                Some(active) ->
                  case active.hooks {
                    Some(bus) -> hooks.compaction_notes(bus, operation, cue)
                    None -> []
                  }
                None -> []
              }
              json.Array(list.map(list.append(baseline, added), json.String))
            },
            json.Array(list.map(baseline, json.String)),
            60_000,
          )
        case encoded {
          json.Array(items) ->
            list.filter_map(items, fn(item) {
              case item {
                json.String(text) -> Ok(text)
                _other -> Error(Nil)
              }
            })
          _other -> baseline
        }
      },
      context: fn(operation, messages) {
        let baseline = context(operation, messages)
        let encoded =
          live.fold(
            owner,
            fn(generation) {
              let folded = case generation {
                None -> baseline
                Some(active) ->
                  case active.hooks {
                    None -> baseline
                    Some(bus) -> hooks.fold_context(bus, operation, baseline)
                  }
              }
              json.Array(list.map(folded, codec.encode_message))
            },
            json.Array(list.map(baseline, codec.encode_message)),
            60_000,
          )
        decode_messages(encoded, baseline)
      },
    ),
  )
}

fn run_with(
  generation: Option(live.Generation),
  request: effects.ToolRun,
  predecessor: fn(effects.ToolRun) -> effects.ToolOutcome,
) -> effects.ToolOutcome {
  case generation {
    None -> predecessor(request)
    Some(active) ->
      case active.hooks {
        None -> predecessor(request)
        Some(bus) ->
          gated(
            bus,
            request,
            predecessor,
            hooks.gate(
              bus,
              request.operation,
              request.call.name,
              request.arguments,
              request.source_index,
            ),
          )
      }
  }
}

fn gated(
  bus: hooks.Bus,
  request: effects.ToolRun,
  predecessor: fn(effects.ToolRun) -> effects.ToolOutcome,
  verdict: hooks.Verdict,
) -> effects.ToolOutcome {
  case verdict {
    hooks.Block(extension:, reason:) ->
      effects.ToolFailed(
        extension <> " blocked " <> request.call.name <> ": " <> reason,
      )
    hooks.Allow ->
      case predecessor(request) {
        effects.ToolFailed(reason:) -> effects.ToolFailed(reason:)
        effects.ToolCompleted(result:, terminate:) ->
          effects.ToolCompleted(
            result: hooks.fold_tool_result(bus, result),
            terminate:,
          )
      }
  }
}

fn decode_messages(
  value: json.JsonValue,
  fallback: List(AgentMessage),
) -> List(AgentMessage) {
  case value {
    json.Array(items) ->
      list.try_map(items, codec.decode_message)
      |> result.unwrap(fallback)
    _other -> fallback
  }
}

fn notify(generation: Option(live.Generation), event: hooks.Event) -> Nil {
  case generation {
    None -> Nil
    Some(active) ->
      case active.hooks {
        None -> Nil
        Some(bus) -> {
          let _ = hooks.notice_sync(bus, event)
          Nil
        }
      }
  }
}
