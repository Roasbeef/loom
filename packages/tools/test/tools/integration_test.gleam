//// Feature-detected end-to-end test: builds the real `loom-exec`
//// helper with the Go toolchain, starts a real broker over it, and
//// runs `echo hello` through the bash tool. Skipped (with the reason
//// printed) when `go` is missing or the build fails.
////
//// The development container usually lacks bwrap, so the helper runs
//// degraded; the context demands `BestEffort` and asserts on the tool
//// result, not on enforcement the kernel here cannot provide.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import simplifile
import support/shell
import tools/bash
import tools/directory_access
import tools/fs
import tools/job
import tools/tool

// Builds the helper (cached by Go, so cheap per run) and returns a
// ready SpawnConfig, or the reason to skip.
fn helper_config() -> Result(#(exec.SpawnConfig, String), String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    option.Some(reason) -> Error(reason)
    option.None -> helper_config_here()
  }
}

fn helper_config_here() -> Result(#(exec.SpawnConfig, String), String) {
  case shell.find_executable("go") {
    Error(Nil) -> Error("go toolchain not on PATH")
    Ok(_go) -> {
      let assert Ok(here) = simplifile.current_directory()
      let work_dir = here <> "/build/integration"
      let helper_path = work_dir <> "/loom-exec"
      let workspace = work_dir <> "/work"
      let assert Ok(Nil) = simplifile.create_directory_all(workspace)
      let assert Ok(Nil) = simplifile.create_directory_all(work_dir <> "/tmp")
      let output =
        shell.os_cmd(
          "cd ../sandbox && go build -o '"
          <> helper_path
          <> "' ./cmd/loom-exec && echo LOOM_BUILD_OK",
        )
      case string.contains(output, "LOOM_BUILD_OK") {
        False -> Error("go build failed: " <> output)
        True ->
          Ok(#(
            exec.SpawnConfig(
              helper_path:,
              shell_path: "/bin/sh",
              base_policy: base_policy(workspace),
              helper_args: [],
              tmp_dir: work_dir <> "/tmp",
              handshake_timeout_ms: 5000,
              cancel_grace_ms: 3000,
              heartbeat_interval_ms: 0,
            ),
            workspace,
          ))
      }
    }
  }
}

fn base_policy(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: ["/"],
    env_allow: ["PATH"],
  )
}

