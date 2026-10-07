import broker/broker
import broker/exec
import broker/policy
import client/gateway_test
import client/working_directory
import core/clock
import core/ids
import core/json
import core/workspace
import gleam/option.{None, Some}
import gleam/result
import runtime/api
import simplifile
import support/notes_session
import tools/directory_access
import tools/fs
import tools/tool
import tools/working_directory as directory

fn ctx(workspace: String, strand: String) -> tool.Ctx {
  tool.Ctx(
    workspace: tool.LocalWorkspace(workspace, fs.real_filesystem()),
    strand:,
    op_id: ids.mint_op(ids.generator(clock.fixed(1000), 638)).0,
    step_id: "directory-test",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [#("TMPDIR", workspace <> "/.codemode/tmp")],
    clock: clock.fixed(1000),
    owner_blobs: tool.OwnerBlobs(workspace <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_, _) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

pub fn registered_context_refuses_before_fetching_the_local_fact_store_test() {
  let assert Ok(scope) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "workspace",
      "executor",
      1,
      1,
    )
    as "fixture scope is valid"
  let caller =
    tool.Ctx(
      ..ctx("/unused-owner-root", "main"),
      workspace: tool.RegisteredWorkspace(scope),
    )
  let door =
    working_directory.door(fn() {
      panic as "registered directory fetched the local fact store"
    })
  assert door.read(caller)
    == Error("working directory requires a local workspace")
  assert door.write(caller, "/owner/blobs")
    == Error("working directory requires a local workspace")
}

pub fn defaults_are_durable_and_strand_local_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "locate test workspace"
  let root = here <> "/build/cwd-store-test"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/review")
    as "create review directory"
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 638)).0
  let harness = gateway_test.reserved_fixture(id)
  let facts = api.fact_handle(harness.runtime)
  let door = working_directory.door(fn() { Ok(facts) })
  let main = ctx(root, "main")
  let child = ctx(root, "child")
  assert door.read(main) == Ok(root)
  let outcome =
    directory.tool(door).run(
      main,
      json.Object([#("path", json.String("review"))]),
    )
  assert !outcome.is_error
  assert working_directory.door(fn() { Ok(facts) }).read(main)
    == Ok(root <> "/review")
  assert door.read(child) == Ok(root)
  assert directory.select(door, main, Some("..")) == Ok(root)
  assert door.read(main) == Ok(root <> "/review")
  assert result.is_error(directory.select(door, main, Some("../../..")))
  let assert Ok(_) =
    api.put_reserved_fact(
      harness.runtime,
      "client/working_directory/main",
      json.Int(3),
    )
    as "plant corrupt state"
  assert result.is_error(door.read(main))
  let repaired =
    directory.tool(door).run(main, json.Object([#("path", json.String(root))]))
  assert !repaired.is_error
  assert door.read(main) == Ok(root)
  assert api.close(harness.runtime) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "remove directory fixture"
}

pub fn unavailable_directory_state_is_an_error_test() {
  let door = working_directory.door(fn() { Error(Nil) })
  assert door.read(ctx("/work", "main"))
    == Error("working directory store is unavailable")
  assert directory.select(door, ctx("/work", "main"), None)
    == Error("working directory store is unavailable")
}

pub fn shell_default_survives_sqlite_reopen_and_deleted_target_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "locate test workspace"
  let root = here <> "/build/cwd-reopen-test"
  let review = root <> "/review"
  let assert Ok(Nil) = simplifile.create_directory_all(review)
    as "create saved directory"
  let path = root <> "/session.db"
  let opened = notes_session.open(path, clock.fixed(1000))
  let facts = api.fact_handle(opened.runtime)
  let door = working_directory.door(fn() { Ok(facts) })
  let caller = ctx(root, "main")
  let saved =
    directory.tool(door).run(
      caller,
      json.Object([#("path", json.String(review))]),
    )
  assert !saved.is_error
  assert api.close(opened.runtime) == Ok(Nil)
  let reopened = notes_session.open(path, clock.fixed(1000))
  let facts = api.fact_handle(reopened.runtime)
  let restored = working_directory.door(fn() { Ok(facts) })
  assert restored.read(caller) == Ok(review)
  let assert Ok(Nil) = simplifile.delete_all([review])
    as "remove previous directory"
  assert result.is_error(restored.read(caller))
  let recovered =
    directory.tool(restored).run(
      caller,
      json.Object([#("path", json.String(root))]),
    )
  assert !recovered.is_error
  assert restored.read(caller) == Ok(root)
  assert api.close(reopened.runtime) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "remove persistence fixture"
}

pub fn remembered_directory_cannot_follow_a_replacement_symlink_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "locate test workspace"
  let root = here <> "/build/cwd-redirection-test"
  let selected = root <> "/review"
  let destination = root <> "/other"
  let assert Ok(Nil) = simplifile.create_directory_all(selected)
    as "create original directory"
  let assert Ok(Nil) = simplifile.create_directory_all(destination)
    as "create alternate directory"
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 639)).0
  let harness = gateway_test.reserved_fixture(id)
  let facts = api.fact_handle(harness.runtime)
  let door = working_directory.door(fn() { Ok(facts) })
  let caller = ctx(root, "main")
  let saved =
    directory.tool(door).run(
      caller,
      json.Object([#("path", json.String(selected))]),
    )
  assert !saved.is_error
  let assert Ok(Nil) = simplifile.delete_all([selected])
    as "replace the canonical target"
  let assert Ok(Nil) = simplifile.create_symlink(destination, selected)
    as "redirect the saved spelling"
  assert result.is_error(door.read(caller))
  assert api.close(harness.runtime) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "remove redirection fixture"
}
