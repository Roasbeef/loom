import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/bash
import tools/fs
import tools/grep
import tools/tool

fn ctx() -> tool.Ctx {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  fake_broker.ctx(
    workspace: "/work",
    filesystem:,
    now: 0,
    script: [],
    recorded:,
  )
}

fn full_registry() -> tool.Registry {
  tool.registry([
    bash.tool(),
    grep.tool(),
    fs.read_tool(),
    fs.write_tool(),
    fs.edit_tool(),
  ])
}

// --- registry ------------------------------------------------------------

pub fn registry_names_sorted_test() {
  assert tool.names(full_registry())
    == ["bash", "fs_edit", "fs_read", "fs_write", "grep"]
}

pub fn registry_lookup_test() {
  let assert Ok(found) = tool.lookup(full_registry(), "fs_read")
  assert found.name == "fs_read"
  assert tool.lookup(full_registry(), "nope") == Error(Nil)
}

pub fn unknown_tool_dispatch_is_structured_error_test() {
  let outcome = tool.dispatch(full_registry(), ctx(), "teleport", json.Null)
  assert outcome.is_error
  // pi §3.8: an unavailable tool is an ordinary is_error text result
  // and details are omitted — no invented value for a typed contract.
  assert outcome.details == None
  let assert [message.ToolResultText(text:, text_signature: _)] =
    outcome.content
  assert string.contains(text, "teleport")
  assert string.contains(text, "unavailable")
}

pub fn dispatch_runs_the_named_tool_test() {
  let context = ctx()
  let filesystem = context.filesystem
  let assert Ok(Nil) = filesystem.write("/work/f.txt", <<"content\n":utf8>>)
  let outcome =
    tool.dispatch(
      full_registry(),
      context,
      "fs_read",
      json.Object([#("path", json.String("f.txt"))]),
    )
  assert outcome.is_error == False
}

pub fn registered_keeps_registration_order_test() {
  // `names` is sorted for the provider cache's byte prefix; `registered`
  // is not, because the prompt's index reads in contribution order and
  // sorting there would scatter a host's own tools through the built-ins.
  let ordered = tool.registered(full_registry())
  assert list.map(ordered, fn(each) { each.name })
    == ["bash", "grep", "fs_read", "fs_write", "fs_edit"]
}

pub fn snippets_follow_registration_order_and_omit_the_silent_test() {
  // pi's rule, adopted whole: a tool with no `prompt_snippet` is absent
  // from the prompt's index and callable all the same, because the
  // authoritative definition is the wire tool array.
  let silent = tool.Tool(..fs.read_tool(), prompt_snippet: None)
  let registry =
    tool.registry([grep.tool(), silent, fs.write_tool(), bash.tool()])
  let assert Some(grep_snippet) = grep.tool().prompt_snippet
  let assert Some(write_snippet) = fs.write_tool().prompt_snippet
  let assert Some(bash_snippet) = bash.tool().prompt_snippet
  assert tool.snippets(registry) == [grep_snippet, write_snippet, bash_snippet]

  // Omission from the index is not removal from the registry.
  let assert Ok(_) = tool.lookup(registry, "fs_read")
}

pub fn every_core_tool_carries_a_snippet_test() {
  // A built-in with no snippet would be invisible in the prompt's index
  // while still being on the wire, which is the one inconsistency the
  // omission rule must not be used to create by accident.
  list.each(tool.registered(full_registry()), fn(each) {
    assert each.prompt_snippet != None
  })
}

pub fn snippet_rendering_is_deterministic_test() {
  // The tool bytes are the provider cache's prefix and the prompt is
  // pinned behind a one-hour breakpoint, so two renders of one registry
  // must be the same string, not merely the same set.
  assert tool.snippets(full_registry()) == tool.snippets(full_registry())
}

// --- terminate -----------------------------------------------------------

pub fn outcome_constructors_continue_the_run_test() {
  // Ending a run is a thing a tool has to say, never a thing it can
  // fall into: every constructor defaults to `ContinueRun`.
  assert tool.success("ok").terminate == tool.ContinueRun
  assert tool.failure("no").terminate == tool.ContinueRun
  assert tool.with_details(tool.success("ok"), json.Object([])).terminate
    == tool.ContinueRun
  assert tool.dispatch(full_registry(), ctx(), "teleport", json.Null).terminate
    == tool.ContinueRun
}

pub fn duplicate_name_keeps_later_tool_test() {
  let first = fs.read_tool()
  let second = tool.Tool(..fs.read_tool(), description: "override")
  let assert Ok(found) = tool.lookup(tool.registry([first, second]), "fs_read")
  assert found.description == "override"
}

// --- replay and schema contract ------------------------------------------

pub fn replay_flags_test() {
  // bash is Never (arbitrary external effect); everything else here is
  // Safe — fs_edit via its digest binding to the exact pre-image
  // content, fs_write via idempotent overwrite, reads trivially.
  assert bash.tool().replay == tool.Never
  assert grep.tool().replay == tool.Safe
  assert fs.read_tool().replay == tool.Safe
  assert fs.write_tool().replay == tool.Safe
  assert fs.edit_tool().replay == tool.Safe
}

pub fn every_tool_has_object_schema_test() {
  let names = ["bash", "grep", "fs_read", "fs_write", "fs_edit"]
  let registry = full_registry()
  list.each(names, fn(name) {
    let assert Ok(found) = tool.lookup(registry, name)
    let assert json.Object(fields) = found.schema
    let assert Ok(json.String("object")) = list.key_find(fields, "type")
    let assert Ok(json.Object(_)) = list.key_find(fields, "properties")
  })
}

// --- result message construction -----------------------------------------

pub fn to_result_message_test() {
  let outcome =
    tool.success("done")
    |> tool.with_details(json.Object([#("k", json.Int(1))]))
  let result =
    tool.to_result_message(
      outcome,
      tool_call_id: "call_9",
      tool_name: "bash",
      timestamp: 777,
    )
  assert result
    == message.ToolResultMessage(
      tool_call_id: "call_9",
      tool_name: "bash",
      content: [message.ToolResultText(text: "done", text_signature: None)],
      details: Some(json.Object([#("k", json.Int(1))])),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 777,
    )
}

pub fn failure_outcome_maps_to_is_error_message_test() {
  let result =
    tool.to_result_message(
      tool.failure("broken"),
      tool_call_id: "call_1",
      tool_name: "grep",
      timestamp: 0,
    )
  let assert message.ToolResultMessage(is_error: True, ..) = result
}
