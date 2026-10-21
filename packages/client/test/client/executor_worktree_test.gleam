//// A worktree workspace served by the real executor host: the plane a session
//// gets is built over its own tree, the tools work in it, and the close settles
//// it (protocol-change/095).
////
//// This is the end of the path the unit tests in `worktrees_test` cannot reach.
//// It runs the production factory, host and surface over a real repository in
//// one VM, with the shipped sandbox helper, so what a tool sees as its
//// workspace and what the jail lets it read are the real ones.

import broker/exec
import client/catalog
import client/executor_plane
import client/internal/ffi_os
import client/jobs
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import core/clock
import core/json
import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import provider/secret
import runtime/effects.{type ToolOutcome, type ToolRun}
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/worktree_rig.{type Rig, exists, git, session, write}
import telemetry/log

type Plane {
  Plane(
    rig: Rig,
    host_pid: process.Pid,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    port: owner_port.Port,
  )
}

fn machine(rig: Rig) -> executor_plane.Machine {
  executor_plane.Machine(
    state_root: rig.state,
    helper_path: helper(),
    helper_pool_size: 4,
    demand: exec.BestEffort,
    workspace: catalog.default_workspace(),
    tools: catalog.default_tools(),
    deactivated_tools: [],
    lsp_servers: [],
    jobs_policy: jobs.default_policy,
    codemode_seed: Some(rig.state <> "/no-such-seed"),
    secrets: secret.env(),
    home: None,
    logger: log.discard(),
    mcp_servers: [],
  )
}

fn helper() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/../sandbox/loom-exec"
}

fn plane(name: String) -> Plane {
  serve(worktree_rig.rig(name))
}

fn serve(rig: Rig) -> Plane {
  let factory = executor_plane.factory(machine(rig), [rig.workspace], rig.trees)
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("executor_worktree_host"),
      ledger_path: rig.ledger_path,
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      execution_result_bytes: host.default_execution_result_bytes,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory:,
    ))
    as "the host starts"
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
    ))
    as "the owner port starts"
  Plane(rig:, host_pid: started.pid, address: started.data, port:)
}

fn stop(plane: Plane) -> Nil {
  process.unlink(plane.host_pid)
  process.kill(plane.host_pid)
}

fn config(
  plane: Plane,
  n: Int,
  incarnation: Int,
) -> surface.Config(RemoteCensus) {
  surface.Config(
    address: plane.address,
    session: session(n),
    workspace: "repo",
    incarnation:,
    port: plane.port,
    read_authority: fn(_run) { Ok(fixtures.authority()) },
    reconnect: fn() { Ok(Nil) },
    remote_tools: ["fs_write", "fs_read", "bash"],
    attach_within_ms: 120_000,
    mint_token: surface.strong_token,
  )
}

fn attached(plane: Plane, n: Int, incarnation: Int) {
  let assert Ok(attachment) = surface.attach(config(plane, n, incarnation))
    as "the attach succeeds"
  attachment
}