pub fn real_broker_bash_echo_test() {
  case helper_config() {
    Error(reason) -> io.println_error("SKIP real_broker_bash_echo: " <> reason)
    Ok(#(spawn_config, workspace)) ->
      case exec.spawn_helper(spawn_config) {
        Error(spawn_error) ->
          panic as { "helper failed to spawn: " <> string.inspect(spawn_error) }
        Ok(helper) -> {
          let assert Ok(broker_actor) =
            broker.start(
              broker.BrokerConfig(
                entropy: token.production_entropy(),
                clock: clock.fixed(at: 0),
                checkout: fn() { Ok(helper) },
                checkin: fn(_helper) { Nil },
              ),
            )
          let outcome = run_echo(broker_actor, workspace)
          broker.stop(broker_actor)
          exec.shutdown(helper)
          assert outcome.is_error == False as string.inspect(outcome)
          let assert [message.ToolResultText(text:, text_signature: _)] =
            outcome.content
          assert string.contains(text, "hello")
        }
      }
  }
}

pub fn real_jail_git_worktree_asks_before_outside_writes_test() {
  case shell.find_executable("git"), helper_config() {
    Error(Nil), _ -> io.println_error("SKIP git worktree: git is unavailable")
    _, Error(reason) -> io.println_error("SKIP git worktree: " <> reason)
    Ok(_git), Ok(#(spawn_config, workspace)) ->
      case exec.spawn_helper(spawn_config) {
        Error(spawn_error) ->
          panic as { "helper failed to spawn: " <> string.inspect(spawn_error) }
        Ok(helper) -> {
          case exec.status(helper, waiting: 5000) {
            exec.StatusReady(features) ->
              case
                list.any(features, fn(feature) {
                  string.starts_with(feature, "landlock:")
                  || feature == "seatbelt"
                  || string.starts_with(feature, "seatbelt-fs:")
                })
              {
                True -> exercise_git_worktree(helper, workspace)
                False ->
                  io.println_error(
                    "SKIP git worktree: helper has no filesystem enforcement",
                  )
              }
            _ ->
              io.println_error(
                "SKIP git worktree: helper has no filesystem enforcement",
              )
          }
          exec.shutdown(helper)
        }
      }
  }
}

// This pair of calls reproduces the reported failure under the real jail.
// The first call has no new authority; the second declares it and the
// approver sees the exact policy diff before Git can create either path.
fn exercise_git_worktree(helper: exec.Helper, workspace: String) -> Nil {
  let repository = workspace <> "-git-repository"
  let git_directory = repository <> "/.git"
  let destination = workspace <> "-git-linked"
  let prepared =
    shell.os_cmd(
      "rm -rf '"
      <> repository
      <> "' '"
      <> destination
      <> "' && git init -q '"
      <> repository
      <> "' && git -C '"
      <> repository
      <> "' -c user.name=Test -c user.email=test@example.invalid "
      <> "commit --allow-empty -qm base && echo LOOM_GIT_READY",
    )
  assert string.contains(prepared, "LOOM_GIT_READY") as prepared
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Ok(helper) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let command =
    "cd '"
    <> repository
    <> "' && git worktree add -b approval-e2e '"
    <> destination
    <> "'"
  let ctx = integration_context(broker_actor, workspace)
  let denied =
    bash.tool(job.unavailable()).run(
      ctx,
      json.Object([#("command", json.String(command))]),
    )
  assert denied.is_error
  let assert [message.ToolResultText(text: denied_text, text_signature: _)] =
    denied.content
  assert string.contains(denied_text, "Operation not permitted")
    || string.contains(denied_text, "Permission denied")
  let assert Error(_) = simplifile.read(destination <> "/.git")
    as "the denied Git worktree must leave no destination"

  let asked = process.new_subject()
  let approved_ctx =
    tool.Ctx(
      ..ctx,
      step_id: "integration-approved",
      raise_refusal: fn(request: tool.RaisedRefusal) {
        process.send(asked, request.denial.wanted)
        tool.Resume(request.denial.wanted)
      },
    )
  let approved =
    bash.tool(job.unavailable()).run(
      approved_ctx,
      json.Object([
        #("command", json.String(command)),
        #(
          "permissions",
          json.Object([
            #("readable_roots", json.Array([json.String(repository)])),
            #(
              "writable_roots",
              json.Array([
                json.String(git_directory),
                json.String(destination),
              ]),
            ),
          ]),
        ),
      ]),
    )
  let assert Ok(wanted) = process.receive(asked, 1000)
    as "the outside writes must ask before Git runs"
  assert list.contains(wanted, policy.GrantWritableRoot(git_directory))
  assert list.contains(wanted, policy.GrantWritableRoot(destination))
  assert approved.is_error == False as string.inspect(approved)
  let assert Ok(_git_file) = simplifile.read(destination <> "/.git")
    as "approved Git worktree must exist"
  broker.stop(broker_actor)
}

fn run_echo(
  broker_actor: broker.Broker,
  workspace: String,
) -> tool.ToolOutcome {
  let ctx = integration_context(broker_actor, workspace)
  bash.tool(job.unavailable()).run(
    ctx,
    json.Object([
      #("command", json.String("echo hello")),
      #("timeout_ms", json.Int(30_000)),
    ]),
  )
}

fn integration_context(
  broker_actor: broker.Broker,
  workspace: String,
) -> tool.Ctx {
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace:,
    op_id:,
    step_id: "integration-1",
    source_index: 0,
    strand: "main",
    base_policy: base_policy(workspace),
    grants: [],
    // No bwrap in most dev containers: accept whatever enforcement
    // the helper honestly reports.
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/local/bin:/usr/bin:/bin")],
    clock: clock.fixed(at: 0),
    filesystem: fs.real_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: tool.broker_runner(broker: broker_actor, waiting: 10_000),
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

// The events subject type is threaded through the seam; this pins the
// production adapter's shape at compile time even when the run is
// skipped.
pub fn broker_runner_shape_test() {
  let _shape: fn(broker.Broker, Int) ->
    fn(broker.CallSpec, process.Subject(broker.CallEvent)) ->
      Result(tool.RunningCall, broker.Refusal) = fn(broker_actor, waiting) {
    tool.broker_runner(broker: broker_actor, waiting:)
  }
  Nil
}
