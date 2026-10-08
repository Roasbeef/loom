//// The executor's real workspace plane, driven through the real host and
//// surface in one VM.
////
//// Everything here runs the production factory over a temporary checkout and
//// the shipped sandbox helper, so it proves the placement claim directly: the
//// tools behind the host are the tools a local session runs, only the caller
//// is a message. The host is registered in this VM and the surface addresses
//// the local node, as `surface_test` does with a fake plane. The two-node case
//// is `remote_nodes_test`.

import broker/exec
import client/catalog
import client/codemode
import client/executor_plane
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/jobs
import client/owner_codemode
import client/owner_codemode_test
import client/owner_services.{type OwnerServices}
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/workspaces.{Workspace}
import core/clock
import core/json
import core/message
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/secret
import runtime/effects.{type ToolOutcome, type ToolRun}
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import telemetry/log
import tools/tool

@external(erlang, "client_test_ffi", "function_values")
fn function_values(term: a) -> Int

@external(erlang, "client_test_ffi", "wire_round_trip")
fn wire_round_trip(term: a) -> a

// An executor over a fresh temporary checkout: the host running the real
// factory, and the paths the tests look at.
type Rig {
  Rig(
    host_pid: process.Pid,
    address: address.Address(RemoteCensus),
    checkout: String,
    state: String,
    port: owner_port.Port,
  )
}

fn absolute(path: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/" <> path
}

fn machine(state: String, seed: Option(String)) -> executor_plane.Machine {
  executor_plane.Machine(
    state_root: state,
    helper_path: absolute("../sandbox/loom-exec"),
    helper_pool_size: 4,
    demand: exec.BestEffort,
    workspace: catalog.default_workspace(),
    tools: catalog.default_tools(),
    deactivated_tools: [],
    lsp_servers: [],
    jobs_policy: jobs.default_policy,
    codemode_seed: Some(option.unwrap(seed, state <> "/no-such-seed")),
    secrets: secret.env(),
    home: None,
    logger: log.discard(),
  )
}

fn rig() -> Rig {
  rig_with(None)
}

// A rig whose code-mode seed is `seed`, when there is one, and otherwise a
// path that holds nothing, so that no `code_mode` tool is registered.
fn rig_with(seed: Option(String)) -> Rig {
  rig_over(
    seed,
    fixtures.quiet_services(),
    absolute(fixtures.scratch("executor-plane")),
  )
}

// A rig whose owner port serves `services`, which is what the executor's
// workspace calls back into, under the directory `scratch`.
fn rig_over(
  seed: Option(String),
  services: OwnerServices,
  scratch: String,
) -> Rig {
  let checkout = scratch <> "/checkout"
  let state = scratch <> "/state"
  let assert Ok(Nil) = simplifile.create_directory_all(checkout)
    as "the checkout is created"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state root is created"
  let assert Ok(checkout) = bootstrap.canonical_directory(checkout)
    as "the checkout resolves"
  let assert Ok(state) = bootstrap.canonical_directory(state)
    as "the state root resolves"
  let factory =
    executor_plane.factory(machine(state, seed), [Workspace("proj", checkout)])
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("executor_plane_host"),
      ledger_path: state <> "/exec-ledger.db",
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory:,
    ))
    as "the host starts"
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services:,
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
    ))
    as "the owner port starts"
  Rig(host_pid: started.pid, address: started.data, checkout:, state:, port:)
}

fn stop(rig: Rig) -> Nil {
  process.unlink(rig.host_pid)
  process.kill(rig.host_pid)
}

fn config(
  rig: Rig,
  session: String,
  workspace: String,
  incarnation: Int,
) -> surface.Config(RemoteCensus) {
  surface.Config(
    address: rig.address,
    session:,
    workspace:,
    incarnation:,
    port: rig.port,
    read_authority: fn(_run) { Ok(fixtures.authority()) },
    reconnect: fn() { Ok(Nil) },
    remote_tools: ["fs_write", "fs_read", "bash", "code_mode"],
    attach_within_ms: 60_000,
    mint_token: surface.strong_token,
  )
}

