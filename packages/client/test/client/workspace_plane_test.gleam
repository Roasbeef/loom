//// The workspace half of a session, built alone: what `prepare` reads off the
//// machine, what `start_local` publishes to custody and in what order, and
//// that the session base is computed again once the owner's storage is open.
////
//// These tests build the half with no session behind it. The owner's
//// services are stubs which refuse or answer nothing, because the half
//// reaches the owner only through them, and that is the property under test.

import broker/broker
import broker/executor
import client/escalate
import client/internal/instance_owner as custody
import client/owned_assembly_test
import client/owner_services
import client/serve
import client/wiring
import client/workspace_plane
import client/workspace_policy
import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import runtime/effects
import simplifile
import telemetry/log
import tools/directory_access
import weft/registry as address

// The owner's side of the seam as a test can state it: every function is the
// answer of an owner which holds nothing. The workspace half must run on
// exactly this, since a remote owner can be no more present than a stub.
fn absent_owner() -> owner_services.OwnerServices {
  owner_services.local(
    handle: fn() { Error(Nil) },
    runtime: fn() { Error(Nil) },
    escalate: escalate.none().refused,
    output: wiring.unobserved(),
    capability: owner_services.no_capability,
    holds: fn(_caller, _tool) { Ok(Nil) },
  )
}

fn files(settings: serve.Settings) -> workspace_policy.OwnerFiles {
  workspace_policy.OwnerFiles(
    index: settings.session_path <> ".index",
    memory_store: settings.session_path <> ".memory",
    memory_digest: settings.session_path <> ".digest",
  )
}

fn prepared(settings: serve.Settings) -> workspace_plane.Prepared {
  let assert Ok(prepared) =
    workspace_plane.prepare(
      serve.workspace_spec(settings, Some(files(settings))),
      reading: workspace_policy.env_text,
    )
    as "a workspace with no toolchain still prepares"
  prepared
}

// Everything `start_local` publishes to custody, in the order it publishes
// it, with the cleanup it registered. The fixture closes them last to first,
// which is what custody does with the parts it holds.
type Published {
  Published(part: custody.Part, cleanup: fn() -> Result(Nil, String))
}

fn attach(
  published: process.Subject(Published),
  namespace: address.Registry,
) -> workspace_plane.Attach {
  workspace_plane.Attach(
    logger: log.discard(),
    namespace:,
    retain: fn(part, cleanup, transfer) {
      process.send(published, Published(part:, cleanup:))
      transfer()
      Ok(Nil)
    },
    owner: absent_owner(),
    session_label: fn() { Error(Nil) },
    code_mode: workspace_plane.CodeModeAttach(
      arms: fn(config) { config },
      tool: fn(_config) {
        panic as "this fixture has no toolchain, so code mode is never built"
      },
    ),
  )
}

