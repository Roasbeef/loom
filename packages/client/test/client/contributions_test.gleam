//// The tool registry as a list of contributions.
////
//// Two things are under test and they pull in opposite directions. The
//// built-in half must register exactly what it always did, plane by
//// plane, because the wire tool array is the provider cache's byte
//// prefix and a tool that quietly appeared or vanished would reprice
//// every session. The extension half must be refused the moment it
//// claims a name someone else holds, because a shadowed `bash` is a
//// sandbox argument about the wrong function.

import broker/broker
import broker/exec
import broker/policy
import client/contributions
import core/clock
import core/ids
import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tools/tool

// A tool an extension might contribute, under whatever name the test
// needs. Nothing about its behaviour matters here: registration is
// decided from the name alone.
fn contributed(name: String) -> tool.Tool {
  tool.Tool(
    name:,
    description: "A tool from outside the harness.",
    prompt_snippet: Some("`" <> name <> "` does something out of tree."),
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: fn(_workspace) { policy.workspace_default("/nonexistent") },
    run: fn(_ctx, _args) { tool.success("done") },
  )
}

fn extension(
  name: String,
  tools: List(tool.Tool),
) -> contributions.Contribution {
  contributions.Contribution(origin: contributions.Extension(name:), tools:)
}

fn built(
  contribution_list: List(contributions.Contribution),
) -> Result(List(String), contributions.Collision) {
  contributions.registry(contribution_list)
  |> result.map(tool.names)
}

// --- the built-in contributions -------------------------------------------

pub fn an_unwired_host_contributes_the_five_core_tools_test() {
  // Gating registration on the seam existing is arithmetic rather than
  // tidiness: a permanently-refusing definition would be paid for on
  // every request of every strand for the life of the session.
  let assert Ok(registry) =
    contributions.registry(contributions.built_in(None, None, None, None, None))
    as "the built-in contributions never collide"
  assert tool.names(registry)
    == ["bash", "fs_edit", "fs_read", "fs_write", "grep"]
}

pub fn the_host_makes_exactly_one_contribution_test() {
  // Every plane the harness compiles in is one origin, `code_mode`
  // included: gating on a plane is what `history_search`, `remember` and
  // the `schedule_*` tools already do, and none of them is a separate
  // origin either. An absent plane contributes nothing at all.
  let assert [contributions.Contribution(origin:, tools:)] =
    contributions.built_in(None, None, None, None, None)
    as "a host makes exactly one built-in contribution"
  assert origin == contributions.BuiltIn
  assert list.length(tools) == 5
}

pub fn the_core_tools_lead_the_registration_order_test() {
  // The order is what the system prompt's index reads, and the core
  // tools come first there because that is how an operator reads a list.
  let assert Ok(registry) =
    contributions.registry(contributions.built_in(None, None, None, None, None))
    as "the built-in contributions never collide"
  assert list.map(tool.registered(registry), fn(each) { each.name })
    == ["bash", "grep", "fs_read", "fs_write", "fs_edit"]
}

// --- collisions -----------------------------------------------------------

pub fn an_extension_may_not_shadow_a_built_in_test() {
  // The security argument for the whole seam: if an extension could
  // register `bash`, installing one would silently redefine what the
  // model's `bash` call does.
  let attempt =
    list.append(contributions.built_in(None, None, None, None, None), [
      extension("hostile", [contributed("bash")]),
    ])
  assert built(attempt)
    == Error(contributions.Collision(
      name: "bash",
      first: contributions.BuiltIn,
      second: contributions.Extension(name: "hostile"),
    ))
}

// --- deactivating a built-in ----------------------------------------------
//
// The ruling in two directions. An extension never overrides a built-in;
// an operator who wants an extension's tool to stand in for one
// deactivates the built-in first, and the name is then simply free.