fn attached(rig: Rig, incarnation: Int) -> surface.Attachment(RemoteCensus) {
  let assert Ok(attachment) =
    surface.attach(config(rig, "s1", "proj", incarnation))
    as "the attach succeeds"
  attachment
}

fn call(
  name: String,
  arguments: List(#(String, json.JsonValue)),
  n: Int,
) -> ToolRun {
  let base = fixtures.tool_run("call_" <> int.to_string(n), n)
  let arguments = json.Object(arguments)
  effects.ToolRun(
    ..base,
    call: message.ToolCall(..base.call, name:, arguments:),
    arguments:,
  )
}

// The text a completed tool call returned, or the reason it failed.
fn text_of(outcome: ToolOutcome) -> Result(String, String) {
  case outcome {
    effects.ToolFailed(reason:) -> Error(reason)
    effects.ToolCompleted(result: message.ToolResultMessage(content:, ..), ..) ->
      Ok(
        list.filter_map(content, fn(part) {
          case part {
            message.ToolResultText(text:, ..) -> Ok(text)
            message.ToolResultImage(..) -> Error(Nil)
          }
        })
        |> string.join("\n"),
      )
    effects.ToolCompleted(..) -> Error("not a tool result")
  }
}

fn close(
  rig: Rig,
  incarnation: Int,
) -> Result(protocol.CloseOutcome, protocol.Refusal) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Close(session: "s1", workspace: "proj", incarnation:, reply:),
  )
  let assert Ok(answer) = process.receive(reply, 60_000)
    as "the host answers a close"
  answer
}

