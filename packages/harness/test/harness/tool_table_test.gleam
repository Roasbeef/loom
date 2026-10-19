//// Registry-level clearance, the declaration answers and the tool wire render.

import broker/policy
import core/clock
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/option.{None}
import harness/provider
import harness/tool_table
import machine/operation
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import provider/model
import runtime/effects
import tools/tool

fn noop(
  name: String,
  replay: tool.ReplaySafety,
  mode: tool.ExecutionMode,
) -> tool.Tool {
  tool.Tool(
    name:,
    description: "the " <> name <> " tool",
    prompt_snippet: None,
    schema: json.Object([]),
    replay:,
    execution_mode: mode,
    requirements: policy.workspace_default,
    run: fn(_ctx, _arguments) { tool.success("ok") },
  )
}

fn registry() -> tool.Registry {
  tool.registry([
    noop("bash", tool.Never, tool.Exclusive),
    noop("grep", tool.Safe, tool.Concurrent),
  ])
}

fn query(name: String, active: List(String)) -> effects.ClearanceQuery {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 7))
  effects.ClearanceQuery(
    operation:,
    step_id: "step",
    source_index: 0,
    call: message.ToolCall(
      id: "call",
      name:,
      arguments: json.Object([]),
      thought_signature: None,
      namespace: None,
    ),
    configuration: StrandConfiguration(
      model: ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: ThinkingOff,
      active_tool_names: active,
    ),
    grants: [],
  )
}

pub fn an_active_registered_tool_is_cleared_with_its_replay_policy_test() {
  let declared = tool.declarations(registry())
  assert tool_table.clear(declared, query("bash", ["bash", "grep"]))
    == effects.Cleared(
      effective_arguments: json.Object([]),
      replay: operation.ReplayNever,
    )
  assert tool_table.clear(declared, query("grep", ["grep"]))
    == effects.Cleared(
      effective_arguments: json.Object([]),
      replay: operation.ReplaySafe,
    )
}

pub fn a_registered_tool_this_strand_does_not_hold_is_refused_test() {
  let declared = tool.declarations(registry())
  let assert effects.ClearanceRefused(reason:) =
    tool_table.clear(declared, query("bash", ["grep"]))
  assert reason
    == "the tool `bash` is not active for this strand. The system prompt "
    <> "lists the session's tools, and a strand may hold fewer; this one can "
    <> "call only: grep."
}

pub fn an_active_name_with_no_registration_is_unavailable_test() {
  let declared = tool.declarations(registry())
  assert tool_table.clear(declared, query("ghost", ["ghost"]))
    == effects.ClearanceRefused(reason: "the tool `ghost` is unavailable")
}

pub fn the_declaration_answers_fail_safe_for_an_unknown_name_test() {
  let declared = tool.declarations(registry())
  assert !tool_table.replay_still_safe(declared, "ghost")
  assert !tool_table.replay_still_safe(declared, "bash")
  assert tool_table.replay_still_safe(declared, "grep")
  assert tool_table.execution_mode(declared, "ghost")
    == effects.ExclusiveExecution
  assert tool_table.execution_mode(declared, "grep")
    == effects.ConcurrentExecution
}

pub fn only_the_terminating_vocabulary_sets_the_effect_planes_flag_test() {
  assert tool_table.terminates(tool.TerminateRun)
  assert !tool_table.terminates(tool.ContinueRun)
}

pub fn the_wire_render_is_sorted_unique_and_omits_unknown_names_test() {
  let definitions = provider.definitions(registry())
  assert dict.size(definitions) == 2
  let names =
    provider.tool_specs(definitions, ["grep", "ghost", "bash", "grep"])
    |> map_names
  assert names == ["bash", "grep"]
}

fn map_names(specs: List(model.ToolSpec)) -> List(String) {
  case specs {
    [] -> []
    [spec, ..rest] -> [spec.name, ..map_names(rest)]
  }
}