fn close(plane: Plane, n: Int, incarnation: Int) -> protocol.CloseOutcome {
  let reply = process.new_subject()
  address.deliver(
    plane.address,
    protocol.Close(session: session(n), workspace: "repo", incarnation:, reply:),
  )
  let assert Ok(Ok(outcome)) = process.receive(reply, 120_000)
    as "the host answers a close"
  outcome
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

fn text_of(outcome: ToolOutcome) -> String {
  case outcome {
    effects.ToolFailed(reason:) -> "FAILED: " <> reason
    effects.ToolCompleted(result: message.ToolResultMessage(content:, ..), ..) ->
      list.filter_map(content, fn(part) {
        case part {
          message.ToolResultText(text:, ..) -> Ok(text)
          message.ToolResultImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    effects.ToolCompleted(..) -> "not a tool result"
  }
}

fn bash(
  attachment: surface.Attachment(RemoteCensus),
  command: String,
  n: Int,
) -> String {
  surface.run(
    attachment.surface,
    call("bash", [#("command", json.String(command))], n),
  )
  |> text_of
}

fn tree_of(plane: Plane, n: Int) -> String {
  plane.rig.state <> "/worktrees/repo/" <> session(n)
}

// Rewrites the README of the attachment's own workspace.
fn overwrite(
  attachment: surface.Attachment(RemoteCensus),
  n: Int,
  text: String,
) -> ToolOutcome {
  let path = attachment.attached.census.census.workspace <> "/README"
  surface.run(
    attachment.surface,
    call(
      "fs_write",
      [#("path", json.String(path)), #("content", json.String(text))],
      n,
    ),
  )
}

// --- the plane is built over the tree -------------------------------------------

pub fn a_worktree_session_works_in_its_own_tree_and_can_commit_there_test() {
  let plane = plane("plane")
  let attachment = attached(plane, 1, 0)
  let census = attachment.attached.census

  // The tools' workspace is the tree, and the census says which branch it is.
  assert census.census.workspace == tree_of(plane, 1)
  assert census.branch == Some("loom/" <> session(1))
  assert string.contains(bash(attachment, "pwd", 0), tree_of(plane, 1))

  // A write lands in the tree and never in the repository's own checkout.
  let written =
    surface.run(
      attachment.surface,
      call(
        "fs_write",
        [
          #("path", json.String(tree_of(plane, 1) <> "/README")),
          #("content", json.String("edited by the session\n")),
        ],
        1,
      ),
    )
  assert !string.contains(text_of(written), "FAILED")
  assert simplifile.read(plane.rig.root <> "/README") == Ok("one\n")

  // The linked worktree's Git directories are writable in the jail, so a
  // commit works, and it lands on the session's branch in the shared store.
  let committed =
    bash(
      attachment,
      "git -c user.name=T -c user.email=t@example.invalid commit -q -am work && echo committed",
      2,
    )
  assert string.contains(committed, "committed")
  assert git(plane.rig.root, ["log", "--format=%s", "loom/" <> session(1)])
    == "work\nfirst"
  assert close(plane, 1, 0) == protocol.AllRetired
  stop(plane)
}

pub fn two_sessions_edit_the_same_file_without_interfering_test() {
  let plane = plane("pair")
  let first = attached(plane, 1, 0)
  let second = attached(plane, 2, 0)
  assert first.attached.census.census.workspace
    != second.attached.census.census.workspace

  let _ = overwrite(first, 0, "from one\n")
  let _ = overwrite(second, 1, "from two\n")

  assert simplifile.read(tree_of(plane, 1) <> "/README") == Ok("from one\n")
  assert simplifile.read(tree_of(plane, 2) <> "/README") == Ok("from two\n")
  assert simplifile.read(plane.rig.root <> "/README") == Ok("one\n")
  assert close(plane, 1, 0) == protocol.AllRetired
  assert close(plane, 2, 0) == protocol.AllRetired
  stop(plane)
}

// --- the close settles the tree -------------------------------------------------

pub fn a_clean_close_removes_the_tree_even_after_code_mode_wrote_dot_codemode_test() {
  let plane = plane("clean")
  let attachment = attached(plane, 1, 0)
  let _ =
    bash(attachment, "mkdir -p .codemode/work && echo x > .codemode/work/y", 0)
  assert exists(tree_of(plane, 1) <> "/.codemode/work/y")

  assert close(plane, 1, 0) == protocol.AllRetired

  assert !exists(tree_of(plane, 1))
  assert git(plane.rig.root, ["branch", "--list", "loom/" <> session(1)]) != ""
  stop(plane)
}

pub fn a_close_with_changes_keeps_the_tree_and_the_next_attach_adopts_it_test() {
  let plane = plane("keep")
  let first = attached(plane, 1, 0)
  let _ = bash(first, "echo precious > mine.txt", 0)

  // The scope closes cleanly; the tree does not go with it.
  assert close(plane, 1, 0) == protocol.AllRetired
  assert simplifile.read(tree_of(plane, 1) <> "/mine.txt") == Ok("precious\n")

  let again = attached(plane, 1, 1)
  assert again.attached.census.census.workspace == tree_of(plane, 1)
  assert string.contains(bash(again, "cat mine.txt", 5), "precious")
  assert close(plane, 1, 1) == protocol.AllRetired
  stop(plane)
}

pub fn a_failed_worktree_is_refused_with_gits_message_and_leaves_nothing_test() {
  let plane = serve(worktree_rig.rig_at("refused", "no-such-ref"))
  let assert Error(protocol.WorktreeFailed(reason)) =
    surface.attach(config(plane, 1, 0))
    |> result.map(fn(_attachment) { Nil })
  assert string.contains(reason, "no-such-ref")
  assert !exists(tree_of(plane, 1))

  // The scope stayed open, so a retry builds again and is refused the same way.
  let assert Error(protocol.WorktreeFailed(_)) =
    surface.attach(config(plane, 1, 0))
    |> result.map(fn(_attachment) { Nil })
  stop(plane)
}

// --- the sandbox ----------------------------------------------------------------

pub fn a_worktree_session_cannot_read_another_sessions_scope_or_tree_test() {
  let plane = plane("jail")

  // The other session attaches first, so it exists when this one's policy is
  // built and is masked from it.
  let other = attached(plane, 2, 0)
  let _ = bash(other, "echo SECRET-TREE > secret.txt", 0)
  write(
    plane.rig.state <> "/scopes/" <> session(2) <> "/secret.txt",
    "SECRET-SCOPE\n",
  )

  let mine = attached(plane, 1, 0)
  let _ = bash(mine, "echo own > own.txt", 0)

  // Its own tree is readable, so the denials below are the mask's.
  assert string.contains(bash(mine, "cat own.txt", 1), "own")
  let tree_read =
    bash(mine, "cat '" <> tree_of(plane, 2) <> "/secret.txt' 2>&1", 2)
  let tree_list = bash(mine, "ls '" <> tree_of(plane, 2) <> "' 2>&1", 3)
  let scope_read =
    bash(
      mine,
      "cat '"
        <> plane.rig.state
        <> "/scopes/"
        <> session(2)
        <> "/secret.txt' 2>&1",
      4,
    )
  assert !string.contains(tree_read, "SECRET-TREE")
  assert !string.contains(tree_list, "secret.txt")
  assert !string.contains(scope_read, "SECRET-SCOPE")

  assert close(plane, 1, 0) == protocol.AllRetired
  assert close(plane, 2, 0) == protocol.AllRetired
  stop(plane)
}