pub fn a_deactivated_built_in_yields_its_name_test() {
  let attempt =
    list.append(contributions.built_in(None, None, None, None, None), [
      extension("hashline", [contributed("fs_edit")]),
    ])

  // Active, the built-in still wins the argument by refusing the boot.
  assert built(attempt)
    == Error(contributions.Collision(
      name: "fs_edit",
      first: contributions.BuiltIn,
      second: contributions.Extension(name: "hashline"),
    ))

  // Deactivated, the name is unclaimed and the extension's tool is the
  // only `fs_edit` the model can reach.
  let assert Ok(names) = built(contributions.deactivate(attempt, ["fs_edit"]))
    as "a deactivated built-in does not collide"
  assert list.contains(names, "fs_edit")
  assert list.length(list.filter(names, fn(name) { name == "fs_edit" })) == 1

  // And the rest of the built-ins are untouched by it.
  assert list.contains(names, "bash")
}

pub fn deactivation_reaches_built_ins_only_test() {
  // Deactivating an extension's tool would be a way to hand one
  // extension's name to another by configuration, which is the peer
  // shadowing this module refuses. The way to stop an extension's tool
  // is to uninstall the extension.
  let attempt = [
    extension("first", [contributed("web_search")]),
    extension("second", [contributed("web_search")]),
  ]
  assert built(contributions.deactivate(attempt, ["web_search"]))
    == Error(contributions.Collision(
      name: "web_search",
      first: contributions.Extension(name: "first"),
      second: contributions.Extension(name: "second"),
    ))
}

pub fn deactivating_a_tool_this_host_never_built_is_not_an_error_test() {
  // A shared configuration is used across hosts whose planes differ, so
  // naming a tool that is not here states a posture rather than a
  // mistake.
  let host = contributions.built_in(None, None, None, None, None)
  assert built(contributions.deactivate(host, ["code_mode", "no_such_tool"]))
    == built(host)
}

pub fn an_extension_may_not_shadow_a_peer_test() {
  // At one remove, the same argument: with last-wins between peers, the
  // install order would decide which of two tools the model reached.
  let attempt = [
    extension("first", [contributed("web_search")]),
    extension("second", [contributed("web_search")]),
  ]
  assert built(attempt)
    == Error(contributions.Collision(
      name: "web_search",
      first: contributions.Extension(name: "first"),
      second: contributions.Extension(name: "second"),
    ))
}

pub fn the_first_claim_is_the_one_that_holds_test() {
  // A collision names the earlier origin as `first` so that the refusal
  // can point at the newcomer as the thing to remove.
  let assert Error(collision) =
    contributions.registry([
      extension("early", [contributed("shared")]),
      extension("late", [contributed("shared")]),
    ])
    as "two extensions claiming one name must be refused"
  assert collision.first == contributions.Extension(name: "early")
  let message = contributions.collision_message(collision)
  assert string.contains(message, "`shared`")
  assert string.contains(message, "`early`")
  assert string.contains(message, "`late`")
}

pub fn a_contribution_may_still_override_itself_test() {
  // Within one contribution, last registration wins, exactly as
  // `tool.registry` has always behaved: a single author restating a name
  // is that author overriding themselves, not a shadowing.
  let quiet = tool.Tool(..contributed("web_search"), description: "quiet")
  let loud = tool.Tool(..contributed("web_search"), description: "loud")
  let assert Ok(registry) =
    contributions.registry([extension("only", [quiet, loud])])
    as "a repeat inside one contribution is an override, not a collision"
  let assert Ok(found) = tool.lookup(registry, "web_search")
    as "the overridden tool stays registered"
  assert found.description == "loud"
}

pub fn an_extension_adds_to_the_built_ins_test() {
  let with_extension =
    list.append(contributions.built_in(None, None, None, None, None), [
      extension("websearch", [contributed("web_search")]),
    ])
  assert built(with_extension)
    == Ok(["bash", "fs_edit", "fs_read", "fs_write", "grep", "web_search"])
}

pub fn a_contributed_tool_dispatches_like_any_other_test() {
  // The registry is a name table and has no memory of origins; dispatch
  // must not be able to tell a contributed tool from a built-in one.
  let assert Ok(registry) =
    contributions.registry([extension("only", [contributed("web_search")])])
    as "one extension alone cannot collide"
  let outcome = tool.dispatch(registry, a_ctx(), "web_search", json.Object([]))
  assert outcome.is_error == False
  assert outcome.terminate == tool.ContinueRun
}

// A context nothing under test reads: the contributed tool's `run`
// ignores it, and dispatch is decided from the name alone.
fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-contributions-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}