pub fn a_real_plane_writes_reads_and_runs_a_shell_through_the_host_test() {
  let rig = rig()
  let attachment = attached(rig, 0)
  let remote = attachment.surface

  // The census describes this machine and names the tools it serves.
  let census = attachment.attached.census
  assert census.census.workspace == rig.checkout
  let names =
    list.map(census.tools, fn(described: tool.Described) { described.name })
  assert list.contains(names, "fs_write")
  assert list.contains(names, "bash")

  let path = rig.checkout <> "/hello.txt"
  let written =
    surface.run(
      remote,
      call(
        "fs_write",
        [#("path", json.String(path)), #("content", json.String("hello\n"))],
        0,
      ),
    )
  assert result.is_ok(text_of(written))

  // The file is in the executor's checkout, not anywhere the caller named.
  assert simplifile.read(path) == Ok("hello\n")
  let read =
    surface.run(remote, call("fs_read", [#("path", json.String(path))], 1))
  let assert Ok(text) = text_of(read)
  assert string.contains(text, "hello")

  let shell =
    surface.run(remote, call("bash", [#("command", json.String("echo hi"))], 2))
  let assert Ok(output) = text_of(shell)
  assert string.contains(output, "hi")
  stop(rig)
}

pub fn close_reports_all_retired_and_reopen_builds_a_new_plane_test() {
  let rig = rig()
  let _first = attached(rig, 0)
  let scope = rig.state <> "/scopes/s1"
  assert simplifile.is_directory(scope) == Ok(True)

  // The helper pool's own retirement result is the witness.
  assert close(rig, 0) == Ok(protocol.AllRetired)
  assert simplifile.is_directory(scope) == Ok(False)

  // Reopening at the next incarnation builds a plane that works.
  let reopened = attached(rig, 1)
  let shell =
    surface.run(
      reopened.surface,
      call("bash", [#("command", json.String("echo again"))], 0),
    )
  let assert Ok(output) = text_of(shell)
  assert string.contains(output, "again")
  assert close(rig, 1) == Ok(protocol.AllRetired)
  stop(rig)
}

pub fn a_workspace_the_executor_does_not_serve_is_refused_test() {
  let rig = rig()
  let assert Error(protocol.NoPlane(reason)) =
    surface.attach(config(rig, "s2", "nowhere", 0))
    |> result.map(fn(_attachment) { Nil })
  assert string.contains(reason, "serves no workspace named `nowhere`")

  // A session name that cannot name a directory is refused the same way.
  let assert Error(protocol.NoPlane(reason)) =
    surface.attach(config(rig, "../escape", "proj", 0))
    |> result.map(fn(_attachment) { Nil })
  assert string.contains(reason, "not usable as a directory name")
  stop(rig)
}

pub fn a_checkout_that_vanished_is_refused_at_attach_test() {
  let rig = rig()
  let assert Ok(Nil) = simplifile.delete(rig.checkout)
  let assert Error(protocol.NoPlane(reason)) =
    surface.attach(config(rig, "s1", "proj", 0))
    |> result.map(fn(_attachment) { Nil })
  assert string.contains(reason, "is not a directory on this executor")
  stop(rig)
}

pub fn the_census_is_plain_data_with_no_function_values_test() {
  let rig = rig()
  let census = attached(rig, 0).attached.census

  // A closure in the census would serialize here and fail to decode on the
  // orchestrator, so the walk looks for any function value in the whole term.
  assert function_values(census) == 0

  // And the term survives the trip a distribution connection gives it.
  assert wire_round_trip(census) == census
  stop(rig)
}

pub fn a_maximum_size_file_read_fits_the_reservation_test() {
  let rig = rig()
  let remote = attached(rig, 0).surface
  let path = rig.checkout <> "/big.txt"
  let assert Ok(Nil) = simplifile.write(path, string.repeat("a", 8_388_608))
  let read =
    surface.run(remote, call("fs_read", [#("path", json.String(path))], 0))
  assert result.is_ok(text_of(read))
  stop(rig)
}

// --- retirement ------------------------------------------------------------

fn gone() -> Result(Nil, String) {
  Ok(Nil)
}

fn stuck() -> Result(Nil, String) {
  Error("the helper pool is still retiring")
}

fn nothing() -> Nil {
  Nil
}

pub fn only_the_helper_witness_reports_all_retired_test() {
  let all = [
    #(custody.Namespace, gone),
    #(custody.Broker, gone),
    #(custody.Helpers, gone),
  ]
  assert executor_plane.retire(nothing, gone, all) == protocol.AllRetired
}

pub fn a_helper_pool_that_did_not_retire_is_unknown_cleanup_test() {
  let pending = [
    #(custody.Namespace, gone),
    #(custody.Broker, gone),
    #(custody.Helpers, stuck),
  ]
  assert executor_plane.retire(nothing, gone, pending)
    == protocol.UnknownCleanup(count: 1)
}

pub fn a_scope_with_no_helper_cleanup_has_no_witness_test() {
  // Every filed cleanup succeeded, and still nothing proves the helpers are
  // gone, so the scope cannot be called retired.
  let no_pool = [#(custody.Namespace, gone), #(custody.Broker, gone)]
  assert executor_plane.retire(nothing, gone, no_pool)
    == protocol.UnknownCleanup(count: 1)
  assert executor_plane.retire(nothing, gone, [])
    == protocol.UnknownCleanup(count: 1)
}

pub fn children_that_did_not_stop_are_counted_test() {
  let all = [#(custody.Broker, gone), #(custody.Helpers, gone)]
  assert executor_plane.retire(nothing, stuck, all)
    == protocol.UnknownCleanup(count: 1)
  let both = [#(custody.Broker, stuck), #(custody.Helpers, stuck)]
  assert executor_plane.retire(nothing, stuck, both)
    == protocol.UnknownCleanup(count: 3)
}

pub fn cleanups_run_in_shutdown_order_whatever_order_they_were_filed_test() {
  let order = process.new_subject()
  let step = fn(name) {
    fn() {
      process.send(order, name)
      Ok(Nil)
    }
  }
  let filed = [
    #(custody.Namespace, step("namespace")),
    #(custody.Helpers, step("helpers")),
    #(custody.Broker, step("broker")),
  ]
  let outcome =
    executor_plane.retire(
      fn() { process.send(order, "servers") },
      fn() {
        process.send(order, "children")
        Ok(Nil)
      },
      filed,
    )
  assert outcome == protocol.AllRetired
  let seen =
    list.map([1, 2, 3, 4, 5], fn(_n) {
      let assert Ok(name) = process.receive(order, 1000)
      name
    })
  assert seen == ["servers", "children", "broker", "helpers", "namespace"]
}

// The prepared build seed beside the repository, when this host has a
// toolchain to run it with. Code mode registers only where both exist.
fn prepared_seed() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let seed = here <> "/../../build/codemode-seed"
  case codemode.discover(seed) {
    Ok(_toolchain) -> Ok(seed)
    Error(reason) -> Error(reason)
  }
}

pub fn a_plane_offers_code_mode_the_owner_bound_capabilities_test() {
  case prepared_seed() {
    Error(reason) ->
      io.println_error(
        "SKIP a_plane_offers_code_mode_the_owner_bound_capabilities: " <> reason,
      )
    Ok(seed) -> {
      let rig = rig_with(Some(seed))
      let census = attached(rig, 0).attached.census
      let assert Ok(code_mode) =
        list.find(census.tools, fn(described: tool.Described) {
          described.name == "code_mode"
        })
        as "an executor with a toolchain registers code_mode"

      // The executor has no Agency, notes door or mailbox of its own. What
      // the model is told it may call there comes from the owner-bound
      // configuration the factory applied, and the owner answers the calls.
      list.each(
        ["strand.spawn", "notes.put", "schedule.create", "peer.roster"],
        fn(cap) {
          assert string.contains(code_mode.description, cap)
        },
      )
      stop(rig)
    }
  }
}

// A program which calls two owner-bound capabilities and reports.
const owner_program =
  "import cap/notes
import cap/report
import cap/strand
import gleam/int
import gleam/list

pub fn main() -> report.Outcome {
  case strand.roster() {
    Ok(peers) -> write(list.length(peers))
    Error(error) -> report.failure(strand.error_text(error))
  }
}

fn write(peers: Int) -> report.Outcome {
  case notes.put(\"proof\", report.string(\"from the executor\")) {
    Ok(Nil) -> report.text(\"note written, roster of \" <> int.to_string(peers))
    Error(error) -> report.failure(notes.error_text(error))
  }
}
"

pub fn a_program_on_the_executor_reaches_the_owners_doors_test() {
  case exec.unjailed_skip_reason(exec.host_platform()), prepared_seed() {
    option.Some(reason), _ ->
      io.println_error("SKIP a_program_reaches_the_owners_doors: " <> reason)
    option.None, Error(reason) ->
      io.println_error("SKIP a_program_reaches_the_owners_doors: " <> reason)
    option.None, Ok(seed) -> {
      let seen = process.new_subject()
      let services =
        owner_services.OwnerServices(
          ..fixtures.quiet_services(),
          capability: owner_codemode.answering(
            codemode.owner_serving(
              codemode.BothSeams,
              over: owner_codemode_test.agency_over(seen),
              schedules: None,
            ),
            peers: owner_codemode_test.mailbox(seen),
          ),
          holds: fn(_caller, _tool) { Ok(Nil) },
        )
      let rig = rig_over(Some(seed), services, shallow_scratch())
      let remote = attached(rig, 0).surface

      // A real compile in the executor's jail and a real satellite, whose two
      // capability calls cross the owner port to doors that are not on the
      // executor. The note is written for the strand the call named.
      let outcome =
        surface.run(
          remote,
          call(
            "code_mode",
            [
              #("program", json.String(owner_program)),
              #("within_ms", json.Int(240_000)),
            ],
            0,
          ),
        )
      let assert Ok(text) = text_of(outcome)
      assert string.contains(text, "note written, roster of 0")
      assert process.receive(seen, 1000) == Ok("roster main")
      assert process.receive(seen, 1000) == Ok("note main proof")
      stop(rig)
      let _removed = simplifile.delete_all([rig.checkout, rig.state])
      Nil
    }
  }
}

// A code-mode execution binds a unix socket under the state root, and a socket
// path may be about a hundred bytes, so a program test keeps its state in a
// shallow directory of its own. It is not under /tmp, which the jail replaces.
fn shallow_scratch() -> String {
  let directory =
    "/var/tmp/.loom-executor-plane-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete_all([directory])
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the shallow scratch directory is created"
  directory
}