fn drain(
  published: process.Subject(Published),
  collected: List(Published),
) -> List(Published) {
  case process.receive(published, 0) {
    Ok(one) -> drain(published, [one, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}

// Starts the half, hands the caller the local start, and closes what was
// published in teardown order afterwards, so no helper outlives the test.
fn with_started(
  settings: serve.Settings,
  body: fn(workspace_plane.Prepared, workspace_plane.Local, List(Published)) ->
    Nil,
) -> Nil {
  let prepared = prepared(settings)
  let published = process.new_subject()
  let assert Ok(namespace) = address.start() as "a namespace for the plane"
  let assert Ok(local) =
    workspace_plane.start_local(prepared, attach(published, namespace))
    as "the half starts with the helper the fixture ships"
  let parts = drain(published, [])
  body(prepared, local, parts)
  list.each(list.reverse(parts), fn(each) {
    let _closed = each.cleanup()
    Nil
  })
  let _stopped = address.stop(namespace)
  Nil
}

pub fn prepare_reads_the_machine_and_makes_its_directories_test() {
  let settings = owned_assembly_test.settings()
  let prepared = prepared(settings)
  let census = prepared.census
  assert census.workspace == settings.workspace
  assert census.shell == workspace_policy.shell_path
  assert census.lsp_servers == []
  assert census.warnings == []
  assert simplifile.is_directory(settings.workspace) == Ok(True)
  assert simplifile.is_directory(prepared.blob_root) == Ok(True)
  assert simplifile.is_directory(settings.session_path <> ".tmp") == Ok(True)
  assert list.key_find(census.env, "PATH") |> result.is_ok
    as "the tool environment is built at prepare, not at start"
}

pub fn prepare_refuses_a_base_the_sandbox_cannot_enforce_before_any_directory_test() {
  let settings = owned_assembly_test.settings()
  let broken =
    serve.Settings(
      ..settings,
      base_policy: workspace_policy.base_policy("relative/workspace"),
    )
  let refused =
    workspace_plane.prepare(
      serve.workspace_spec(broken, None),
      reading: workspace_policy.env_text,
    )
  assert result.is_error(refused)
  assert simplifile.is_directory(settings.session_path <> ".tmp") == Ok(False)
    as "a refused base leaves no directory behind"
}

pub fn start_publishes_helpers_then_broker_to_custody_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, parts <- with_started(settings)
  assert list.map(parts, fn(each) { each.part })
    == [custody.Helpers, custody.Broker]
    as "the executor service is published before the broker, as it always was"
  let plane = local.started.plane
  assert list.map(plane.fatal, fn(root) { root.0 })
    == [
      "the helper pool",
      "the executor service",
      "the capability broker",
    ]
  assert process.is_alive(executor.pid(local.executor))
  assert result.is_ok(broker.pid(plane.broker))
  Nil
}

// The second session base. The memory digest is masked only once the file
// exists, because the jail refuses to mask a missing path under a read-only
// parent, and the digest sits beside the session file and outside the
// workspace. A file which appears between `prepare` and `start_local` (the
// owner's storage probes do this) is therefore missing from the first base
// and must be present in the second, and the census a start returns carries
// the second.
pub fn start_masks_the_files_which_appeared_since_prepare_test() {
  let settings = owned_assembly_test.settings()
  let digest = files(settings).memory_digest
  let prepared = prepared(settings)
  assert !list.contains(prepared.census.base_policy.protected, digest)
    as "the digest does not exist yet, so prepare cannot mask it"
  let assert Ok(Nil) = simplifile.write(digest, "a digest")
    as "the owner's storage creates the file after prepare"

  let published = process.new_subject()
  let assert Ok(namespace) = address.start() as "a namespace for the plane"
  let assert Ok(local) =
    workspace_plane.start_local(prepared, attach(published, namespace))
    as "the half starts"
  let parts = drain(published, [])
  let masked = local.started.plane.census.base_policy.protected
  list.each(list.reverse(parts), fn(each) {
    let _closed = each.cleanup()
    Nil
  })
  let _stopped = address.stop(namespace)
  assert list.contains(masked, digest)
    as "the second base is the one the processes run under"
}

pub fn the_decls_are_the_tools_in_registration_order_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  assert list.map(local.started.decls, fn(each) { each.name })
    == [
      "bash",
      "grep",
      "fs_read",
      "fs_write",
      "fs_edit",
      "job_poll",
      "job_kill",
      "job_send",
      "working_directory",
    ]
  assert list.map(local.tools, fn(each) { each.name })
    == list.map(local.started.decls, fn(each) { each.name })
  Nil
}

pub fn a_deactivated_tool_is_not_in_the_workspaces_registry_test() {
  let settings = owned_assembly_test.settings()
  let settings = serve.Settings(..settings, deactivated_tools: ["bash"])
  use _prepared, local, _parts <- with_started(settings)
  assert !list.contains(
    list.map(local.started.decls, fn(each) { each.name }),
    "bash",
  )
  Nil
}

// `run` is the workspace half of `wiring.run_tool` and refuses stale
// authority before it dispatches, whatever the tool is.
pub fn run_revalidates_stored_authority_on_the_workspaces_machine_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  let shared = settings.workspace <> "/shared"
  let elsewhere = settings.workspace <> "/elsewhere"
  let assert Ok(Nil) = simplifile.create_directory_all(elsewhere)
    as "the other target exists"
  let assert Ok(Nil) = simplifile.create_symlink(elsewhere, shared)
    as "the recorded name now resolves elsewhere"
  let stale =
    wiring.Authority(
      access: directory_access.Access([shared], []),
      standing: [],
    )
  let outcome = local.started.plane.run(a_run("grep"), stale)
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: True, ..),
    ..,
  ) = outcome
    as "the call is refused in band"
  assert string.contains(text_of(outcome), "canonical target")
  Nil
}

pub fn run_dispatches_a_tool_over_the_workspaces_registry_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  let path = settings.workspace <> "/note.txt"
  let assert Ok(Nil) = simplifile.write(path, "from the workspace")
    as "a file to read"
  let authority =
    wiring.Authority(access: directory_access.none(), standing: [])
  let run =
    effects.ToolRun(
      ..a_run("fs_read"),
      arguments: json.Object([#("path", json.String(path))]),
    )
  let outcome = local.started.plane.run(run, authority)
  assert string.contains(text_of(outcome), "from the workspace")
  Nil
}

pub fn an_unknown_tool_settles_in_band_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  let authority =
    wiring.Authority(access: directory_access.none(), standing: [])
  let outcome = local.started.plane.run(a_run("no_such_tool"), authority)
  assert string.contains(text_of(outcome), "unavailable")
  Nil
}

pub fn resolve_directory_answers_from_the_workspaces_filesystem_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  let inside = settings.workspace <> "/lib"
  let assert Ok(Nil) = simplifile.create_directory_all(inside)
    as "a directory to add"
  let plane = local.started.plane
  assert plane.resolve_directory("lib", "read") |> result.is_ok
  assert plane.resolve_directory("missing", "read") |> result.is_error
  Nil
}

pub fn prompt_facts_read_the_workspaces_instruction_files_lazily_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  let assert Ok(Nil) =
    simplifile.write(settings.workspace <> "/AGENTS.md", "Be brief.")
    as "an instruction file written after the half started"
  let assert Ok(facts) = local.started.plane.prompt_facts()
    as "the facts are read when asked for"
  assert list.map(facts.guidance, fn(file) { file.text }) == ["Be brief."]
  Nil
}

pub fn close_is_safe_with_no_language_server_test() {
  let settings = owned_assembly_test.settings()
  use _prepared, local, _parts <- with_started(settings)
  local.started.plane.close()
  local.started.plane.close()
  Nil
}

fn a_run(tool_name: String) -> effects.ToolRun {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  effects.ToolRun(
    operation:,
    step_id: "turn-1:tools",
    source_index: 0,
    strand: "main",
    call: message.ToolCall(
      id: "call_1",
      name: tool_name,
      arguments: json.Object([]),
      thought_signature: None,
      namespace: None,
    ),
    arguments: json.Object([]),
    replay: operation.ReplayNever,
    grants: [],
  )
}

fn text_of(outcome: effects.ToolOutcome) -> String {
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(content:, ..),
    ..,
  ) = outcome
    as "a tool always completes in band"
  content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join(with: "\n")
}
