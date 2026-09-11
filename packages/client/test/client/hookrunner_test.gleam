//// The imported-hook command runner against the real jailed executor:
//// one helper, one broker, real `sh -c` processes — the same fixture
//// shape the developer-environment test uses, trimmed to what the
//// runner needs.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/hookrunner
import host/bootstrap
import client/internal/ffi_os
import client/serve
import core/clock
import core/ids
import gleam/int
import gleam/option.{None, Some}
import simplifile

pub fn shell_form_hook_runs_and_reports_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("echo out; echo err >&2; exit 7", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 7
  assert outcome.stdout == "out\n"
  assert outcome.stderr == "err\n"
  assert !outcome.timed_out
  assert !outcome.truncated
}

pub fn stdin_reaches_the_hook_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("cat", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{\"prompt\":\"hello\"}", 30)
  assert outcome.code == 0
  assert outcome.stdout == "{\"prompt\":\"hello\"}"
}

pub fn exec_form_passes_arguments_without_a_shell_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("printf", Some(["%s %s", "a;b", "c|d"]), Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
  assert outcome.stdout == "a;b c|d"
}

pub fn a_tilde_prefix_expands_to_the_workspace_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("echo ~/x", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
  assert outcome.stdout == ctx.workspace <> "/x\n"
}

pub fn a_timed_out_hook_reports_no_output_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("echo partial; sleep 30", None, Some(1))
  let started = bootstrap.monotonic_time_ms()
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  let elapsed = bootstrap.monotonic_time_ms() - started
  assert outcome.timed_out
  assert outcome.stdout == ""
  assert outcome.stderr == ""
  assert elapsed < 20_000
}

pub fn an_absent_timeout_takes_the_events_default_test() {
  let #(ctx, _helper) = fixture()
  let cmd = hookrunner.Command("exit 0", None, None)
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.code == 0
}

pub fn the_env_allowlist_reaches_the_hook_test() {
  let #(ctx, _helper) = fixture()
  let ctx =
    hookrunner.Context(..ctx, env: [#("HOOK_MARKER", "visible"), ..ctx.env])
  let cmd = hookrunner.Command("echo $HOOK_MARKER", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.stdout == "visible\n"
}

pub fn the_env_allowlist_hides_names_the_hook_did_not_list_test() {
  let #(ctx, _helper) = fixture()
  let ctx =
    hookrunner.Context(
      ..ctx,
      env: [#("PATH", "/usr/bin:/bin"), ..delete(ctx.env, "PATH")],
    )
  let cmd = hookrunner.Command("echo ${HOOK_UNSEEN:-unset}", None, Some(3))
  let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{}", 30)
  assert outcome.stdout == "unset\n"
}

fn delete(
  pairs: List(#(String, String)),
  key: String,
) -> List(#(String, String)) {
  case pairs {
    [#(k, _), ..rest] if k == key -> delete(rest, key)
    [head, ..rest] -> [head, ..delete(rest, key)]
    [] -> []
  }
}

// One jailed fixture: a workspace, a session-shaped base policy, the
// real helper, and a broker over it — the developer-environment
// fixture's arrangement, trimmed to what the runner needs. The helper
// outlives the test the way it does there; the workspace stays in
// `build/` and is gitignored.
fn fixture() -> #(hookrunner.Context, exec.Helper) {
  let assert Ok(here) = simplifile.current_directory()
  let workspace =
    here
    <> "/build/hookrunner-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let home = serve.tool_home_directory(workspace)
  let temp = serve.tool_tmp_directory(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(home)
  let assert Ok(Nil) = simplifile.create_directory_all(temp)

  let base = serve.base_policy(workspace) |> serve.merging_mounts

  let base = policy.SandboxPolicy(..base, env_allow: ["PATH", "HOME", "TMPDIR"])
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: here <> "/../sandbox/loom-exec",
      shell_path: "/bin/sh",
      base_policy: base,
      helper_args: [],
      tmp_dir: temp,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
  let wall = clock.from_function(ffi_os.system_time_ms)
  let assert Ok(broker_actor) =
    broker.start(broker.BrokerConfig(
      entropy: token.production_entropy(),
      clock: wall,
      checkout: fn() { Ok(helper) },
      checkin: fn(_helper) { Nil },
    ))
  let #(op_id, _generator) = ids.mint_op(ids.generator(wall, seed: 20_260_911))
  #(
    hookrunner.Context(
      broker: broker_actor,
      base_policy: base,
      op_id:,
      step_id: "hookcompat-fixture",
      workspace:,
      env: serve.session_environment(workspace, None),
      demand: exec.PlatformEnforcement,
      clock: wall,
      session_id: "hookrunner-fixture",
      transcript_path: workspace <> "/session.db",
    ),
    helper,
  )
}
